"""
test/tools_test.jl — Tests of the real `AgentTools` implementation.

`tools.jl` is loaded into a test-side namespace (`TestToolsEnv`) that binds the
REAL production modules (`FileAccess`, `KamilaMemory`, `TaskManager`,
`SystemMonitor`) and mocks only the external seam (`HTTP` for web_search).
Everything else runs against the actual `src/ai/tools.jl` code.
"""

using Test
using JSON
using Dates

using .Kamila

# ─── Test environment: real modules + mocked external HTTP seam ─────────────
module TestToolsEnv
using Test

# Real production modules (loaded via src/Kamila.jl in the sandbox).
const FileAccess = Main.Kamila.FileAccess
const KamilaMemory = Main.Kamila.KamilaMemory
const TaskManager = Main.Kamila.TaskManager
const SystemMonitor = Main.Kamila.SystemMonitor
const OllamaInterface = Main.Kamila.OllamaInterface
const KamilaLog = Main.Kamila.KamilaLog
const Errors = Main.Kamila.Errors
const ModelRouter = Main.Kamila.ModelRouter
const Confirm = Main.Kamila.Confirm
const Permission = Main.Kamila.Permission
const Capability = Main.Kamila.Capability
const Decompose = Main.Kamila.Decompose
const Search = Main.Kamila.Search
const MemoryDB = Main.Kamila.MemoryDB
const Episodic = Main.Kamila.Episodic
const Context = Main.Kamila.Context
const Scheduler = Main.Kamila.Scheduler
const Experience = Main.Kamila.Experience
const Vision = Main.Kamila.Vision
const STT = Main.Kamila.STT
const DesktopContext = Main.Kamila.DesktopContext
const Screenshot = Main.Kamila.Screenshot

# Mock HTTP — the only external seam. Production shape kept identical:
# `escapeuri` + `get` return a MockResponse with `.body::Vector{UInt8}`.
module HTTP
const canned_body = Ref("")

function escapeuri(s::AbstractString)
    return replace(String(s), " " => "+")
end

struct MockResponse
    status::Int
    body::Vector{UInt8}
end
MockResponse(s::Int, b::String) = MockResponse(s, Vector{UInt8}(b))

function get(url::String; headers = Dict(), readtimeout = 15)
    return MockResponse(200, canned_body[])
end
end

# Load the real tool implementations into this namespace.
include(joinpath(dirname(@__DIR__), "src", "ai", "tools.jl"))
end

const AT = TestToolsEnv.AgentTools

"""
Run `f` with `input` fed to stdin, restoring the original stdin afterwards.
"""
function with_test_stdin(f::Function, input::AbstractString)
    mktemp() do path, io
        write(io, input)
        close(io)
        open(path) do h
            redirect_stdin(() -> f(), h)
        end
    end
end

# Common sandbox fixture: write a couple of files in the allowed dir.
# Installs a permissive policy (write_file/set_reminder allowed) so legacy tool
# tests keep working; dangerous shell patterns stay denied.
function with_test_policy(f::Function, policy::AbstractDict)
    P = Main.Kamila.Permission
    old_file = P.POLICY_FILE[]
    policy_path = joinpath(TEST_SANDBOX[]["root"], "test_policy.json")
    P.POLICY_FILE[] = policy_path
    try
        @assert P.set_policy(policy) "set_policy failed"
        P.clear_session_cache()
        P.clear_policy_cache()
        f()
    finally
        P.POLICY_FILE[] = old_file
        P.clear_session_cache()
        P.clear_policy_cache()
    end
end

function permissive_tool_policy()
    Dict(
        "version" => 1,
        "rules" => [
            Dict(
                "tool" => "run_shell_command",
                "match" => "ls|cat|pwd",
                "action" => "allow",
                "scope" => "pattern",
            ),
            Dict(
                "tool" => "run_shell_command",
                "match" => "rm|mv|shutdown|reboot|mkfs|sudo",
                "action" => "deny",
                "scope" => "pattern",
            ),
            Dict(
                "tool" => "write_file",
                "match" => "*",
                "action" => "allow",
                "scope" => "tool",
            ),
            Dict(
                "tool" => "set_reminder",
                "match" => "*",
                "action" => "allow",
                "scope" => "tool",
            ),
        ],
        "default_action" => "ask",
        "session_remember" => true,
        "max_asks_per_session" => 20,
    )
end

