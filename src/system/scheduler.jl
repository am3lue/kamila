"""
Scheduler — persisted job scheduling for the proactive daemon (06.1).

Jobs live in the `scheduled_jobs` table (schema v6). Each job has a `kind`
(`reminder` | `check` | `daily_report` | `web_poll`), a JSON `spec`, and a
`next_run_at` timestamp. `run_due!(run_job)` runs every job whose time has
arrived and computes the next run (once for catch-up, then every
`interval_seconds`). Delivering a job's effect is the caller's job — the
scheduler never touches tools or permissions directly.
"""

module Scheduler

using Dates
using JSON
using ..MemoryDB
using ..KamilaLog
using ..Errors

export Job,
    create_job,
    list_jobs,
    get_job,
    delete_job,
    run_due!,
    set_next_run,
    mark_status,
    DEFAULT_INTERVALS

# Default intervals (seconds) per kind, used when a spec omits interval.
const DEFAULT_INTERVALS = Dict{String,Int}(
    "reminder" => 0,       # one-shot unless spec.interval set
    "check" => 3600,       # 1h health checks
    "daily_report" => 86400,
    "web_poll" => 3600,
)

struct Job
    id::String
    kind::String
    spec::Dict{String,Any}
    next_run_at::DateTime
    interval_seconds::Union{Nothing,Int}
    last_status::String
    last_run_at::Union{Nothing,DateTime}
    created_at::DateTime
    updated_at::DateTime
end

_parse_dt(s) = try
    DateTime(s)
catch
    now()
end

function _job_from_row(row)
    return Job(
        string(get(row, :id, "")),
        string(get(row, :kind, "")),
        try
            d = JSON.parse(string(get(row, :spec, "{}")))
            d isa AbstractDict ? Dict{String,Any}(String(k) => v for (k, v) in d) :
            Dict{String,Any}()
        catch
            Dict{String,Any}()
        end,
        _parse_dt(string(get(row, :next_run_at, string(now())))),
        get(row, :interval_seconds, nothing) === nothing ? nothing : Int(get(row, :interval_seconds, 0)),
        string(get(row, :last_status, "pending")),
        get(row, :last_run_at, nothing) === nothing ? nothing : _parse_dt(string(get(row, :last_run_at, ""))),
        _parse_dt(string(get(row, :created_at, string(now())))),
        _parse_dt(string(get(row, :updated_at, string(now())))),
    )
end

function _next_id()
    return string(time_ns(), "-", rand(1:Int64(1e12)))
end

"""
Create a job. `at` is a DateTime (or string) for the first run; `interval_seconds`
repeats the job after each run (0/nothing = one-shot). Returns the `Job`.
"""
function create_job(
    kind::String;
    spec::AbstractDict = Dict{String,Any}(),
    at::Union{Nothing,DateTime} = nothing,
    interval_seconds::Union{Nothing,Int} = nothing,
)
    id = _next_id()
    next_run = at === nothing ? now() : at
    interval = interval_seconds === nothing ? get(DEFAULT_INTERVALS, kind, 0) : interval_seconds
    now_s = string(now())
    MemoryDB.execute!(
        """
        INSERT INTO scheduled_jobs
            (id, kind, spec, next_run_at, interval_seconds, last_status,
             last_run_at, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, 'pending', NULL, ?, ?)
        """,
        (id, kind, JSON.json(Dict{String,Any}(spec)), string(next_run), interval,
            now_s, now_s),
    )
    return get_job(id)
end

function list_jobs(kind::Union{Nothing,String} = nothing)
    rows = kind === nothing ?
        MemoryDB.query_all("SELECT * FROM scheduled_jobs ORDER BY next_run_at") :
        MemoryDB.query_all("SELECT * FROM scheduled_jobs WHERE kind = ? ORDER BY next_run_at", kind)
    return [_job_from_row(r) for r in rows]
end

function get_job(id::String)
    rows = MemoryDB.query_all("SELECT * FROM scheduled_jobs WHERE id = ?", id)
    isempty(rows) && return nothing
    return _job_from_row(first(rows))
end

function delete_job(id::String)
    MemoryDB.execute!("DELETE FROM scheduled_jobs WHERE id = ?", id)
    return nothing
end

"""
Set the next run time for a job (after a run, or for manual reschedule).
"""
function set_next_run(id::String, at::DateTime)
    MemoryDB.execute!(
        "UPDATE scheduled_jobs SET next_run_at = ?, updated_at = ? WHERE id = ?",
        (string(at), string(now()), id),
    )
    return nothing
end

function mark_status(id::String, status::String; at::Union{Nothing,DateTime} = nothing)
    MemoryDB.execute!(
        "UPDATE scheduled_jobs SET last_status = ?, last_run_at = COALESCE(?, last_run_at), updated_at = ? WHERE id = ?",
        (status, at === nothing ? nothing : string(at), string(now()), id),
    )
    return nothing
end

"""
Run every job whose `next_run_at` has arrived, once. `run_job` is called with
the `Job`; it returns `true` on success (any return is treated as completion).
After a run, a repeating job is advanced by `interval_seconds` from *now* (so a
missed interval catches up only once, then resumes cadence); one-shot jobs are
deleted. Returns the number of jobs run.
"""
function run_due!(run_job::Function; now_ref::DateTime = now())
    due = list_jobs()
    ran = 0
    for job in due
        job.next_run_at <= now_ref || continue
        id = job.id
        KamilaLog.info(
            "scheduler.job.due";
            mod = "scheduler",
            fields = Dict("job" => id, "kind" => job.kind),
        )
        try
            run_job(job)
            mark_status(id, "ok"; at = now_ref)
        catch e
            KamilaLog.warn(
                "scheduler.job.failed";
                mod = "scheduler",
                fields = Dict("job" => id, "kind" => job.kind, "error" => Errors.error_string(e)),
            )
            mark_status(id, "failed"; at = now_ref)
        end

        if job.interval_seconds !== nothing && job.interval_seconds > 0
            # Advance by interval from now: catch-up runs exactly once, then the
            # job resumes its cadence.
            set_next_run(id, now_ref + Second(job.interval_seconds))
        else
            delete_job(id)
        end
        ran += 1
    end
    return ran
end

end # module Scheduler