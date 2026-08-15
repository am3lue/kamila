"""
Daemon — persistent background lifetime for Kamila (06.1).

`run()` is the main loop: a 1s tick that dispatches due scheduler jobs, runs the
health monitor, and drains the event queue. It owns the SQLite connection and
writes a pid file (\`\$XDG_STATE_HOME\`/kamila/daemon.pid). SIGTERM/SIGINT trigger a
clean shutdown: flush scheduler state, close the DB, remove the pid file.

Headless policy: daemon-initiated actions resolve through `Permission.evaluate`;
an `:ask` resolves to `:deny` (with an audit entry) rather than prompting — the
daemon must never block on a TTY that may not exist.
"""

module Daemon

using Dates
using Base.Threads
using ..KamilaLog
using ..Events
using ..Scheduler
using ..MemoryDB
using ..Permission
using ..SystemMonitor
using ..Orchestrator.Executive

export run, status, stop, pid_file_path, is_running, tick_once

const _RUNNING = Ref(false)
const _SHUTDOWN = Ref(false)
const _TICK_SECONDS = Ref(1.0)

"""
Path of the daemon pid file. `KAMILA_STATE_DIR` overrides for tests.
"""
function pid_file_path()
    state = get(
        ENV,
        "KAMILA_STATE_DIR",
        joinpath(get(ENV, "XDG_STATE_HOME", joinpath(homedir(), ".local", "state")), "kamila"),
    )
    return joinpath(state, "daemon.pid")
end

function is_running()
    path = pid_file_path()
    isfile(path) || return false
    pid = try
        parse(Int, strip(read(path, String)))
    catch
        return false
    end
    return _pid_alive(pid)
end

function _pid_alive(pid::Int)
    pid <= 0 && return false
    try
        # signal 0 probes without sending; returns 0 if the process exists.
        return ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0
    catch
        return false
    end
end

function _write_pid_file()
    path = pid_file_path()
    dir = dirname(path)
    isdir(dir) || mkpath(dir)
    write(path, string(getpid()))
    return path
end

function _remove_pid_file()
    path = pid_file_path()
    isfile(path) && rm(path; force = true)
    return nothing
end

"""
Deliver a scheduler job's effect. Uses the permission policy (headless):
`:allow` proceeds; `:ask`/`:deny` are denied and logged — never a TTY prompt.
"""
function _deliver_job(job::Scheduler.Job)
    kind = job.kind
    spec = job.spec

    if kind == "reminder"
        message = string(get(spec, "message", ""))
        urgency = string(get(spec, "urgency", "normal"))
        decision = Permission.evaluate("set_reminder", spec)
        if decision == :allow
            Events.publish(Dict(
                "kind" => "notification",
                "title" => "Kamila Reminder",
                "body" => message,
                "urgency" => urgency,
                "source" => "daemon",
            ))
            _notify_send(message; urgency = urgency)
        else
            KamilaLog.warn(
                "daemon.job.denied";
                mod = "daemon",
                fields = Dict("job" => job.id, "kind" => kind, "decision" => string(decision)),
            )
        end

    elseif kind == "check"
        alert_threshold = Float64(get(spec, "threshold", 50.0))
        stats = SystemMonitor.get_system_stats()
        healthy = get(stats, "is_healthy", Dict{String,Any}())
        score = Float64(get(healthy, "score", 100.0))
        if score < alert_threshold
            Events.publish(Dict(
                "kind" => "health.alert",
                "score" => score,
                "body" => "System health dropped to $score (threshold $alert_threshold)",
                "source" => "daemon",
            ))
        end

    elseif kind == "daily_report"
        report = _build_daily_report()
        Events.publish(Dict(
            "kind" => "notification",
            "title" => "Kamila Daily Report",
            "body" => report,
            "source" => "daemon",
        ))

    else
        KamilaLog.warn(
            "daemon.job.unknown_kind";
            mod = "daemon",
            fields = Dict("job" => job.id, "kind" => kind),
        )
    end
    return nothing
end

