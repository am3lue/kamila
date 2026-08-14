"""
test/confirm_test.jl — Tests of the `Confirm` confirmation service.

Covers the interactive backend (y/N/! prompt), the allowlist short-circuit, the
bridge backend (resolve via `resolve_confirm`) and the timeout-to-deny default.
The full bridge round-trip (agent calls `run_shell_command` -> `confirm_request`
event -> `confirm_response` -> tool_result) lives in `test/bridge_test.jl`.
"""

using Test
using JSON

using .Kamila
const C = Kamila.Confirm

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

@testset "Confirm" begin
    @testset "force bypasses prompt" begin
        C.set_backend(:interactive)
        @test C.confirm("rm -rf /"; force = true)
    end

    @testset "interactive prompt y/N/!" begin
        C.set_backend(:interactive)
        # "n" / newline / anything non-y -> deny
        for input in ["n\n", "\n", "no\n", "whatever\n"]
            denied = with_test_stdin(() -> C.confirm("ls"), input)
            @test !denied
        end
        # "y" -> approve
        @test with_test_stdin(() -> C.confirm("ls"), "y\n")
        # "!" -> force-approve
        @test with_test_stdin(() -> C.confirm("ls"), "!\n")
    end

    @testset "allowlist skips prompt" begin
        C.set_backend(:interactive)
        allow_path = tempname() * ".json"
        old = C.ALLOWLIST_FILE[]
        C.ALLOWLIST_FILE[] = allow_path
        try
            write(allow_path, JSON.json(Dict("commands" => ["ls", "git status"])))
            @test C.is_allowlisted("ls")
            @test C.is_allowlisted("git status")
            @test !C.is_allowlisted("rm -rf")
            # allowlisted command approves without consuming stdin
            @test C.confirm("ls")
            # non-allowlisted still prompts (deny via empty stdin)
            @test !with_test_stdin(() -> C.confirm("echo hi"), "")
        finally
            rm(allow_path; force = true)
            C.ALLOWLIST_FILE[] = old
        end
    end

    @testset "missing allowlist file is not allowlisted" begin
        C.set_backend(:interactive)
        old = C.ALLOWLIST_FILE[]
        C.ALLOWLIST_FILE[] = joinpath(mktempdir(), "nope.json")
        try
            @test !C.is_allowlisted("anything")
        finally
            C.ALLOWLIST_FILE[] = old
        end
    end

    @testset "bridge backend: resolve allow/deny" begin
        C.set_backend(:bridge)
        C.set_timeout_seconds(5.0)

        task = @async C.confirm("echo hi")
        id = nothing
        for _ = 1:200
            sleep(0.01)
            id = length(C._PENDING) == 1 ? first(keys(C._PENDING)) : nothing
            id === nothing || break
        end
        @test id !== nothing
        C.resolve_confirm(id, true)
        @test fetch(task) == true

        task = @async C.confirm("echo hi2")
        id = nothing
        for _ = 1:200
            sleep(0.01)
            id = length(C._PENDING) == 1 ? first(keys(C._PENDING)) : nothing
            id === nothing || break
        end
        @test id !== nothing
        C.resolve_confirm(id, false)
        @test fetch(task) == false

        # pending registry cleaned up after resolution
        @test isempty(C._PENDING)
    end

    @testset "bridge backend: unknown id ignored" begin
        C.set_backend(:bridge)
        C.resolve_confirm("does-not-exist", true)  # must not throw
        @test true
    end

    @testset "timeout -> deny" begin
        C.set_backend(:bridge)
        C.set_timeout_seconds(0.5)
        t0 = time()
        result = C.confirm("sleep 30")
        @test result == false
        @test time() - t0 >= 0.4
        @test isempty(C._PENDING)
    end

    C.set_backend(:interactive)
    C.set_timeout_seconds(30.0)
end
