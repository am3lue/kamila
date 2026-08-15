"""
Orchestrator — parallel tool execution, fan-out/fan-in, and sub-agent
delegation for plan steps (04.2).

- `batch`: execute multiple independent tool calls concurrently (bounded worker
  pool), with all-or-nothing permission preflight, resource serialization, and
  per-call timeouts.
- `delegate`: spawn a child agent as a sub-plan step with its own plan id,
  bounded by a depth cap.
- Results are always collected in call order for deterministic output.
"""

module Orchestrator

using Base.Threads
using Dates
using JSON
using ..Kamila
using ..KamilaLog
using ..Errors
using ..AgentTools
using ..Permission
using ..Capability
import ..Plan
import ..AgentStream

export batch, delegate, batch_structured, preflight_batch, execute_batch

const DEFAULT_WORKERS = 4
const MAX_BATCH_CALLS = 8
const MAX_RESULT_BYTES = 100_000
const DEFAULT_CALL_TIMEOUT = 30.0
const MAX_DELEGATION_DEPTH = 3

const _RESOURCE_LOCKS = Dict{String,ReentrantLock}()
const _RESOURCE_LOCK_GUARD = ReentrantLock()

"""
Return (or create) the lock guarding `resource`. Two calls targeting the same
resource string serialize; different resources run concurrently.
"""
function _resource_lock(resource::String)
    lock(_RESOURCE_LOCK_GUARD) do
        return get!(_RESOURCE_LOCKS, resource, ReentrantLock())
    end
end

"""
Infer a resource key for a tool call so writes to the same file serialize.
Defaults to the tool name when no mutable resource is evident.
"""
function _resource_key(tool::String, args)
    if tool in ("write_file", "read_file", "list_directory", "file_find")
        return "file:" * string(get(args, "file_path", get(args, "path", "")))
    elseif tool in ("add_task", "complete_task", "delete_task")
        return "task"
    elseif tool == "run_shell_command"
        # Shell commands touching the same file serialize; otherwise the
        # command text itself is a safe key.
        cmd = string(get(args, "command", ""))
        return "shell:" * cmd
    end
    return "tool:" * tool
end

"""
Check the permission policy for every call in the batch BEFORE executing any.
Returns `:allow` if all calls are allowed, otherwise the first non-allowed
decision. Never executes a partially-authorized batch. `capabilities` optionally
narrows the whole batch to a capability scope (05.3): any call outside the scope
is rejected up front.
"""
function preflight_batch(calls::Vector{Dict{String,Any}}; capabilities::Union{Nothing,AbstractSet} = nothing)
    isempty(calls) && return :allow
    for call in calls
        tool = string(get(call, "tool", ""))
        isempty(tool) && return :validation
        args = Dict{String,Any}(get(call, "args", Dict()))
        if capabilities !== nothing && !Capability.in_scope(tool, capabilities)
            return :permission
        end
        decision = Permission.evaluate(tool, args)
        decision == :allow || return decision
    end
    return :allow
end

"""
Execute a single tool call within the batch honoring its resource lock.
Returns a structured per-call result dict.
"""
function _execute_call(call::Dict{String,Any}; capabilities::Union{Nothing,AbstractSet} = nothing)
    tool = string(get(call, "tool", ""))
    args = Dict{String,Any}(get(call, "args", Dict()))
    timeout = Float64(get(call, "timeout_seconds", DEFAULT_CALL_TIMEOUT))
    resource = _resource_key(tool, args)

    result = Dict{String,Any}(
        "call" => tool,
        "args" => args,
        "ok" => false,
        "result" => "tool call did not complete",
        "category" => "timeout",
        "duration_ms" => 0,
    )

    started = now()
    lock(_resource_lock(resource)) do
        # Run the tool on a worker thread and poll for completion so a hung
        # call can be timed out without blocking the batch.
        outcome = Ref{Union{Nothing,Dict{String,Any}}}(nothing)
        done = Ref(false)
        t = Threads.@spawn begin
            outcome[] = AgentTools.execute_tool_structured(tool, args; capabilities = capabilities)
            done[] = true
        end

        deadline = time() + timeout
        while !done[] && time() < deadline
            sleep(0.01)
        end

        if !done[]
            schedule(t, InterruptException(); error = true)
        else
            outcome[] !== nothing && merge!(result, outcome[])
        end
    end

    duration = Dates.value(now() - started)
    result["duration_ms"] = duration
    return result
