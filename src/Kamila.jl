module Kamila

using HTTP
using JSON
using SHA
using Dates
using Printf

# Configuration and constants
# Environment variables override the defaults so tests can isolate to temp paths.
const _PATH_SEP = Sys.iswindows() ? ';' : ':'
const ALLOWED_DIRS = split(
    get(
        ENV,
        "KAMILA_ALLOWED_DIRS",
        joinpath(homedir(), "Desktop") *
        _PATH_SEP *
        joinpath(homedir(), "Pictures") *
        _PATH_SEP *
        joinpath(homedir(), "Documents") *
        _PATH_SEP *
        joinpath(homedir(), "Downloads") *
        _PATH_SEP *
        joinpath(homedir(), "Trash") *
        _PATH_SEP *
        joinpath(homedir(), "Codes"),
    ),
    _PATH_SEP,
)

const MEMORY_FILE =
    get(ENV, "KAMILA_MEMORY_FILE", joinpath(homedir(), ".kamila_memory.json"))
const CONFIG_FILE =
    get(ENV, "KAMILA_CONFIG_FILE", joinpath(homedir(), ".kamila_config.json"))
const CHAT_HISTORY_FILE =
    get(ENV, "KAMILA_CHAT_HISTORY_FILE", joinpath(homedir(), ".kamila_chat_history.json"))

# Include all modules
include("system/log.jl")
include("system/events.jl")
include("ai/response_parser.jl")
include("errors.jl")
include("system/confirm.jl")
include("security/os_check.jl")
include("security/capability.jl")
include("security/permission.jl")
include("security/auth.jl")
include("security/file_access.jl")
include("memory/db.jl")
include("memory/vectors.jl")
include("memory/memory.jl")
include("memory/experience.jl")
include("research/outcome_predictor.jl")
include("planning/plan.jl")
include("tasks/task_manager.jl")
include("system/desktop.jl")
include("system/monitor.jl")
include("system/scheduler.jl")
include("system/search.jl")
include("system/code_tracker.jl")
include("ai/ollama_interface.jl")
include("ai/model_router.jl")
include("system/stt.jl")
include("learning/preferences.jl")
include("learning/eval.jl")
include("learning/tune/import.jl")
include("learning/tune/train.jl")
include("learning/tune/promote.jl")
include("planning/decompose.jl")
include("memory/episodic.jl")
include("memory/context.jl")
include("ai/vision.jl")
include("system/desktop_context.jl")
include("system/screenshot.jl")
include("ai/tools.jl")
include("ai/tool_spec.jl")
include("ai/skills/loader.jl")
include("planning/verify.jl")
include("planning/rollback.jl")
include("ai/agent_stream.jl")
include("planning/orchestrator.jl")
include("system/daemon.jl")
include("ai/tts.jl")
include("ai/agent.jl")
include("bridge.jl")

# 05.2: from this point `AgentTools.get_all_tools()` derives from the persisted
# skill registry (seeded lazily on first call) instead of the hardcoded list.
try
    Skills.register_tool_source!()
catch e
    KamilaLog.warn(
        "skills.init.failed";
        mod = "kamila",
        fields = Dict("error" => string(e)),
    )
end

export main,
    start_kamila, get_ai_status, MEMORY_FILE, CONFIG_FILE, CHAT_HISTORY_FILE, ALLOWED_DIRS

function main()
    if !OSCheck.is_linux_os()
        println("Kamila is only compatible with Linux operating systems.")
        exit(1)
    end

    # 08.4: Optional non-Arch restriction. `off` by default; `strict` refuses
    # to run on non-Arch systems, `warn` logs a warning. Arch users are
    # unaffected. Env: KAMILA_ARCH_RESTRICT=off|warn|strict
    OSCheck.verify_arch_restriction()

    KamilaMemory.initialize_memory()
    Permission.ensure_policy_file()
    SystemMonitor.prime_cpu_baseline()

    if "--bridge" in ARGS
        KamilaBridge.run_bridge(; read_timeout = 86400.0)
    elseif "--daemon" in ARGS
        # 06.1: run as a detached background daemon.
        Daemon.run()
    elseif "--daemon-status" in ARGS
        status = Daemon.status()
        if status["running"]
            println("Kamila daemon is running (pid $(status["pid"])).")
        else
            println("Kamila daemon is not running.")
        end
    elseif "--daemon-stop" in ARGS
        if Daemon.is_running()
            pid = Daemon.status()["pid"]
            try
                ccall(:kill, Cint, (Cint, Cint), pid, 15)
                println("Sent SIGTERM to Kamila daemon (pid $pid).")
            catch e
                println("Failed to stop daemon: $e")
            end
        else
            println("Kamila daemon is not running.")
        end
    else
        println("Kamila v0.2.0 — backend ready")
        println("Launch the TUI: node tui/index.js")
        println("Bridge mode:    julia src/Kamila.jl --bridge")
        println("Daemon mode:    julia src/Kamila.jl --daemon")
    end
end

function start_kamila()
    main()
end

function get_ai_status()
    return OllamaInterface.get_ai_status()
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

end # module
