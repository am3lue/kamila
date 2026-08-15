"""
test/executive_test.jl — Tests of the 06.3 orchestrator executive loop.

Covers work-item collection + deterministic prioritization (plans/jobs/goals),
the propose-vs-execute gate (auto_execute=false default never runs), the daily
budget governor (exhaustion idles dispatch), interactive preemption, verify-
failure pausing a plan (pause_on_failure), catch-up proposing overdue work under
default policy, and auditable budget debits per action.
"""

using Test
using JSON
using Dates

using .Kamila
const EX = Kamila.Orchestrator.Executive
const P = Kamila.Permission
const PLAN = Kamila.Plan
const MDB = Kamila.MemoryDB
const SCH = Kamila.Scheduler
const KM = Kamila.KamilaMemory
const AT = Kamila.AgentTools
const CAP = Kamila.Capability

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

function allow_all_policy()
    Dict(
        "version" => 1,
        "default_action" => "allow",
        "rules" => [Dict("match" => "*", "action" => "allow")],
    )
end

function with_policy(f::Function)
    old_file = P.POLICY_FILE[]
    P.POLICY_FILE[] = joinpath(TEST_SANDBOX[]["root"], "exec_policy.json")
    try
        P.set_policy(allow_all_policy())
        P.clear_session_cache()
        P.clear_policy_cache()
        f()
    finally
        P.POLICY_FILE[] = old_file
        P.clear_session_cache()
        P.clear_policy_cache()
    end
end

function with_budget(f::Function, daily_actions::Int)
    old_cfg = EX._CONFIG[]
    EX.reset_executive!()
    MDB.execute!("DELETE FROM kv WHERE key LIKE 'orchestrator.budget.%'")
    EX._CONFIG[] = Dict{String,Any}(copy(EX.DEFAULT_CONFIG))
    EX._CONFIG[]["daily_actions"] = daily_actions
    try
        f()
    finally
        EX.reset_executive!()
        EX._CONFIG[] = old_cfg
        MDB.execute!("DELETE FROM kv WHERE key LIKE 'orchestrator.budget.%'")
    end
end

function one_step_plan(goal_text::String; tool::String = "run_shell_command", args = Dict("command" => "echo hi"), verify = nothing)
    p = PLAN.create(
        goal_text,
        [(description = "s1", depends_on = Int[], tool = tool, args = args, verify = verify)],
    )
    PLAN.start(p)
    return p
end

# ─── 1. Work-item collection + prioritization ─────────────

@testset "collect work items + deterministic priority" begin
    with_fresh_db() do
        with_policy() do
            EX.reset_executive!()
            MDB.execute!("DELETE FROM kv WHERE key LIKE 'orchestrator.budget.%'")

            # A critical due job must outrank a normal job and a plan step.
            SCH.create_job("check"; spec = Dict{String,Any}("urgency" => "critical"), at = now() - Minute(1))
            SCH.create_job("check"; spec = Dict{String,Any}("urgency" => "normal"), at = now() - Minute(1))
            p = one_step_plan("exec item plan")
            @test PLAN.load(p.id).status == :active

            items = EX.collect_work_items()
            @test length(items) == 3
            sorted = EX.prioritize(items)
            @test sorted[1].source == :job
            @test sorted[1].priority == 0        # critical
            @test sorted[2].source == :job
            @test sorted[2].priority == 2        # normal job
            @test sorted[3].source == :plan
            @test sorted[3].priority == 4        # plan step

            # Goal advance nudge is collected and deduplicated against the same
            # plan step.
            KM.add_goal("exec goal", "general", 1)
            g = first(KM.get_goals())
            KM.link_goal_plan(g["id"], p.id)
            items2 = EX.collect_work_items()
            # The plan step is already present from the :plan source, so the
            # goal nudge for the same step is not duplicated.
            @test count(i -> i.source == :plan && i.id == p.id, items2) == 1
        end
    end
end

# ─── 2. Propose-vs-execute: default never runs ─────────────

@testset "propose-vs-execute: auto_execute=false default" begin
    with_fresh_db() do
        with_policy() do
            with_budget(10) do
                @test !EX.auto_execute()
                p = one_step_plan("exec propose plan")

                r = EX.tick()
                @test r["yielded"] == false
                @test r["executed"] == []
                @test length(r["proposed"]) >= 1
                @test r["proposed"][1]["source"] == "plan"

                # The step was never marked running/verified without approval.
                reloaded = PLAN.load(p.id)
                @test reloaded.steps[1].status == :pending
                @test reloaded.status == :active
            end
        end
    end