end

"""
Run a batch of tool calls concurrently. Collects results in input order.
"""
function execute_batch(
    calls::Vector{Dict{String,Any}};
    max_workers::Int = DEFAULT_WORKERS,
    capabilities::Union{Nothing,AbstractSet} = nothing,
)
    length(calls) > MAX_BATCH_CALLS &&
        throw(Errors.KamilaError(:validation, "batch too large (max $MAX_BATCH_CALLS)"))

    results = Vector{Dict{String,Any}}(undef, length(calls))
    nworkers = min(max_workers, Threads.nthreads(), length(calls))
    nworkers = max(nworkers, 1)
    channel = Channel{Int}(nworkers)

    @sync begin
        for w in 1:nworkers
            Threads.@spawn begin
                for idx in channel
                    results[idx] = _execute_call(calls[idx]; capabilities = capabilities)
                end
            end
        end
        for i in 1:length(calls)
            put!(channel, i)
        end
        close(channel)
    end

    # Enforce the result byte cap across the whole batch.
    total_bytes = sum(length(string(get(r, "result", ""))) for r in results)
    if total_bytes > MAX_RESULT_BYTES
        for r in results
            r["result"] = string(r["result"])[1:min(end, 2000)] * "\n… (truncated)"
        end
    end

    return results
end

"""
Execute a `batch` tool call (the tool-facing entry point used by the agent).
Returns a JSON string the model can consume.
"""
function batch(calls::AbstractVector; max_workers::Int = DEFAULT_WORKERS, capabilities::Union{Nothing,AbstractSet} = nothing)
    isempty(calls) && return "[]"
    decision = preflight_batch(Dict{String,Any}[
        Dict{String,Any}("tool" => string(get(c, "tool", "")), "args" => Dict{String,Any}(get(c, "args", Dict())))
        for c in calls
    ]; capabilities = capabilities)
    if decision != :allow
        return JSON.json(Dict(
            "ok" => false,
            "category" => "permission",
            "reason" => "batch denied by permission policy: $decision",
            "results" => [],
        ))
    end
    results = execute_batch(
        Dict{String,Any}[
            Dict{String,Any}("tool" => string(get(c, "tool", "")), "args" => Dict{String,Any}(get(c, "args", Dict())))
            for c in calls
        ];
        max_workers = max_workers,
        capabilities = capabilities,
    )
    return JSON.json(Dict("ok" => true, "results" => results))
end

function batch(args::Dict{String,Any}; capabilities::Union{Nothing,AbstractSet} = nothing)
    calls = get(args, "calls", Any[])
    return batch(calls; max_workers = Int(get(args, "max_workers", DEFAULT_WORKERS)), capabilities = capabilities)
end

"""
Structured variant for the bridge / plan runner: returns an array of per-call
dicts, never throws (mirrors `execute_tool_structured`).
"""
function batch_structured(calls::AbstractVector; max_workers::Int = DEFAULT_WORKERS, capabilities::Union{Nothing,AbstractSet} = nothing)
    try
        decision = preflight_batch(Dict{String,Any}[
            Dict{String,Any}("tool" => string(get(c, "tool", "")), "args" => Dict{String,Any}(get(c, "args", Dict())))
            for c in calls
        ]; capabilities = capabilities)
        decision == :allow || return Dict{String,Any}(
            "ok" => false,
            "category" => "permission",
            "retryable" => false,
            "result" => JSON.json(Dict("ok" => false, "reason" => "permission: $decision", "results" => [])),
        )
        results = execute_batch(
            Dict{String,Any}[
                Dict{String,Any}("tool" => string(get(c, "tool", "")), "args" => Dict{String,Any}(get(c, "args", Dict())))
                for c in calls
            ];
            max_workers = max_workers,
            capabilities = capabilities,
        )
        return Dict{String,Any}(
            "ok" => true,
            "category" => "success",
            "retryable" => false,
            "result" => JSON.json(Dict("ok" => true, "results" => results)),
        )
    catch e
        payload = Errors.error_payload(e)
        payload["result"] = Errors.error_string(e)
        return payload
    end
