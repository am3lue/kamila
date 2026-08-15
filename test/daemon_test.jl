"""
test/daemon_test.jl — Tests of the 06.1 proactive daemon.

Covers the event bus (publish/subscribe order), the persisted scheduler
(catch-up, once-per-interval, one-shot delete, restart persistence), the daemon
main-loop tick, headless permission resolution, pid-file lifecycle, and the
bridge forwarding of daemon events to the TUI protocol.
"""

using Test
using JSON
using Dates

using .Kamila
const EV = Kamila.Events
const SCH = Kamila.Scheduler
const DA = Kamila.Daemon
const MDB = Kamila.MemoryDB
const PERM = Kamila.Permission

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

# Isolate the daemon pid file from the real $XDG_STATE_HOME.
function with_state_dir(f::Function)
    old_dir = get(ENV, "KAMILA_STATE_DIR", nothing)
    dir = mktempdir()
    ENV["KAMILA_STATE_DIR"] = dir
    try
        f()
    finally
        old_dir === nothing ? delete!(ENV, "KAMILA_STATE_DIR") : ENV["KAMILA_STATE_DIR"] = old_dir
        rm(dir; force = true, recursive = true)
    end
end

# Apply an arbitrary policy for the duration of `f`.
function with_policy(f::Function, policy::AbstractDict)
    old_file = PERM.POLICY_FILE[]
    path = joinpath(mktempdir(), "policy.json")
    PERM.POLICY_FILE[] = path
    try
        @assert PERM.set_policy(policy) "set_policy failed"
        PERM.clear_session_cache()
        f()
    finally
        PERM.clear_session_cache()
        PERM.clear_policy_cache()
        PERM.POLICY_FILE[] = old_file
    end
end

# ─── 1. Event bus ─────────────────────────────────────────

@testset "event bus" begin
    EV.clear_subscribers!()
    EV.clear_queue!()

    seen = String[]
    h1 = EV.subscribe("noti", e -> push!(seen, "noti:" * string(get(e, "title", ""))))
    h2 = EV.subscribe("", e -> push!(seen, "all:" * string(get(e, "kind", ""))))

    EV.publish(Dict("kind" => "notification", "title" => "first"))
    EV.publish(Dict("kind" => "notification", "title" => "second"))

    @test seen == ["noti:first", "all:notification", "noti:second", "all:notification"]

    # Unsubscribe removes the handler.
    EV.unsubscribe("noti", h1)
    empty!(seen)
    EV.publish(Dict("kind" => "notification", "title" => "third"))
    @test seen == ["all:notification"]

    # Unknown kinds still reach catch-all subscribers; empty kind is dropped.
    empty!(seen)
    EV.publish(Dict("kind" => "health.alert", "body" => "x"))
    @test seen == ["all:health.alert"]
    EV.publish(Dict("title" => "no-kind"))
    @test seen == ["all:health.alert"]

    # Queue drains in publish order.
    EV.clear_queue!()
    EV.publish(Dict("kind" => "a"))
    EV.publish(Dict("kind" => "b"))
    @test length(EV.drain(10)) == 2

    EV.clear_subscribers!()
    EV.clear_queue!()
end

# ─── 2. Scheduler ──────────────────────────────────────────

@testset "scheduler CRUD + catch-up" begin
    with_fresh_db() do
        @test MDB.schema_version() >= 6

        # One-shot job in the past fires exactly once and is deleted.
        j = SCH.create_job(
            "reminder";
            spec = Dict("message" => "hi", "urgency" => "low"),
            at = now() - Second(30),
        )
        @test j.kind == "reminder"
        @test j.interval_seconds === 0
        @test j.next_run_at <= now()

        ran = String[]
        n = SCH.run_due!() do job
            push!(ran, string(job.spec["message"]))
        end
        @test n == 1
        @test ran == ["hi"]
        @test isempty(SCH.list_jobs())

        # Repeating job catches up once (not more), then advances by interval.
        j2 = SCH.create_job(
            "check";
            spec = Dict("threshold" => 50),
            at = now() - Second(600),   # overdue by 10 min
            interval_seconds = 3600,
        )
        @test j2.interval_seconds == 3600
        @test length(SCH.list_jobs()) == 1

        n = SCH.run_due!() do job
            push!(ran, "check")
        end
        @test n == 1
        @test count(==("check"), ran) == 1

        remaining = SCH.list_jobs()
        @test length(remaining) == 1
        @test first(remaining).last_status == "ok"
        @test first(remaining).last_run_at !== nothing
        # Advanced forward from now, not from the original due time.
        @test first(remaining).next_run_at >= now() + Minute(58)

        # Not due yet → nothing runs.
        @test SCH.run_due!(j -> push!(ran, "nope")) == 0
        SCH.delete_job(first(SCH.list_jobs()).id)

        # Failed repeating jobs record status and are not deleted.
        j3 = SCH.create_job(
            "check";
            spec = Dict("threshold" => 1),
            at = now() - Second(1),
            interval_seconds = 60,
        )
        n = SCH.run_due!(j -> error("intentional"))
        @test n == 1
        remaining = SCH.list_jobs()
        @test length(remaining) == 1
        @test first(remaining).last_status == "failed"
        @test length(SCH.list_jobs("check")) == 1

        SCH.delete_job(first(remaining).id)
        @test isempty(SCH.list_jobs())
    end
