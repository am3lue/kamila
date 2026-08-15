"""
Plan — persisted multi-step plan state machine.

Replaces the bare `while iteration < max_iterations` loop with an explicit
lifecycle: created → pending → active → paused → completed / failed /
cancelled. Each step is runnable only when its `depends_on` steps are
`:verified`, and plans survive process restarts via the `plans` /
`plan_steps` SQLite tables (migration 4).
"""

module Plan

using Dates
using JSON
using SQLite
using ..Kamila
using ..KamilaLog
using ..MemoryDB
using ..Errors
using ..Events
using ..Experience: record as record_experience

export Plan, PlanStep,
    create, start, next_runnable, mark_step, pause, resume, cancel,
    load, load_active, save, list, delete, validate_steps, promote_subplan,
    pause_on_failure

const MAX_PLAN_STEPS = 50
const MAX_RETRIES = 3

mutable struct PlanStep
    id::Int
    description::String
    status::Symbol              # :pending, :running, :verified, :failed, :skipped
    depends_on::Vector{Int}
    tool::String                # tool name, or :verify / :delegate
    args::Dict{String,Any}
    result::Union{Nothing,String}
    attempts::Int
    verify::Union{Nothing,String}   # JSON string of a VerifySpec, or nothing
end

PlanStep(id::Int, description::String, status::Symbol, depends_on::Vector{Int}, tool::String, args::Dict{String,Any}, result::Union{Nothing,String}, attempts::Int) =
    PlanStep(id, description, status, depends_on, tool, args, result, attempts, nothing)

mutable struct Plan
    id::String
    goal::String
    status::Symbol              # :created, :pending, :active, :paused, :completed, :failed, :cancelled
    steps::Vector{PlanStep}
    created_at::DateTime
    updated_at::DateTime
    session::String
    metadata::Dict{String,Any}
    parent_plan_id::Union{Nothing,String}
    parent_step_id::Union{Nothing,Int}
end

const _VALID_PLAN_STATUS = Set([
    :created, :pending, :active, :paused, :completed, :failed, :cancelled,
])
const _VALID_STEP_STATUS = Set([:pending, :running, :verified, :failed, :skipped])

Plan(id, goal) = Plan(id, goal, :created, PlanStep[], now(), now(), "default", Dict{String,Any}(), nothing, nothing)

"""
Read a field from a step spec that may use Symbol or String keys (NamedTuple,
Dict{Symbol}, Dict{String}). Returns `default` when absent.
"""
function _step_field(s, sym::Symbol, str::String, default)
    if s isa NamedTuple
        return hasfield(typeof(s), sym) ? getfield(s, sym) : default
    end
    if haskey(s, sym)
        return s[sym]
    end
    return haskey(s, str) ? s[str] : default
end

"""
Validate step list: non-empty, ids unique and 1..n, dependencies acyclic and
within range, description non-empty, and the plan under the size cap.
Returns (ok::Bool, reason::String).
"""
function validate_steps(steps::Vector{PlanStep})
    isempty(steps) && return (false, "plan has no steps")
    length(steps) > MAX_PLAN_STEPS && return (false, "too many steps (max $MAX_PLAN_STEPS)")

    ids = [s.id for s in steps]
    length(unique(ids)) == length(ids) || return (false, "duplicate step ids")
    for s in steps
        isempty(strip(s.description)) && return (false, "step $(s.id) has empty description")
        for dep in s.depends_on
            dep in ids || return (false, "step $(s.id) depends on unknown step $dep")
        end
    end

    # Cycle detection: DFS over the dependency graph.
    color = Dict{Int,Symbol}()   # :white, :gray, :black
    for s in steps
        color[s.id] = :white
    end
    function visit(id::Int)
        color[id] == :gray && return true
        color[id] == :black && return false
        color[id] = :gray
        s = findfirst(x -> x.id == id, steps)
        s === nothing && return false
        for dep in steps[s].depends_on
            visit(dep) && return true
        end
        color[id] = :black
        return false
    end
    for s in steps
        visit(s.id) && return (false, "dependency cycle detected")
    end

    return (true, "")
end