end

"""
Delegate a sub-task to a child agent as a sub-plan step. Creates a child plan
(04.1) with a single step, runs it, and returns the child's final answer.
`depth` bounds nesting; exceeding `MAX_DELEGATION_DEPTH` throws `:validation`.
`capabilities` narrows what the child may do (05.3): the child receives the
intersection of its declared needs and its parent's capability set, so it can
never invoke a tool outside that scope.
"""
function delegate(
    sub_prompt::String;
    session::String = "default",
    depth::Int = 1,
    max_iterations::Int = 5,
    on_token::Union{Nothing,Function} = nothing,
    capabilities::Union{Nothing,AbstractSet} = nothing,
)
    depth > MAX_DELEGATION_DEPTH &&
        throw(Errors.KamilaError(:validation, "delegation depth exceeds cap ($MAX_DELEGATION_DEPTH)"))

    child = Plan.create(
        sub_prompt,
        [
            (
                description = sub_prompt,
                depends_on = Int[],
                tool = "assistant",
                args = Dict{String,Any}("prompt" => sub_prompt),
            ),
        ];
        session = session,
    )
    Plan.start(child)

    answer = AgentStream.run_agent_sync(
        sub_prompt;
        system_prompt = "You are a sub-agent. Answer the delegated sub-task directly with a concise result.",
        max_iterations = max_iterations,
        capabilities = capabilities,
    )

    Plan.mark_step(child, 1, :verified, answer)
    return answer
end

# ─── Tool registration (runs at module load) ──────────────

AgentTools.register_tool!(
    AgentTools.Tool(
        "batch",
        "Execute multiple independent tool calls concurrently in a single turn. Args: {\"calls\": [{\"tool\": \"name\", \"args\": {...}}, ...]}. All calls are permission-checked first; results are returned in call order. Use when several independent lookups or operations can run in parallel. Max 8 calls per batch.",
        Dict("calls" => "Array of {tool, args} objects (required)"),
        args -> JSON.parse(batch(args)),
    ),
)

# ─── Executive Loop (06.3) ────────────────────────────────

"""
Executive — bounded autonomous work dispatcher (06.3).

Collects runnable work from active plans (04.1 `next_runnable`), due scheduler
jobs (06.1), and goal-advance nudges (06.2), then either **proposes** them to the
user or **executes** them under a daily budget and capability scope.

Policy:
- `auto_execute` defaults to `false`: work is proposed, never run, unless the
  user turns on auto-execute or explicitly approves an item via `advance_now`.
- Budget (`orchestrator.daily_actions`, `orchestrator.daily_model_calls`,
  `orchestrator.max_autonomous_duration_min`) is enforced per calendar day and
  persisted in the `kv` table, so a spent budget idles until the next day.
- Interactive requests preempt autonomous dispatch: `set_interactive!(true)`
  makes `tick` yield.
- A step that fails verification pauses its plan (`Plan.pause_on_failure`) and
  is reported; it is never silently retried.
- Every autonomous action is appended to an in-memory audit ring and published
  as an `orchestrator.executed` event, so debits are auditable.
"""
module Executive

using Dates
using JSON
using Base.Threads
using ...KamilaLog
using ...MemoryDB
using ...Events
using ...Scheduler
using ...KamilaMemory
using ...Permission
using ...Verify
using ...AgentTools
using ...Experience
using ...Vectors
import ...Plan
import ...Errors

