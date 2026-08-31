"""
test/bridge_test.jl — Tests of the real `KamilaBridge` protocol handling.

The Ollama mock server is started by `test/run.jl` BEFORE `src/Kamila.jl` loads
(so `OLLAMA_HOST` is bound at module load). `run_bridge` is driven by piping
JSON requests into stdin and capturing the JSON events on stdout.

Covers: dispatch/error handling, task/memory/auth/file handlers, chat reset,
mode switching, and a full `ai.query` tool-call round trip (read_file) against
the mocked Ollama.
"""

using Test
using JSON

using .Kamila
const BR = Kamila.KamilaBridge

# ─── Helpers ──────────────────────────────────────────────

"""
Run `run_bridge` with `requests` (Vector of JSON strings) as stdin; returns the
stdout output as a single string.
"""
function run_bridge_with_input(requests::Vector{String}; read_timeout::Float64 = 10.0)
    mktemp() do out_path, out_io
        close(out_io)
        open(out_path, "w") do out_h
            mktemp() do path, io
                for r in requests
                    write(io, r * "\n")
                end
                close(io)
                open(path) do stdin_h
                    redirect_stdout(
                        () -> begin
                            redirect_stdin(
                                () -> BR.run_bridge(read_timeout = read_timeout),
                                stdin_h,
                            )
                        end,
                        out_h,
                    )
                end
            end
        end
        return read(out_path, String)
    end
end

"""
Parse each JSON line from bridge output into a Vector of Dicts (skipping blanks).
"""
function parse_bridge_output(output::String)
    events = Dict{String,Any}[]
    for line in split(output, "\n")
        isempty(strip(line)) && continue
        try
            push!(events, JSON.parse(line))
        catch
            # Skip malformed/partial lines (e.g. interrupted writes).
        end
    end
    return events
end

function find_event(events, type::String)
    return filter(e -> get(e, "type", "") == type, events)
end

function reset_bridge_chat!()
    BR.chat_messages["default"] = Vector{Dict{String,Any}}()
    BR.reset_chat_history_internal("default")
end

