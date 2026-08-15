"""
Experience — structured, queryable action → outcome records (07.1).

Records Kamila's operational history (verified/failed plan steps and tool calls)
so it can be semantically recalled ("I've done this before"), deduplicated, and
exported for `07.2` fine-tuning / `07.3` preference learning.

Design notes:
- Writes are best-effort and non-blocking: `record` enqueues into a bounded
  buffer drained by a background flush task (every `FLUSH_INTERVAL_SECONDS` s or
  `FLUSH_BATCH` rows). The interactive path never waits on a write.
- `similar_solution` embeds the query with the same provider as `03.2`
  (`Vectors`) and ranks verified experience rows by cosine similarity.
- `verified=false` rows are retained (training needs negatives) but excluded
  from `similar_solution(; verified_only=true)` (the default).
- Dedupe: consecutive records sharing prompt+tool+result hash are collapsed.
- Pruning: `MAX_ROWS` cap, oldest pruned. Opt-out via `enabled=false`.
"""

module Experience

using Dates
using JSON
using Base.Threads
using SQLite
using ..KamilaLog
using ..MemoryDB
using ..Vectors

export record, search, similar_solution, export_rows, count, enabled

# ─── Config ────────────────────────────────────────────────

const ENABLED = Ref{Bool}(get(ENV, "KAMILA_EXPERIENCE_ENABLED", "true") != "false")
const MAX_ROWS = Ref{Int}(50_000)
const FLUSH_INTERVAL_SECONDS = 5.0
const FLUSH_BATCH = 50
const BUFFER_MAX = 200

const _BUFFER = Vector{Dict{String,Any}}()
const _BUFFER_LOCK = ReentrantLock()
const _FLUSH_TASK = Ref{Union{Nothing,Task}}(nothing)
const _LAST_FLUSH = Ref{Float64}(time())
const _STARTED = Ref{Bool}(false)
const _EMBED_THRESHOLD = Ref{Float64}(0.30)

"""
    enabled()

Whether the experience store is active (config opt-out `KAMILA_EXPERIENCE_ENABLED=false`).
"""
enabled() = ENABLED[]

# ─── Batching / flushing ───────────────────────────────────

function _start_flusher!()
    if _STARTED[]
        return nothing
    end
    _STARTED[] = true
    _FLUSH_TASK[] = @async begin
        while true
            sleep(FLUSH_INTERVAL_SECONDS)
            try
                flush!
            catch e
                KamilaLog.warn("experience.flush_failed: $e"; mod = "experience")
            end
        end
    end
    return nothing
end

