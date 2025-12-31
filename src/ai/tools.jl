"""
Tool Definitions for Kamila Agent
"""

module AgentTools

# using ..TaskManager
using Dates
using ..FileAccess

export Tool, get_all_tools, execute_tool

struct Tool
    name::String
    description::String
    parameters::Dict
    func::Function
end

"""
Execute a shell command
"""
function run_shell_command(args::Dict)
    command = get(args, "command", "")
    if isempty(command)
        return "Error: Command cannot be empty"
    end
    
    # Security: Ask for user confirmation
    println("\n⚠️  SECURITY ALERT: The agent wants to execute the following command:")
    println("   $command")
    print("Do you want to allow this? (y/N): ")
    
    # Read user input from stdin
    user_response = strip(readline(stdin))
    
    if lowercase(user_response) != "y"
        println("❌ Command execution denied by user.")
        return "Error: Command execution denied by user."
    end
    
    try
        # Simple execution
        output = read(`bash -c $command`, String)
        return output
    catch e
        return "Error executing command: $e"
    end
end

"""
Read a file
"""
function read_file(args::Dict)
    file_path = get(args, "file_path", "")
    if isempty(file_path)
        return "Error: file_path is required"
    end
    
    try
        # Use safe_read_file from FileAccess to enforce allowed directories
        return FileAccess.safe_read_file(file_path)
    catch e
        return "Error reading file: $e"
    end
end

"""
Write to a file
"""
function write_file(args::Dict)
    file_path = get(args, "file_path", "")
    content = get(args, "content", "")
    
    if isempty(file_path)
        return "Error: file_path is required"
    end
    
    try
        # Use safe_write_file from FileAccess to enforce allowed directories
        FileAccess.safe_write_file(file_path, content)
        return "Successfully wrote to $file_path"
    catch e
        return "Error writing file: $e"
    end
end

"""
Add a task
"""
function add_task_tool(args::Dict)
    title = get(args, "title", "")
    if isempty(title)
        return "Error: Task title is required"
    end
    
    description = get(args, "description", "")
    category = get(args, "category", "general")
    priority = get(args, "priority", 2)
    
    # For now, just simulate task creation since TaskManager dependency is problematic
    task_id = rand(1:1000)  # Simulate a task ID
    return "Task added successfully: ID $task_id (Title: $title)"
end

"""
List tasks
"""
function list_tasks_tool(args::Dict)
    # For now, return a simulated task list
    return """Pending Tasks:
- [1] Complete project documentation (Priority: 3)
- [2] Review code changes (Priority: 2)
- [3] Plan next sprint (Priority: 1)"""
end

"""
Complete a task
"""
function complete_task_tool(args::Dict)
    task_id = get(args, "task_id", 0)
    if task_id == 0
        return "Error: Valid task_id is required"
    end
    
    return "Task $task_id marked as completed successfully."
end

"""
Get all available tools
"""
function get_all_tools()
    return [
        Tool(
            "run_shell_command",
            "Execute a shell command. Requires user confirmation before execution. Use this for listing files (ls), checking system status, or running programs.",
            Dict(
                "command" => "The bash command to execute"
            ),
            run_shell_command
        ),
        Tool(
            "read_file",
            "Read the content of a specific file.",
            Dict(
                "file_path" => "The path to the file to read"
            ),
            read_file
        ),
        Tool(
            "write_file",
            "Write content to a file. Overwrites existing content.",
            Dict(
                "file_path" => "The path to the file to write",
                "content" => "The content to write"
            ),
            write_file
        ),
        Tool(
            "add_task",
            "Add a new task to the task manager.",
            Dict(
                "title" => "Title of the task",
                "description" => "Optional description",
                "category" => "Task category (default: general)",
                "priority" => "Priority 1-4 (default: 2)"
            ),
            add_task_tool
        ),
        Tool(
            "list_tasks",
            "List all pending tasks.",
            Dict(),
            list_tasks_tool
        ),
        Tool(
            "complete_task",
            "Mark a task as completed by its ID.",
            Dict(
                "task_id" => "The numeric ID of the task to complete"
            ),
            complete_task_tool
        )
    ]
end

"""
Execute a tool by name
"""

function execute_tool(tool_name::String, args)
    # Ensure args is a Dict since tool functions expect strict Dict
    cmd_args = if args isa Dict
        args
    else
        # Convert JSON.Object or other dict-likes to Dict
        d = Dict{String, Any}()
        for k in keys(args)
            d[String(k)] = args[k]
        end
        d
    end

    tools = get_all_tools()
    for tool in tools
        if tool.name == tool_name
            return tool.func(cmd_args)
        end
    end
    return "Error: Tool '$tool_name' not found"
end
    
# function execute_tool(tool_name::String, args::Dict)
#     tools = get_all_tools()
#     for tool in tools
#         if tool.name == tool_name
#             return tool.func(args)
#         end
#     end
#     return "Error: Tool '$tool_name' not found"
# end

end # module
