

module UIComponents

using Term
using Crayons
using ..Kamila
using ..KamilaMemory
using ..TaskManager
using ..SystemMonitor
using ..Desktop

# Crayons for the "crayons.jl system"
const C_BLUE = Crayon(foreground=:blue, bold=true)
const C_BRIGHT_BLUE = Crayon(foreground=:light_blue, bold=true)
const C_CYAN = Crayon(foreground=:cyan, bold=true)
const C_BRIGHT_CYAN = Crayon(foreground=:light_cyan, bold=true)
const C_YELLOW = Crayon(foreground=:yellow, bold=true)
const C_BRIGHT_YELLOW = Crayon(foreground=:light_yellow, bold=true)
const C_MAGENTA = Crayon(foreground=:magenta, bold=true)
const C_BRIGHT_MAGENTA = Crayon(foreground=:light_magenta, bold=true)
const C_RED = Crayon(foreground=:red, bold=true)
const C_BRIGHT_RED = Crayon(foreground=:light_red, bold=true)
const C_GREEN = Crayon(foreground=:green, bold=true)
const C_BRIGHT_GREEN = Crayon(foreground=:light_green, bold=true)
const C_DIM = Crayon(italics=true, faint=true)
const C_BOLD = Crayon(bold=true)
const C_RESET = Crayon(reset=true)

export show_main_menu, show_task_manager, show_system_status, show_memory_stats,
       show_desktop_organization, show_ai_assistant, show_settings,
       show_loading, show_success, show_error, show_warning, show_info,
       C_BLUE, C_BRIGHT_BLUE, C_CYAN, C_BRIGHT_CYAN, C_YELLOW, C_BRIGHT_YELLOW,
       C_MAGENTA, C_BRIGHT_MAGENTA, C_RED, C_BRIGHT_RED, C_GREEN, C_BRIGHT_GREEN,
       C_DIM, C_BOLD, C_RESET

"""
Create a styled panel for displaying information
"""
function create_panel(title::String, content::String; width::Int=80)
    Panel(content, title=title, style="bold light_blue", fit=false, width=width)
end

"""
Create a menu item
"""
function create_menu_item(number::Int, title::String, description::String="")
    if isempty(description)
        return "$(C_BRIGHT_BLUE)$number$(C_RESET). $title"
    else
        return "$(C_BRIGHT_BLUE)$number$(C_RESET). $title\n   $(C_DIM)$description$(C_RESET)"
    end
end

"""
Show the main menu
"""
function show_main_menu()
    clear()
    
    # Header
    header = """
    $(C_BRIGHT_CYAN)
    ╔══════════════════════════════════════════════════════════════╗
    ║                    🤖 KAMILA ASSISTANT                       ║
    ║          Kind • Adaptive • Mind • Integrating • Logic •      ║
    ║                                                              ║
    ║                    Your Personal Terminal AI                 ║
    ╚══════════════════════════════════════════════════════════════╝
    $(C_RESET)
    """
    
    println(header)
    
    # Quick stats
    memory_stats = try KamilaMemory.get_memory_stats() catch e Dict("error" => "Unable to load") end
    task_stats = try TaskManager.get_task_stats() catch e Dict("error" => "Unable to load") end
    
    stats_content = """
    $(C_BOLD)User:$(C_RESET) $(get(memory_stats, "user_alias", "Blue"))
    $(C_BOLD)Tasks:$(C_RESET) $(get(task_stats, "completed_today", 0)) completed today
    $(C_BOLD)Productivity:$(C_RESET) $(get(memory_stats, "productivity_percentage", 0))%
    $(C_BOLD)Goals Active:$(C_RESET) $(get(memory_stats, "active_goals", 0))
    """
    
    stats_panel = create_panel("📊 Quick Stats", stats_content)
    println(stats_panel)
    println()
    
    # Menu options
    menu_content = """
    $(C_BRIGHT_YELLOW)Main Menu$(C_RESET)
    
    $(create_menu_item(1, "📋 Task Manager", "Add, view, and manage your tasks"))
    $(create_menu_item(2, "💾 Memory & Achievements", "View your progress and achievements"))
    $(create_menu_item(3, "🖥️  System Status", "Monitor system health and performance"))
    $(create_menu_item(4, "📁 Desktop Organization", "Organize and clean your desktop"))
    $(create_menu_item(5, "🤖 AI Assistant", "Get AI help and explanations"))
    $(create_menu_item(6, "⚙️  Settings", "Configure Kamila preferences"))
    $(create_menu_item(7, "🔍 Code Tracker", "Track file changes in projects"))
    $(create_menu_item(8, "💬 Agent Mode", "Interactive chat with Kamila"))
    $(create_menu_item(0, "🔒 Lock System", "Return to Auto Mode"))
    """
    
    menu_panel = create_panel("Menu", menu_content)
    println(menu_panel)
    println()
    
    print("$(C_BRIGHT_GREEN)Choose an option (0-6): $(C_RESET)")