function _notify_send(message::String; urgency::String = "normal")
    try
        Base.run(`notify-send -u $urgency "Kamila" $message`; wait = false)
    catch e
        KamilaLog.warn(
            "daemon.notify.failed";
            mod = "daemon",
            fields = Dict("error" => string(e)),
        )
    end
    return nothing
end

function _build_daily_report()
    stats = try
        SystemMonitor.get_system_stats()
    catch
        Dict{String,Any}()
    end
    healthy = get(stats, "is_healthy", Dict{String,Any}())
    score = string(get(healthy, "score", "n/a"))
    return "System health: $score. Generated $(Dates.format(Dates.now(), "yyyy-mm-dd HH:MM"))"
end

"""
Run one daemon tick: dispatch due jobs, then run the 06.3 orchestrator's
executive cycle (which proposes or, under `auto_execute`, runs work within the
daily budget). Interactive requests set a flag the executive observes so it
yields. Separated so tests can drive the loop deterministically.
"""
function tick_once()
    Scheduler.run_due!(_deliver_job)
    try
        Executive.tick()
    catch e
        KamilaLog.warn(
            "daemon.executive.tick_failed";
            mod = "daemon",
            fields = Dict("error" => string(e)),
        )
    end
    return nothing
end

"""
Start the daemon main loop. Blocks until `stop()`/SIGTERM/SIGINT. On shutdown
the pid file is removed and the DB closed.

When called via `--daemon` (and not `--no-detach`), spawns a detached child
process that owns the loop and returns immediately, so the CLI exits and the
daemon survives the terminal closing.
"""
function run()
    if "--daemon" in Base.ARGS && !("--no-detach" in Base.ARGS)
        return _detach_and_spawn()
    end
    return _run_loop()
end

function _detach_and_spawn()
    # Re-run ourselves as a setsid child with output redirected to a log file,
    # then exit the parent so the CLI returns immediately.
    logdir = dirname(pid_file_path())
    isdir(logdir) || mkpath(logdir)
    logfile = joinpath(logdir, "daemon.log")
    julia_bin = joinpath(Sys.BINDIR, "julia")
    project = dirname(dirname(@__DIR__))
    program = abspath(Base.PROGRAM_FILE)
    inner = "exec $julia_bin --project=$project $program --daemon --no-detach"
    shell_cmd = "bash -c '$inner' > $logfile 2>&1 < /dev/null &"
    try
        Base.run(`bash -c $(shell_cmd)`)
    catch e
        KamilaLog.warn(
            "daemon.detach.failed";
            mod = "daemon",
            fields = Dict("error" => string(e)),
        )
    end
    return nothing
end

function _run_loop()
    _RUNNING[] = true
    _SHUTDOWN[] = false
    path = _write_pid_file()
    KamilaLog.info(
        "daemon.start";
        mod = "daemon",
        fields = Dict("pid" => getpid(), "pid_file" => path),
    )

    # Julia 1.12's runtime handles SIGTERM/SIGINT itself, terminating the process
    # but still running `atexit` handlers. Register one so the pid file is
    # removed and the DB closed even when the loop is killed externally.
    atexit() do
        _remove_pid_file()
        MemoryDB.reset!()
    end

    try
        while !_SHUTDOWN[]
            tick_once()
            sleep(_TICK_SECONDS[])
        end
    catch e
        KamilaLog.error(
            "daemon.error";
            mod = "daemon",
            fields = Dict("error" => string(e)),
        )
    finally
        _remove_pid_file()
        MemoryDB.reset!()
        _RUNNING[] = false
        KamilaLog.info("daemon.stop"; mod = "daemon", fields = Dict("pid" => getpid()))
    end
    return nothing
end

"""
Signal a running daemon (in-process) to shut down.
"""
function stop()
    _SHUTDOWN[] = true
    return nothing
end

"""
Return a Dict describing daemon status for `--daemon-status`.
"""
function status()
    running = is_running()
    return Dict{String,Any}(
        "running" => running,
        "pid" => running ? (isfile(pid_file_path()) ? parse(Int, strip(read(pid_file_path(), String))) : nothing) : nothing,
        "pid_file" => pid_file_path(),
    )
end

end # module Daemon