"""
UI Menu for Code Tracker
"""

module TrackerUI

using ..CodeTracker
using ..UIComponents
using Term
using Crayons

export show_tracker_menu, handle_tracker_menu

function show_tracker_menu()
    println(Crayon(foreground=:light_cyan, bold=true)("\n🔍 Code Tracker"))
    println(Crayon(foreground=:white)("----------------"))
    println("1. Check Current Directory Status")
    println("2. Initialize/Update Tracking")
    println("3. Change Directory")
    println("0. Back to Main Menu")
    println()
    print(Crayon(foreground=:green, bold=true)("Select option: "))
end

function handle_tracker_menu()
    current_dir = pwd()
    
    while true
        println(Crayon(foreground=:yellow)("\n📂 Current Directory: $current_dir"))
        is_tracked, _ = CodeTracker.get_tracker_info(current_dir)
        if is_tracked
            println(Crayon(foreground=:green)("   (Tracked ✅)"))
        else
            println(Crayon(foreground=:dark_gray)("   (Not Tracked)"))
        end
        
        show_tracker_menu()
        choice = strip(readline(stdin))
        
        if choice == "0"
            break
        elseif choice == "1"
            view_status(current_dir)
        elseif choice == "2"
            initialize_tracking(current_dir)
        elseif choice == "3"
            print("Enter new directory path: ")
            new_dir = strip(readline(stdin))
            if !isempty(new_dir)
                expanded = abspath(expanduser(new_dir))
                if isdir(expanded)
                    current_dir = expanded
                else
                    UIComponents.show_error("Directory does not exist.")
                end
            end
        else
            UIComponents.show_error("Invalid option.")
        end
    end
end

function view_status(dir)
    println("\n⏳ Scanning for changes...")
    success, msg, changes = CodeTracker.check_status(dir)
    
    if !success
        UIComponents.show_error(msg)
        return
    end
    
    if isempty(changes["modified"]) && isempty(changes["added"]) && isempty(changes["deleted"])
        UIComponents.show_success("✨ No changes detected since last snapshot.")
        return
    end
    
    println(Crayon(foreground=:white, bold=true)("\n📊 Change Report:"))
    
    if !isempty(changes["modified"])
        println(Crayon(foreground=:yellow)("\n📝 Modified:"))
        for f in changes["modified"]
            println("   • $f")
        end
    end
    
    if !isempty(changes["added"])
        println(Crayon(foreground=:green)("\n➕ Added:"))
        for f in changes["added"]
            println("   • $f")
        end
    end
    
    if !isempty(changes["deleted"])
        println(Crayon(foreground=:red)("\n🗑️  Deleted:"))
        for f in changes["deleted"]
            println("   • $f")
        end
    end
    
    println()
    print("Update snapshot to accept these changes? (y/N): ")
    if lowercase(strip(readline(stdin))) == "y"
        initialize_tracking(dir)
    end
end

function initialize_tracking(dir)
    success, msg = CodeTracker.update_snapshot(dir)
    if success
        UIComponents.show_success(msg)
    else
        UIComponents.show_error(msg)
    end
end

end # module