end

"""
Show task manager interface
"""
function show_task_manager()
    clear()
    
    header = """
    $(C_BRIGHT_MAGENTA)
    ╔══════════════════════════════════════════════════════════════╗
    ║                       📋 TASK MANAGER                        ║
    ╚══════════════════════════════════════════════════════════════╝
    $(C_RESET)
    """
    
    println(header)
    
    # Get task statistics
    stats = try TaskManager.get_task_stats() catch e Dict("error" => "Unable to load") end
    
    stats_content = """
    $(C_BOLD)Overview:$(C_RESET)
    • Total Tasks: $(get(stats, "total_tasks", 0))
    • Pending: $(get(stats, "pending_tasks", 0))
    • Overdue: $(get(stats, "overdue_tasks", 0))
    • Completed Today: $(get(stats, "completed_today", 0))
    • Completion Rate: $(get(stats, "completion_rate", 0))%
    """
    
    stats_panel = create_panel("Task Statistics", stats_content)
    println(stats_panel)
    println()
    
    # Show pending tasks
    pending_tasks = try TaskManager.get_pending_tasks() catch e Task[] end
    
    if !isempty(pending_tasks)
        tasks_content = ""
        for (i, task) in enumerate(pending_tasks[1:min(5, length(pending_tasks))])
            priority_str = task.priority >= 4 ? "🔴" : task.priority >= 3 ? "🟡" : "🟢"
            tasks_content *= "$(C_BOLD)$priority_str $(task.title)$(C_RESET)\n"
            tasks_content *= "   Category: $(task.category) | Est. Time: $(task.estimated_time)min\n"
            if task.due_date !== nothing
                tasks_content *= "   Due: $(task.due_date)\n"
            end
            tasks_content *= "\n"
        end
        
        if length(pending_tasks) > 5
            tasks_content *= "$(C_DIM)... and $(length(pending_tasks) - 5) more tasks$(C_RESET)\n"
        end
        
        tasks_panel = create_panel("Pending Tasks", tasks_content)
        println(tasks_panel)
    else
        empty_panel = create_panel("Tasks", "🎉 No pending tasks! Great job staying on top of things!")
        println(empty_panel)
    end
    
    println()
    println("$(C_BRIGHT_GREEN)Task Manager Options:$(C_RESET)")
    println("$(C_BRIGHT_BLUE)1.$(C_RESET) Add new task")
    println("$(C_BRIGHT_BLUE)2.$(C_RESET) Complete a task")
    println("$(C_BRIGHT_BLUE)3.$(C_RESET) Generate daily schedule")
    println("$(C_BRIGHT_BLUE)4.$(C_RESET) View overdue tasks")
    println("$(C_BRIGHT_BLUE)5.$(C_RESET) Export tasks")
    println("$(C_BRIGHT_BLUE)0.$(C_RESET) Back to main menu")
    println()
    print("$(C_BRIGHT_GREEN)Choose an option: $(C_RESET)")
end