end

# ─── 3. Budget exhaustion stops dispatch ───────────────────

@testset "budget exhaustion stops dispatch" begin
    with_fresh_db() do
        with_policy() do
            with_budget(1) do
                EX.set_auto_execute(true)
                p1 = one_step_plan("exec budget 1")
                p2 = one_step_plan("exec budget 2")

                r = EX.tick()
                @test length(r["executed"]) == 1   # only one action allowed

                # Second tick has nothing left in the daily budget.
                r2 = EX.tick()
                @test length(r2["executed"]) == 0
                @test EX.budget_status()["actions_remaining"] == 0

                # At least one plan still has pending steps.
                reloaded1 = PLAN.load(p1.id)
                reloaded2 = PLAN.load(p2.id)
                @test reloaded1.steps[1].status == :pending ||
                      reloaded2.steps[1].status == :pending
            end
        end
    end
end

# ─── 4. Interactive request preempts autonomous dispatch ───

@testset "interactive request preempts autonomous dispatch" begin
    with_fresh_db() do
        with_policy() do
            with_budget(10) do
                EX.set_auto_execute(true)
                p = one_step_plan("exec interactive plan")

                EX.set_interactive!(true)
                r = EX.tick()
                @test r["yielded"] == true
                @test r["executed"] == []
                reloaded = PLAN.load(p.id)
                @test reloaded.steps[1].status == :pending

                EX.set_interactive!(false)
                r2 = EX.tick()
                @test r2["yielded"] == false
                @test length(r2["executed"]) == 1
            end
        end
    end
end

# ─── 5. Verify-failed step pauses its plan ─────────────────

@testset "verify-failed step pauses plan (pause_on_failure)" begin
    with_fresh_db() do
        with_policy() do
            with_budget(10) do
                EX.set_auto_execute(true)
                target = joinpath(TEST_SANDBOX[]["allowed"], "exec_verify.txt")
                write(target, "hello")
                verify_spec = Dict{String,Any}(
                    "kind" => "file_contains",
                    "target" => target,
                    "expected" => "WRONG",
                )
                p = one_step_plan(
                    "exec verify plan";
                    tool = "read_file",
                    args = Dict{String,Any}("file_path" => target),
                    verify = verify_spec,
                )

                r = EX.tick()
                @test length(r["executed"]) == 1
                entry = r["executed"][1]
                @test entry["outcome"] == "failed_verify_paused"

                reloaded = PLAN.load(p.id)
                @test reloaded.status == :paused
                @test reloaded.metadata["pause_on_failure"] == true
                @test reloaded.steps[1].status == :failed

                # It is reported (audited), not silently retried: budget debited
                # exactly once for this action.
                audit = EX.recent_audit()
                @test count(e -> get(e, "event", "") == "orchestrator.executed", audit) == 1
                @test EX.budget_status()["actions_used"] == 1
            end
        end
    end
end

# ─── 6. Boot catch-up proposes (not runs) overdue work ─────

@testset "boot catch-up proposes overdue work under default policy" begin
    with_fresh_db() do
        with_policy() do
            with_budget(10) do
                # Default policy (auto_execute=false): overdue work is proposed.
                p = one_step_plan("exec catchup plan")
                SCH.create_job("check"; spec = Dict{String,Any}("urgency" => "critical"), at = now() - Minute(30))

                r = EX.tick()
                @test r["executed"] == []
                @test length(r["proposed"]) == 2   # overdue job + plan step
                @test any(x -> x["source"] == "job" && x["priority"] == 0, r["proposed"])
                @test any(x -> x["source"] == "plan", r["proposed"])

                reloaded = PLAN.load(p.id)
                @test reloaded.steps[1].status == :pending
            end
        end
    end
end

# ─── 7. Budget debits are auditable per action ─────────────

@testset "budget debits auditable per action" begin
    with_fresh_db() do
        with_policy() do
            with_budget(10) do
                EX.set_auto_execute(true)
                p = one_step_plan("exec audit plan")

                r = EX.tick()
                @test length(r["executed"]) == 1
                entry = r["executed"][1]
                @test haskey(entry, "budget")
                @test entry["budget"]["actions"] == 1

                audit = EX.recent_audit(10)
                @test length(audit) == 1
                @test audit[1]["event"] == "orchestrator.executed"
                @test audit[1]["plan_id"] == p.id
                @test audit[1]["outcome"] == "verified"
                @test audit[1]["budget"]["actions"] == 1

                # Budget state is persisted to the kv ledger for the day.
                raw = KM.get_kv("orchestrator.budget." * string(today()))
                @test raw !== nothing
                parsed = JSON.parse(raw)
                @test parsed["actions"] == 1
            end
        end
    end