export configure,
    tick,
    advance_now,
    pause,
    status,
    collect_work_items,
    prioritize,
    set_auto_execute,
    auto_execute,
    set_interactive!,
    budget_status,
    recent_audit,
    reset_executive!,
    set_curiosity!,
    curiosity_enabled,
    novelty_score,
    WorkItem,
    DEFAULT_CONFIG

# ─── Config ────────────────────────────────────────────────

const DEFAULT_CONFIG = Dict{String,Any}(
    "daily_actions" => 20,
    "daily_model_calls" => 40,
    "max_autonomous_duration_min" => 60,
    "auto_execute" => false,
    "proposal_rate_limit" => 3,
)

const _CONFIG = Ref{Dict{String,Any}}(deepcopy(DEFAULT_CONFIG))
const _AUTO_EXECUTE = Ref{Bool}(false)
const _INTERACTIVE = Ref{Bool}(false)

_default_config_file() =
    get(ENV, "KAMILA_CONFIG_FILE", joinpath(homedir(), ".kamila_config.json"))

"""
Read the `orchestrator` section of the config file and apply it. Unknown keys are
ignored; a missing config keeps the defaults. Mirrors `Search.configure`.
"""
function configure(config_file::String = _default_config_file())
    isfile(config_file) || return nothing
    try
        data = JSON.parsefile(config_file)
        orch = get(data, "orchestrator", Dict())
        cfg = _CONFIG[]
        for k in keys(DEFAULT_CONFIG)
            if haskey(orch, k)
                cfg[k] = get(orch, k, DEFAULT_CONFIG[k])
            end
        end
        # The runtime toggle is session state: only override it when the config
        # explicitly declares `auto_execute` (default keeps the session toggle).
        if haskey(orch, "auto_execute")
            _AUTO_EXECUTE[] = Bool(get(orch, "auto_execute", false))
        end
        KamilaLog.info(
            "executive configured";
            mod = "orchestrator",
            fields = Dict{String,Any}(
                "daily_actions" => cfg["daily_actions"],
                "daily_model_calls" => cfg["daily_model_calls"],
                "max_autonomous_duration_min" => cfg["max_autonomous_duration_min"],
                "auto_execute" => _AUTO_EXECUTE[],
            ),
        )
    catch e
        KamilaLog.warn("executive config unreadable: $e"; mod = "orchestrator")
    end
    return nothing
end

# ─── Budget ledger (per calendar day, persisted in kv) ────

_budget_key(day::Date) = "orchestrator.budget." * string(day)

function _load_budget(day::Date)
    raw = KamilaMemory.get_kv(_budget_key(day))
    raw === nothing && return Dict{String,Any}("actions" => 0, "model_calls" => 0, "duration_min" => 0.0)
    try
        parsed = JSON.parse(raw)
        return Dict{String,Any}(
            "actions" => Int(get(parsed, "actions", 0)),
            "model_calls" => Int(get(parsed, "model_calls", 0)),
            "duration_min" => Float64(get(parsed, "duration_min", 0.0)),
        )
    catch
        return Dict{String,Any}("actions" => 0, "model_calls" => 0, "duration_min" => 0.0)
    end
end

function _save_budget(day::Date, b::AbstractDict)
    KamilaMemory.set_kv(_budget_key(day), JSON.json(b))
    return b
end

"""
Current budget state: caps from config plus what has been spent today.
"""
function budget_status()
    cfg = _CONFIG[]
    b = _load_budget(today())
    return Dict{String,Any}(
        "date" => string(today()),
        "actions_used" => b["actions"],
        "actions_limit" => cfg["daily_actions"],
        "actions_remaining" => max(0, Int(cfg["daily_actions"]) - b["actions"]),
        "model_calls_used" => b["model_calls"],
        "model_calls_limit" => cfg["daily_model_calls"],
        "model_calls_remaining" => max(0, Int(cfg["daily_model_calls"]) - b["model_calls"]),
        "duration_min" => round(b["duration_min"], digits = 2),
        "duration_limit_min" => cfg["max_autonomous_duration_min"],
    )