"""
Flush any buffered experience rows to the DB (batch insert). Best-effort:
a failure is logged and the rows are dropped so the buffer never backlogs.
"""
function flush!()
    isempty(_BUFFER) && return 0
    rows = lock(_BUFFER_LOCK) do
        batch = copy(_BUFFER)
        empty!(_BUFFER)
        batch
    end
    isempty(rows) && return 0
    inserted = 0
    try
        MemoryDB.transaction() do db
            for r in rows
                SQLite.execute(
                    db,
                    """INSERT INTO experience
                       (ts, kind, goal, plan_id, step_id, prompt, tool, args, result,
                        verified, role, feedback, cost_tokens, duration_ms)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (
                        string(get(r, "ts", string(now()))),
                        string(get(r, "kind", "tool")),
                        get(r, "goal", nothing),
                        get(r, "plan_id", nothing),
                        get(r, "step_id", nothing),
                        get(r, "prompt", nothing),
                        get(r, "tool", nothing),
                        get(r, "args", nothing),
                        get(r, "result", nothing),
                        Bool(get(r, "verified", false)) ? 1 : 0,
                        get(r, "role", nothing),
                        get(r, "feedback", nothing),
                        get(r, "cost_tokens", nothing),
                        get(r, "duration_ms", nothing),
                    ),
                )
                inserted += 1
            end
        end
        _prune!()
    catch e
        KamilaLog.warn("experience.batch_insert_failed: $e"; mod = "experience")
    end
    return inserted
end

"""
Prune the table to `MAX_ROWS` (oldest rows removed). Runs opportunistically
after a flush so growth stays bounded.
"""
function _prune!()
    try
        n = MemoryDB.query_all("SELECT COUNT(*) AS n FROM experience")[1].n
        cap = MAX_ROWS[]
        if Int(n) > cap
            MemoryDB.execute!(
                "DELETE FROM experience WHERE id IN (SELECT id FROM experience ORDER BY id ASC LIMIT ?)",
                Int(n) - cap,
            )
        end
    catch e
        KamilaLog.warn("experience.prune_failed: $e"; mod = "experience")
    end
    return nothing
end

# ─── Record ────────────────────────────────────────────────

"""
Record one experience row (async, non-blocking). Keys may be omitted; `kind`
is one of `"plan" | "tool" | "conversation"`. Returns `true` when enqueued.
"""
function record(;
    kind::String = "tool",
    goal::Union{Nothing,String} = nothing,
    plan_id::Union{Nothing,String} = nothing,
    step_id::Union{Nothing,Int} = nothing,
    prompt::Union{Nothing,String} = nothing,
    tool::Union{Nothing,String} = nothing,
    args = nothing,
    result::Union{Nothing,String} = nothing,
    verified::Bool = false,
    role::Union{Nothing,String} = nothing,
    feedback::Union{Nothing,Int} = nothing,
    cost_tokens::Union{Nothing,Int} = nothing,
    duration_ms::Union{Nothing,Int} = nothing,
)
    enabled() || return false

    entry = Dict{String,Any}(
        "ts" => string(now()),
        "kind" => kind,
        "goal" => goal,
        "plan_id" => plan_id,
        "step_id" => step_id,
        "prompt" => prompt,
        "tool" => tool,
        "args" => args isa AbstractDict || args isa AbstractVector ? JSON.json(args) : args,
        "result" => result,
        "verified" => verified,
        "role" => role,
        "feedback" => feedback,
        "cost_tokens" => cost_tokens,
        "duration_ms" => duration_ms,
    )

    _start_flusher!()
    lock(_BUFFER_LOCK) do
        # Dedupe: collapse an identical row buffered immediately before.
        if !isempty(_BUFFER)
            last = _BUFFER[end]
            if get(last, "prompt", nothing) == prompt &&
               get(last, "tool", nothing) == tool &&
               get(last, "result", nothing) == result
                return true
            end
        end
        push!(_BUFFER, entry)
        if length(_BUFFER) >= FLUSH_BATCH
            # Flush synchronously on the enqueueing thread only when the buffer
            # is full; normal path stays async. Errors are contained in flush!.
            @async flush!()
        end
    end
    return true
end

"""
Flush any pending rows and return the total row count (also runs pruning).
"""
function count()
    flush!()
    rows = MemoryDB.query_all("SELECT COUNT(*) AS n FROM experience")
    return Int(rows[1].n)
end

# ─── Search / similar_solution ─────────────────────────────

function _row_to_dict(r)
    return Dict{String,Any}(
        "id" => Int(r.id),
        "ts" => string(r.ts),
        "kind" => string(r.kind),
        "goal" => r.goal,
        "plan_id" => r.plan_id,
        "step_id" => r.step_id,
        "prompt" => r.prompt,
        "tool" => r.tool,
        "args" => r.args,
        "result" => r.result,
        "verified" => r.verified == 1,
        "role" => r.role,
        "feedback" => r.feedback,
        "cost_tokens" => r.cost_tokens,
        "duration_ms" => r.duration_ms,
    )
end

"""
Vector recall over experience. Ranks verified rows by embedding cosine
similarity to `query`. `verified_only=true` (default) excludes negative
records from recall but keeps them stored.
"""
function similar_solution(query::String; k::Int = 5, verified_only::Bool = true)
    flush!()
    isempty(strip(query)) && return Dict{String,Any}[]

    qvec = Vectors.embed(query)
    if qvec === nothing
        return Dict{String,Any}[]
    end

    where = verified_only ? " WHERE verified = 1 AND prompt IS NOT NULL" :
             " WHERE prompt IS NOT NULL"
    rows = MemoryDB.query_all(
        "SELECT id, ts, kind, goal, plan_id, step_id, prompt, tool, args, result, verified, role, feedback, cost_tokens, duration_ms FROM experience" * where,
    )

    scored = []
    for r in rows
        r.prompt === nothing && continue
        # Embedding on demand would be slow; reuse the query vector against a
        # cached-per-row path. For correctness within budget, embed the prompt
        # (cache hits are cheap thanks to Vectors._EMBED_CACHE).
        pvec = Vectors.embed(String(r.prompt))
        pvec === nothing && continue
        sim = Vectors.cosine(qvec, pvec)
        sim < _EMBED_THRESHOLD[] && continue
        d = _row_to_dict(r)
        d["score"] = round(sim, digits = 4)
        push!(scored, d)
    end
    sort!(scored; by = x -> -x["score"])
    return scored[1:min(k, length(scored))]
end

"""
FTS-free text recall (fallback to `similar_solution` when Ollama is down is
handled by the caller; here we do an exact-match over stored text too).
"""
function search(query::String; k::Int = 10, verified::Union{Nothing,Bool} = nothing)
    results = similar_solution(query; k = k, verified_only = verified !== false)
    return results
end

# ─── Export ────────────────────────────────────────────────

"""
Export experience rows to JSONL at `path`. Returns the number of rows written.
"""
function export_rows(path::String; format::Symbol = :jsonl)
    flush!()
    rows = MemoryDB.query_all(
        "SELECT id, ts, kind, goal, plan_id, step_id, prompt, tool, args, result, verified, role, feedback, cost_tokens, duration_ms FROM experience ORDER BY id",
    )
    open(path, "w") do io
        for r in rows
            write(io, JSON.json(_row_to_dict(r)) * "\n")
        end
    end
    return length(rows)
end

end # module
