"""
test/decompose_test.jl — Tests for task decomposition (04.4): valid
decomposition parsing, JSON repair, cycle/dedup rejection, size caps with a
"remaining work" step, fallback single-step on repeated bad JSON, sub-plan
promotion, and the plan.decompose bridge route.
"""

using Test
using JSON
using Dates

using .Kamila
const DC = Kamila.Decompose
const PLAN = Kamila.Plan
const MDB = Kamila.MemoryDB
const BR = Kamila.KamilaBridge

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

with_mock_model(f::Function, responses::Vector{String}) = begin
    old = DC.MODEL_FN[]
    calls = Ref(0)
    DC.MODEL_FN[] = (_prompt) -> begin
        calls[] += 1
        return responses[min(calls[], length(responses))]
    end
    try
        f(calls)
    finally
        DC.MODEL_FN[] = old
    end
end

valid_json = """{"steps": [
    {"id": 1, "description": "install deps", "depends_on": [], "verify": null},
    {"id": 2, "description": "write server", "depends_on": [1], "verify": {"kind": "file_exists", "target": "server.py"}},
    {"id": 3, "description": "run tests", "depends_on": [2], "verify": {"kind": "command_ok", "target": "pytest"}}
]}"""

@testset "Decompose" begin
    @testset "valid decomposition parses + persists" begin
        with_fresh_db() do
            with_mock_model([valid_json]) do calls
                steps, ok, note = DC.decompose("build a small web server")
                @test ok
                @test length(steps) == 3
                @test steps[1]["depends_on"] == Int[]
                @test steps[2]["depends_on"] == [1]
                @test steps[3]["depends_on"] == [2]
                @test steps[2]["verify"] isa AbstractDict
                @test isempty(note)
                @test calls[] == 1
            end
        end
    end

    @testset "decompose_to_plan persists a valid plan" begin
        with_fresh_db() do
            with_mock_model([valid_json]) do _
                p = DC.decompose_to_plan("build a web server")
                @test p.status == :created
                @test length(p.steps) == 3
                loaded = PLAN.load(p.id)
                @test loaded !== nothing
                @test length(loaded.steps) == 3
                @test loaded.steps[3].verify !== nothing
            end
        end
    end

    @testset "missing/dup id repaired via retry" begin
        with_fresh_db() do
            bad = """{"steps": [
                {"id": 1, "description": "a", "depends_on": [], "verify": null},
                {"id": 1, "description": "b", "depends_on": [], "verify": null}
            ]}"""
            with_mock_model([bad, valid_json]) do calls
                steps, ok, note = DC.decompose("goal")
                @test ok
                @test length(steps) == 3
                @test calls[] == 2
            end
        end
    end

    @testset "fenced JSON tolerated" begin
        with_fresh_db() do
            fenced = "Here is the plan:\n```json\n" * valid_json * "\n```\n"
            with_mock_model([fenced]) do _
                steps, ok, _ = DC.decompose("goal")
                @test ok
                @test length(steps) == 3
            end
        end
    end

    @testset "cycle rejected then fallback on second failure" begin
        with_fresh_db() do
            cyclic = """{"steps": [
                {"id": 1, "description": "a", "depends_on": [2], "verify": null},
                {"id": 2, "description": "b", "depends_on": [1], "verify": null}
            ]}"""
            with_mock_model([cyclic, cyclic]) do calls
                steps, ok, note = DC.decompose("goal")
                @test ok
                @test length(steps) == 1  # fallback single-step
                @test occursin("fallback", note)
                @test calls[] == 2
            end
        end
    end

    @testset "invalid JSON retry once then fallback" begin
        with_fresh_db() do
            with_mock_model(["not json at all", "also not json"]) do calls
                steps, ok, note = DC.decompose("goal")
                @test ok
                @test length(steps) == 1
                @test occursin("fallback", note)
                @test calls[] == 2
            end
        end
    end

    @testset "oversized decomposition truncated with remaining step" begin
        with_fresh_db() do
            many = Dict("steps" => [
                Dict("id" => i, "description" => "step $i",
                     "depends_on" => i == 1 ? Int[] : [i - 1], "verify" => nothing)
                for i in 1:25
            ])
            with_mock_model([JSON.json(many)]) do _
                steps, ok, note = DC.decompose("big goal"; max_steps = 5)
                @test ok
                @test length(steps) == 6  # 5 + remaining-work step
                @test occursin("truncated", note)
                @test steps[end]["description"] == "Remaining work beyond the decomposed steps"
                @test steps[end]["depends_on"] == [5]
            end
        end
    end

    @testset "empty steps list rejected → fallback" begin
        with_fresh_db() do
            with_mock_model(["""{"steps": []}"""]) do _
                steps, ok, note = DC.decompose("goal")
                @test ok
                @test length(steps) == 1
                @test occursin("fallback", note)
            end
        end
    end

    @testset "sub-plan promotion marks parent verified" begin
        with_fresh_db() do
            parent = PLAN.create(
                "parent",
                [
                    Dict(:description => "big step", :tool => "delegate",
                         :args => Dict("sub_goal" => "sub task")),
                ],
            )
            PLAN.start(parent)
            PLAN.mark_step(parent, 1, :running)
            child = PLAN.create(
                "child goal",
                [Dict(:description => "do it", :tool => "system_status", :args => Dict())],
                parent_plan_id = parent.id,
                parent_step_id = 1,
            )
            PLAN.start(child)
            PLAN.mark_step(child, 1, :running)
            PLAN.mark_step(child, 1, :verified, "done")
            @test child.status == :completed
            PLAN.promote_subplan(child)
            @test PLAN.load(parent.id).steps[1].status == :verified
            @test PLAN.load(parent.id).status == :completed
        end
    end

    @testset "decompose_goal tool registered + works" begin
        with_fresh_db() do
            with_mock_model([valid_json]) do _
                tools = Kamila.AgentTools.get_all_tools()
                @test any(t -> t.name == "decompose_goal", tools)
                r = Kamila.AgentTools.execute_tool_structured(
                    "decompose_goal",
                    Dict("goal" => "build a web server"),
                )
                @test r["ok"]
                @test occursin("plan", r["result"])
            end
        end
    end

    @testset "plan.decompose bridge route" begin
        with_fresh_db() do
            with_mock_model([valid_json]) do _
                out = capture_stdout() do
                    BR.dispatch(
                        Dict(
                            "type" => "request",
                            "id" => "t123",
                            "method" => "plan.decompose",
                            "params" => Dict("goal" => "build a small web server"),
                        ),
                    )
                end
                events = Dict{String,Any}[JSON.parse(l) for l in split(strip(out), "\n") if !isempty(strip(l))]
                resp = findfirst(e -> get(e, "type", "") == "response", events)
                @test resp !== nothing
                @test events[resp]["id"] == "t123"
                body = events[resp]["result"]
                @test body["status"] == "created"
                @test body["step_count"] == 3
                @test !isempty(body["id"])
            end
        end
    end
end