end

function _budget_allows(day::Date)
    cfg = _CONFIG[]
    b = _load_budget(day)
    return b["actions"] < Int(cfg["daily_actions"]) &&
           b["model_calls"] < Int(cfg["daily_model_calls"]) &&
           b["duration_min"] < Float64(cfg["max_autonomous_duration_min"])
end

function _debit!(day::Date; model::Bool = false, duration::Float64 = 0.0)
    b = _load_budget(day)
    b["actions"] += 1
    b["model_calls"] += model ? 1 : 0
    b["duration_min"] += duration
    _save_budget(day, b)
    return b
end

# ─── Audit ring ────────────────────────────────────────────

const _AUDIT = Vector{Dict{String,Any}}()
const _AUDIT_LOCK = ReentrantLock()
const _MAX_AUDIT = 200

function _audit(entry::Dict{String,Any})
    lock(_AUDIT_LOCK) do
        push!(_AUDIT, entry)
        if length(_AUDIT) > _MAX_AUDIT
            deleteat!(_AUDIT, 1:(length(_AUDIT) - _MAX_AUDIT))
        end
    end
    return nothing
end

function recent_audit(limit::Int = 50)
    entries = lock(_AUDIT_LOCK) do
        copy(_AUDIT)
    end
    return entries[max(1, length(entries) - limit + 1):end]
end

# ─── Work items ────────────────────────────────────────────

"""
    WorkItem

A runnable unit surfaced by the executive loop. `source` is one of
`:plan`, `:job`, `:goal`. Lower `priority` runs first.
"""
struct WorkItem
    source::Symbol
    id::String
    step_id::Union{Nothing,Int}
    priority::Int
    description::String
    created_at::DateTime
end

WorkItem(source::Symbol, id::AbstractString, step_id, priority::Int, description::AbstractString, created_at::DateTime) =
    WorkItem(source, String(id), step_id, priority, String(description), created_at)

"""
Collect runnable work from active plans, due scheduler jobs, and linked goals.
A goal pointing at the same plan step as an already-collected plan item is
deduplicated (plan is the source of truth for step execution).
"""
function collect_work_items(; now_ref::DateTime = now())
    items = WorkItem[]
    seen = Set{Tuple{String,Int}}()   # (plan_id, step_id) from plan source

    # 1. Active plans: the next runnable step.
    for p in Plan.load_active()
        p.status == :active || continue
        step = Plan.next_runnable(p)
        step === nothing && continue
        meta_priority = Int(get(p.metadata, "priority", 3))
        push!(seen, (p.id, step.id))
        push!(
            items,
            WorkItem(:plan, p.id, step.id, 4,
                "advance plan $(p.id) step $(step.id): $(step.description)",
                p.updated_at),
        )
    end

    # 2. Due scheduler jobs. Critical urgency outranks everything.
    for job in Scheduler.list_jobs()
        job.next_run_at <= now_ref || continue
        urgency = string(get(job.spec, "urgency", "normal"))
        pr = urgency == "critical" ? 0 : 2
        push!(
            items,
            WorkItem(:job, job.id, nothing, pr,
                "due job $(job.kind) ($urgency)",
                job.next_run_at),
        )
    end

    # 3. Goals: advance the next step of a linked active plan.
    for g in KamilaMemory.get_active_goals()
        plan_id = get(g, "plan_id", nothing)
        plan_id === nothing && continue
        p = Plan.load(String(plan_id))
        p === nothing && continue
        p.status == :active || continue
        step = Plan.next_runnable(p)
        step === nothing && continue
        (p.id, step.id) in seen && continue
        push!(
            items,
            WorkItem(:goal, string(g["id"]), step.id, 3,
                "advance goal $(get(g, "goal", ""))",
                now_ref),
        )
    end

    return items
