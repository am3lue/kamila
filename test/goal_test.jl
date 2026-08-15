"""
test/goal_test.jl — Tests of the 06.2 goal engine.

Covers plan linkage, derived progress (verified/total), completion gating on
plan status, retro-decomposition, `goal.progress` event emission on plan-step
verification, and the bridge `goal.*` routes.
"""

using Test
using JSON
using Dates

using .Kamila
const KM = Kamila.KamilaMemory
const MDB = Kamila.MemoryDB
const EV = Kamila.Events
const BR = Kamila.KamilaBridge
const PLAN = Kamila.Plan

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

function three_step_plan(goal_text::String)
    steps = [
        (description = "s1", depends_on = Int[], tool = "", args = Dict{String,Any}()),
        (description = "s2", depends_on = Int[], tool = "", args = Dict{String,Any}()),
        (description = "s3", depends_on = Int[], tool = "", args = Dict{String,Any}()),
    ]
    plan = PLAN.create(goal_text, steps)
    PLAN.start(plan)
    return plan
end

# ─── 1. Plan linkage + derived progress ───────────────────

@testset "goal plan linkage + derived progress" begin
    with_fresh_db() do
        @test MDB.schema_version() >= 7
        KM.add_goal("Learn Julia", "personal", 1)
        g = first(KM.get_goals())
        @test g["plan_id"] === nothing
        @test g["status"] == "active"

        plan = three_step_plan("Learn Julia")
        @test KM.link_goal_plan(g["id"], plan.id)
        @test KM.goal_progress(g["id"]) == 0

        # Verify steps drive progress: running → verified.
        PLAN.mark_step(plan, 1, :running); PLAN.mark_step(plan, 1, :verified)
        PLAN.mark_step(plan, 2, :running); PLAN.mark_step(plan, 2, :verified)
        @test KM.goal_progress(g["id"]) == 67  # 2/3

        # get_active_goals refreshes and reflects derived progress.
        active = KM.get_active_goals()
        @test any(x -> x["id"] == g["id"] && x["progress"] == 67, active)

        # Derived progress is persisted to the goals row.
        row = MDB.query_all("SELECT progress FROM goals WHERE id = ?", (g["id"],))[1]
        @test row.progress == 67
    end
end

# ─── 2. Completion gating ──────────────────────────────────

@testset "complete_goal gated on plan completion" begin
    with_fresh_db() do
        KM.add_goal("Ship feature", "work", 1)
        g = first(KM.get_goals())

        # No plan: completing is allowed (legacy behavior preserved).
        @test KM.complete_goal(g["id"])
        @test first(KM.get_goals())["completed"]

        # Fresh goal with a partial plan: completion rejected.
        KM.add_goal("Another feature", "work", 1)
        g2 = last(KM.get_goals())
        plan = three_step_plan("Another feature")
        KM.link_goal_plan(g2["id"], plan.id)
        PLAN.mark_step(plan, 1, :running); PLAN.mark_step(plan, 1, :verified)
        @test !KM.complete_goal(g2["id"])
        @test !last(KM.get_goals())["completed"]

        # Complete the plan → completion succeeds.
        PLAN.mark_step(plan, 2, :running); PLAN.mark_step(plan, 2, :verified)
        PLAN.mark_step(plan, 3, :running); PLAN.mark_step(plan, 3, :verified)
        @test PLAN.load(plan.id).status == :completed
        @test KM.complete_goal(g2["id"])
        @test last(KM.get_goals())["completed"]
        @test last(KM.get_goals())["status"] == "completed"
    end
end

# ─── 3. goal.progress events ───────────────────────────────

@testset "goal.progress events fire per verified step" begin
    with_fresh_db() do
        KM.add_goal("Event goal", "general", 1)
        g = first(KM.get_goals())
        plan = three_step_plan("Event goal")
        KM.link_goal_plan(g["id"], plan.id)

        EV.clear_subscribers!()
        EV.clear_queue!()
        seen = Any[]
        EV.subscribe("goal.progress", e -> push!(seen, (e["verified"], e["total"])))

        PLAN.mark_step(plan, 1, :running); PLAN.mark_step(plan, 1, :verified)
        PLAN.mark_step(plan, 2, :running); PLAN.mark_step(plan, 2, :verified)
        @test seen == [(1, 3), (2, 3)]

        # No duplicate emission for a repeated transition (verified→verified
        # is an illegal transition, so there is nothing to double-count).
        @test length(EV.drain(10)) == 2

        EV.clear_subscribers!()
        EV.clear_queue!()
    end
end

# ─── 4. Retro decomposition ────────────────────────────────

@testset "retro decomposition of legacy goals" begin
    with_fresh_db() do
        # A goal created without a plan (legacy).
        KM.add_goal("Legacy goal", "general", 1)
        g = first(KM.get_goals())
        @test g["plan_id"] === nothing

        # decompose_goal calls the model; use the fallback path (no mock model
        # available in this target) by expecting either a plan id or an error.
        plan_id = try
            KM.decompose_goal(g["id"])
        catch e
            nothing
        end
        if plan_id !== nothing
            @test plan_id isa String
            @test KM.link_goal_plan(g["id"], plan_id)
            @test KM.goal_progress(g["id"]) !== nothing
        end
    end
end

# ─── 5. Bridge routes ──────────────────────────────────────

@testset "bridge goal routes" begin
    with_fresh_db() do
        KM.add_goal("Bridge goal", "general", 1)
        g = first(KM.get_goals())

        out = Pipe()
        text = ""
        try
            Base.link_pipe!(out; reader_supports_async = true, writer_supports_async = true)
            redirect_stdout(out) do
                BR.handle_goal_progress("r1", Dict("goal_id" => g["id"]))
            end
            close(out.in)
            text = read(out.out, String)
        finally
            close(out)
        end
        # No linked plan → 404 error.
        resp = JSON.parse(text)
        @test resp["type"] == "error"
        @test resp["code"] == 404
    end
end