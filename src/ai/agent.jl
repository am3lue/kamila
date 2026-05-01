module Agent

using ..OllamaInterface
using ..AgentTools
using JSON
using Term
using Crayons

export start_agent_mode, parse_response

# --- Constants & Configuration ---

const MAX_HISTORY = 10

const MAX_ITERATIONS = 10

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
        "You are Kamila, an intelligent and strategic autonomous AI assistant running on Linux.",
        "Your goal is to fulfill user requests efficiently. You have a mental framework: Read -> Analyze -> Execute -> Check.",
        "",
        "## STRATEGY & FLEXIBILITY:",
        "- DO NOT follow the cycle blindly. Identify which steps are actually needed for the specific task.",
        "- If a task is simple and you already have the answer, provide the Final Response immediately.",
        "- If you need to perform actions, explain your reasoning (Thought) before calling a tool.",
        "- You can skip the 'Check' phase if the tool output is definitive and self-explanatory.",
        "- Be concise. Do not perform redundant steps or repeat actions.",
        "",
        "## TOOL USAGE:",
        "- Respond with JSON when you want to use a tool: {\"tool\": \"function_name\", \"args\": {...}}",
        "- Include your reasoning BEFORE the JSON block so the user knows what you are doing.",
        "- You can only call ONE tool at a time.",
        "- NEVER simulate tool outputs. Use the real results provided by the system.",
        "",
        "## Available Tools:",
        json_tools,
        "",
        "Awaiting your instructions."
    ]
    
    return join(parts, "\n")
end

function parse_response(response::String)
    clean_response = strip(response)
    
    # List of potential JSON candidates
    candidates = String[]
    json_blocks = [] # Store matches to identify where they are in the string
    
    # 1. Extract from markdown blocks
    for m in eachmatch(r"```(?:json)?\s*(\{.*?\})\s*```"s, clean_response)
        push!(candidates, m.captures[1])
        push!(json_blocks, m.match)
    end
    
    # 2. Extract anything between { and } if no markdown
    if isempty(candidates)
        m_outer = match(r"(\{.*\})"s, clean_response)
        if m_outer !== nothing
            push!(candidates, m_outer.captures[1])
            push!(json_blocks, m_outer.match)
        end
    end

    # Extract the "Thought" (text outside the JSON)
    thought = clean_response
    for block in json_blocks
        thought = replace(thought, block => "")
    end
    thought = strip(thought)

    for json_str in candidates
        processed_json = replace(json_str, r",\s*([\}\]])" => s"\1")
        
        try
            data = JSON.parse(processed_json)
            
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
            
            args = Dict()
            for key in ["args", "arguments", "parameters", "params", "input", "props"]
                if haskey(data, key) && (data[key] isa Dict || data[key] isa AbstractDict)
                    args = data[key]
                    break
                end
            end
            
            if isempty(args)
                args = copy(data)
                for key in ["tool", "name", "function", "tool_name", "call", "command"]
                    delete!(args, key)
                end
            end
            
            return (true, tool_name, args, thought)
        catch
            continue
        end
    end
    
    return (false, "", Dict(), clean_response)
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
        try
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
            # We enter an autonomous loop for this request
            current_context = ""
            for (role, msg) in history
                current_context *= "$role: $msg\n"
            end
            current_context *= "User: $user_input\n"
            
            iteration = 0
            while iteration < MAX_ITERATIONS
                iteration += 1
                
                print(Crayon(foreground=:yellow, italics=true)("\rThinking... (Step $iteration, Press Ctrl+C to cancel)"))
                
                try
                    prompt = current_context * "Kamila:"
                    response = OllamaInterface.query_ollama(prompt, system_prompt=get_system_prompt())
                    
                    # Clear the "Thinking..." line
                    print("\r" * " "^60 * "\r")
                    
                    if startswith(response, "❌")
                        println(Crayon(foreground=:red)("Error: " * response))
                        break
                    end
                    
                    # Show the raw reasoning/output for analysis
                    println(Crayon(foreground=:dark_gray)("--- AI Analysis ---"))
                    println(Crayon(foreground=:dark_gray)(response))
                    println(Crayon(foreground=:dark_gray)("------------------"))

                    is_tool, tool_name, tool_args, thought = parse_response(response)
                    
                    if is_tool
                        println(Crayon(foreground=:blue)("🛠️  Using tool: "), Crayon(bold=true)(tool_name))
                        
                        try
                            tool_output = AgentTools.execute_tool(tool_name, tool_args)
                            
                            println(Crayon(foreground=:dark_gray)("   ↳ Tool execution completed output: $tool_output"))
                            
                            # Add this step to the current context for the next iteration
                            current_context *= "Kamila: (Tool Call) $response\nSystem: Tool output: $tool_output\n"
                            # Continue to next iteration to let AI analyze output
                        catch e
                            if e isa InterruptException
                                println(Crayon(foreground=:yellow)("\n⚠️  Tool execution interrupted."))
                                break
                            end
                            println(Crayon(foreground=:red)("❌ Error executing tool: $e"))
                            current_context *= "Kamila: (Tool Call) $response\nSystem: Error: $e\n"
                        end
                    else
                        # AI gave a final response
                        format_ai_response(response)
                        push!(history, ("User", user_input))
                        push!(history, ("Kamila", response))
                        break
                    end
                    
                    if iteration == MAX_ITERATIONS
                        println(Crayon(foreground=:yellow)("⚠️  Maximum autonomous steps reached ($MAX_ITERATIONS)."))
                        format_ai_response("I've reached my maximum allowed steps for this task. Here is what I've done so far.")
                        break
                    end
                    
                catch e
                    if e isa InterruptException
                        println(Crayon(foreground=:yellow)("\n\n⚠️  Interrupted. Returning to prompt..."))
                        print("\r" * " "^60 * "\r")
                        break
                    else
                        println(Crayon(foreground=:red)("\n❌ System Error: $e"))
                        break
                    end
                end
            end
            
            # Maintain history limit
            if length(history) > MAX_HISTORY
                popfirst!(history)
                popfirst!(history)
            end
            
        catch e
            if e isa InterruptException
                println(Crayon(foreground=:yellow)("\n\n⚠️  Interrupted. Returning to prompt..."))
                # Clear generated text/thinking lines
                print("\r" * " "^40 * "\r")
                continue
            else
                println(Crayon(foreground=:red)("\n❌ System Error: $e"))
                # For significant errors, we might want to see the stack trace in dev
                # Base.display_error(e, catch_backtrace())
            end
        end
    end
end

end # module