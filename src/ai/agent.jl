module Agent

using ..OllamaInterface
using ..AgentTools
using JSON
using Term
using Crayons

export start_agent_mode, parse_response

# --- Constants & Configuration ---

const MAX_HISTORY = 10

# --- Helper Functions ---

function get_system_prompt()
    tools = AgentTools.get_all_tools()
    
    tools_desc = []
    for tool in tools
        push!(tools_desc, Dict(
            "name" => tool.name,
            "description" => tool.description,
            "parameters" => tool.parameters
        ))
    end
    
    json_tools = JSON.json(tools_desc)
    
    parts = [
        "You are Kamila, an AI assistant. Help users with their requests naturally.",
        "",
        "## Available Tools (for system integration)",
        json_tools,
        "",
        "TOOL USAGE INSTRUCTIONS:",
        "- Always respond with JSON when using tools. Format: {\"tool\": \"function_name\", \"args\": {...}}",
        "- Use tools for all system interactions, file operations, and task management",
        "- For file operations, use absolute paths or paths relative to current directory",
        "- When creating/modifying files, ensure content is properly formatted",
        "- Track all activities using memory functions after tool usage",
        "- Generate summaries after completing user tasks",
        "- Use run_shell_command for system operations like file listing, process management",
        "- Combine multiple tools in sequence when needed for complex tasks",
        "",
        "## Response Style",
        "- Be conversational and helpful",
        "- Provide direct answers when possible",
        "- Use tools only when absolutely necessary for system operations",
        "- Keep responses concise and clear",
        "",
        "You are running on Linux. Awaiting your first command."
    ]
    
    return join(parts, "\n")
end

function parse_response(response::String)
    clean_response = strip(response)
    
    # List of potential JSON candidates
    candidates = String[]
    
    # 1. Extract from markdown blocks (```json ... ``` or just ``` ... ```)
    for m in eachmatch(r"```(?:json)?\s*(\{.*?\})\s*```"s, clean_response)
        push!(candidates, m.captures[1])
    end
    
    # 2. Extract anything between { and }
    # We use a greedy match for the outer-most braces
    m_outer = match(r"(\{.*\})"s, clean_response)
    if m_outer !== nothing
        push!(candidates, m_outer.captures[1])
    end
    
    # 3. Add the whole string if it starts/ends with braces
    if startswith(clean_response, "{") && endswith(clean_response, "}")
        push!(candidates, clean_response)
    end

    for json_str in candidates
        # Pre-process json_str to fix common AI mistakes
        processed_json = json_str
        
        # Remove trailing commas in objects/arrays (common AI mistake)
        processed_json = replace(processed_json, r",\s*([\}\]])" => s"\1")
        
        # Fix unescaped newlines in strings
        # This is tricky, but we can try to find newlines that aren't followed by a key or end of object
        # For now, let's stick to basics but keep it in mind
        
        try
            data = JSON.parse(processed_json)
            
            # Normalize keys: check for 'tool', 'name', 'function', 'call'
            tool_name = ""
            for key in ["tool", "name", "function", "tool_name", "call", "command"]
                if haskey(data, key) && data[key] isa String
                    tool_name = data[key]
                    break
                end
            end
            
            if isempty(tool_name)
                continue
            end
            
            # Normalize arguments: check for 'args', 'arguments', 'parameters', 'params', 'input'
            args = Dict()
            for key in ["args", "arguments", "parameters", "params", "input", "props"]
                if haskey(data, key) && (data[key] isa Dict || data[key] isa AbstractDict)
                    args = data[key]
                    break
                end
            end
            
            # If no explicit args object, the rest of the object might BE the args
            if isempty(args)
                args = copy(data)
                # Remove the tool name key from args
                for key in ["tool", "name", "function", "tool_name", "call", "command"]
                    delete!(args, key)
                end
            end
            
            return (true, tool_name, args)
        catch
            continue
        end
    end
    
    return (false, "", Dict())
end

# --- UI Functions ---

function print_header()
    print("\033[2J\033[H") # Clear screen
    
    panel = Panel(
        """
        $(Crayon(foreground=:light_cyan))Type your request naturally. Kamila can use tools to help you.$(Crayon(reset=true))
        
        $(Crayon(bold=true))Commands:$(Crayon(reset=true))
        $(Crayon(foreground=:yellow))/help$(Crayon(reset=true))    - Show available commands
        $(Crayon(foreground=:yellow))/clear$(Crayon(reset=true))   - Clear the screen
        $(Crayon(foreground=:yellow))/exit$(Crayon(reset=true))    - Return to main menu
        """,
        title="Kamila Agent Mode",
        style="bold green",
        fit=true
    )
    println(panel)
end

