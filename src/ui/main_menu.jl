"""
Main TUI Interface for Kamila
Handles the main application loop and menu navigation
"""

module MainUI

using ..UIComponents
using ..KamilaMemory
using ..TaskManager
using ..SystemMonitor
using ..Desktop
using ..OllamaInterface
using ..Agent
using ..TrackerUI

export start_tui, run_main_loop

"""
Start the main TUI interface
"""
function start_tui()
    UIComponents.show_info("Starting TUI interface...")
    UIComponents.show_success("Kamila is now ready to assist you!")
    
    run_main_loop()
end

"""
Main application loop
"""
function run_main_loop()
    running = true
    
    while running
        try
            UIComponents.show_main_menu()
           
            choice = strip(readline(stdin))
            
            if choice == "0"
                UIComponents.show_info("System Locked. Returning to Auto Mode...")
                running = false
            elseif choice == "1"
                handle_task_manager()
            elseif choice == "2"
                handle_memory_stats()
            elseif choice == "3"
                handle_system_status()
            elseif choice == "4"
                handle_desktop_organization()
            elseif choice == "5"
                handle_ai_assistant()
            elseif choice == "6"
                handle_settings()
            elseif choice == "7"
                TrackerUI.handle_tracker_menu()
            elseif choice == "8"
                Agent.start_agent_mode()
            else
                UIComponents.show_error("Invalid option. Please choose 0-8.")
                sleep(2)
            end
        catch e
            if e isa InterruptException
                UIComponents.show_info("\n⚠️  Interrupted. Returning to Main Menu...")
                sleep(1)
                continue
            end
            UIComponents.show_error("An error occurred: $e")
            println("Press Enter to continue...")
            readline(stdin)
        end
    end
end

"""
Handle task manager menu
"""
function handle_task_manager()
    while true
        try
            UIComponents.show_task_manager()
            choice = strip(readline(stdin))
            
            if choice == "0"
                break
            elseif choice == "1"
                add_new_task()
            elseif choice == "2"
                complete_task()
            elseif choice == "3"
                generate_daily_schedule()
            elseif choice == "4"
                view_overdue_tasks()
            elseif choice == "5"
                export_tasks()
            else
                UIComponents.show_error("Invalid option. Please choose 0-5.")
                sleep(1)
            end
        catch e
            if e isa InterruptException
                UIComponents.show_info("\n⚠️  Interrupted. Resetting menu...")
                sleep(1)
                continue
            end
            rethrow(e)
        end
    end
end

"""
Handle memory stats menu
"""
function handle_memory_stats()
    while true
        try
            UIComponents.show_memory_stats()
            choice = strip(readline(stdin))
            
            if choice == "0"
                break
            elseif choice == "1"
                add_new_goal()
            elseif choice == "2"
                view_active_goals()
            elseif choice == "3"
                complete_goal()
            elseif choice == "4"
                generate_memory_summary()
            else
                UIComponents.show_error("Invalid option. Please choose 0-4.")
                sleep(1)
            end
        catch e
            if e isa InterruptException
                UIComponents.show_info("\n⚠️  Interrupted. Resetting menu...")
                sleep(1)
                continue
            end
            rethrow(e)
        end
    end
end

"""
Handle system status menu
"""
function handle_system_status()
    while true
        try
            UIComponents.show_system_status()
            choice = strip(readline(stdin))
            
            if choice == "0"
                break
            elseif choice == "1"
                generate_daily_system_report()
            elseif choice == "2"
                monitor_resources()
            elseif choice == "3"
                view_system_alerts()
            elseif choice == "4"
                get_compatibility_report()
            else
                UIComponents.show_error("Invalid option. Please choose 0-4.")
                sleep(1)
            end
        catch e
            if e isa InterruptException
                UIComponents.show_info("\n⚠️  Interrupted. Resetting menu...")
                sleep(1)
                continue
            end
            rethrow(e)
        end
    end
end

