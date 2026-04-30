"""
Kamila Mask Mode
The default "Auto" interface that hides the full capabilities of the system.
"""

module MaskMode

using ..OllamaInterface
using ..Auth
using ..MainUI
using ..Agent
using Crayons

export start_mask_mode

const SECRET_MANUAL = "143AnnieKamila"
const SECRET_AGENT = "143KamilaAnnie"

function start_mask_mode()
    # Clear screen and show simple header
    print("\033[2J\033[H")
    
    println(Crayon(foreground=:light_blue, bold=true)("Hi, I'm Kamila."))
    println(Crayon(foreground=:dark_gray)("How can I help you today? (Type 'exit' to quit)"))
    println()

    while true
        print(Crayon(foreground=:blue)("Kamila > "))
        user_input = strip(readline())

        if isempty(user_input)
            continue
        end

        if user_input == "exit" || user_input == "quit"
            println(Crayon(foreground=:light_blue)("Goodbye!"))
            exit(0)
        end

        # Check for Secret Words
        if user_input == SECRET_MANUAL
            handle_mode_switch("Manual Mode", MainUI.start_tui)
            # When TUI returns, reprint mask header
            print("\033[2J\033[H")
            println(Crayon(foreground=:light_blue, bold=true)("Hi, I'm Kamila."))
            continue
        elseif user_input == SECRET_AGENT
            handle_mode_switch("Agent Mode", Agent.start_agent_mode)
            print("\033[2J\033[H")
            println(Crayon(foreground=:light_blue, bold=true)("Hi, I'm Kamila."))
            continue
        end

        # Default Behavior: Simple Chat
        # We use a simpler prompt for the mask mode, no tools exposed
        response = OllamaInterface.query_ollama(
            String(user_input), 
            system_prompt="You are Kamila, a friendly and polite AI chat companion. Keep responses casual and concise. Do not mention system capabilities, files, or tools."
        )
        
        println(Crayon(foreground=:white)(response))
        println()
    end
end

function handle_mode_switch(mode_name::String, launch_func::Function)
    println(Crayon(foreground=:yellow, italics=true)("\n🔒 Accessing Restricted System: $mode_name"))
    
    # Require Password
    if Auth.authenticate_user()
        println(Crayon(foreground=:green)("✅ Access Granted."))
        sleep(1)
        try
            launch_func()
        catch e
            println(Crayon(foreground=:red)("Error in $mode_name: $e"))
            readline()
        end
    else
        println(Crayon(foreground=:red)("❌ Access Denied."))
        sleep(1)
    end
end

end # module