end

@testset "scheduler restart persistence" begin
    # Jobs survive a DB reopen (simulated by re-opening the same file path).
    old_db = get(ENV, "KAMILA_DB", nothing)
    dir = mktempdir()
    dbpath = joinpath(dir, "kamila.db")
    ENV["KAMILA_DB"] = dbpath
    try
        MDB.reset!()
        j = SCH.create_job(
            "reminder";
            spec = Dict("message" => "persist me"),
            at = now() - Second(5),
        )
        id = j.id

        # Simulate daemon restart: close and reopen the DB.
        MDB.reset!()
        j2 = SCH.get_job(id)
        @test j2 !== nothing
        @test j2.spec["message"] == "persist me"

        ran = String[]
        @test SCH.run_due!(job -> push!(ran, string(job.spec["message"]))) == 1
        @test ran == ["persist me"]
        @test SCH.get_job(id) === nothing  # one-shot consumed after restart

        MDB.reset!()
    finally
        MDB.reset!()
        old_db === nothing ? delete!(ENV, "KAMILA_DB") : ENV["KAMILA_DB"] = old_db
        rm(dir; force = true, recursive = true)
    end
end

# ─── 3. Daemon tick / permission / pid file ────────────────

@testset "daemon headless permission + tick" begin
    with_fresh_db() do
        # set_reminder is informational → allowed headless under starter policy.
        @test PERM.evaluate("set_reminder", Dict("message" => "x")) == :allow

        EV.clear_subscribers!()
        EV.clear_queue!()

        SCH.create_job(
            "reminder";
            spec = Dict("message" => "hello daemon"),
            at = now() - Second(1),
        )
        DA.tick_once()

        events = EV.drain(10)
        @test any(e -> e["kind"] == "notification" && e["body"] == "hello daemon", events)
        @test isempty(SCH.list_jobs())

        # A job whose tool is denied headless must not publish an event.
        EV.clear_queue!()
        with_policy(Dict("default_action" => "deny", "rules" => [])) do
            SCH.create_job(
                "reminder";
                spec = Dict("message" => "should not fire"),
                at = now() - Second(1),
            )
            DA.tick_once()
            @test isempty(EV.drain(10))
        end
    end
end

@testset "daemon loop + pid file lifecycle" begin
    with_state_dir() do
        DA.stop()
        @test !DA._RUNNING[]

        # Run the loop in-process with short ticks and stop it cleanly.
        t = @async DA.run()
        sleep(1.5)
        @test DA._RUNNING[]
        @test isfile(DA.pid_file_path())
        @test endswith(DA.pid_file_path(), "daemon.pid")

        DA.stop()
        wait(t)
        @test !DA._RUNNING[]
        @test !isfile(DA.pid_file_path())
    end
end

@testset "daemon status" begin
    with_state_dir() do
        s = DA.status()
        @test haskey(s, "running")
        @test haskey(s, "pid_file")
        @test s["pid_file"] == DA.pid_file_path()
    end
end

# ─── 4. Bridge forwarding ──────────────────────────────────

@testset "bridge forwards daemon events" begin
    # `_forward_daemon_event` emits a `notification` protocol event for
    # informational kinds and ignores others. We capture stdout writes.
    EV.clear_subscribers!()
    EV.clear_queue!()

    BR = Kamila.KamilaBridge
    out = Pipe()
    text = ""
    try
        Base.link_pipe!(out; reader_supports_async = true, writer_supports_async = true)
        redirect_stdout(out) do
            BR._forward_daemon_event(Dict("kind" => "notification", "title" => "T", "body" => "B"))
            BR._forward_daemon_event(Dict("kind" => "health.alert", "body" => "low", "source" => "daemon"))
            BR._forward_daemon_event(Dict("kind" => "internal", "secret" => "x"))
        end
        close(out.in)
        text = read(out.out, String)
    finally
        close(out)
    end

    lines = [JSON.parse(String(strip(l))) for l in split(text, '\n') if !isempty(strip(l))]
    @test length(lines) == 2
    @test lines[1]["type"] == "notification"
    @test lines[1]["title"] == "T"
    @test lines[1]["body"] == "B"
    @test lines[2]["kind"] == "health.alert"
    @test lines[2]["source"] == "daemon"
end