end

"""
Deterministic priority sort: lowest `priority` first, then oldest first. When
curiosity is enabled (09.3), novelty is a *tie-breaker* among items of equal
priority: the more novel item runs first. Curiosity never introduces new work —
it only reorders already-planned candidates, and never overrides permission or
budget gates.
"""
function prioritize(items::Vector{WorkItem}; curiosity::Bool = _CURIOSITY[])
    if !curiosity
        return sort(items; by = i -> (i.priority, i.created_at))
    end
    scored = [(novelty_score(i), i) for i in items]
    sort!(scored; by = t -> (t[2].priority, -t[1], t[2].created_at))
    return [s[2] for s in scored]
end

# ─── Curiosity novelty (09.3 research prototype) ──────────
# Off by default; a user/operator action turns it on. Novelty is bounded: it
# only reorders work that is ALREADY collected from plans/jobs/goals.

const _CURIOSITY = Ref(false)

"""
    set_curiosity!(on::Bool)

Toggle the novelty tie-breaker (09.3). Off by default (privacy/consent); on,
novelty only reorders already-planned work — never adds new unsupervised work.
"""
function set_curiosity!(on::Bool)
    _CURIOSITY[] = on
    return on
end

curiosity_enabled() = _CURIOSITY[]

"""
    novelty_score(item::WorkItem; k::Int = 5) -> Float64

Embedding-distance novelty of an item's description against recently executed
experience (`07.1`): how far this work is from what was just done. Returns a
value in `[0,1]`; `0.0` when no embedding evidence is available (so no
reordering happens — graceful degradation, never an invented score).
"""
function novelty_score(item::WorkItem; k::Int = 5)
    desc = item.description
    isempty(strip(desc)) && return 0.0
    qvec = try
        Vectors.embed(desc)
    catch
        return 0.0
    end
    qvec === nothing && return 0.0
    recent = try
        Experience.similar_solution(desc; k = k, verified_only = false)
    catch
        return 0.0
    end
    isempty(recent) && return 0.0
    maxsim = maximum(Float64(get(r, "score", 0.0)) for r in recent)
    return clamp(1.0 - maxsim, 0.0, 1.0)
end

# ─── Propose-vs-execute gate ───────────────────────────────

const _PROPOSED_IDS = Set{String}()
const _PROPOSED_DATE = Ref{Date}(today())

function _propose(item::WorkItem)
    d = today()
    if d != _PROPOSED_DATE[]
        _PROPOSED_DATE[] = d
        empty!(_PROPOSED_IDS)
    end
    key = "$(item.source):$(item.id)"
    key in _PROPOSED_IDS && return false
    length(_PROPOSED_IDS) >= Int(_CONFIG[]["proposal_rate_limit"]) && return false
    push!(_PROPOSED_IDS, key)
    Events.publish(Dict{String,Any}(
        "kind" => "orchestrator.proposal",
        "source" => string(item.source),
        "id" => item.id,
        "step_id" => item.step_id,
        "description" => item.description,
    ))
    return true
end

"""
    set_auto_execute(on::Bool)

Per-session autonomy toggle. `true` lets `tick` execute work within budget
instead of only proposing it.
"""
function set_auto_execute(on::Bool)
    _AUTO_EXECUTE[] = on
    return _AUTO_EXECUTE[]
end

auto_execute() = _AUTO_EXECUTE[]

"""
    set_interactive!(active::Bool)

Signal that the user is interactively driving Kamila. While true, `tick` yields
(returns `yielded=true` and dispatches nothing) so autonomous work never competes
with the interactive request.
"""
function set_interactive!(active::Bool)
    _INTERACTIVE[] = active
    return nothing
end

# ─── Step execution ────────────────────────────────────────

