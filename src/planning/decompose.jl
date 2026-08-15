"""
Decompose — turn a large goal into a validated, dependency-resolved plan (04.4).

The decomposer asks the model for a JSON step list, validates it (empty steps,
duplicate/missing ids, unknown dependencies, cycles), repairs it once by feeding
the parse error back, and on a second failure falls back to a single
"do it directly" step so the task still completes. Oversized decompositions are
truncated with a trailing "remaining work" step.
"""

module Decompose

using JSON
using Dates
using ..KamilaLog
using ..Errors
using ..OllamaInterface
using ..ModelRouter
import ..Plan as PlanModule

export decompose, decompose_to_plan, validate_decomposition

const MAX_STEPS = 20
const MAX_DEPTH = 2

"""
Model-call seam. Tests replace this with a fake that returns scripted JSON.
Defaults to a real Ollama call via `query_ollama`.
"""
const MODEL_FN = Ref{Function}(
    (prompt) -> begin
        models = ModelRouter.get_router_config()
        cfg = ModelRouter.select_model(:task, models)
        return OllamaInterface.query_ollama(
            prompt;
            model = cfg.name,
            temperature = 0.2,
            max_tokens = 2048,
        )
    end,
)

const DECOMPOSE_PROMPT = """
You are a task decomposer. Break the user's goal into discrete, ordered steps.

Return ONLY valid JSON with this exact shape (no markdown, no commentary):
{"steps": [
  {"id": 1, "description": "...", "depends_on": [], "verify": null},
  {"id": 2, "description": "...", "depends_on": [1], "verify": {"kind": "file_contains", "target": "...", "expected": "..."}}
]}

Rules:
- id is a unique positive integer starting at 1.
- description is non-empty and imperative.
- depends_on lists the ids that must finish first; leave [] for independent steps.
- verify is null, or a spec with kind one of: file_exists, file_contains,
  file_matches_regex, command_ok, shell_output_contains, schema.
- No cycles. Cover the whole goal. Use no more than $MAX_STEPS steps.
"""

function _prompt_for(goal::String)
    return "$DECOMPOSE_PROMPT\n\nGoal: $goal"
end

"""
Validate a parsed decomposition. Returns `(ok::Bool, steps::Vector{Dict}, reason::String)`.
"""
function validate_decomposition(data)
    steps = try
        get(data, "steps", nothing)
    catch
        nothing
    end
    steps === nothing && return false, Dict{String,Any}[], "missing 'steps' key"
    steps isa AbstractVector || return false, Dict{String,Any}[], "'steps' is not a list"
    isempty(steps) && return false, Dict{String,Any}[], "no steps"

    ids = Int[]
    for (i, s) in enumerate(steps)
        s isa AbstractDict || return false, Dict{String,Any}[], "step $i is not an object"
        desc = get(s, "description", "")
        isempty(strip(string(desc))) &&
            return false, Dict{String,Any}[], "step $i missing description"
        id = get(s, "id", 0)
        try
            id = Int(id)
        catch
            return false, Dict{String,Any}[], "step $i has non-integer id"
        end
        id >= 1 || return false, Dict{String,Any}[], "step $i has invalid id $id"
        id in ids && return false, Dict{String,Any}[], "duplicate id $id"
        push!(ids, id)
    end

    idset = Set(ids)
    for (i, s) in enumerate(steps)
        deps = try
            Vector{Int}([Int(d) for d in get(s, "depends_on", Int[])])
        catch
            return false, Dict{String,Any}[], "step $(get(s,"id",i)) has invalid depends_on"
        end
        for d in deps
            d in idset || return false, Dict{String,Any}[], "step $i depends on unknown id $d"
        end
    end

    # Cycle detection (DFS).
    color = Dict{Int,Symbol}()
    for id in ids
        color[id] = :white
    end
    byid = Dict{Int,Any}(Int(get(s, "id", 0)) => s for s in steps)
    function visit(id::Int)
        color[id] == :gray && return true
        color[id] == :black && return false
        color[id] = :gray
        for d in Vector{Int}([Int(x) for x in get(byid[id], "depends_on", Int[])])
            visit(d) && return true
        end
        color[id] = :black
        return false
    end
    for id in ids
        visit(id) && return false, Dict{String,Any}[], "dependency cycle detected"
    end

    return true, steps, ""
