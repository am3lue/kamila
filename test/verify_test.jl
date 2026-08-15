"""
test/verify_test.jl — Tests for the enforced verification loop (04.3):
deterministic verify kinds, model_judgement, rollback-restore, and plan step
integration (verify spec stored, failed verification marks step failed).
"""

using Test
using JSON
using Dates

using .Kamila
const V = Kamila.Verify
const RB = Kamila.Rollback
const PLAN = Kamila.Plan
const MDB = Kamila.MemoryDB

function with_fresh_db(f::Function)
    old_db = get(ENV, "KAMILA_DB", nothing)
    ENV["KAMILA_DB"] = ":memory:"
    try
        MDB.reset!()
        f()
    finally
        MDB.reset!()
        old_db === nothing ? delete!(ENV, "KAMILA_DB") : ENV["KAMILA_DB"] = old_db
    end
end

@testset "Verify" begin
    @testset "VerifySpec parsing" begin
        spec = V.VerifySpec(Dict("kind" => "file_contains", "target" => "a.txt", "expected" => "hi"))
        @test spec.kind == :file_contains
        @test spec.target == "a.txt"
        @test spec.expected == "hi"
        @test V.is_verifiable(spec)
        @test V.is_verifiable(:model_judgement)
        @test !V.is_verifiable(:nonsense)
        @test V.VerifySpec(Dict("kind" => "schema")).expected === nothing
        from_json = V.VerifySpec(JSON.json(Dict("kind" => "status_code", "target" => "true", "expected" => 0)))
        @test from_json.kind == :status_code
        @test from_json.expected == "0"
    end

    @testset "file_exists" begin
        mktempdir() do dir
            file = joinpath(dir, "x.txt")
            write(file, "hello")
            @test V.verify(V.VerifySpec(:file_exists, file, nothing), "").ok
            @test V.verify(V.VerifySpec(:file_exists, joinpath(dir, "nope"), nothing), "").ok == false
            @test V.verify(V.VerifySpec(:file_exists, "x.txt", nothing), ""; workdir = dir).ok
        end
    end

    @testset "file_contains" begin
        mktempdir() do dir
            file = joinpath(dir, "x.txt")
            write(file, "the quick brown fox")
            @test V.verify(V.VerifySpec(:file_contains, file, "brown"), "").ok
            @test !V.verify(V.VerifySpec(:file_contains, file, "purple"), "").ok
            @test !V.verify(V.VerifySpec(:file_contains, joinpath(dir, "missing"), "x"), "").ok
        end
    end

    @testset "file_matches_regex" begin
        mktempdir() do dir
            file = joinpath(dir, "x.txt")
            write(file, "error code 42")
            @test V.verify(V.VerifySpec(:file_matches_regex, file, "code \\d+"), "").ok
            @test !V.verify(V.VerifySpec(:file_matches_regex, file, "code [a-z]+"), "").ok
        end
    end

    @testset "command_ok / status_code / shell_output" begin
        @test V.verify(V.VerifySpec(:command_ok, "true", nothing), "").ok
        @test !V.verify(V.VerifySpec(:command_ok, "false", nothing), "").ok
        @test V.verify(V.VerifySpec(:status_code, "exit 0", 0), "").ok
        @test !V.verify(V.VerifySpec(:status_code, "exit 3", 0), "").ok
        @test V.verify(V.VerifySpec(:shell_output_contains, "echo hello world", "hello"), "").ok
        @test !V.verify(V.VerifySpec(:shell_output_contains, "echo hello", "goodbye"), "").ok
        @test V.verify(V.VerifySpec(:shell_output_matches, "echo abc123", "abc\\d+"), "").ok
        @test !V.verify(V.VerifySpec(:shell_output_matches, "echo abc", "\\d+"), "").ok
    end

    @testset "schema (JSON validity)" begin
        mktempdir() do dir
            good = joinpath(dir, "good.json")
            bad = joinpath(dir, "bad.json")
            write(good, "{\"a\": 1}")
            write(bad, "{not json")
            @test V.verify(V.VerifySpec(:schema, good, nothing), "").ok
            @test !V.verify(V.VerifySpec(:schema, bad, nothing), "").ok
        end
    end

    @testset "verifier never throws" begin
        r = V.verify(V.VerifySpec(:file_contains, "/nonexistent/path/z", "x"), "")
        @test !r.ok
        @test r isa V.VerifyResult
        @test r.duration_ms >= 0
    end

    @testset "plan step persists verify spec" begin
        with_fresh_db() do
            spec = Dict("kind" => "file_contains", "target" => "a.txt", "expected" => "ok")
            p = PLAN.create(
                "verify persistence",
                [
                    Dict(:description => "write file", :tool => "write_file",
                         :args => Dict("file_path" => "a.txt", "content" => "ok"),
                         :verify => spec),
                ],
            )
            loaded = PLAN.load(p.id)
            @test loaded.steps[1].verify !== nothing
            @test occursin("file_contains", loaded.steps[1].verify)
        end
    end

    @testset "verify spec optional (defaults to nothing)" begin
        with_fresh_db() do
            p = PLAN.create(
                "no verify",
                [Dict(:description => "plain step", :tool => "system_status", :args => Dict())],
            )
            @test PLAN.load(p.id).steps[1].verify === nothing
        end
    end

    @testset "failed verification marks step failed + plan failed" begin
        with_fresh_db() do
            spec = Dict("kind" => "file_contains", "target" => "x.txt", "expected" => "NEVER")
            p = PLAN.create(
                "verify fail",
                [
                    Dict(:description => "write wrong content", :tool => "write_file",
                         :args => Dict("file_path" => "x.txt", "content" => "hello", "create_backup" => false),
                         :verify => spec),
                ],
            )
            PLAN.start(p)
            s = PLAN.next_runnable(p)
            @test s !== nothing
            PLAN.mark_step(p, s.id, :running)
            # Simulate tool success but failing verification by running the verify
            # directly against the real file.
            file = joinpath(TEST_SANDBOX[]["allowed"], "x.txt")
            write(file, "hello")
            vr = V.verify(V.VerifySpec(spec), "wrote hello"; workdir = TEST_SANDBOX[]["allowed"])
            @test !vr.ok
            PLAN.mark_step(p, s.id, :failed, vr.evidence; retryable = true)
            # Retryable failure keeps the plan active; attempts remain below cap.
            @test p.status == :active
            @test p.steps[1].status == :failed
        end
    end

    @testset "rollback: restore_from_backup" begin
        mktempdir() do dir
            file = joinpath(dir, "a.txt")
            write(file, "original")
            # write_file with create_backup=true creates the .bak
            cp(file, file * ".bak"; force = true)
            write(file, "overwritten")
            ok, ev = RB.restore_from_backup(file)
            @test ok
            @test read(file, String) == "original"
            # no backup → false
            ok2, _ = RB.restore_from_backup(joinpath(dir, "ghost.txt"))
            @test !ok2
        end
    end

    @testset "rollback: write_file restores backup when create_backup was set" begin
        mktempdir() do dir
            file = joinpath(dir, "b.txt")
            write(file, "before")
            # Simulate the .bak created by write_file with create_backup=true.
            cp(file, file * ".bak"; force = true)
            write(file, "after")
            ok, ev = RB.rollback(
                "write_file",
                Dict("file_path" => file, "create_backup" => true),
                dir,
            )
            @test ok
            @test read(file, String) == "before"
            # Without create_backup → refused.
            ok2, _ = RB.rollback(
                "write_file",
                Dict("file_path" => file, "create_backup" => false),
                dir,
            )
            @test !ok2
        end
    end

    @testset "rollback: shell undo_command" begin
        mktempdir() do dir
            marker = joinpath(dir, "u.txt")
            write(marker, "x")
            ok, ev = RB.rollback(
                "run_shell_command",
                Dict("command" => "rm $marker", "undo_command" => "touch $marker"),
                dir,
            )
            @test ok
            @test isfile(marker)
            # No undo_command → refused.
            ok2, _ = RB.rollback(
                "run_shell_command",
                Dict("command" => "echo hi"),
                dir,
            )
            @test !ok2
        end
    end

    @testset "rollback: unknown tool surfaced" begin
        ok, ev = RB.rollback("web_search", Dict(), pwd())
        @test !ok
        @test occursin("no rollback defined", ev)
    end

    @testset "rollback: custom registry" begin
        RB.register!("my_tool", (args, wd) -> (true, "undone"))
        @test RB.has_rollback("my_tool")
        ok, ev = RB.rollback("my_tool", Dict(), pwd())
        @test ok
        @test ev == "undone"
    end
end