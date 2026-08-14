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
include("ai/response_parser.jl")
include("errors.jl")
include("system/confirm.jl")
include("security/os_check.jl")
include("security/permission.jl")
include("security/auth.jl")
include("security/file_access.jl")
include("memory/db.jl")
include("memory/vectors.jl")
include("memory/memory.jl")
include("tasks/task_manager.jl")
include("system/desktop.jl")
include("system/monitor.jl")
include("system/search.jl")
include("system/code_tracker.jl")
include("ai/ollama_interface.jl")
include("ai/model_router.jl")
include("memory/episodic.jl")
include("memory/context.jl")
include("ai/tools.jl")
include("ai/agent_stream.jl")
include("ai/tts.jl")
include("ai/agent.jl")
include("bridge.jl")

export main,
    start_kamila, get_ai_status, MEMORY_FILE, CONFIG_FILE, CHAT_HISTORY_FILE, ALLOWED_DIRS

function main()
    if !OSCheck.is_linux_os()
        println("Kamila is only compatible with Linux operating systems.")
        exit(1)
    end

    KamilaMemory.initialize_memory()
    Permission.ensure_policy_file()
    SystemMonitor.prime_cpu_baseline()

    if "--bridge" in ARGS
        KamilaBridge.run_bridge(; read_timeout = 86400.0)
    else
        println("Kamila v0.2.0 — backend ready")
        println("Launch the TUI: node tui/index.js")
        println("Bridge mode:    julia src/Kamila.jl --bridge")
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