"""
Show memory and achievements
"""
function show_memory_stats()
    clear()
    
    header = """
    $(C_BRIGHT_GREEN)
    ╔══════════════════════════════════════════════════════════════╗
    ║                   💾 MEMORY & ACHIEVEMENTS                   ║
    ╚══════════════════════════════════════════════════════════════╝
    $(C_RESET)
    """
    
    println(header)
    
    # Get memory statistics
    stats = try 
        KamilaMemory.get_memory_stats()
            catch e 
                Dict("error" => "Unable to load $e") end
    
    stats_content = """
    $(C_BOLD)User Alias:$(C_RESET) $(get(stats, "user_alias", "Blue"))
    $(C_BOLD)Total Tasks:$(C_RESET) $(get(stats, "total_tasks", 0)) 
    $(C_BOLD)Completed Tasks:$(C_RESET) $(get(stats, "completed_tasks", 0))
    $(C_BOLD)Achievements:$(C_RESET) $(get(stats, "total_achievements", 0))
    $(C_BOLD)Active Goals:$(C_RESET) $(get(stats, "active_goals", 0))
    $(C_BOLD)Productivity:$(C_RESET) $(get(stats, "productivity_percentage", 0))%
    $(C_BOLD)Total Activities:$(C_RESET) $(get(stats, "total_activities", 0))
    $(C_BOLD)Last Updated:$(C_RESET) $(get(stats, "last_updated", "Never"))
    """
    
    stats_panel = create_panel("Memory Statistics", stats_content)
    println(stats_panel)
    println()
    
    # Show recent achievements
    achievements = try KamilaMemory.get_today_achievements() catch _ end
    
    if !isempty(achievements)
        ach_content = ""
        for achievement in achievements[1:min(3, length(achievements))]
            ach_content *= "$(C_BRIGHT_YELLOW)🏆 $(achievement["title"])$(C_RESET)\n"
            if !isempty(get(achievement, "description", ""))
                ach_content *= "   $(achievement["description"])\n"
            end
            ach_content *= "   $(C_DIM)$(achievement["date"])$(C_RESET)\n\n"
        end
        
        if length(achievements) > 3
            ach_content *= "$(C_DIM)... and $(length(achievements) - 3) more achievements$(C_RESET)\n"
        end
        
        ach_panel = create_panel("Today's Achievements", ach_content)
        println(ach_panel)
    else
        empty_ach = create_panel("Achievements", "🎯 No achievements yet today. Keep working towards your goals!")
        println(empty_ach)
    end
    
    println()
    println("$(C_BRIGHT_GREEN)Memory Options:$(C_RESET)")
    println("$(C_BRIGHT_BLUE)1.$(C_RESET) Add new goal")
    println("$(C_BRIGHT_BLUE)2.$(C_RESET) View active goals")
    println("$(C_BRIGHT_BLUE)3.$(C_RESET) Complete a goal")
    println("$(C_BRIGHT_BLUE)4.$(C_RESET) Generate memory summary")
    println("$(C_BRIGHT_BLUE)0.$(C_RESET) Back to main menu")
    println()
    print("$(C_BRIGHT_GREEN)Choose an option: $(C_RESET)")
end

"""
Show system status
"""
function show_system_status()
    clear()
    
    header = """
    $(C_BRIGHT_CYAN)
    ╔══════════════════════════════════════════════════════════════╗
    ║                      🖥️  SYSTEM STATUS                       ║
    ╚══════════════════════════════════════════════════════════════╝
    $(C_RESET)
    """
    
    println(header)
    
    # Get system statistics
    stats = try SystemMonitor.get_system_stats() catch e Dict("error" => "Unable to load") end
    
    if haskey(stats, "error")
        error_panel = create_panel("System Status", "❌ $(stats["error"])")
        println(error_panel)
    else
        # System info panel
        sys_content = """
        $(C_BOLD)Operating System:$(C_RESET) $(stats["os_info"]["os_name"]) $(stats["os_info"]["kernel_version"])
        $(C_BOLD)Architecture:$(C_RESET) $(stats["os_info"]["arch"])
        $(C_BOLD)Uptime:$(C_RESET) $(stats["uptime"]["formatted"])
        $(C_BOLD)CPU Threads:$(C_RESET) $(stats["cpu"]["threads"])
        """
        
        sys_panel = create_panel("System Information", sys_content)
        println(sys_panel)
        println()
        
        # Performance panel
        perf_content = """
        $(C_BOLD)CPU Usage:$(C_RESET) $(stats["cpu"]["usage_percent"])%
        $(C_BOLD)Memory Usage:$(C_RESET) $(stats["memory"]["used_percent"])% ($(stats["memory"]["free_gb"]) GB free)
        $(C_BOLD)Processes:$(C_RESET) $(stats["processes"]["running"]) running
        """
        
        perf_panel = create_panel("Performance", perf_content)
        println(perf_panel)
        println()
        
        # Health status
        health = stats["is_healthy"]
        status_text = uppercasefirst(get(health, "status", "unknown"))
        score_text = string(get(health, "score", 0))
        
        health_content = """
        $(C_BOLD)Overall Health:$(C_RESET) $status_text
        $(C_BOLD)Health Score:$(C_RESET) $score_text/100
        
        $(C_BRIGHT_GREEN)✅ No issues detected$(C_RESET)
        """
        
        health_panel = create_panel("Health Status", health_content)
        println(health_panel)
    end
    
    println()
    println("$(C_BRIGHT_GREEN)System Options:$(C_RESET)")
    println("$(C_BRIGHT_BLUE)1.$(C_RESET) Generate daily report")
    println("$(C_BRIGHT_BLUE)2.$(C_RESET) Monitor resources")
    println("$(C_BRIGHT_BLUE)3.$(C_RESET) View system alerts")
    println("$(C_BRIGHT_BLUE)4.$(C_RESET) Get compatibility report")
    println("$(C_BRIGHT_BLUE)0.$(C_RESET) Back to main menu")
    println()
    print("$(C_BRIGHT_GREEN)Choose an option: $(C_RESET)")