"""
Create a plan from a goal and a list of steps.
Steps may be given as (description, depends_on, tool, args) tuples or as
PlanStep objects. Invalid plans are rejected (throw).
"""
function create(goal::String, steps; session::String = "default", metadata::Dict{String,Any} = Dict{String,Any}(), parent_plan_id::Union{Nothing,String} = nothing, parent_step_id::Union{Nothing,Int} = nothing)
    isempty(strip(goal)) && throw(Errors.KamilaError(:validation, "plan goal is required"))

    plan_steps = PlanStep[]
    for (i, s) in enumerate(steps)
        if s isa PlanStep
            push!(plan_steps, s)
        else
            desc = _step_field(s, :description, "description", "")
            deps = Vector{Int}(_step_field(s, :depends_on, "depends_on", Int[]))
            tool = string(_step_field(s, :tool, "tool", ""))
            args = Dict{String,Any}(_step_field(s, :args, "args", Dict{String,Any}()))
            verify = _step_field(s, :verify, "verify", nothing)
            verify = verify isa AbstractDict ? JSON.json(verify) :
                     verify isa AbstractString ? verify : nothing
            push!(plan_steps, PlanStep(i, desc, :pending, deps, tool, args, nothing, 0, verify))
        end
    end

    ok, reason = validate_steps(plan_steps)
    ok || throw(Errors.KamilaError(:validation, reason))

    p = Plan(
        _new_id(), goal, :created, plan_steps, now(), now(), session, metadata,
        parent_plan_id, parent_step_id,
    )
    save(p)
    return p
end

function _new_id()
    return "plan-" * string(Dates.value(now())) * "-" * string(rand(1000:9999))
end

"""
Transition guards. Throws on illegal transitions.
"""
function _guard_transition!(p::Plan, to::Symbol)
    allowed = Dict(
        :created => [:pending, :active, :cancelled],
        :pending => [:active, :cancelled],
        :active => [:paused, :completed, :failed, :cancelled],
        :paused => [:active, :cancelled],
        :completed => Symbol[],
        :failed => [:active],
        :cancelled => Symbol[],
    )
    from = p.status
    if !haskey(allowed, from) || !(to in allowed[from])
        throw(
            Errors.KamilaError(
                :validation,
                "illegal plan transition: $from -> $to",
            ),
        )
    end
end

function _guard_step_transition!(s::PlanStep, to::Symbol)
    from = s.status
    if from == :pending
        to in [:running, :skipped] || throw(
            Errors.KamilaError(:validation, "illegal step transition: $from -> $to"),
        )
    elseif from == :running
        to in [:verified, :failed, :skipped] || throw(
            Errors.KamilaError(:validation, "illegal step transition: $from -> $to"),
        )
    elseif from == :failed
        to in [:running, :skipped] || throw(
            Errors.KamilaError(:validation, "illegal step transition: $from -> $to"),
        )
    else
        throw(Errors.KamilaError(:validation, "illegal step transition: $from -> $to"))
    end
end

function _touch!(p::Plan)
    p.updated_at = now()
    return p
end

"""
Start a plan: `:created`/`:pending` → `:active`.
"""
function start(p::Plan)
    p.status in [:created, :pending] || _guard_transition!(p, :active)
    p.status = :active
    save(p)
    return p
end

"""
Pause an active plan.
"""
function pause(p::Plan)
    _guard_transition!(p, :paused)
    p.status = :paused
    save(p)
    return p
end

"""
Resume a paused (or failed) plan.
"""
function resume(p::Plan)
    _guard_transition!(p, :active)
    p.status = :active
    save(p)
    return p
end

"""
Pause a plan because a step failed verification (06.3 orchestrator). Sets the
`metadata["pause_on_failure"]` flag for audit and transitions the plan to
`:paused` so the orchestrator stops dispatching it. The plan must be
`:active`; a non-retryable step failure already sets it to `:failed`, in which
case this is a no-op (the plan is already stopped).
"""
function pause_on_failure(p::Plan)
    if p.status == :failed
        return p
    end
    _guard_transition!(p, :paused)
    p.metadata["pause_on_failure"] = true
    p.status = :paused
    save(p)
    return p
end

"""
Cancel a plan; no further steps may run.
"""
function cancel(p::Plan)
    _guard_transition!(p, :cancelled)
    p.status = :cancelled
    for s in p.steps
        s.status in [:pending, :running] && (s.status = :skipped)
    end
    save(p)
    return p
end

"""
Return the next runnable step: a pending step whose dependencies are verified,
or a `:failed` step with attempts left (retry candidate). Returns nothing when
nothing is runnable.
"""
function next_runnable(p::Plan)
    p.status == :active || return nothing
    verified = Set{Int}([s.id for s in p.steps if s.status == :verified])
    for s in p.steps
        if s.status == :pending
            if all(dep -> dep in verified, s.depends_on)
                return s
            end
        end
    end
    for s in p.steps
        if s.status == :failed && s.attempts < MAX_RETRIES
            if all(dep -> dep in verified, s.depends_on)
                return s
            end
        end
    end
    return nothing
