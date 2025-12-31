"""
Memory System for Kamila
Handles persistent storage and memory management
"""

module KamilaMemory

using JSON
using Dates

export initialize_memory, get_memory_stats, get_today_achievements,
       add_goal, get_active_goals, complete_goal, generate_summary,
       load_memory, save_memory, track_activity, add_achievement

"""
Initialize the memory system
"""
function initialize_memory()
    memory_file = joinpath(homedir(), ".kamila_memory.json")
    
    if !isfile(memory_file)
        # Create default memory structure
        default_memory = Dict(
            "user_alias" => "Blue",
            "tasks" => [],
            "achievements" => [],
            "goals" => [],
            "usage_stats" => Dict(
                "useful_activities" => 0,
                "total_activities" => 0,
                "productivity_percentage" => 0.0
            ),
            "last_updated" => string(now())
        )

        write(memory_file, JSON.json(default_memory))
    end
end

"""
Load memory from file
"""
function load_memory()
    memory_file = joinpath(homedir(), ".kamila_memory.json")
    
    try
        memory_data = JSON.parsefile(memory_file)
        return memory_data
    catch e
        println("Error loading memory: $e")
        return Dict()
    end
end

"""
Save memory to file
"""
function save_memory(memory_data::AbstractDict)
    memory_file = joinpath(homedir(), ".kamila_memory.json")
    
    try
        memory_data["last_updated"] = string(now())
        write(memory_file, JSON.json(memory_data))
        return true
    catch e
        println("Error saving memory: $e")
        return false
    end
end

"""
Get memory statistics
"""
function get_memory_stats()
    memory_data = load_memory()
    
    usage_stats = get(memory_data, "usage_stats", Dict(
        "productivity_percentage" => 0.0,
        "total_activities" => 0
    ))
    
    return Dict(
        "user_alias" => get(memory_data, "user_alias", "Blue"),
        "total_tasks" => length(get(memory_data, "tasks", [])),
        "completed_tasks" => count(x -> get(x, "completed", false), get(memory_data, "tasks", [])),
        "total_achievements" => length(get(memory_data, "achievements", [])),
        "active_goals" => length([g for g in get(memory_data, "goals", []) if !get(g, "completed", false)]),
        "productivity_percentage" => get(usage_stats, "productivity_percentage", 0.0),
        "total_activities" => get(usage_stats, "total_activities", 0),
        "last_updated" => get(memory_data, "last_updated", "Never")
    )
end

"""
Get today's achievements
"""
function get_today_achievements()
    memory_data = load_memory()
    achievements = get(memory_data, "achievements", [])
    today = string(today())
    
    # Filter achievements from today
    todays_achievements = [a for a in achievements if get(a, "date", "") == today]
    
    return todays_achievements
end

"""
Add a new goal
"""
function add_goal(goal_text::String, category::String="general", priority::Int=1)
    memory_data = load_memory()
    
    if !haskey(memory_data, "goals")
        memory_data["goals"] = []
    end
    
    new_goal = Dict(
        "id" => length(memory_data["goals"]) + 1,
        "goal" => goal_text,
        "category" => category,
        "priority" => priority,
        "completed" => false,
        "created_date" => string(now()),
        "completed_date" => ""
    )
    
    push!(memory_data["goals"], new_goal)
    save_memory(memory_data)
    
    return true
end

"""
Get active (incomplete) goals
"""
function get_active_goals()
    memory_data = load_memory()
    goals = get(memory_data, "goals", [])
    
    active_goals = [g for g in goals if !get(g, "completed", false)]
    
    return active_goals
end

"""
Complete a goal
"""
function complete_goal(goal_id::Int)
    memory_data = load_memory()
    goals = get(memory_data, "goals", [])
    
    for goal in goals
        if get(goal, "id", 0) == goal_id
            goal["completed"] = true
            goal["completed_date"] = string(now())
            
            # Add achievement
            achievement = Dict(
                "title" => "Goal Completed: $(goal["goal"])",
                "description" => "Successfully completed goal in $(goal["category"]) category",
                "date" => string(now())
            )
            
            if !haskey(memory_data, "achievements")
                memory_data["achievements"] = []
            end
            
            push!(memory_data["achievements"], achievement)
            
            save_memory(memory_data)
            return true
        end
    end
    
    return false
end

"""
Generate memory summary
"""
function generate_summary()
    memory_data = load_memory()
    stats = get_memory_stats()
    
    summary = """
    📊 MEMORY SUMMARY
    ================
    
    User: $(stats["user_alias"])
    Total Tasks: $(stats["total_tasks"])
    Completed Tasks: $(stats["completed_tasks"])
    Active Goals: $(stats["active_goals"])
    Total Achievements: $(stats["total_achievements"])
    Productivity: $(stats["productivity_percentage"])%
    
    Last Updated: $(stats["last_updated"])
    """
    
    return summary
end

"""
Add an achievement
"""
function add_achievement(title::String, description::String)
    memory_data = load_memory()
    
    achievement = Dict(
        "title" => title,
        "description" => description,
        "date" => string(now())
    )
    
    if !haskey(memory_data, "achievements")
        memory_data["achievements"] = []
    end
    
    push!(memory_data["achievements"], achievement)
    
    save_memory(memory_data)
    return true
end

"""
Track activity statistics
"""
function track_activity(useful::Bool=true)
    memory_data = load_memory()
    
    if !haskey(memory_data, "usage_stats")
        memory_data["usage_stats"] = Dict(
            "useful_activities" => 0,
            "total_activities" => 0,
            "productivity_percentage" => 0.0
        )
    end
    
    memory_data["usage_stats"]["total_activities"] += 1
    
    if useful
        memory_data["usage_stats"]["useful_activities"] += 1
    end
    
    # Calculate productivity percentage
    total = memory_data["usage_stats"]["total_activities"]
    useful_count = memory_data["usage_stats"]["useful_activities"]
    
    if total > 0
        memory_data["usage_stats"]["productivity_percentage"] = round(useful_count / total * 100, digits=1)
    end
    
    save_memory(memory_data)
end

"""
Export memory data to file
"""
function export_memory(filename::String="kamila_memory_export.json")
    memory_data = load_memory()
    
    try
        write(filename, JSON.json(memory_data, 4))  # Pretty print with 4 spaces
        return true
    catch e
        println("Error exporting memory: $e")
        return false
    end
end

"""
Import memory data from file
"""
function import_memory(filename::String)
    try
        imported_data = JSON.parsefile(filename)
        save_memory(imported_data)
        return true
    catch e
        println("Error importing memory: $e")
        return false
    end
end

"""
Clear all memory data
"""
function clear_memory()
    initialize_memory()
    return true
end

"""
Reset memory statistics (keep goals and achievements)
"""
function reset_stats()
    memory_data = load_memory()
    
    memory_data["usage_stats"] = Dict(
        "useful_activities" => 0,
        "total_activities" => 0,
        "productivity_percentage" => 0.0
    )
    
    save_memory(memory_data)
    return true
end

end # module