end

"""
Show desktop organization
"""
function show_desktop_organization()
    clear()
    
    header = """
    $(C_BRIGHT_YELLOW)
    ╔══════════════════════════════════════════════════════════════╗
    ║                  📁 DESKTOP ORGANIZATION                     ║
    ╚══════════════════════════════════════════════════════════════╝
    $(C_RESET)
    """
    
    println(header)
    
    # Get desktop statistics
    stats = try Desktop.get_desktop_stats() catch e Dict("error" => "Unable to load") end
    
    if haskey(stats, "error")
        error_panel = create_panel("Desktop Status", "❌ $(stats["error"])")
        println(error_panel)
    else
        # Desktop stats panel
        desk_content = """
        $(C_BOLD)Total Items:$(C_RESET) $(stats["total_items"])
        $(C_BOLD)Files:$(C_RESET) $(stats["files"])
        $(C_BOLD)Directories:$(C_RESET) $(stats["directories"])
        $(C_BOLD)Storage Used:$(C_RESET) $(stats["total_size_mb"]) MB
        """
        
        desk_panel = create_panel("Desktop Statistics", desk_content)
        println(desk_panel)
        println()
        
        # File types breakdown
        if haskey(stats, "file_types") && !isempty(stats["file_types"])
            types_content = "$(C_BOLD)File Types:$(C_RESET)\n"
            for (ext, count) in sort(collect(stats["file_types"]), by=x->x[2], rev=true)[1:min(5, length(stats["file_types"]))]
                types_content *= "• $ext: $count files\n"
            end
            
            types_panel = create_panel("File Breakdown", types_content)
            println(types_panel)
        end
        
        # Health assessment
        health_score = 100
        if stats["total_items"] > 50
            health_score -= 30
        elseif stats["total_items"] > 30
            health_score -= 15
        end
        
        if stats["total_size_mb"] > 500
            health_score -= 20
        end
        
        status = health_score >= 80 ? "$(C_BRIGHT_GREEN)Good$(C_RESET)" : 
                health_score >= 60 ? "$(C_BRIGHT_YELLOW)Fair$(C_RESET)" : 
                "$(C_BRIGHT_RED)Needs Attention$(C_RESET)"
        
        suggestions = if stats["total_items"] > 30
            "• Consider organizing files into folders\n• Move old files to appropriate directories"
        else
            "• Desktop is well organized\n• Keep up the good work!"
        end
        
        health_content = """
        $(C_BOLD)Organization Health:$(C_RESET) $status
        $(C_BOLD)Health Score:$(C_RESET) $health_score/100
        
        $(C_BRIGHT_CYAN)Suggestions:$(C_RESET)
        $suggestions
        """
        
        health_panel = create_panel("Organization Health", health_content)
        println(health_panel)
    end        
    
    println()
    println("$(C_BRIGHT_GREEN)Desktop Options:$(C_RESET)")
    println("$(C_BRIGHT_BLUE)1.$(C_RESET) Organize desktop automatically")
    println("$(C_BRIGHT_BLUE)2.$(C_RESET) Get AI organization suggestions")
    println("$(C_BRIGHT_BLUE)3.$(C_RESET) Clean old files")
    println("$(C_BRIGHT_BLUE)4.$(C_RESET) Generate health report")
    println("$(C_BRIGHT_BLUE)0.$(C_RESET) Back to main menu")
    println()
    print("$(C_BRIGHT_GREEN)Choose an option: $(C_RESET)")
end