end

"""
Mark a step's status. Runs transition guards, enforces retry policy, and
updates the plan status when appropriate.

`result` is optional (stored on the step). `retryable` is honored only for
`:failed`: a non-retryable failure (e.g. `:permission`) fails the step AND the
plan immediately, whereas a retryable failure leaves the plan `:active` so the
runner may `mark_step(:running)` again (bounded by `MAX_RETRIES`).

Returns the step.
"""
function mark_step(
    p::Plan,
    step_id::Int,
    status::Symbol,
    result::Union{Nothing,String} = nothing;
    retryable::Bool = true,
)
    s = findfirst(x -> x.id == step_id, p.steps)
    s === nothing && throw(Errors.KamilaError(:notfound, "step $step_id not found"))

    _guard_step_transition!(p.steps[s], status)

    if status == :running
        p.steps[s].status = :running
        p.steps[s].attempts += 1
    elseif status == :verified
        result !== nothing && (p.steps[s].result = result)
        p.steps[s].status = :verified
    elseif status == :failed
        result !== nothing && (p.steps[s].result = result)
        p.steps[s].status = :failed
    elseif status == :skipped
        p.steps[s].status = :skipped
    end

    _touch!(p)

    # Plan-level transitions.
    if p.status == :active
        if all(s -> s.status == :verified, p.steps)
            p.status = :completed
        elseif status == :failed && !retryable
            # Non-retryable failure: fail the plan immediately.
            p.status = :failed
        elseif any(
            s -> s.status == :failed && s.attempts >= MAX_RETRIES,
            p.steps,
        ) && all(s -> s.status in [:verified, :failed, :skipped], p.steps)
            # A retryable step exhausted its retries and nothing else can run.
            p.status = :failed
        end
    end

    save(p)

    # 07.1: persist verified/failed outcomes as structured experience (async,
    # best-effort). The negative rows (verified=false) are kept for training.
    if status == :verified
        record_experience(
            kind = "plan",
            goal = p.goal,
            plan_id = p.id,
            step_id = step_id,
            prompt = p.steps[s].description,
            tool = p.steps[s].tool,
            args = p.steps[s].args,
            result = result === nothing ? p.steps[s].result : result,
            verified = true,
            role = "assistant",
        )
    elseif status == :failed
        record_experience(
            kind = "plan",
            goal = p.goal,
            plan_id = p.id,
            step_id = step_id,
            prompt = p.steps[s].description,
            tool = p.steps[s].tool,
            args = p.steps[s].args,
            result = result === nothing ? p.steps[s].result : result,
            verified = false,
            role = "assistant",
        )
    end

    # 06.2: notify the goal engine so linked goals can refresh derived progress
    # and the TUI/daemon can reflect real movement. Fires once per transition.
    if status == :verified
        Events.publish(Dict(
            "kind" => "goal.progress",
            "plan_id" => p.id,
            "step_id" => step_id,
            "plan_status" => string(p.status),
            "verified" => count(s -> s.status == :verified, p.steps),
            "total" => length(p.steps),
        ))
    end
    return p.steps[s]
end

# ─── Sub-plan promotion (04.4) ─────────────────────────────

"""
When a sub-plan completes, mark its parent step `:verified` so the parent plan
advances. Returns the parent plan (or `nothing` if this plan has no parent).
"""
function promote_subplan(p::Plan)
    p.parent_plan_id === nothing && return nothing
    parent = load(p.parent_plan_id)
    parent === nothing && return nothing
    step_id = p.parent_step_id === nothing ? nothing : p.parent_step_id
    if step_id !== nothing
        step = findfirst(x -> x.id == step_id, parent.steps)
        if step !== nothing && parent.steps[step].status == :running
            mark_step(parent, step_id, :verified, "completed by sub-plan $(p.id)")
        end
    end
    return parent
end

# ─── Persistence ──────────────────────────────────────────

function _step_to_row(plan_id::String, s::PlanStep)
    return (
        plan_id,
        s.id,
        s.description,
        string(s.status),
        JSON.json(s.depends_on),
        s.tool,
        JSON.json(s.args),
        s.result === nothing ? nothing : s.result,
        s.attempts,
        s.verify === nothing ? nothing : s.verify,
    )
end

function _row_to_step(r)
    result = r.result === nothing || r.result === missing ? nothing : r.result
    verify = r.verify === nothing || r.verify === missing ? nothing : r.verify
    return PlanStep(
        r.step_id,
        r.description,
        Symbol(r.status),
        JSON.parse(r.depends_on),
        r.tool,
        isempty(r.args) ? Dict{String,Any}() : JSON.parse(r.args),
        result,
        r.attempts,
        verify,
    )