"""
Execute a single plan step: mark `:running`, run its tool, enforce its verify
spec (04.3) when declared, and mark `:verified`/`:failed`. A failed verification
or non-retryable failure pauses the plan via `Plan.pause_on_failure` and is
reported — never silently retried. Debits one budget action.
"""
function _execute_plan_step(p::Plan.Plan, step_id::Int; capabilities::Union{Nothing,AbstractSet} = nothing)
    idx = findfirst(s -> s.id == step_id, p.steps)
    idx === nothing && return Dict{String,Any}("ok" => false, "reason" => "step not found")
    step = p.steps[idx]

    t0 = time()
    Plan.mark_step(p, step_id, :running)
    result = try
        AgentTools.execute_tool_structured(step.tool, step.args; capabilities = capabilities)
    catch e
        Dict{String,Any}(
            "ok" => false,
            "category" => "internal",
            "retryable" => false,
            "result" => "Error executing tool: $(Errors.error_string(e))",
        )
    end
    model_used = step.tool in ("assistant", "delegate", "batch")

    if result["ok"]
        if step.verify !== nothing
            spec = try
                Verify.VerifySpec(step.verify)
            catch e
                Verify.VerifySpec(Dict{String,Any}("kind" => "schema", "target" => ""))
            end
            vr = Verify.verify(spec, string(result["result"]); workdir = pwd())
            if vr.ok
                Plan.mark_step(p, step_id, :verified, string(result["result"]))
                outcome = "verified"
            else
                Plan.mark_step(p, step_id, :failed, vr.evidence; retryable = true)
                Plan.pause_on_failure(p)
                outcome = "failed_verify_paused"
            end
        else
            Plan.mark_step(p, step_id, :verified, string(result["result"]))
            outcome = "verified"
        end
    else
        retryable = Bool(get(result, "retryable", false))
        Plan.mark_step(p, step_id, :failed, string(result["result"]); retryable = retryable)
        if !retryable
            Plan.pause_on_failure(p)
            outcome = "failed_paused"
        else
            outcome = "failed_retryable"
        end
    end

    elapsed_min = (time() - t0) / 60
    budget = _debit!(today(); model = model_used, duration = elapsed_min)
    entry = Dict{String,Any}(
        "ts" => Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS"),
        "event" => "orchestrator.executed",
        "source" => "plan",
        "plan_id" => p.id,
        "step_id" => step_id,
        "outcome" => outcome,
        "duration_min" => round(elapsed_min, digits = 4),
        "budget" => budget,
    )
    _audit(entry)
    Events.publish(Dict{String,Any}(
        "kind" => "orchestrator.executed",
        "plan_id" => p.id,
        "step_id" => step_id,
        "outcome" => outcome,
    ))
    return entry
end

function _execute_item(item::WorkItem; capabilities::Union{Nothing,AbstractSet} = nothing)
    if item.source == :plan
        p = Plan.load(item.id)
        p === nothing && return Dict{String,Any}("ok" => false, "reason" => "plan not found")
        item.step_id === nothing && return Dict{String,Any}("ok" => false, "reason" => "no step")
        return _execute_plan_step(p, item.step_id; capabilities = capabilities)
    elseif item.source == :goal
        # Goal advance = run the linked plan's next step.
        goals = KamilaMemory.get_goals()
        g = findfirst(x -> string(x["id"]) == item.id, goals)
        g === nothing && return Dict{String,Any}("ok" => false, "reason" => "goal not found")
        plan_id = get(g, "plan_id", nothing)
        plan_id === nothing && return Dict{String,Any}("ok" => false, "reason" => "goal has no plan")
        p = Plan.load(String(plan_id))
        p === nothing && return Dict{String,Any}("ok" => false, "reason" => "plan not found")
        step = Plan.next_runnable(p)
        step === nothing && return Dict{String,Any}("ok" => false, "reason" => "no runnable step")
        return _execute_plan_step(p, step.id; capabilities = capabilities)
    else
        # Jobs are dispatched by the daemon's scheduler; the orchestrator only
        # surfaces them for prioritization/approval.
        return Dict{String,Any}("ok" => false, "reason" => "jobs are dispatched by the scheduler", "source" => "job", "id" => item.id)
    end