end

"""
Normalize a validated decomposition into Plan.create-compatible step dicts.
Drops `id` (Plan reassigns ids 1..n) and keeps dependency ordering.
"""
function _to_plan_steps(steps::AbstractVector)
    idmap = Dict{Int,Int}()  # original id -> new 1..n position
    for (i, s) in enumerate(steps)
        idmap[Int(get(s, "id", i))] = i
    end
    result = Dict{String,Any}[]
    for (i, s) in enumerate(steps)
        deps = [idmap[d] for d in Vector{Int}([Int(x) for x in get(s, "depends_on", Int[])])]
        verify = get(s, "verify", nothing)
        push!(
            result,
            Dict{String,Any}(
                "description" => string(get(s, "description", "")),
                "depends_on" => deps,
                "verify" => verify,
            ),
        )
    end
    return result
end

"""
Parse model output. Accepts a bare JSON object, or JSON embedded in text (fenced
blocks tolerated). Returns `(parsed, error)`.
"""
function _parse_model_output(raw::String)
    text = strip(raw)
    # Strip ```json ... ``` fences if present.
    if occursin("```", text)
        m = match(r"```(?:json)?\s*(\{.*\})\s*```"s, text)
        if m !== nothing
            text = strip(m.captures[1])
        else
            # Take the first { ... } span as a last resort.
            m2 = match(r"\{.*\}"s, text)
            m2 === nothing && return nothing, "no JSON object found in response"
            text = m2.match
        end
    end
    data = try
        JSON.parse(text)
    catch e
        return nothing, "invalid JSON: $(Errors.error_string(e))"
    end
    return data, ""
end

"""
Truncate an over-limit decomposition to the first `limit` steps plus a trailing
"remaining work" step that depends on the last kept step.
"""
function _truncate(steps::AbstractVector, limit::Int)
    kept = steps[1:limit]
    return vcat(kept, [Dict{String,Any}(
        "id" => limit + 1,
        "description" => "Remaining work beyond the decomposed steps",
        "depends_on" => [Int(get(steps[limit], "id", limit))],
        "verify" => nothing,
    )])
end

"""
Decompose `goal` into validated step dicts (Plan.create-compatible), or a
fallback single-step decomposition when the model fails twice.
Returns `(steps::Vector{Dict}, ok::Bool, note::String)`.
"""
function decompose(
    goal::String;
    max_steps::Int = MAX_STEPS,
    max_attempts::Int = 2,
)
    isempty(strip(goal)) && throw(Errors.KamilaError(:validation, "goal is required"))
    prompt = _prompt_for(goal)

    last_error = ""
    for attempt in 1:max_attempts
        raw = try
            MODEL_FN[](prompt)
        catch e
            last_error = "model call failed: $(Errors.error_string(e))"
            continue
        end
        data, perr = _parse_model_output(raw)
        if data === nothing
            last_error = perr
            continue
        end
        ok, steps, reason = validate_decomposition(data)
        if !ok
            last_error = reason
            continue
        end
        if length(steps) > max_steps
            steps = _truncate(steps, max_steps)
            return _to_plan_steps(steps), true, "truncated to $max_steps steps plus remaining work"
        end
        return _to_plan_steps(steps), true, ""
    end

    KamilaLog.warn(
        "decompose.fallback";
        mod = "decompose",
        fields = Dict{String,Any}("goal" => goal, "reason" => last_error),
    )
    fallback = [
        Dict{String,Any}(
            "description" => "Complete the goal directly: $goal",
            "depends_on" => Int[],
            "verify" => nothing,
        ),
    ]
    return fallback, true, "fallback single-step decomposition ($last_error)"
end

"""
Decompose `goal` and persist it as a Plan. Returns the persisted `Plan`.
"""
function decompose_to_plan(
    goal::String;
    session::String = "default",
    metadata::Dict{String,Any} = Dict{String,Any}("source" => "decompose"),
    max_steps::Int = MAX_STEPS,
)
    steps, ok, note = decompose(goal; max_steps = max_steps)
    ok || throw(Errors.KamilaError(:internal, "decomposition failed"))
    plan = PlanModule.create(goal, steps; session = session, metadata = metadata)
    return plan
end

end # module