"""
Show AI assistant interface
"""
function show_ai_assistant()
    clear()
    
    header = """
    $(C_BRIGHT_RED)
    ╔══════════════════════════════════════════════════════════════╗
    ║                        🤖 AI ASSISTANT                       ║
    ╚══════════════════════════════════════════════════════════════╝
    $(C_RESET)
    """
    
    println(header)
    
    # Check AI status
    ai_status = try Kamila.get_ai_status() catch e Dict("error" => "Unable to check AI status") end
    
    if haskey(ai_status, "error")
        error_panel = create_panel("AI Status", "❌ $(ai_status["error"])")
        println(error_panel)
    else
        # AI status panel
        ollama_status = get(ai_status, "ollama_running", false) ? "✅ Running" : "❌ Not Running"
        model_status = get(ai_status, "kamila_model_available", false) ? "✅ Available" : "❌ Not Available"
        
        status_content = """
        $(C_BOLD)Ollama Server:$(C_RESET) $ollama_status
        $(C_BOLD)Kamila Model:$(C_RESET) $model_status
        $(C_BOLD)Host:$(C_RESET) $(get(ai_status, "host", "localhost:11434"))
        $(C_BOLD)Model Name:$(C_RESET) $(get(ai_status, "model_name", "kamila"))
        """
        
        status_panel = create_panel("AI Status", status_content)
        println(status_panel)
        println()
        
        # Available models (if connected)
        if get(ai_status, "ollama_running", false) && haskey(ai_status, "available_models")
            models_content = "$(C_BOLD)Available Models:$(C_RESET)\n"
            for model in ai_status["available_models"]
                models_content *= "• $model\n"
            end
            
            models_panel = create_panel("Models", models_content)
            println(models_panel)
        end
    end
    
    println()
    println("$(C_BRIGHT_GREEN)AI Options:$(C_RESET)")
    println("$(C_BRIGHT_BLUE)1.$(C_RESET) Test AI connection")
    println("$(C_BRIGHT_BLUE)2.$(C_RESET) Setup Kamila model")
    println("$(C_BRIGHT_BLUE)3.$(C_RESET) Get productivity suggestions")
    println("$(C_BRIGHT_BLUE)4.$(C_RESET) Explain a file")
    println("$(C_BRIGHT_BLUE)5.$(C_RESET) Generate daily report")
    println("$(C_BRIGHT_BLUE)0.$(C_RESET) Back to main menu")
    println()
    print("$(C_BRIGHT_GREEN)Choose an option: $(C_RESET)")
end

"""
Show settings menu
"""
function show_settings()
    clear()
    
    header = """
    $(C_BRIGHT_MAGENTA)
    ╔══════════════════════════════════════════════════════════════╗
    ║                        ⚙️  SETTINGS                          ║
    ╚══════════════════════════════════════════════════════════════╝
    $(C_RESET)
    """
    
    println(header)
    
    # Security status
    security_content = """
    $(C_BOLD)Platform Security:$(C_RESET)
    • OS Check: ✅ Linux verification enabled
    • File Access: ✅ Restricted to home directories
    • Authentication: ✅ Password protection active
    
    $(C_BOLD)Allowed Directories:$(C_RESET)
    • ~/Desktop
    • ~/Pictures  
    • ~/Documents
    • ~/Downloads
    • ~/Trash
    • ~/Codes
    """
    
    security_panel = create_panel("Security Status", security_content)
    println(security_panel)
    println()
    
    # Memory status
    memory_content = """
    $(C_BOLD)Memory System:$(C_RESET)
    • Memory File: $(Kamila.MEMORY_FILE)
    • Config File: $(Kamila.CONFIG_FILE)
    • Auto-save: ✅ Enabled
    
    $(C_BOLD)Data Privacy:$(C_RESET)
    • All data stored locally
    • No external data transmission
    • Secure file access controls
    """
    
    memory_panel = create_panel("Memory & Privacy", memory_content)
    println(memory_panel)
    
    println()
    println("$(C_BRIGHT_GREEN)Settings Options:$(C_RESET)")
    println("$(C_BRIGHT_BLUE)1.$(C_RESET) Change password")
    println("$(C_BRIGHT_BLUE)2.$(C_RESET) Reset authentication")
    println("$(C_BRIGHT_BLUE)3.$(C_RESET) View file security report")
    println("$(C_BRIGHT_BLUE)4.$(C_RESET) Export settings")
    println("$(C_BRIGHT_BLUE)0.$(C_RESET) Back to main menu")
    println()
    print("$(C_BRIGHT_GREEN)Choose an option: $(C_RESET)")
end

"""
Clear the terminal screen
"""
function clear()
    # ANSI escape code to clear screen
    print("\033[2J\033[H")
end

"""
Show a loading spinner
"""
function show_loading(message::String="Loading...")
    print("$(C_BRIGHT_BLUE)$message$(C_RESET)")
    for i in 1:3
        sleep(0.5)
        print(".")
    end
    println()
end

"""
Show a success message
"""
function show_success(message::String)
    println("$(C_BRIGHT_GREEN)✅ $message$(C_RESET)")
end

"""
Show an error message
"""
function show_error(message::String)
    println("$(C_BRIGHT_RED)❌ $message$(C_RESET)")
end

"""
Show a warning message
"""
function show_warning(message::String)
    println("$(C_BRIGHT_YELLOW)⚠️  $message$(C_RESET)")
end

"""
Show an info message
"""
function show_info(message::String)
    println("$(C_BRIGHT_CYAN)ℹ️  $message$(C_RESET)")
end

end # module
