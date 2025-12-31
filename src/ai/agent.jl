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
    
    # Try to find a JSON block in markdown
    m = match(r"```json\s*({.*?})\s*```"s, clean_response)
    json_str = m !== nothing ? m.captures[1] : ""
    
    # If no markdown, check if the whole response is JSON
    if isempty(json_str) && startswith(clean_response, "{") && endswith(clean_response, "}")
        json_str = clean_response
    end
    
    # If still empty, try to find any { } block that might be JSON
    if isempty(json_str)
        m = match(r"({.*})"s, clean_response)
        if m !== nothing
            json_str = m.captures[1]
        end
    end

    if !isempty(json_str)
        try
            data = JSON.parse(json_str)
            if haskey(data, "tool") && (haskey(data, "args") || haskey(data, "arguments"))
                args = get(data, "args", get(data, "arguments", Dict()))
                return (true, data["tool"], args)
            end
        catch
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
        title="🤖 Kamila Agent Mode",
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
        width=80
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
            current_dir = "/"
        end
        
        prompt_str = "\n$(Crayon(foreground=:green, bold=true))User [$(current_dir)] > $(Crayon(reset=true))"
        print(prompt_str)
        
        user_input = strip(readline(stdin))
        
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
                println(Crayon(foreground=:blue)("🛠️  Using tool: ") * Crayon(bold=true)(tool_name))
                
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