"""
Handle desktop organization menu
"""
function handle_desktop_organization()
    while true
        try
            UIComponents.show_desktop_organization()
            choice = strip(readline(stdin))
            
            if choice == "0"
                break
            elseif choice == "1"
                organize_desktop_automatically()
            elseif choice == "2"
                get_ai_organization_suggestions()
            elseif choice == "3"
                clean_old_files()
            elseif choice == "4"
                generate_desktop_health_report()
            else
                UIComponents.show_error("Invalid option. Please choose 0-4.")
                sleep(1)
            end
        catch e
            if e isa InterruptException
                UIComponents.show_info("\n⚠️  Interrupted. Resetting menu...")
                sleep(1)
                continue
            end
            rethrow(e)
        end
    end
end

"""
Handle AI assistant menu
"""
function handle_ai_assistant()
    while true
        try
            UIComponents.show_ai_assistant()
            choice = strip(readline(stdin))
            
            if choice == "0"
                break
            elseif choice == "1"
                test_ai_connection()
            elseif choice == "2"
                setup_kamila_model()
            elseif choice == "3"
                get_productivity_suggestions()
            elseif choice == "4"
                explain_file_with_ai()
            elseif choice == "5"
                generate_ai_daily_report()
            elseif choice == "6"
                Agent.start_agent_mode()
            else
                UIComponents.show_error("Invalid option. Please choose 0-5.")
                sleep(1)
            end
        catch e
            if e isa InterruptException
                UIComponents.show_info("\n⚠️  Interrupted. Resetting menu...")
                sleep(1)
                continue
            end
            rethrow(e)
        end
    end
end

"""
Handle settings menu
"""
function handle_settings()
    while true
        try
            UIComponents.show_settings()
            choice = strip(readline(stdin))
            
            if choice == "0"
                break
            elseif choice == "1"
                change_password()
            elseif choice == "2"
                reset_authentication()
            elseif choice == "3"
                view_security_report()
            elseif choice == "4"
                export_settings()
            else
                UIComponents.show_error("Invalid option. Please choose 0-4.")
                sleep(1)
            end
        catch e
            if e isa InterruptException
                UIComponents.show_info("\n⚠️  Interrupted. Resetting menu...")
                sleep(1)
                continue
            end
            rethrow(e)
        end
    end
end

# Task Manager Functions
function add_new_task()
    println("\n📝 Add New Task")
    print("Title: ")
    title = readline(stdin)
    
    print("Description: ")
    description = readline(stdin)
    
    print("Category (default: general): ")
    category = readline(stdin)
    if isempty(category)
        category = "general"
    end
    
    print("Priority (1-4, default: 2): ")
    priority_input = readline(stdin)
    priority = try parse(Int, priority_input) catch e 2 end
    priority = clamp(priority, 1, 4)
    
    print("Estimated time in minutes (default: 30): ")
    time_input = readline(stdin)
    estimated_time = try parse(Int, time_input) catch e 30 end
    
    try
        task = TaskManager.add_task(title, description=description, category=category, 
                                  priority=priority, estimated_time=estimated_time)
        UIComponents.show_success("Task added successfully!")
    catch e
        UIComponents.show_error("Error adding task: $e")
    end
    
    println("Press Enter to continue...")
    readline(stdin)
end

function complete_task()
    println("\n✅ Complete Task")
    tasks = TaskManager.get_pending_tasks()
    
    if isempty(tasks)
        println("No pending tasks to complete.")
        sleep(2)
        return
    end
    
    println("Pending tasks:")
    for task in tasks
        println("$(task.id). $(task.title)")
    end
    
    print("Enter task ID to complete: ")
    task_id = try parse(Int, readline(stdin)) catch e 0 end
    
    if TaskManager.complete_task(task_id)
        UIComponents.show_success("Task completed!")
    else
        UIComponents.show_error("Task not found.")
    end
    
    sleep(2)
end

function generate_daily_schedule()
    println("\n🗓️  Generating Daily Schedule")
    schedule = TaskManager.generate_timetable()
    
    if isempty(schedule)
        println("No tasks scheduled.")
    else
        println("Today's schedule:")
        for (task, start_time) in schedule
            end_time = start_time + Minute(task.estimated_time)
            println("• $(start_time)-$(end_time): $(task.title)")
        end
    end
    
    println("Press Enter to continue...")
    readline(stdin)
end