function show_help()
    println()
    println(Crayon(bold=true, foreground=:yellow)("Available Commands:"))
    println("  $(Crayon(foreground=:cyan))/help$(Crayon(reset=true))     - Show this help message")
    println("  $(Crayon(foreground=:cyan))/clear$(Crayon(reset=true))    - Clear the terminal screen")
    println("  $(Crayon(foreground=:cyan))/history$(Crayon(reset=true))  - Show conversation history")
    println("  $(Crayon(foreground=:cyan))/tools$(Crayon(reset=true))    - List available tools")
    println("  $(Crayon(foreground=:cyan))/exit$(Crayon(reset=true))     - Exit Agent Mode")
    println()
end

function show_tools()
    tools = AgentTools.get_all_tools()
    println()
    println(Crayon(bold=true, foreground=:blue)("Available Tools:"))
    for tool in tools
        println("  $(Crayon(bold=true))$(tool.name)$(Crayon(reset=true)) - $(tool.description)")
    end
    println()
end

function show_history_log(history)
    println()
    println(Crayon(bold=true, foreground=:magenta)("Conversation History:"))
    for (role, msg) in history
        color = role == "User" ? :green : :white
        println(Crayon(foreground=color)("$role: ") * msg)
    end
    println()
end

function format_ai_response(text::String)
    # Use Term.jl Panel for nice formatting of AI responses
    # We strip the text to avoid excess whitespace
    clean_text = strip(text)
    if isempty(clean_text)
        return
    end
    
    println()
    println(Panel(
        clean_text,
        title="Kamila",
        style="blue",
        fit=false,
        width=60
    ))
    println()
end

# --- Main Logic ---

function start_agent_mode()
    print_header()
    
    history = []
    
    while true
        # Fancy prompt with current directory
        current_dir = basename(pwd())
        if isempty(current_dir)
            current_dir = "/home/"
        end
        
        prompt_str = "\n$(Crayon(foreground=:green, bold=true))User [$(current_dir)] > $(Crayon(reset=true))"
        print(prompt_str)
        
        user_input = strip(readline())
        
        # Handle empty input
        if isempty(user_input)
            continue
        end
        
        # Handle Commands
        if startswith(user_input, "/")
            cmd = lowercase(user_input)
            if cmd == "/exit" || cmd == "/quit" || cmd == "/back"
                println(Crayon(foreground=:dark_gray)("Exiting Agent Mode..."))
                break
            elseif cmd == "/help"
                show_help()
                continue
            elseif cmd == "/clear"
                print_header()
                continue
            elseif cmd == "/history"
                show_history_log(history)
                continue
            elseif cmd == "/tools"
                show_tools()
                continue
            else
                println(Crayon(foreground=:red)("Unknown command: $cmd. Type /help for options."))
                continue
            end
        end
        
        # Process regular input
        print(Crayon(foreground=:yellow, italics=true)("\rThinking..."))
        
        # Construct conversation prompt
        prompt = ""
        for (role, msg) in history
            prompt *= "$role: $msg\n"
        end
        prompt *= "User: $user_input\nKamila:"
        
        try
            response = OllamaInterface.query_ollama(prompt, system_prompt=get_system_prompt())
            
            # Clear the "Thinking..." line
            print("\r" * " "^20 * "\r")
            
            if startswith(response, "❌")
                println(Crayon(foreground=:red)("Error: " * response))
                continue
            end
            
            is_tool, tool_name, tool_args = parse_response(response)
            
            if is_tool
                println(Crayon(foreground=:blue)("🛠️  Using tool: "), Crayon(bold=true)(tool_name))
                
                try
                    tool_output = AgentTools.execute_tool(tool_name, tool_args)
                    
                    println(Crayon(foreground=:dark_gray)("   ↳ Tool executed successfully"))
                    
                    next_prompt = prompt * "\n" * response * "\nSystem: Tool output: " * string(tool_output) * "\nKamila:"
                    
                    print(Crayon(foreground=:yellow, italics=true)("\rProcessing result..."))
                    final_response = OllamaInterface.query_ollama(next_prompt, system_prompt=get_system_prompt())
                    print("\r" * " "^20 * "\r") # Clear processing line
                    
                    format_ai_response(final_response)
                    
                    push!(history, ("User", user_input))
                    push!(history, ("Kamila", final_response))
                catch e
                    println(Crayon(foreground=:red)("❌ Error executing tool: $e"))
                end
                
            else
                format_ai_response(response)
                push!(history, ("User", user_input))
                push!(history, ("Kamila", response))
            end
            
            # Maintain history limit
            if length(history) > MAX_HISTORY
                popfirst!(history)
                popfirst!(history)
            end
            
        catch e
            println(Crayon(foreground=:red)("\n❌ System Error: $e"))
        end
    end
end

end # module