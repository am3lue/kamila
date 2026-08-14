"""
test/agent_test.jl — Tests of the real `Agent` module (parse_response edge cases,
prompt builders). No mocks: `parse_response` is pure string handling and the
prompt builders only call the real `AgentTools.get_all_tools()`.
"""

using Test
using JSON
using Random

using .Kamila
const AGENT = Kamila.Agent

@testset "Agent" begin
    @testset "parse_response: standard fenced JSON" begin
        resp = "```json\n{\"tool\": \"list_directory\", \"args\": {\"path\": \".\"}}\n```"
        is_tool, name, args, thought = AGENT.parse_response(resp)
        @test is_tool == true
        @test name == "list_directory"
        @test args["path"] == "."
        @test isempty(thought)
    end

    @testset "parse_response: unlabeled fenced JSON" begin
        resp = "```\n{\"tool\": \"read_file\", \"args\": {\"file_path\": \"a.txt\"}}\n```"
        is_tool, name, args, _ = AGENT.parse_response(resp)
        @test is_tool == true
        @test name == "read_file"
        @test args["file_path"] == "a.txt"
    end

    @testset "parse_response: thought before fenced block" begin
        resp = "I should look first. ```json\n{\"tool\": \"ls\"}\n```"
        is_tool, name, args, thought = AGENT.parse_response(resp)
        @test is_tool == true
        @test name == "ls"
        @test occursin("I should look first", thought)
    end

    @testset "parse_response: trailing comma tolerated" begin
        resp = "{\"tool\": \"read_file\", \"args\": {\"file_path\": \"test.txt\"},}"
        is_tool, name, args, _ = AGENT.parse_response(resp)
        @test is_tool == true
        @test name == "read_file"
        @test args["file_path"] == "test.txt"
    end

    @testset "parse_response: trailing comma in nested object" begin
        resp = "{\"tool\": \"write_file\", \"args\": {\"file_path\": \"x.txt\", \"content\": \"hi\",},}"
        is_tool, name, args, _ = AGENT.parse_response(resp)
        @test is_tool == true
        @test name == "write_file"
        @test args["content"] == "hi"
    end

    @testset "parse_response: flat structure (no args key)" begin
        resp = "{\"tool\": \"complete_task\", \"task_id\": 123}"
        is_tool, name, args, _ = AGENT.parse_response(resp)
        @test is_tool == true
        @test name == "complete_task"
        @test args["task_id"] == 123
    end

    @testset "parse_response: nested braces in args" begin
        resp = "{\"tool\": \"write_file\", \"args\": {\"content\": \"{\\\"a\\\": 1}\"}}"
        is_tool, name, args, _ = AGENT.parse_response(resp)
        @test is_tool == true
        @test name == "write_file"
        @test args["content"] == "{\"a\": 1}"
    end

    @testset "parse_response: multiple fenced blocks (first valid wins)" begin
        resp = """
        Let me do this.
        ```json
        {"tool": "read_file", "args": {"file_path": "first.txt"}}
        ```
        Wait, actually:
        ```json
        {"tool": "list_directory", "args": {"path": "."}}
        ```
        """
        is_tool, name, args, _ = AGENT.parse_response(resp)
        @test is_tool == true
        @test name == "read_file"
        @test args["file_path"] == "first.txt"
    end

    @testset "parse_response: no JSON at all" begin
        resp = "I don't need any tools for this, just answering."
        is_tool, name, args, thought = AGENT.parse_response(resp)
        @test is_tool == false
        @test name == ""
        @test isempty(args)
        @test thought == resp
    end

    @testset "parse_response: malformed JSON" begin
        resp = "{\"tool\": \"read_file\", \"args\": {broken"
        is_tool, name, args, thought = AGENT.parse_response(resp)
        @test is_tool == false
        @test name == ""
        @test isempty(args)
    end

    @testset "parse_response: JSON with no tool key" begin
        resp = "{\"args\": {\"path\": \".\"}}"
        is_tool, name, args, _ = AGENT.parse_response(resp)
        @test is_tool == false
        @test name == ""
    end

    @testset "parse_response: alternate tool key names" begin
        for key in ["name", "function", "tool_name", "call", "command"]
            resp = "{\"$key\": \"web_search\", \"args\": {\"query\": \"x\"}}"
            is_tool, name, args, _ = AGENT.parse_response(resp)
            @test is_tool == true
            @test name == "web_search"
            @test args["query"] == "x"
        end
    end

    @testset "parse_response: alternate args key names" begin
        for key in ["arguments", "parameters", "params", "input", "props"]
            resp = "{\"tool\": \"file_find\", \"$key\": {\"pattern\": \"a\"}}"
            is_tool, name, args, _ = AGENT.parse_response(resp)
            @test is_tool == true
            @test name == "file_find"
            @test args["pattern"] == "a"
        end
    end

    @testset "parse_response: tool key not a string" begin
        resp = "{\"tool\": 123}"
        is_tool, name, args, _ = AGENT.parse_response(resp)
        @test is_tool == false
    end

    @testset "parse_response: thought extracted from JSON" begin
        resp = "{\"tool\": \"ls\", \"thought\": \"Checking the directory\", \"args\": {\"path\": \".\"}}"
        is_tool, name, args, thought = AGENT.parse_response(resp)
        @test is_tool == true
        @test name == "ls"
        @test occursin("Checking the directory", thought)
    end

    @testset "parse_response: leading/trailing whitespace" begin
        resp = "   \n{\"tool\": \"ls\", \"args\": {\"path\": \"/\"}}\n   "
        is_tool, name, args, _ = AGENT.parse_response(resp)
        @test is_tool == true
        @test name == "ls"
        @test args["path"] == "/"
    end

    @testset "parse_response: empty string" begin
        is_tool, name, args, thought = AGENT.parse_response("")
        @test is_tool == false
        @test name == ""
        @test thought == ""
    end

    @testset "parse_response: JSON only (no code fence)" begin
        resp = "{\"tool\": \"system_status\"}"
        is_tool, name, args, _ = AGENT.parse_response(resp)
        @test is_tool == true
        @test name == "system_status"
    end

    @testset "parse_response: string with both thought and fence" begin
        resp = "The output shows an error.\n```json\n{\"tool\": \"grep_search\", \"args\": {\"pattern\": \"error\", \"path\": \".\"}}\n```\nLet me check the results."
        is_tool, name, args, thought = AGENT.parse_response(resp)
        @test is_tool == true
        @test name == "grep_search"
        @test occursin("The output shows an error", thought)
        @test occursin("Let me check the results", thought)
        @test !occursin("{", thought)
    end

    @testset "parse_response: JSON.parse error inside candidate" begin
        # A fenced block that is not valid JSON followed by a valid one
        resp = "```json\n{this is not json}\n```\nAnd then: ```json\n{\"tool\": \"ls\"}\n```"
        is_tool, name, args, _ = AGENT.parse_response(resp)
        @test is_tool == true
        @test name == "ls"
    end

    @testset "parse_response: args is array (ignored)" begin
        resp = "{\"tool\": \"ls\", \"args\": [1,2,3]}"
        is_tool, name, args, _ = AGENT.parse_response(resp)
        @test is_tool == true
        @test name == "ls"
    end

    @testset "parse_response: trailing comma inside a string survives" begin
        resp = "{\"tool\": \"write_file\", \"args\": {\"file_path\": \"x.txt\", \"content\": \"hi, } and ] more\"}}"
        is_tool, name, args, _ = AGENT.parse_response(resp)
        @test is_tool == true
        @test name == "write_file"
        @test args["content"] == "hi, } and ] more"
    end

    @testset "parse_response: escaped quotes inside a string" begin
        resp = "{\"tool\": \"write_file\", \"args\": {\"content\": \"she said \\\"hi\\\" then left\"}}"
        is_tool, name, args, _ = AGENT.parse_response(resp)
        @test is_tool == true
        @test args["content"] == "she said \"hi\" then left"
    end

    @testset "parse_response: nested braces + trailing comma in string" begin
        resp = "{\"tool\": \"write_file\", \"args\": {\"content\": \"{\\\"a\\\": [1,2,]}\",},}"
        is_tool, name, args, _ = AGENT.parse_response(resp)
        @test is_tool == true
        @test name == "write_file"
        @test args["content"] == "{\"a\": [1,2,]}"
    end

    @testset "parse_response: multiple bare JSON objects (first valid wins)" begin
        resp = "{\"tool\": \"read_file\", \"args\": {\"file_path\": \"first.txt\"}} {\"tool\": \"ls\"}"
        is_tool, name, args, _ = AGENT.parse_response(resp)
        @test is_tool == true
        @test name == "read_file"
        @test args["file_path"] == "first.txt"
    end

    @testset "parse_response: JSON-only fenced returns thought from JSON key" begin
        resp = "```json\n{\"tool\": \"ls\", \"thought\": \"Only a thought\", \"args\": {\"path\": \".\"}}\n```"
        is_tool, name, args, thought = AGENT.parse_response(resp)
        @test is_tool == true
        @test name == "ls"
        @test thought == "Only a thought"
    end

    @testset "parse_response: never throws on garbage (fuzz)" begin
        # Deterministic pseudo-random strings (seeded by hand) incl. JSON-ish garbage.
        garbage = [
            "",
            "   ",
            "}",
            "{",
            "{{}}",
            "{\"tool\":}",
            "```",
            "```json\n{\"tool\": \"ls\"",
            "\"hi, then\"",
            "{\"a\": 1,} trailing",
            "noise { notjson } more",
            "{",
        ]
        for g in garbage
            is_tool, name, args, _ = AGENT.parse_response(g)
            @test is_tool isa Bool
            @test name isa String
            @test args isa AbstractDict
        end

        # 1,000 deterministic random strings (incl. JSON-ish garbage) must never throw.
        chars = ['{', '}', '[', ']', ',', '"', '\\', ':', ' ', 'a', 'b', '1', '\n', '`']
        rng = Random.MersenneTwister(42)
        for _ = 1:1000
            len = rand(rng, 0:60)
            s = String([chars[rand(rng, 1:length(chars))] for _ = 1:len])
            is_tool, name, args, _ = AGENT.parse_response(s)
            @test is_tool isa Bool
            @test name isa String
            @test args isa AbstractDict
        end
    end

    @testset "parse_response: fenced block with nested braces" begin
        resp = "```json\n{\"tool\": \"add_task\", \"args\": {\"tags\": \"a,b\", \"description\": \"{\\\"priority\\\": 1}\"}}\n```"
        is_tool, name, args, _ = AGENT.parse_response(resp)
        @test is_tool == true
        @test name == "add_task"
        @test args["description"] == "{\"priority\": 1}"
    end

    @testset "get_system_prompt lists real tools" begin
        prompt = AGENT.get_system_prompt()
        @test occursin("Kamila", prompt)
        @test occursin("run_shell_command", prompt)
        @test occursin("Available Tools", prompt)
        for tool in AGENT.AgentTools.get_all_tools()
            @test occursin(tool.name, prompt)
        end
    end

    @testset "chat/planning/testing/execution prompts" begin
        @test occursin("Kamila", AGENT.get_chat_system_prompt())
        @test occursin("planning mode", AGENT.get_planning_prompt())
        @test occursin("testing mode", AGENT.get_testing_prompt())
        @test occursin("execution mode", AGENT.get_execution_prompt())
        @test occursin("run_shell_command", AGENT.get_chat_system_prompt())
        @test occursin("tool", lowercase(AGENT.get_planning_prompt()))
    end
end