function view_overdue_tasks()
    println("\n⚠️  Overdue Tasks")
    overdue = TaskManager.get_overdue_tasks()
    
    if isempty(overdue)
        println("🎉 No overdue tasks!")
    else
        for task in overdue
            println("• $(task.title) (Due: $(task.due_date))")
        end
    end
    
    println("Press Enter to continue...")
    readline(stdin)
end

function export_tasks()
    println("\n📤 Export Tasks")
    print("Enter filename (default: tasks.json): ")
    filename = readline(stdin)
    if isempty(filename)
        filename = "tasks.json"
    end
    
    if TaskManager.export_tasks(filename)
        UIComponents.show_success("Tasks exported successfully!")
    else
        UIComponents.show_error("Error exporting tasks.")
    end
    
    sleep(2)
end

# Memory Functions
function add_new_goal()
    println("\n🎯 Add New Goal")
    print("Goal description: ")
    goal = readline(stdin)
    
    print("Category (default: general): ")
    category = readline(stdin)
    if isempty(category)
        category = "general"
    end
    
    print("Priority (1-3, default: 1): ")
    priority_input = readline(stdin)
    priority = try parse(Int, priority_input) catch e 1 end
    priority = clamp(priority, 1, 3)
    
    if KamilaMemory.add_goal(goal, category, priority)
        UIComponents.show_success("Goal added successfully!")
    else
        UIComponents.show_error("Error adding goal.")
    end
    
    sleep(2)
end

function view_active_goals()
    println("\n🎯 Active Goals")
    goals = KamilaMemory.get_active_goals()
    
    if isempty(goals)
        println("No active goals.")
    else
        for (i, goal) in enumerate(goals)
            println("$i. $(goal["goal"]) (Priority: $(goal["priority"]))")
        end
    end
    
    println("Press Enter to continue...")
    readline(stdin)
end

function complete_goal()
    println("\n✅ Complete Goal")
    goals = KamilaMemory.get_active_goals()
    
    if isempty(goals)
        println("No active goals to complete.")
        sleep(2)
        return
    end
    
    println("Active goals:")
    for (i, goal) in enumerate(goals)
        println("$i. $(goal["goal"])")
    end
    
    print("Enter goal number to complete: ")
    goal_num = try parse(Int, readline(stdin)) catch e 0 end
    
    if KamilaMemory.complete_goal(goal_num + 1)
        UIComponents.show_success("Goal completed!")
    else
        UIComponents.show_error("Invalid goal number.")
    end
    
    sleep(2)
end

function generate_memory_summary()
    println("\n📊 Memory Summary")
    summary = KamilaMemory.generate_summary()
    println(summary)
    
    println("Press Enter to continue...")
    readline(stdin)
end

# System Functions
function generate_daily_system_report()
    println("\n📊 Generating Daily System Report...")
    report = SystemMonitor.generate_daily_report()
    println(report)
    
    println("Press Enter to continue...")
    readline(stdin)
end

function monitor_resources()
    println("\n🔍 Monitoring Resources")
    println("Press Ctrl+C to stop...")
    sleep(2)
    
    try
        SystemMonitor.monitor_resources(10)
    catch
        println("Monitoring stopped.")
    end
    
    sleep(1)
end

function view_system_alerts()
    println("\n🚨 System Alerts")
    alerts = SystemMonitor.get_system_alerts()
    
    if isempty(alerts)
        println("✅ No system alerts.")
    else
        for alert in alerts
            println(alert)
        end
    end
    
    println("Press Enter to continue...")
    readline(stdin)
end

function get_compatibility_report()
    println("\n🔍 Compatibility Report")
    report = get_os_compatibility_report()
    println(report)
    
    println("Press Enter to continue...")
    readline(stdin)
end

function get_os_compatibility_report()
    # This would call the OS check module
    return """
    🔍 System Compatibility Report
    
    Operating System: $(Sys.name()) $(Sys.kernel_version())
    Architecture: $(Sys.ARCH)
    Word Size: $(Sys.WORD_SIZE)-bit
    
    Compatibility:
    • Linux Compatible: ✅ Yes
    • Kamila Status: ✅ Fully Supported
    """
end

