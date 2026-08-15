"""
test/tool_spec_test.jl — Tests for native function calling (05.1): JSON-schema
derivation from Tool parameters, argument validation, validated execution with
:validation results, native tool_calls parsing via the mock Ollama chat server,
the text-parse fallback path, capability detection, and system prompt trimming.
"""

using Test
using JSON

using .Kamila
const TS = Kamila.ToolSpec
const AT = Kamila.AgentTools
const MR = Kamila.ModelRouter
const OI = Kamila.OllamaInterface
const AGS = Kamila.AgentStream
const AGENT = Kamila.Agent
const AGENTSTREAM = Kamila.AgentStream

using .OllamaMockServer

const MOCK = TEST_SANDBOX[]["mock_server"]

# Auto-approve the echo commands used by the loop tests so `run_shell_command`
# never blocks on an interactive confirmation prompt.
function with_allowlist(f::Function)
    file = joinpath(homedir(), ".kamila_allowlist.json")
    write(file, JSON.json(Dict("commands" => ["echo kamila_native_05_1", "echo fallback_05_1"])))
    try
        f()
    finally
        isfile(file) && rm(file, force = true)
    end
end

@testset "ToolSpec" begin
    @testset "schema derivation" begin
        tool = first(filter(t -> t.name == "run_shell_command", AT.get_all_tools()))
        @test tool !== nothing
        schema = TS.to_json_schema(tool)
        @test schema["type"] == "object"
        @test haskey(schema, "properties")
        @test haskey(schema["properties"], "command")
        @test schema["properties"]["command"]["type"] == "string"

        specs = TS.get_tool_specs()
        @test length(specs) == length(AT.get_all_tools())
        @test all(s -> s.name isa String, specs)

        payload = TS.to_payload(first(specs))
        @test payload["type"] == "function"
        @test haskey(payload["function"], "name")
        @test haskey(payload["function"], "parameters")
    end

    @testset "argument validation" begin
        schema = Dict{String,Any}(
            "type" => "object",
            "properties" => Dict{String,Any}(
                "command" => Dict{String,Any}("type" => "string"),
                "max_results" => Dict{String,Any}("type" => "integer"),
            ),
            "required" => ["command"],
        )
        ok, errors = TS.validate_args(schema, Dict("command" => "ls"))
        @test ok
        @test isempty(errors)

        ok, errors = TS.validate_args(schema, Dict("max_results" => 5))
        @test !ok
        @test any(e -> occursin("missing required argument: command", e), errors)

        ok, errors = TS.validate_args(schema, Dict("command" => "ls", "max_results" => "five"))
        @test !ok
        @test any(e -> occursin("expected integer", e), errors)
    end

    @testset "validated execution produces :validation results" begin
        # Use a real tool spec so a schema mismatch is testable.
        spec = first(filter(s -> s.name == "read_file", TS.get_tool_specs()))
        # read_file requires file_path; a bad type should fail cleanly.
        bad = Dict{String,Any}("file_path" => 123)
        result = TS.execute_tool_validated("read_file", bad, spec)
        @test !result["ok"]
        @test result["category"] == "validation"
        @test result["retryable"]
    end

    @testset "capability detection" begin
        @test TS.supports_native_tools("kamila1") == false
        @test TS.supports_native_tools("gpt-oss", ["tools"]) == true
        @test TS.supports_native_tools("gpt-oss", ["embedding"]) == false
    end

    @testset "system prompt lists names, not full param dumps" begin
        prompt = AGENT.get_system_prompt()
        for tool in AT.get_all_tools()
            @test occursin(tool.name, prompt)
        end
        @test occursin("Available Tools", prompt)
        # The prompt must not contain the full JSON parameter dump (criterion 5).
        @test !occursin("\"parameters\"", prompt)
    end
end

@testset "Native tool_calls end-to-end" begin
    @testset "chat stream parses native tool_calls" begin
        OllamaMockServer.set_script!(
            MOCK;
            chat_lines = [
                OllamaMockServer.chat_line_tool_call(
                    name = "run_shell_command",
                    arguments = Dict("command" => "echo hi"),
                ),
            ],
        )
        messages = [Dict("role" => "user", "content" => "run a command")]
        items = collect(OI.query_ollama_chat_stream(messages; tools = []))
        calls = [it.tool_calls for it in items if !isempty(it.tool_calls)]
        @test length(calls) == 1
        @test calls[1][1]["name"] == "run_shell_command"
        @test calls[1][1]["arguments"]["command"] == "echo hi"
    end

    @testset "chat stream sends the tools array" begin
        OllamaMockServer.set_script!(
            MOCK;
            chat_lines = [OllamaMockServer.chat_line(content = "ok", done = true)],
        )
        spec_payloads = [TS.to_payload(s) for s in TS.get_tool_specs()]
        collect(
            OI.query_ollama_chat_stream(
                [Dict("role" => "user", "content" => "hi")],
                tools = spec_payloads,
            ),
        )
        @test OllamaMockServer.last_chat_has_tools(MOCK)
    end

    @testset "native agent loop executes validated tool" begin
        with_allowlist() do
            OllamaMockServer.reset_chat_request_count!(MOCK)
            OllamaMockServer.set_chat_scripts!(
                MOCK,
                [
                    [
                        OllamaMockServer.chat_line_tool_call(
                            name = "run_shell_command",
                            arguments = Dict("command" => "echo kamila_native_05_1"),
                        ),
                    ],
                    [OllamaMockServer.chat_line(content = "done.", done = true)],
                ],
            )
            events = collect(
                AGS.run_agent_stream_native("say hello"; model = "kamila1"),
            )
            names = [typeof(e).name.wrapper for e in events]
            @test AGENTSTREAM.ToolCallEvent in names
            @test AGENTSTREAM.ToolResultEvent in names
            result = first(filter(e -> e isa AGENTSTREAM.ToolResultEvent, events))
            @test occursin("kamila_native_05_1", result.result)
        end
    end

    @testset "text-parse fallback path" begin
        with_allowlist() do
            # Model returns plain JSON text; loop must still execute the tool.
            OllamaMockServer.set_script!(
                MOCK;
                chat_lines = [
                    OllamaMockServer.chat_line(
                        content = "{\"tool\": \"run_shell_command\", \"args\": {\"command\": \"echo fallback_05_1\"}}",
                        done = true,
                    ),
                ],
            )
            events = collect(
                AGS.run_agent_stream_native("say hello"; model = "kamila1"),
            )
            results = [e for e in events if e isa AGENTSTREAM.ToolResultEvent]
            @test !isempty(results)
            @test occursin("fallback_05_1", results[1].result)
        end
    end
end