end

# ─── 8. advance_now runs user-approved work ────────────────

@testset "advance_now runs proposed work on approval" begin
    with_fresh_db() do
        with_policy() do
            with_budget(10) do
                @test !EX.auto_execute()
                p = one_step_plan("exec advance plan")

                # Propose first.
                r = EX.tick()
                @test r["executed"] == []

                # User approves: advance_now runs the step despite auto_execute=false.
                res = EX.advance_now(plan_id = p.id)
                @test res["outcome"] == "verified"
                reloaded = PLAN.load(p.id)
                @test reloaded.steps[1].status == :verified
                @test reloaded.status == :completed
                @test EX.budget_status()["actions_used"] == 1
            end
        end
    end
end

# ─── 9. Capability scope narrows autonomous execution ──────

@testset "capability scope narrows autonomous execution" begin
    with_fresh_db() do
        with_policy() do
            with_budget(10) do
                EX.set_auto_execute(true)
                # system_status maps to "system.read"; restrict to files.read.
                p = one_step_plan("exec caps plan"; tool = "system_status", args = Dict{String,Any}())

                r = EX.tick(; capabilities = Set{String}(["files.read"]))
                @test length(r["executed"]) == 1
                entry = r["executed"][1]
                # Out-of-scope tool fails; result is a failure outcome (not an
                # executed success) and is not silently retried.
                @test entry["outcome"] in ("failed_paused", "failed_retryable")
            end
        end
    end
end

# ─── 10. Kill switch pauses autonomous dispatch ────────────

@testset "kill switch pauses autonomous dispatch" begin
    with_fresh_db() do
        with_policy() do
            with_budget(10) do
                EX.set_auto_execute(true)
                p = one_step_plan("exec pause plan")

                EX.pause()
                @test !EX.auto_execute()
                r = EX.tick()
                @test length(r["executed"]) == 0
                reloaded = PLAN.load(p.id)
                @test reloaded.steps[1].status == :pending

                # Re-enabling lets autonomous dispatch resume.
                EX.set_auto_execute(true)
                r2 = EX.tick()
                @test length(r2["executed"]) == 1
            end
        end
    end
end

# ─── 09.3 Curiosity novelty tie-breaker ───────────────────

@testset "curiosity novelty tie-breaker (09.3)" begin
    @testset "curiosity is off by default and toggles explicitly" begin
        with_fresh_db() do
            EX.reset_executive!()
            @test EX.curiosity_enabled() == false
            EX.set_curiosity!(true)
            @test EX.curiosity_enabled() == true
            # reset returns to the default (off).
            EX.reset_executive!()
            @test EX.curiosity_enabled() == false
        end
    end

    @testset "novelty_score degrades to 0.0 without embedding evidence" begin
        with_fresh_db() do
            # Empty description → 0.0 (never an invented score).
            item = EX.WorkItem(:plan, "p1", 1, 4, "   ", now())
            @test EX.novelty_score(item) == 0.0
            # With no embed endpoint reachable, a real description also yields
            # 0.0 (graceful), and the plain description still works.
            item2 = EX.WorkItem(:plan, "p2", 1, 4, "advance a plan step", now())
            @test EX.novelty_score(item2) == 0.0
        end
    end

    @testset "prioritize is unchanged when curiosity is off" begin
        with_fresh_db() do
            EX.reset_executive!()
            now_ref = now()
            a = EX.WorkItem(:plan, "pa", 1, 2, "step A", now_ref)
            b = EX.WorkItem(:job, "jb", nothing, 0, "critical job", now_ref)
            c = EX.WorkItem(:goal, "gc", 1, 4, "goal C", now_ref)
            sorted = EX.prioritize([a, b, c])
            @test [s.id for s in sorted] == ["jb", "pa", "gc"]
            # Same result with curiosity on but no embedding evidence (all
            # novelty 0.0 → falls back to the deterministic priority sort).
            sorted2 = EX.prioritize([a, b, c]; curiosity = true)
            @test [s.id for s in sorted2] == ["jb", "pa", "gc"]
        end
    end
end
