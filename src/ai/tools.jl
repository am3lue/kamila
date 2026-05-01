"""
Tool Definitions for Kamila Agent
"""

module AgentTools


using Dates
using ..FileAccess
using ..KamilaMemory
using ..TaskManager

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
        return "The Command \"$command\" returned: $output please Check the output and if it is correct, you can use the output for your next steps."
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
    # Ensure priority is Int
    priority = if priority isa String
        tryparse(Int, priority) === nothing ? 2 : parse(Int, priority)
    elseif priority isa Number
        Int(priority)
    else
        2
    end

    estimated_time = get(args, "estimated_time", 30)
    estimated_time = if estimated_time isa String
        tryparse(Int, estimated_time) === nothing ? 30 : parse(Int, estimated_time)
    elseif estimated_time isa Number
        Int(estimated_time)
    else
        30
    end

    due_date_str = get(args, "due_date", "")
    due_date = isempty(due_date_str) ? nothing : TaskManager.parse_date(due_date_str)
    
    try
        task = TaskManager.add_task(
            title, 
            description=description, 
            category=category, 
            priority=priority, 
            estimated_time=estimated_time,
            due_date=due_date
        )
        return "Task added successfully: ID $(task.id) (Title: $(task.title))"
    catch e
        return "Error adding task: $e"
    end
end

"""
List tasks
"""
function list_tasks_tool(args::Dict)
    try
        tasks = TaskManager.get_pending_tasks()
        if isempty(tasks)
            return "No pending tasks found."
        end
        
        report = ["Pending Tasks:"]
        for task in tasks
            due_str = task.due_date !== nothing ? " (Due: $(task.due_date))" : ""
            push!(report, "- [$(task.id)] $(task.title) (Priority: $(task.priority))$due_str")
        end
        return join(report, "\n")
    catch e
        return "Error listing tasks: $e"
    end
end

"""
Complete a task
"""
function complete_task_tool(args::Dict)
    task_id = get(args, "task_id", 0)
    # Handle string task_id
    task_id = if task_id isa String
        tryparse(Int, task_id) === nothing ? 0 : parse(Int, task_id)
    elseif task_id isa Number
        Int(task_id)
    else
        0
    end

    if task_id == 0
        return "Error: Valid numeric task_id is required"
    end
    
    try
        if TaskManager.complete_task(task_id)
            return "Task $task_id marked as completed successfully."
        else
            return "Error: Task $task_id not found."
        end
    catch e
        return "Error completing task: $e"
    end
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

# """Parse tool command from AI response
# Expected format: {"tool": "tool_name", "args": {"param1": "value1", ...}}
# """

end # module