end

"""
Persist a plan (upsert) and its steps. Parent references are carried inside
`metadata` (kept in sync) so no extra schema migration is needed.
"""
function save(p::Plan)
    meta = copy(p.metadata)
    if p.parent_plan_id !== nothing
        meta["parent_plan_id"] = p.parent_plan_id
    else
        delete!(meta, "parent_plan_id")
    end
    if p.parent_step_id !== nothing
        meta["parent_step_id"] = p.parent_step_id
    else
        delete!(meta, "parent_step_id")
    end
    MemoryDB.transaction() do db
        SQLite.execute(
            db,
            """INSERT INTO plans (id, goal, status, created_at, updated_at, session, metadata)
               VALUES (?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(id) DO UPDATE SET
                 goal = excluded.goal, status = excluded.status,
                 updated_at = excluded.updated_at, session = excluded.session,
                 metadata = excluded.metadata""",
            (
                p.id,
                p.goal,
                string(p.status),
                string(p.created_at),
                string(p.updated_at),
                p.session,
                JSON.json(meta),
            ),
        )
        SQLite.execute(db, "DELETE FROM plan_steps WHERE plan_id = ?", (p.id,))
        for s in p.steps
            SQLite.execute(
                db,
                """INSERT INTO plan_steps
                   (plan_id, step_id, description, status, depends_on, tool, args, result, attempts, verify)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                _step_to_row(p.id, s),
            )
        end
    end
    return p
end

function _load_steps(plan_id::String)
    rows = MemoryDB.query_all(
        "SELECT * FROM plan_steps WHERE plan_id = ? ORDER BY step_id",
        (plan_id,),
    )
    return [_row_to_step(r) for r in rows]
end

function _row_to_plan(r, steps::Vector{PlanStep})
    meta = r.metadata === nothing || r.metadata === missing ? "{}" : r.metadata
    parsed = isempty(meta) ? Dict{String,Any}() : JSON.parse(meta)
    parent_id = get(parsed, "parent_plan_id", nothing)
    parent_step = get(parsed, "parent_step_id", nothing)
    parent_step = parent_step === nothing ? nothing : Int(parent_step)
    return Plan(
        r.id,
        r.goal,
        Symbol(r.status),
        steps,
        try
            DateTime(r.created_at)
        catch
            now()
        end,
        try
            DateTime(r.updated_at)
        catch
            now()
        end,
        r.session,
        parsed,
        parent_id,
        parent_step,
    )
end

"""
Load a single plan by id. Returns nothing if not found.
"""
function load(plan_id::String)
    rows = MemoryDB.query_all("SELECT * FROM plans WHERE id = ?", (plan_id,))
    isempty(rows) && return nothing
    return _row_to_plan(rows[1], _load_steps(plan_id))
end

"""
Load all plans matching a status filter (default: all).
"""
function load_all(; status::Union{Symbol,Nothing} = nothing)
    if status === nothing
        rows = MemoryDB.query_all("SELECT * FROM plans ORDER BY created_at DESC")
    else
        rows = MemoryDB.query_all(
            "SELECT * FROM plans WHERE status = ? ORDER BY created_at DESC",
            (string(status),),
        )
    end
    return [_row_to_plan(r, _load_steps(r.id)) for r in rows]
end

"""
Load active or paused plans (in-progress work across restarts).
"""
function load_active()
    return load_all(; status = :active) ∪ load_all(; status = :paused)
end

"""
List plans as lightweight summaries (no steps).
"""
function list(; status::Union{Symbol,Nothing} = nothing)
    return [_summarize(p) for p in load_all(; status = status)]
end

function _summarize(p::Plan)
    return Dict(
        "id" => p.id,
        "goal" => p.goal,
        "status" => string(p.status),
        "step_count" => length(p.steps),
        "verified" => count(s -> s.status == :verified, p.steps),
        "failed" => count(s -> s.status == :failed, p.steps),
        "created_at" => string(p.created_at),
        "updated_at" => string(p.updated_at),
        "session" => p.session,
    )
end

"""
Delete a plan and its steps.
"""
function delete(plan_id::String)
    MemoryDB.transaction() do db
        SQLite.execute(db, "DELETE FROM plan_steps WHERE plan_id = ?", (plan_id,))
        SQLite.execute(db, "DELETE FROM plans WHERE id = ?", (plan_id,))
    end
    return nothing
end

end # module