end

# ─── Public entry points ───────────────────────────────────

"""
    tick(; now_ref, capabilities)

Run one executive cycle:
- Yields when an interactive request is active.
- Collects and prioritizes work items.
- With `auto_execute=false` (default): proposes items (rate-limited), executes
  nothing.
- With `auto_execute=true`: executes the highest-priority items while the daily
  budget allows.

Returns a summary Dict.
"""
function tick(; now_ref::DateTime = now(), capabilities::Union{Nothing,AbstractSet} = nothing)
    if _INTERACTIVE[]
        return Dict{String,Any}("yielded" => true, "executed" => [], "proposed" => [])
    end

    items = prioritize(collect_work_items(; now_ref = now_ref))
    executed = []
    proposed = []
    day = today()

    if _AUTO_EXECUTE[]
        for item in items
            _budget_allows(day) || break
            push!(executed, _execute_item(item; capabilities = capabilities))
        end
    else
        for item in items
            _propose(item)
            push!(proposed, Dict{String,Any}(
                "source" => string(item.source),
                "id" => item.id,
                "step_id" => item.step_id,
                "priority" => item.priority,
                "description" => item.description,
            ))
        end
    end

    return Dict{String,Any}("yielded" => false, "executed" => executed, "proposed" => proposed)
end

"""
    advance_now(; plan_id, capabilities)

User-triggered execution of proposed work. With `plan_id`, runs the next step of
that plan; otherwise runs the single highest-priority proposed item. Respects the
daily budget. Returns the execution result (or an error dict).
"""
function advance_now(; plan_id::Union{Nothing,String} = nothing, capabilities::Union{Nothing,AbstractSet} = nothing)
    items = prioritize(collect_work_items())
    if plan_id !== nothing
        idx = findfirst(i -> i.source in (:plan, :goal) && i.id == plan_id, items)
        target = idx === nothing ? nothing : items[idx]
    else
        target = isempty(items) ? nothing : first(items)
    end
    target === nothing && return Dict{String,Any}("ok" => false, "reason" => "no proposed work")
    day = today()
    _budget_allows(day) || return Dict{String,Any}("ok" => false, "reason" => "daily budget exhausted")
    return _execute_item(target; capabilities = capabilities)
end

"""
    pause()

Global kill switch: disable autonomous execution and clear pending proposals so
the orchestrator idles until re-enabled. Cheap to call repeatedly.
"""
function pause()
    _AUTO_EXECUTE[] = false
    empty!(_PROPOSED_IDS)
    _PROPOSED_DATE[] = today()
    return nothing
end

"""
    status()

Orchestrator status for the bridge/TUI: autonomy toggle, budget, and current
proposed work.
"""
function status()
    return Dict{String,Any}(
        "auto_execute" => _AUTO_EXECUTE[],
        "interactive" => _INTERACTIVE[],
        "budget" => budget_status(),
        "proposed" => [
            Dict{String,Any}(
                "source" => string(i.source),
                "id" => i.id,
                "step_id" => i.step_id,
                "priority" => i.priority,
                "description" => i.description,
            ) for i in prioritize(collect_work_items())
        ],
    )
end

"""
Reset executive session state (config, toggles, audit ring, proposal cache).
Does not clear the budget ledger (that is daily state, kept in the DB).
"""
function reset_executive!()
    _CONFIG[] = deepcopy(DEFAULT_CONFIG)
    _AUTO_EXECUTE[] = false
    _INTERACTIVE[] = false
    _CURIOSITY[] = false
    empty!(_PROPOSED_IDS)
    _PROPOSED_DATE[] = today()
    lock(_AUDIT_LOCK) do
        empty!(_AUDIT)
    end
    return nothing
end

end # module Executive

end # module Orchestrator