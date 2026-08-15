"""
test/plan_test.jl — Tier-1 tests for the Plan state machine (04.1):
lifecycle transitions, dependency gating, retry/fail policy, pause/resume
persistence, illegal-transition rejection, and crash-resume.
"""

using Test
using JSON
using Dates
using SQLite

using .Kamila
const P = Kamila.Plan
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

function make_chain(n::Int)
    steps = [
        (description = "step $i", depends_on = i == 1 ? Int[] : [i - 1], tool = "run_shell_command", args = Dict{String,Any}("command" => "true"))
        for i in 1:n
    ]
    return steps
end

@testset "Plan" begin

    @testset "create + dependency order" begin
        with_fresh_db() do
            p = P.create("deploy", make_chain(3))
            @test p.status == :created
            @test length(p.steps) == 3

            P.start(p)
            @test p.status == :active

            # Only step 1 runnable initially.
            s = P.next_runnable(p)
            @test s.id == 1

            # Step 2 gated on step 1 being verified.
            P.mark_step(p, 1, :running)
            P.mark_step(p, 1, :verified, "ok")
            s = P.next_runnable(p)
            @test s.id == 2

            # Step 3 still gated.
            P.mark_step(p, 2, :running)
            P.mark_step(p, 2, :verified, "ok")
            s = P.next_runnable(p)
            @test s.id == 3

            P.mark_step(p, 3, :running)
            P.mark_step(p, 3, :verified, "ok")
            @test p.status == :completed
            @test P.next_runnable(p) === nothing
        end
    end

    @testset "retryable failure retries; exhausted fails plan" begin
        with_fresh_db() do
            p = P.create("flaky", make_chain(1))
            P.start(p)
            # First attempt: running -> failed (retryable). Plan stays active.
            P.mark_step(p, 1, :running)
            P.mark_step(p, 1, :failed, "boom"; retryable = true)
            @test p.status == :active
            @test p.steps[1].attempts == 1

            # Second attempt.
            P.mark_step(p, 1, :running)
            P.mark_step(p, 1, :failed, "boom"; retryable = true)
            @test p.status == :active
            @test p.steps[1].attempts == 2

            # Third attempt exhausts MAX_RETRIES -> plan fails.
            P.mark_step(p, 1, :running)
            P.mark_step(p, 1, :failed, "boom"; retryable = true)
            @test p.steps[1].status == :failed
            @test p.status == :failed
        end
    end

    @testset "non-retryable failure fails plan immediately" begin
        with_fresh_db() do
            p = P.create("denied", make_chain(1))
            P.start(p)
            P.mark_step(p, 1, :running)
            P.mark_step(p, 1, :failed, "permission denied"; retryable = false)
            @test p.status == :failed
        end
    end

    @testset "illegal transitions rejected" begin
        with_fresh_db() do
            p = P.create("guard", make_chain(2))
            @test_throws Exception P.mark_step(p, 1, :verified)   # pending -> verified illegal
            @test_throws Exception P.pause(p)                      # created -> paused illegal
            P.start(p)
            @test_throws Exception P.mark_step(p, 2, :verified)   # step2 pending -> verified (also dep-gated)
            P.mark_step(p, 1, :running)
            P.mark_step(p, 1, :verified, "ok")
            P.mark_step(p, 2, :running)
            P.mark_step(p, 2, :verified, "ok")
            @test p.status == :completed
            @test_throws Exception P.start(p)   # completed -> active illegal
            @test_throws Exception P.cancel(p)  # completed -> cancelled illegal
        end
    end

    @testset "cancel marks pending/running skipped, no further steps run" begin
        with_fresh_db() do
            p = P.create("cancel", make_chain(3))
            P.start(p)
            P.mark_step(p, 1, :running)
            P.mark_step(p, 1, :verified, "ok")
            P.cancel(p)
            @test p.status == :cancelled
            @test all(s -> s.status == :skipped, p.steps[2:end])
            @test P.next_runnable(p) === nothing
        end
    end

    @testset "pause/resume persistence (crash-resume)" begin
        with_fresh_db() do
            p = P.create("persist", make_chain(4))
            P.start(p)
            P.mark_step(p, 1, :running)
            P.mark_step(p, 1, :verified, "ok")
            P.pause(p)
            @test p.status == :paused

            # Simulate a crash: drop the in-memory object, reload from DB.
            pid = p.id
            loaded = P.load(pid)
            @test loaded !== nothing
            @test loaded.status == :paused
            @test loaded.steps[1].status == :verified

            P.resume(loaded)
            s = P.next_runnable(loaded)
            @test s.id == 2

            # load_active returns paused+active plans.
            active = P.load_active()
            @test any(x -> x.id == pid, active)
        end
    end

    @testset "validation: empty, dup ids, unknown dep, cycle, size cap" begin
        with_fresh_db() do
            @test_throws Exception P.create("no steps", PlanStep[])
            # empty description
            @test_throws Exception P.create(
                "empty desc",
                [PlanStep(1, "   ", :pending, Int[], "", Dict{String,Any}(), nothing, 0)],
            )
        end
        # dup ids
        @test_throws Exception P.create(
            "dup",
            [
                PlanStep(1, "a", :pending, Int[], "", Dict{String,Any}(), nothing, 0),
                PlanStep(1, "b", :pending, Int[], "", Dict{String,Any}(), nothing, 0),
            ],
        )
        # unknown dependency
        @test_throws Exception P.create(
            "unknown dep",
            [PlanStep(1, "a", :pending, [5], "", Dict{String,Any}(), nothing, 0)],
        )
        # cycle
        @test_throws Exception P.create(
            "cycle",
            [
                PlanStep(1, "a", :pending, [2], "", Dict{String,Any}(), nothing, 0),
                PlanStep(2, "b", :pending, [1], "", Dict{String,Any}(), nothing, 0),
            ],
        )
        # size cap
        @test_throws Exception P.create(
            "too big",
            [(description = "x", depends_on = Int[], tool = "", args = Dict()) for _ in 1:(P.MAX_PLAN_STEPS + 1)],
        )
    end

    @testset "mark_step notfound + missing step" begin
        with_fresh_db() do
            p = P.create("nf", make_chain(1))
            @test_throws Exception P.mark_step(p, 99, :running)
        end
    end

    @testset "delete removes plan + steps" begin
        with_fresh_db() do
            p = P.create("del", make_chain(2))
            pid = p.id
            P.delete(pid)
            @test P.load(pid) === nothing
        end
    end

    @testset "04.3: step with verify spec transitions correctly" begin
        with_fresh_db() do
            spec = Dict("kind" => "file_contains", "target" => "notes.txt", "expected" => "done")
            p = P.create(
                "verified step",
                [
                    Dict(:description => "write notes",
                         :tool => "write_file",
                         :args => Dict("file_path" => "notes.txt", "content" => "done"),
                         :verify => spec),
                    Dict(:description => "second", :tool => "system_status", :args => Dict(),
                         :depends_on => [1]),
                ],
            )
            P.start(p)
            s = P.next_runnable(p)
            @test s.id == 1
            P.mark_step(p, s.id, :running)
            # Verification passes → step verified → next step runnable.
            P.mark_step(p, s.id, :verified, "wrote file")
            @test p.steps[1].status == :verified
            @test P.next_runnable(p).id == 2
        end
    end

    @testset "04.3: failed verify step is retryable then exhausts retries" begin
        with_fresh_db() do
            spec = Dict("kind" => "file_contains", "target" => "x.txt", "expected" => "NEVER")
            p = P.create(
                "verify fail exhaust",
                [
                    Dict(:description => "write", :tool => "write_file",
                         :args => Dict("file_path" => "x.txt", "content" => "hi"),
                         :verify => spec),
                ],
            )
            P.start(p)
            # Retryable failures keep the plan active and let next_runnable
            # return the same step again (bounded by MAX_RETRIES).
            s = P.next_runnable(p)
            for i in 1:P.MAX_RETRIES
                @test s !== nothing
                P.mark_step(p, s.id, :running)
                P.mark_step(p, s.id, :failed, "verify evidence"; retryable = true)
                s = P.next_runnable(p)
            end
            @test p.status == :failed
            @test p.steps[1].status == :failed
            @test p.steps[1].attempts == P.MAX_RETRIES
        end
    end

    @testset "04.3: next_runnable returns failed step for retry" begin
        with_fresh_db() do
            p = P.create(
                "retry candidate",
                [
                    Dict(:description => "a", :tool => "system_status", :args => Dict()),
                ],
            )
            P.start(p)
            s = P.next_runnable(p)
            P.mark_step(p, s.id, :running)
            P.mark_step(p, s.id, :failed, "nope"; retryable = true)
            retry = P.next_runnable(p)
            @test retry !== nothing
            @test retry.id == 1
        end
    end

end