@testset "KamilaBridge" begin
    @testset "run_bridge emits ready and shutdown" begin
        output = run_bridge_with_input(String[])
        events = parse_bridge_output(output)
        @test any(e -> get(e, "type", "") == "ready", events)
        @test any(e -> get(e, "type", "") == "shutdown", events)
    end

    @testset "JSON logs go to stderr; stdout carries only valid protocol JSON" begin
        # With KAMILA_LOG_FORMAT=json, log traffic must never leak into the
        # protocol stream on stdout (Acceptance 01.3 #1).
        Kamila.KamilaLog.set_json_format(true)
        Kamila.KamilaLog.set_level("debug")
        try
            protocol_str, stderr_str = mktemp() do out_path, out_io
                close(out_io)
                open(out_path, "w") do out_h
                    mktemp() do err_path, err_io
                        close(err_io)
                        open(err_path, "w") do err_h
                            mktemp() do path, io
                                write(
                                    io,
                                    JSON.json(
                                        Dict(
                                            "type" => "request",
                                            "id" => "1",
                                            "method" => "memory.get_stats",
                                            "params" => Dict(),
                                        ),
                                    ) * "\n",
                                )
                                close(io)
                                open(path) do stdin_h
                                    redirect_stderr(
                                        () -> begin
                                            redirect_stdout(
                                                () -> begin
                                                    redirect_stdin(
                                                        () -> BR.run_bridge(
                                                            read_timeout = 5.0,
                                                        ),
                                                        stdin_h,
                                                    )
                                                end,
                                                out_h,
                                            )
                                        end,
                                        err_h,
                                    )
                                end
                            end
                        end
                        (read(out_path, String), read(err_path, String))
                    end
                end
            end

            # stdout: only parseable JSON protocol objects.
            protocol_lines = filter(!isempty, split(protocol_str, "\n"))
            @test !isempty(protocol_lines)
            for line in protocol_lines
                d = JSON.parse(line)
                @test haskey(d, "type")
            end

            # stderr: JSON log lines with level/origin/kind/msg fields.
            log_lines = filter(l -> startswith(l, "{"), split(stderr_str, "\n"))
            @test !isempty(log_lines)
            sample = JSON.parse(log_lines[1])
            @test haskey(sample, "level")
            @test haskey(sample, "origin")
            @test haskey(sample, "kind")
            @test haskey(sample, "msg")
        finally
            Kamila.KamilaLog.set_json_format(false)
            Kamila.KamilaLog.set_level("info")
        end
    end

    @testset "dispatch rejects non-request and unknown method" begin
        out = capture_stdout() do
            BR.dispatch(Dict("type" => "ping"))
        end
        events = parse_bridge_output(out)
        @test length(events) == 1
        @test events[1]["type"] == "error"
        @test events[1]["code"] == 400

        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "x",
                    "method" => "no.such.method",
                    "params" => Dict(),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "error"
        @test events[1]["code"] == 404
        @test occursin("Unknown method", events[1]["error"])
    end

    @testset "orchestrator.status / toggle_auto / pause routes" begin
        # Kill-switch route: turning auto on then pausing must disable execution.
        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "os1",
                    "method" => "orchestrator.toggle_auto",
                    "params" => Dict("auto_execute" => true),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "response"
        @test events[1]["result"]["auto_execute"] == true

        out = capture_stdout() do
            BR.dispatch(
                Dict("type" => "request", "id" => "os2", "method" => "orchestrator.pause", "params" => Dict()),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "response"
        @test events[1]["result"]["paused"] == true

        out = capture_stdout() do
            BR.dispatch(
                Dict("type" => "request", "id" => "os3", "method" => "orchestrator.status", "params" => Dict()),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "response"
        @test haskey(events[1]["result"], "budget")
        @test events[1]["result"]["auto_execute"] == false
        @test events[1]["result"]["interactive"] == false

        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "os4",
                    "method" => "orchestrator.advance_now",
                    "params" => Dict(),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "error"
        @test events[1]["code"] == 400
        @test occursin("plan_id", events[1]["error"])
    end

    @testset "experience.reuse / experience.search / experience.export routes" begin
        # Record an experience row, then exercise the reuse route.
        Kamila.Experience.record(
            kind = "tool",
            prompt = "install python on ubuntu",
            tool = "run_shell_command",
            result = "done",
            verified = true,
        )
        Kamila.Experience.count()

        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "ex1",
                    "method" => "experience.reuse",
                    "params" => Dict("description" => "install python"),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "response"
        @test haskey(events[1]["result"], "results")
        @test haskey(events[1]["result"], "count")

        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "ex2",
                    "method" => "experience.search",
                    "params" => Dict("query" => "install python"),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "response"
        @test haskey(events[1]["result"], "results")

        mktempdir() do dir
            path = joinpath(dir, "exp.jsonl")
            out = capture_stdout() do
                BR.dispatch(
                    Dict(
                        "type" => "request",
                        "id" => "ex3",
                        "method" => "experience.export",
                        "params" => Dict("path" => path),
                    ),
                )
            end
            events = parse_bridge_output(out)
            @test events[1]["type"] == "response"
            @test events[1]["result"]["rows"] >= 1
            @test isfile(path)
        end

        # Missing params are rejected.
        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "ex4",
                    "method" => "experience.reuse",
                    "params" => Dict(),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "error"
        @test events[1]["code"] == 400
        @test occursin("description", events[1]["error"])
    end

    @testset "feedback.record / preferences routes" begin
        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "fb1",
                    "method" => "feedback.record",
                    "params" => Dict("key" => "tone", "value" => "concise", "explicit" => true),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "response"
        @test events[1]["result"]["key"] == "tone"
        @test events[1]["result"]["value"] == "narrated"  # not enough signals yet

        # Missing params rejected.
        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "fb2",
                    "method" => "feedback.record",
                    "params" => Dict("key" => "tone"),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "error"
        @test events[1]["code"] == 400

        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "pf1",
                    "method" => "preferences.get",
                    "params" => Dict(),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "response"
        @test haskey(events[1]["result"], "preferences")
        @test haskey(events[1]["result"], "active")

        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "pf2",
                    "method" => "preferences.history",
                    "params" => Dict("key" => "tone"),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "response"
        @test length(events[1]["result"]["events"]) >= 1

        # Revert (no-op-safe even without a committed value).
        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "pf3",
                    "method" => "preferences.revert",
                    "params" => Dict("key" => "tone"),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "response"
        @test events[1]["result"]["restored"] == "narrated"
    end

    @testset "tasks.add / tasks.list / tasks.complete / tasks.delete" begin
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "1",
                    "method" => "tasks.add",
                    "params" => Dict("title" => "Bridge Task", "priority" => 3),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "response"
        @test events[1]["result"]["title"] == "Bridge Task"
        task_id = events[1]["result"]["id"]

        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "2",
                    "method" => "tasks.list",
                    "params" => Dict(),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "response"
        @test length(events[1]["result"]) == 1
        @test events[1]["result"][1]["id"] == task_id

        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "3",
                    "method" => "tasks.complete",
                    "params" => Dict("task_id" => task_id),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "response"
        @test events[1]["result"]["success"] == true

        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "4",
                    "method" => "tasks.delete",
                    "params" => Dict("task_id" => task_id),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "response"

        # tasks.add without title -> 400 error
        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "5",
                    "method" => "tasks.add",
                    "params" => Dict(),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "error"
        @test events[1]["code"] == 400
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
    end

    @testset "memory.add_goal / memory.goals / memory.complete_goal" begin
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "1",
                    "method" => "memory.add_goal",
                    "params" =>
                        Dict("goal" => "Ship test infra", "category" => "coding"),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "response"
        @test events[1]["result"]["success"] == true

        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "2",
                    "method" => "memory.goals",
                    "params" => Dict(),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "response"
        @test length(events[1]["result"]) == 1
        @test events[1]["result"][1]["goal"] == "Ship test infra"
        goal_id = events[1]["result"][1]["id"]

        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "3",
                    "method" => "memory.complete_goal",
                    "params" => Dict("goal_id" => goal_id),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "response"
        @test events[1]["result"]["success"] == true
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
    end

    @testset "auth.setup / auth.verify / auth.status / auth.reset" begin
        cfg = TEST_SANDBOX[]["config_file"]
        isfile(cfg) && rm(cfg; force = true)
        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "1",
                    "method" => "auth.setup",
                    "params" => Dict("password" => "bridgepass"),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "response"
        @test events[1]["result"]["success"] == true

        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "2",
                    "method" => "auth.verify",
                    "params" => Dict("password" => "bridgepass"),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["result"]["valid"] == true

        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "3",
                    "method" => "auth.status",
                    "params" => Dict(),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["result"]["configured"] == true

        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "4",
                    "method" => "auth.reset",
                    "params" => Dict(),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["result"]["success"] == true
        isfile(cfg) && rm(cfg; force = true)
    end

    @testset "file.list within sandbox" begin
        allowed = TEST_SANDBOX[]["allowed"]
        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "1",
                    "method" => "file.list",
                    "params" => Dict("path" => allowed),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "response"
        names = [e["name"] for e in events[1]["result"]]
        @test "hello.txt" in names

        # Outside allowed dir -> 403 error
        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "2",
                    "method" => "file.list",
                    "params" => Dict("path" => "/etc"),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "error"
        @test events[1]["code"] == 403
    end

    @testset "mode.get / mode.set" begin
        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "1",
                    "method" => "mode.get",
                    "params" => Dict(),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["result"]["mode"] == "chat"

        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "2",
                    "method" => "mode.set",
                    "params" => Dict("mode" => "plan"),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["result"]["success"] == true
        @test events[1]["result"]["mode"] == "plan"

        # invalid mode
        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "3",
                    "method" => "mode.set",
                    "params" => Dict("mode" => "nope"),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "error"
        @test events[1]["code"] == 400

        # reset mode back to chat for later tests
        BR.ACTIVE_MODE[] = "chat"
    end

    @testset "chat.reset" begin
        reset_bridge_chat!()
        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "1",
                    "method" => "chat.reset",
                    "params" => Dict(),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "response"
        @test events[1]["result"]["success"] == true
    end

    @testset "chat.history" begin
        reset_bridge_chat!()
        # Seed the session history directly, then request it back.
        hist = BR.get_chat_history("default")
        push!(hist, Dict("role" => "user", "content" => "first", "session_id" => 0))
        push!(hist, Dict("role" => "assistant", "content" => "answer", "session_id" => 0))

        out = capture_stdout() do
            BR.dispatch(
                Dict(
                    "type" => "request",
                    "id" => "h1",
                    "method" => "chat.history",
                    "params" => Dict("session" => "default"),
                ),
            )
        end
        events = parse_bridge_output(out)
        @test events[1]["type"] == "response"
        @test events[1]["result"]["session"] == "default"
        msgs = events[1]["result"]["messages"]
        @test length(msgs) == 2
        @test msgs[1]["role"] == "user"
        @test msgs[1]["content"] == "first"
        @test msgs[2]["role"] == "assistant"
        @test msgs[2]["content"] == "answer"

        reset_bridge_chat!()
    end

    @testset "ai.query tool-call round trip (read_file)" begin
        reset_bridge_chat!()
        allowed = TEST_SANDBOX[]["allowed"]
        file_path = joinpath(allowed, "hello.txt")
        write(file_path, "Hello from bridge round trip!")

        mock = TEST_SANDBOX[]["mock_server"]
        OllamaMockServer.reset_chat_request_count!(mock)
        tool_call_json = "{\"tool\": \"read_file\", \"args\": {\"file_path\": \"$file_path\"}}"
        OllamaMockServer.set_chat_scripts!(
            mock,
            [
                [
                    OllamaMockServer.chat_line(
                        content = "Reading the file now. $tool_call_json",
                        done = true,
                    ),
                ],
                [
                    OllamaMockServer.chat_line(
                        content = "The file says: Hello from bridge round trip!",
                        done = true,
                    ),
                ],
            ],
        )

        output = run_bridge_with_input(
            [
                JSON.json(
                    Dict(
                        "type" => "request",
                        "id" => "ai1",
                        "method" => "ai.query",
                        "params" => Dict("prompt" => "read the file", "mode" => "chat"),
                    ),
                ),
            ];
            read_timeout = 10.0,
        )

        events = parse_bridge_output(output)

        # 1. tool_call event for read_file
        tool_calls = find_event(events, "tool_call")
        @test length(tool_calls) == 1
        @test tool_calls[1]["name"] == "read_file"
        @test tool_calls[1]["args"]["file_path"] == file_path

        # 2. tool_result event that actually read the file content
        tool_results = find_event(events, "tool_result")
        @test length(tool_results) == 1
        @test tool_results[1]["name"] == "read_file"
        @test occursin("Hello from bridge round trip", tool_results[1]["result"])

        # 3. final stream chunk carries the second model response
        stream_events = find_event(events, "stream")
        stream_text = join([e["chunk"] for e in stream_events], "")
        @test occursin("The file says: Hello from bridge round trip", stream_text)

        # 4. stream_end event present
        @test length(find_event(events, "stream_end")) == 1

        # 5. chat history persisted to disk with the exchange
        @test isfile(TEST_SANDBOX[]["chat_file"])
        history_data = JSON.parsefile(TEST_SANDBOX[]["chat_file"])
        default_msgs = get(history_data, "default", [])
        @test length(default_msgs) >= 2
        @test default_msgs[1]["role"] == "user"
        @test occursin("read the file", default_msgs[1]["content"])
    end

    @testset "ai.query system prompt carries labeled context blocks" begin
        reset_bridge_chat!()
        # Seed a pending task so the TaskProvider contributes a labeled block.
        Kamila.TaskManager.add_task("Bridge context injection milestone"; priority = 4)

        mock = TEST_SANDBOX[]["mock_server"]
        OllamaMockServer.reset_chat_request_count!(mock)
        OllamaMockServer.set_chat_scripts!(
            mock,
            [
                [
                    OllamaMockServer.chat_line(
                        content = "understood, will handle the milestone",
                        done = true,
                    ),
                ],
            ],
        )

        output = run_bridge_with_input(
            [
                JSON.json(
                    Dict(
                        "type" => "request",
                        "id" => "aictx",
                        "method" => "ai.query",
                        "params" => Dict(
                            "prompt" => "summarize the context injection work",
                            "mode" => "chat",
                        ),
                    ),
                ),
            ];
            read_timeout = 10.0,
        )

        events = parse_bridge_output(output)
        @test isempty(find_event(events, "error"))
        @test length(find_event(events, "stream_end")) == 1

        # The system prompt actually sent to the model must contain the
        # provenance-labeled context block (not a raw task dump).
        sent = OllamaMockServer.last_chat_request(mock)
        @test !isempty(sent)
        @test occursin("## Injected Context", sent)
        @test occursin("# [memory:", sent)
        @test occursin("pending-tasks", sent)
        @test occursin("Bridge context injection milestone", sent)
    end

    @testset "ai.query with DB-style history (Int idx) does not MethodError" begin
        reset_bridge_chat!()
        # "idx" field. Appending these into the system+user message vector used
        # to trigger convert(String, Int) == MethodError on the first query.
        BR.chat_messages["default"] = [
            Dict{String,Any}(
                "role" => "user",
                "content" => "prior message",
                "idx" => 1,
                "created_at" => "2026-01-01T00:00:00",
            ),
        ]

        mock = TEST_SANDBOX[]["mock_server"]
        OllamaMockServer.reset_chat_request_count!(mock)
        OllamaMockServer.set_chat_scripts!(
            mock,
            [
                [
                    OllamaMockServer.chat_line(
                        content = "hello after prior message",
                        done = true,
                    ),
                ],
            ],
        )

        output = run_bridge_with_input(
            [
                JSON.json(
                    Dict(
                        "type" => "request",
                        "id" => "ai3",
                        "method" => "ai.query",
                        "params" => Dict("prompt" => "hi", "mode" => "chat"),
                    ),
                ),
            ];
            read_timeout = 10.0,
        )

        events = parse_bridge_output(output)
        # No error event (would be "AI query failed: MethodError(...)")
        @test isempty(find_event(events, "error"))
        # Normal completion
        @test length(find_event(events, "stream_end")) == 1
        stream_text = join([e["chunk"] for e in find_event(events, "stream")], "")
        @test occursin("hello after prior message", stream_text)
    end

    @testset "ai.query missing prompt -> 400" begin
        reset_bridge_chat!()
        output = run_bridge_with_input([
            JSON.json(
                Dict(
                    "type" => "request",
                    "id" => "ai2",
                    "method" => "ai.query",
                    "params" => Dict(),
                ),
            ),
        ])
        events = parse_bridge_output(output)
        errors = find_event(events, "error")
        @test length(errors) == 1
        @test errors[1]["code"] == 400
        @test occursin("prompt is required", errors[1]["error"])
    end

    @testset "ai.query run_shell_command confirm round-trip" begin
        reset_bridge_chat!()
        mock = TEST_SANDBOX[]["mock_server"]
        OllamaMockServer.reset_chat_request_count!(mock)
        tool_call_json = "{\"tool\": \"run_shell_command\", \"args\": {\"command\": \"echo confirm-roundtrip-ok\"}}"
        OllamaMockServer.set_chat_scripts!(
            mock,
            [
                [
                    OllamaMockServer.chat_line(
                        content = "Running the command now. $tool_call_json",
                        done = true,
                    ),
                ],
                [
                    OllamaMockServer.chat_line(
                        content = "The command output was: confirm-roundtrip-ok",
                        done = true,
                    ),
                ],
            ],
        )

        # Drive the bridge over real pipes so the confirm_response can arrive
        # only AFTER the confirm_request event is emitted (a pre-written stdin
        # buffer can't express that ordering).
        in_r = Base.PipeEndpoint()
        in_w = Base.PipeEndpoint()
        Base.link_pipe!(in_r, true, in_w, true)
        out_r = Base.PipeEndpoint()
        out_w = Base.PipeEndpoint()
        Base.link_pipe!(out_r, true, out_w, true)

        bridge_task = @async redirect_stdin(in_r) do
            redirect_stdout(out_w) do
                BR.run_bridge(read_timeout = 15.0)
            end
        end

        # Read from the bridge until stream_end, answering the confirm request.
        events = Dict{String,Any}[]
        confirm_id = nothing
        got_confirm = false
        got_tool_result = false
        got_stream_end = false
        watchdog = Timer(20.0) do tm
            try
                close(out_r)
            catch
            end
        end
        try
            write(
                in_w,
                JSON.json(
                    Dict(
                        "type" => "request",
                        "id" => "cf1",
                        "method" => "ai.query",
                        "params" => Dict("prompt" => "run echo", "mode" => "chat"),
                    ),
                ) * "\n",
            )
            flush(in_w)

            while !got_stream_end
                line = readline(out_r)
                isempty(strip(line)) && break
                event = JSON.parse(line)
                push!(events, event)
                if get(event, "type", "") == "confirm_request"
                    got_confirm = true
                    confirm_id = event["id"]
                    @test event["command"] == "echo confirm-roundtrip-ok"
                    # The modal shows which rule fired (:ask under default_action).
                    @test event["rule"] == "default"
                    # TUI responds with allow=true
                    write(
                        in_w,
                        JSON.json(
                            Dict(
                                "type" => "confirm_response",
                                "id" => confirm_id,
                                "allow" => true,
                            ),
                        ) * "\n",
                    )
                    flush(in_w)
                elseif get(event, "type", "") == "tool_result"
                    got_tool_result = true
                elseif get(event, "type", "") == "stream_end"
                    got_stream_end = true
                end
            end
        finally
            close(watchdog)
            try
                close(in_w)
            catch
            end
        end
        wait(bridge_task)
        try
            close(out_w)
        catch
        end

        @test got_confirm
        @test confirm_id !== nothing
        @test got_tool_result
        @test got_stream_end

        tool_results = find_event(events, "tool_result")
        @test length(tool_results) == 1
        @test occursin("confirm-roundtrip-ok", tool_results[1]["result"])

        # Protocol stayed intact: every event parsed as JSON above.
        @test length(events) > 0
    end

    @testset "ai.query run_shell_command confirm timeout -> deny" begin
        reset_bridge_chat!()
        mock = TEST_SANDBOX[]["mock_server"]
        OllamaMockServer.reset_chat_request_count!(mock)
        tool_call_json = "{\"tool\": \"run_shell_command\", \"args\": {\"command\": \"echo never-approved\"}}"
        OllamaMockServer.set_chat_scripts!(
            mock,
            [
                [
                    OllamaMockServer.chat_line(
                        content = "Run this please. $tool_call_json",
                        done = true,
                    ),
                ],
                [OllamaMockServer.chat_line(content = "Done.", done = true)],
            ],
        )

        old_timeout = Kamila.Confirm._TIMEOUT_SECONDS[]
        Kamila.Confirm.set_timeout_seconds(1.0)
        try
            # The tool handler needs to find a running bridge backend; drive the
            # confirm_request but never answer, so it must time out to deny.
            in_r = Base.PipeEndpoint()
            in_w = Base.PipeEndpoint()
            Base.link_pipe!(in_r, true, in_w, true)
            out_r = Base.PipeEndpoint()
            out_w = Base.PipeEndpoint()
            Base.link_pipe!(out_r, true, out_w, true)

            bridge_task = @async redirect_stdin(in_r) do
                redirect_stdout(out_w) do
                    BR.run_bridge(read_timeout = 15.0)
                end
            end

            events = Dict{String,Any}[]
            got_confirm = false
            got_stream_end = false
            watchdog = Timer(20.0) do tm
                try
                    close(out_r)
                catch
                end
            end
            try
                write(
                    in_w,
                    JSON.json(
                        Dict(
                            "type" => "request",
                            "id" => "cf2",
                            "method" => "ai.query",
                            "params" => Dict("prompt" => "run echo", "mode" => "chat"),
                        ),
                    ) * "\n",
                )
                flush(in_w)

                while !got_stream_end
                    line = readline(out_r)
                    isempty(strip(line)) && break
                    event = JSON.parse(line)
                    push!(events, event)
                    if get(event, "type", "") == "confirm_request"
                        got_confirm = true
                        # intentionally do NOT answer -> times out to deny
                    elseif get(event, "type", "") == "tool_result"
                        # nothing
                    elseif get(event, "type", "") == "stream_end"
                        got_stream_end = true
                    end
                end
            finally
                close(watchdog)
                try
                    close(in_w)
                catch
                end
            end
            wait(bridge_task)
            try
                close(out_w)
            catch
            end

            @test got_confirm
            @test got_stream_end
            tool_results = find_event(events, "tool_result")
            @test length(tool_results) == 1
            @test occursin("denied", lowercase(tool_results[1]["result"]))
        finally
            Kamila.Confirm.set_timeout_seconds(old_timeout)
        end
    end

    @testset "system.status tolerates null cpu (unavailable telemetry)" begin
        # Reset the CPU baseline so the first sample reports unavailable (null),
        # then confirm the bridge still emits a well-formed status payload.
        Kamila.SystemMonitor.reset_cpu_baseline()
        output = run_bridge_with_input([
            JSON.json(
                Dict(
                    "type" => "request",
                    "id" => "st1",
                    "method" => "system.status",
                    "params" => Dict(),
                ),
            ),
        ])
        events = parse_bridge_output(output)
        responses = find_event(events, "response")
        @test length(responses) == 1
        @test haskey(responses[1]["result"], "cpu")
        @test haskey(responses[1]["result"]["cpu"], "usage_percent")
        # Either a real measured value or explicit null — never a fabricated number.
        val = responses[1]["result"]["cpu"]["usage_percent"]
        @test val === nothing || val isa Number
        # system.latency must serialize `nothing` as JSON null (not -1).
        lat_out = run_bridge_with_input([
            JSON.json(
                Dict(
                    "type" => "request",
                    "id" => "lt1",
                    "method" => "system.latency",
                    "params" => Dict(),
                ),
            ),
        ])
        lat_events = parse_bridge_output(lat_out)
        lat_resp = find_event(lat_events, "response")
        @test length(lat_resp) == 1
        @test haskey(lat_resp[1]["result"], "internet_ms")
        @test lat_resp[1]["result"]["internet_ms"] === nothing ||
              lat_resp[1]["result"]["internet_ms"] isa Number
    end

    @testset "plan.create / plan.list / plan.status / plan.cancel / plan.resume" begin
        old_db = get(ENV, "KAMILA_DB", nothing)
        ENV["KAMILA_DB"] = ":memory:"
        try
            Kamila.MemoryDB.reset!()

            out = capture_stdout() do
                BR.dispatch(
                    Dict(
                        "type" => "request",
                        "id" => "p1",
                        "method" => "plan.create",
                        "params" => Dict(
                            "goal" => "deploy the service",
                            "session" => "default",
                            "steps" => [
                                Dict("description" => "build", "depends_on" => Int[], "tool" => "run_shell_command", "args" => Dict("command" => "true")),
                                Dict("description" => "test", "depends_on" => Int[1], "tool" => "run_shell_command", "args" => Dict("command" => "true")),
                            ],
                        ),
                    ),
                )
            end
            events = parse_bridge_output(out)
            @test events[1]["type"] == "response"
            plan_id = events[1]["result"]["id"]
            @test events[1]["result"]["status"] == "created"
            @test events[1]["result"]["step_count"] == 2

            out = capture_stdout() do
                BR.dispatch(
                    Dict(
                        "type" => "request",
                        "id" => "p2",
                        "method" => "plan.list",
                        "params" => Dict(),
                    ),
                )
            end
            events = parse_bridge_output(out)
            @test events[1]["type"] == "response"
            @test length(events[1]["result"]) == 1
            @test events[1]["result"][1]["id"] == plan_id

            out = capture_stdout() do
                BR.dispatch(
                    Dict(
                        "type" => "request",
                        "id" => "p3",
                        "method" => "plan.status",
                        "params" => Dict("id" => plan_id),
                    ),
                )
            end
            events = parse_bridge_output(out)
            @test events[1]["type"] == "response"
            @test events[1]["result"]["status"] == "created"
            @test length(events[1]["result"]["steps"]) == 2
            @test events[1]["result"]["steps"][1]["status"] == "pending"

            out = capture_stdout() do
                BR.dispatch(
                    Dict(
                        "type" => "request",
                        "id" => "p4",
                        "method" => "plan.resume",
                        "params" => Dict("id" => plan_id),
                    ),
                )
            end
            events = parse_bridge_output(out)
            @test events[1]["type"] == "response"
            @test events[1]["result"]["status"] == "active"

            out = capture_stdout() do
                BR.dispatch(
                    Dict(
                        "type" => "request",
                        "id" => "p5",
                        "method" => "plan.cancel",
                        "params" => Dict("id" => plan_id),
                    ),
                )
            end
            events = parse_bridge_output(out)
            @test events[1]["type"] == "response"
            @test events[1]["result"]["status"] == "cancelled"

            # Unknown plan -> 404 error, not a crash.
            out = capture_stdout() do
                BR.dispatch(
                    Dict(
                        "type" => "request",
                        "id" => "p6",
                        "method" => "plan.status",
                        "params" => Dict("id" => "nope"),
                    ),
                )
            end
            events = parse_bridge_output(out)
            @test events[1]["type"] == "error"
            @test events[1]["code"] == 404

            # Invalid plan (cycle) -> 400 error.
            out = capture_stdout() do
                BR.dispatch(
                    Dict(
                        "type" => "request",
                        "id" => "p7",
                        "method" => "plan.create",
                        "params" => Dict(
                            "goal" => "bad",
                            "steps" => [
                                Dict("description" => "a", "depends_on" => Int[2], "tool" => "", "args" => Dict()),
                                Dict("description" => "b", "depends_on" => Int[1], "tool" => "", "args" => Dict()),
                            ],
                        ),
                    ),
                )
            end
            events = parse_bridge_output(out)
            @test events[1]["type"] == "error"
            @test events[1]["code"] == 400
        finally
            Kamila.MemoryDB.reset!()
            old_db === nothing ? delete!(ENV, "KAMILA_DB") : ENV["KAMILA_DB"] = old_db
        end
    end
end