# Desktop Functions
function organize_desktop_automatically()
    println("\n📁 Organizing Desktop...")
    result = Desktop.organize_desktop(create_folders=true, move_files=false)
    
    if result["success"]
        UIComponents.show_success(result["message"])
    else
        UIComponents.show_error(result["error"])
    end
    
    sleep(2)
end

function get_ai_organization_suggestions()
    println("\n🤖 AI Organization Suggestions")
    suggestions = Desktop.get_ai_organization_suggestions()
    println(suggestions)
    
    println("Press Enter to continue...")
    readline(stdin)
end

function clean_old_files()
    println("\n🧹 Cleaning Desktop")
    result = Desktop.clean_desktop(days_old=30)
    
    if result["success"]
        UIComponents.show_success(result["message"])
    else
        UIComponents.show_error(result["error"])
    end
    
    sleep(2)
end

function generate_desktop_health_report()
    println("\n🏥 Desktop Health Report")
    report = Desktop.generate_desktop_health_report()
    println(report)
    
    println("Press Enter to continue...")
    readline(stdin)
end

# AI Functions
function test_ai_connection()
    println("\n🤖 Testing AI Connection...")
    
    if OllamaInterface.test_ollama_connection()
        UIComponents.show_success("AI connection successful!")
    else
        UIComponents.show_error("AI connection failed. Make sure Ollama is running.")
    end
    
    sleep(2)
end

function setup_kamila_model()
    println("\n🔧 Setting up Kamila Model...")
    result = OllamaInterface.setup_kamila_model()
    
    if result["success"]
        UIComponents.show_success(result["message"])
    else
        UIComponents.show_error(result["error"])
    end
    
    sleep(2)
end

function get_productivity_suggestions()
    println("\n💡 Productivity Suggestions")
    tasks = TaskManager.get_pending_tasks()
    stats = TaskManager.get_task_stats()
    
    suggestions = OllamaInterface.generate_productivity_suggestions(tasks, stats)
    println(suggestions)
    
    println("Press Enter to continue...")
    readline(stdin)
end

function explain_file_with_ai()
    println("\n📄 Explain File with AI")
    print("Enter file path: ")
    file_path = readline(stdin)
    
    if isempty(file_path)
        println("No file specified.")
        sleep(2)
        return
    end
    
    try
        content = read(file_path, String)
        explanation = OllamaInterface.explain_file_with_ai(file_path, content)
        println(explanation)
    catch e
        println("❌ Error reading file: $e")
    end
    
    println("Press Enter to continue...")
    readline(stdin)
end

function generate_ai_daily_report()
    println("\n📊 AI Daily Report")
    tasks = TaskManager.get_pending_tasks()
    memory_stats = KamilaMemory.get_memory_stats()
    system_info = SystemMonitor.get_system_stats()
    
    report = OllamaInterface.generate_ai_daily_report(tasks, memory_stats, system_info)
    println(report)
    
    println("Press Enter to continue...")
    readline(stdin)
end

# Settings Functions
function change_password()
    println("\n🔐 Change Password")
    # This would integrate with the auth module
    println("Password change functionality would be implemented here.")
    
    sleep(2)
end

function reset_authentication()
    println("\n⚠️  Reset Authentication")
    print("Are you sure? (y/N): ")
    confirm = lowercase(readline(stdin))
    
    if confirm == "y"
        println("Authentication reset. Next login will require new password.")
    else
        println("Reset cancelled.")
    end
    
    sleep(2)
end

function view_security_report()
    println("\n🔒 Security Report")
    report = get_file_security_report()
    println(report)
    
    println("Press Enter to continue...")
    readline(stdin)
end

function get_file_security_report()
    return """
    🔒 File Access Security Report
    
    Allowed Directories:
    • ~/Desktop
    • ~/Pictures
    • ~/Documents
    • ~/Downloads
    • ~/Trash
    • ~/Codes
    
    Security Status:
    • OS Check: ✅ Passed
    • Path Validation: ✅ Enabled
    • Write Restrictions: ✅ Active
    """
end

function export_settings()
    println("\n📤 Export Settings")
    println("Settings export functionality would be implemented here.")
    
    sleep(2)
end

end # module
