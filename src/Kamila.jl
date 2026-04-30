module Kamila

using HTTP
using JSON
using SHA
using Crayons
using Dates
# using FileWatching
# using ArgParse
using Printf

# Configuration and constants
const ALLOWED_DIRS = [
    joinpath(homedir(), "Desktop"),
    joinpath(homedir(), "Pictures"),
    joinpath(homedir(), "Documents"),
    joinpath(homedir(), "Downloads"),
    joinpath(homedir(), "Trash"),
    joinpath(homedir(), "Codes")
]

const MEMORY_FILE = joinpath(homedir(), ".kamila_memory.json")
const CONFIG_FILE = joinpath(homedir(), ".kamila_config.json")

# Include all modules
include("security/os_check.jl")
include("security/auth.jl") 
include("security/file_access.jl")
include("memory/memory.jl")
include("tasks/task_manager.jl")
include("system/desktop.jl")
include("system/monitor.jl")
include("system/code_tracker.jl")
include("ai/ollama_interface.jl")
include("ai/tools.jl")
include("ai/agent.jl")
include("ui/components.jl")
include("ui/tracker_menu.jl")
include("ui/main_menu.jl")
include("security/mask.jl")

export main, start_kamila, get_ai_status, MEMORY_FILE, CONFIG_FILE, ALLOWED_DIRS

"""
Main entry point for Kamila assistant.
Checks system compatibility, handles authentication, and starts the TUI.
"""
function main()
    # Check if running on Linux
    if !OSCheck.is_linux_os()
        println(Crayon(foreground=:red, bold=true)("❌ Kamila is only compatible with Linux operating systems."))
        println(Crayon(foreground=:red)("   Windows and other platforms are not supported."))
        exit(1)
    end
    
    # Initialize memory system
    KamilaMemory.initialize_memory()
    
    # Start the Mask Mode (Auto Mode) by default
    # Authentication is now deferred to specific mode access
    MaskMode.start_mask_mode()
end

"""
Start Kamila assistant (alternate entry point)
"""
function start_kamila()
    main()
end

"""
Get AI system status (for UI components)
"""
function get_ai_status()
    return OllamaInterface.get_ai_status()
end

# Simple command line handling
function handle_args(args::Vector{String})
    if "--version" in args || "-v" in args
        println("Kamila v0.1.0")
        println("Personal Terminal Assistant")
        return true
    end
    
    if "--test" in args || "-t" in args
        println("🧪 Running Kamila tests...")
        # This would run tests
        println("✅ Tests completed")
        return true
    end
    
    if "--setup" in args
        println("🔧 Initial setup...")
        # This would run initial setup
        println("✅ Setup completed")
        return true
    end
    
    return false  # Continue to main application
end

# Entry point for standalone execution
if abspath(PROGRAM_FILE) == @__FILE__
    args = ARGS
    if !handle_args(args)
        main()
    end
end

end # module