function with_tool_sandbox(f::Function)
    with_test_policy(permissive_tool_policy()) do
        allowed = TEST_SANDBOX[]["allowed"]
        write(joinpath(allowed, "hello.txt"), "hello world\nline two\n")
        write(joinpath(allowed, "notes.jl"), "module X\nend\n")
        mkpath(joinpath(allowed, "subdir"))
        write(joinpath(allowed, "subdir", "nested.md"), "nested file")
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
        try
            f(allowed)
        finally
            reset_memory_file!(TEST_SANDBOX[]["memory_file"])
        end
    end
end

@testset "AgentTools" begin
    @testset "Discovery: tools" begin
        tools = AT.get_all_tools()
        @test length(tools) == 19
        names = [t.name for t in tools]
        for expected in [
            "run_shell_command",
            "list_directory",
            "read_file",
            "write_file",
            "add_task",
            "list_tasks",
            "complete_task",
            "web_search",
            "file_find",
            "grep_search",
            "system_status",
            "set_reminder",
            "memory_query",
            "decompose_goal",
            "reuse_solution",
            "vision",
            "transcribe_audio",
            "desktop_status",
            "screenshot_describe",
        ]
            @test expected in names
        end
        @test all(t -> t isa AT.Tool, tools)
        @test all(t -> t.name != "" && t.description != "", tools)
    end

    @testset "get_filtered_tools categories" begin
        all_tools = AT.get_all_tools()
        @test length(AT.get_filtered_tools("all")) == 19
        plan_names = [t.name for t in AT.get_filtered_tools("plan")]
        @test "add_task" in plan_names
        @test "list_directory" in plan_names
        test_names = [t.name for t in AT.get_filtered_tools("test")]
        @test "grep_search" in test_names
        execute_names = [t.name for t in AT.get_filtered_tools("execute")]
        @test "run_shell_command" in execute_names
        @test "write_file" in execute_names
    end

    @testset "execute_tool normalization" begin
        @test occursin("not found", AT.execute_tool("no_such_tool", Dict()))
        @test AT.normalize_tool_name("ls") == "list_directory"
        @test AT.normalize_tool_name("grep") == "grep_search"
        @test AT.normalize_tool_name("memory") == "memory_query"
        @test AT.normalize_tool_name("unknown") === nothing
        # Alias typos produce a suggestion, never a silent wrong-tool call.
        typo = AT.execute_tool("lisdirectory", Dict())
        @test occursin("not found", typo)
        @test occursin("Did you mean 'list_directory'?", typo)
    end

    @testset "read_file / write_file" begin
        with_tool_sandbox() do allowed
            f = joinpath(allowed, "test.txt")
            res =
                AT.execute_tool("write_file", Dict("file_path" => f, "content" => "abc123"))
            @test occursin("Successfully wrote", res)
            @test isfile(f)
            @test read(f, String) == "abc123"

            res = AT.execute_tool("read_file", Dict("file_path" => f))
            @test occursin("abc123", res)
            @test occursin("test.txt", res)

            # append mode
            res = AT.execute_tool(
                "write_file",
                Dict("file_path" => f, "content" => "def", "append" => true),
            )
            @test occursin("Successfully appended", res)
            @test read(f, String) == "abc123def"

            # backup mode
            res = AT.execute_tool(
                "write_file",
                Dict("file_path" => f, "content" => "new", "create_backup" => true),
            )
            @test isfile(f * ".bak")
            @test read(f * ".bak", String) == "abc123def"

            # missing file_path
            @test occursin("Error", AT.execute_tool("write_file", Dict()))
            @test occursin("Error", AT.execute_tool("read_file", Dict()))

            # path outside allowed dir is denied by the real FileAccess
            @test occursin(
                "Error",
                AT.execute_tool("read_file", Dict("file_path" => "/etc/passwd")),
            )
        end
    end

    @testset "read_file line ranges" begin
        with_tool_sandbox() do allowed
            f = joinpath(allowed, "lines.txt")
            write(f, join(["line $i" for i = 1:20], "\n"))
            res = AT.execute_tool(
                "read_file",
                Dict("file_path" => f, "start_line" => 2, "end_line" => 4),
            )
            @test occursin("line 2", res)
            @test occursin("line 4", res)
            @test !occursin("line 5", res)

            res = AT.execute_tool("read_file", Dict("file_path" => f, "start_line" => 18))
            @test occursin("line 18", res)
            @test occursin("line 20", res)

            res = AT.execute_tool("read_file", Dict("file_path" => f, "max_bytes" => 10))
            @test length(res) < length(read(f, String))
        end
    end

    @testset "list_directory" begin
        with_tool_sandbox() do allowed
            res = AT.execute_tool("list_directory", Dict("path" => allowed))
            @test occursin("hello.txt", res)
            @test occursin("notes.jl", res)
            @test occursin("subdir", res)

            res_hidden = AT.execute_tool(
                "list_directory",
                Dict("path" => allowed, "show_hidden" => true),
            )
            @test occursin("hello.txt", res_hidden)

            res_depth =
                AT.execute_tool("list_directory", Dict("path" => allowed, "max_depth" => 3))
            @test occursin("nested.md", res_depth)

            @test occursin(
                "Error",
                AT.execute_tool("list_directory", Dict("path" => "/nonexistent")),
            )
            @test occursin(
                "Error",
                AT.execute_tool("list_directory", Dict("path" => "/etc")),
            )
        end
    end

    @testset "file_find" begin
        with_tool_sandbox() do allowed
            res =
                AT.execute_tool("file_find", Dict("pattern" => "hello", "path" => allowed))
            @test occursin("hello.txt", res)
            @test occursin("Found 1 files", res)

            res2 =
                AT.execute_tool("file_find", Dict("pattern" => "nested", "path" => allowed))
            @test occursin("nested.md", res2)

            @test occursin(
                "No files matching",
                AT.execute_tool("file_find", Dict("pattern" => "zzz", "path" => allowed)),
            )
            @test occursin("Error", AT.execute_tool("file_find", Dict()))
            @test occursin(
                "Error",
                AT.execute_tool(
                    "file_find",
                    Dict("pattern" => "x", "path" => "/nonexistent"),
                ),
            )
        end
    end

    @testset "grep_search" begin
        with_tool_sandbox() do allowed
            res = AT.execute_tool(
                "grep_search",
                Dict("pattern" => "hello world", "path" => allowed),
            )
            @test occursin("hello.txt", res)
            @test occursin("Grep results", res)

            res2 = AT.execute_tool(
                "grep_search",
                Dict("pattern" => "nested", "path" => allowed),
            )
            @test occursin("nested.md", res2)

            @test occursin(
                "No matches found",
                AT.execute_tool(
                    "grep_search",
                    Dict("pattern" => "zzzz", "path" => allowed),
                ),
            )
            @test occursin("Error", AT.execute_tool("grep_search", Dict()))
            @test occursin(
                "Error",
                AT.execute_tool(
                    "grep_search",
                    Dict("pattern" => "x", "path" => "/nonexistent"),
                ),
            )
        end
    end

    @testset "add_task / list_tasks / complete_task" begin
        with_tool_sandbox() do allowed
            res = AT.execute_tool(
                "add_task",
                Dict("title" => "Tool Test Task", "priority" => 3, "tags" => "test,urgent"),
            )
            @test occursin("Task added", res)
            @test occursin("Tool Test Task", res)

            res2 = AT.execute_tool("add_task", Dict("title" => "Tool Test Task 2"))
            @test occursin("Task added", res2)

            list_res = AT.execute_tool("list_tasks", Dict())
            @test occursin("Tool Test Task", list_res)
            @test occursin("Tasks (", list_res)

            all_res = AT.execute_tool("list_tasks", Dict("filter" => "all"))
            @test occursin("2 found", all_res)

            complete_res = AT.execute_tool("complete_task", Dict("task_id" => 1))
            @test occursin("Task 1 marked as completed", complete_res)
            @test occursin(
                "Error",
                AT.execute_tool("complete_task", Dict("task_id" => 999)),
            )
            @test occursin("Error", AT.execute_tool("complete_task", Dict()))
            @test occursin("Error", AT.execute_tool("add_task", Dict()))
        end
    end

    @testset "memory_query" begin
        with_tool_sandbox() do allowed
            res = AT.execute_tool("memory_query", Dict("query" => "summary"))
            @test occursin("Memory Summary", res)
            @test occursin("Test", res)

            res2 = AT.execute_tool("memory_query", Dict())
            @test occursin("Memory Summary", res2)

            res3 = AT.execute_tool("memory_query", Dict("query" => "goals"))
            @test occursin("No goals found", res3)

            res4 = AT.execute_tool("memory_query", Dict("query" => "productivity"))
            @test occursin("Productivity Report", res4)

            res5 = AT.execute_tool("memory_query", Dict("query" => "achievements"))
            @test occursin("No achievements yet", res5)

            res6 = AT.execute_tool("memory_query", Dict("query" => "bogus"))
            @test occursin("Available queries", res6)

            # 03.4: context debug view -> labeled blocks + provider breakdown.
            # Seed a task so at least one block is actually packed (exercises
            # the "packed blocks" rendering path, which reads Dict entries).
            Main.Kamila.TaskManager.add_task("Debug context view task"; priority = 3)
            res7 = AT.execute_tool("memory_query", Dict("query" => "context"))
            @test occursin("Context Injection Debug", res7)
            @test occursin("Budget:", res7)
            @test occursin("Providers queried:", res7)
            @test occursin("[P", res7)
        end
    end

    @testset "web_search (mocked HTTP)" begin
        with_tool_sandbox() do allowed
            S = Main.Kamila.Search
            old_get = S._HTTP_GET[]
            S._set_http_get(
                function (url; headers = Dict(), readtimeout = 15, retry = false)
                    return TestToolsEnv.HTTP.MockResponse(
                        200,
                        TestToolsEnv.HTTP.canned_body[],
                    )
                end,
            )
            try
                # No results / empty page
                TestToolsEnv.HTTP.canned_body[] = "<html><body></body></html>"
                res = AT.execute_tool("web_search", Dict("query" => "kamila"))
                @test occursin("Error", res)

                # With a result block (DDG lite markup the parser actually reads)
                html = """
                <html><body>
                <table>
                  <tr>
                    <td class="result-snippet">
                      <a rel="nofollow" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2F1">Example Result</a>
                      A useful snippet here.
                    </td>
                  </tr>
                </table>
                </body></html>
                """
                TestToolsEnv.HTTP.canned_body[] = html
                res2 = AT.execute_tool("web_search", Dict("query" => "julia language"))
                @test occursin("Web search results", res2)
                @test occursin("Example Result", res2)
                @test occursin("https://example.com/1", res2)

                @test occursin("Error", AT.execute_tool("web_search", Dict()))
            finally
                S._set_http_get(old_get)
            end
        end
    end

    @testset "system_status" begin
        res = AT.execute_tool("system_status", Dict())
        @test occursin("System Status", res)
        @test occursin("CPU", res)
        @test occursin("Memory", res)
        @test occursin("Health", res)
    end

    @testset "run_shell_command" begin
        # Denied by default: pipe a non-approving input.
        denied = with_test_stdin("n\n") do
            AT.execute_tool("run_shell_command", Dict("command" => "echo hi"))
        end
        @test occursin("denied", lowercase(denied))

        # Approved with "y"
        approved = with_test_stdin("y\n") do
            AT.execute_tool("run_shell_command", Dict("command" => "echo hello-from-shell"))
        end
        @test occursin("Command executed successfully", approved)
        @test occursin("hello-from-shell", approved)

        # Empty command
        @test occursin("Error", AT.execute_tool("run_shell_command", Dict()))

        # `force=true` is not a free bypass: without a capability token it is
        # treated per policy (:ask -> still requires confirmation).
        forced = with_test_stdin("n\n") do
            AT.execute_tool(
                "run_shell_command",
                Dict("command" => "echo forced-nope", "force" => true),
            )
        end
        @test occursin("denied", lowercase(forced))
    end

    @testset "set_reminder" begin
        # Provide a fake notify-send on PATH so no GUI is touched.
        fake_bin = joinpath(TEST_SANDBOX[]["root"], "fakebin")
        mkpath(fake_bin)
        notify_script = joinpath(fake_bin, "notify-send")
        write(notify_script, "#!/bin/sh\necho \"\$@\" >> \"\$HOME/notify_log.txt\"\n")
        chmod(notify_script, 0o755)

        old_path = get(ENV, "PATH", "")
        ENV["PATH"] = fake_bin * ":" * old_path
        try
            with_test_policy(permissive_tool_policy()) do
                res = AT.execute_tool("set_reminder", Dict("message" => "Drink water"))
                @test occursin("Reminder sent", res)
                sleep(0.2)
                logfile = joinpath(TEST_SANDBOX[]["root"], "notify_log.txt")
                @test isfile(logfile)
                @test occursin("Drink water", read(logfile, String))

                res2 = AT.execute_tool(
                    "set_reminder",
                    Dict("message" => "Stand up", "delay_minutes" => 1),
                )
                @test occursin("Reminder set", res2)
                @test occursin("Error", AT.execute_tool("set_reminder", Dict()))
            end
        finally
            ENV["PATH"] = old_path
        end
    end
end
