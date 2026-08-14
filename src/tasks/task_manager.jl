"""
Task Management System for Kamila
Handles task creation, management, timetabling, and productivity calculations
"""

module TaskManager

using JSON
using Dates
using ..KamilaMemory

export Task,
    add_task, list_tasks, delete_task, complete_task, get_pending_tasks, generate_timetable

# Task structure
mutable struct Task
    id::Int
    title::String
    description::String
    category::String
    priority::Int  # 1=Low, 2=Medium, 3=High, 4=Critical
    estimated_time::Int  # minutes
    due_date::Union{Date,Nothing}
    created_date::Date
    completed::Bool
    completed_date::Union{Date,Nothing}
    tags::Vector{String}
end

"""
Load tasks from DB via KamilaMemory
"""
function load_tasks()
    tasks_data = KamilaMemory.get_tasks()
    tasks = Task[]
    for task_data in tasks_data
        task = Task(
            get(task_data, "id", 0),
            get(task_data, "title", ""),
            get(task_data, "description", ""),
            get(task_data, "category", "general"),
            get(task_data, "priority", 2),
            get(task_data, "estimated_time", 30),
            parse_date(get(task_data, "due_date", "")),
            parse_date(get(task_data, "created_date", string(now()))),
            get(task_data, "completed", false),
            parse_date(get(task_data, "completed_date", "")),
            get(task_data, "tags", String[]),
        )
        push!(tasks, task)
    end
    return tasks
end

"""
Save tasks to DB via KamilaMemory.upsert_tasks
"""
function save_tasks(tasks::Vector{Task})
    tasks_data = []
    for task in tasks
        task_data = Dict(
            "id" => task.id,
            "title" => task.title,
            "description" => task.description,
            "category" => task.category,
            "priority" => task.priority,
            "estimated_time" => task.estimated_time,
            "due_date" => task.due_date !== nothing ? string(task.due_date) : "",
            "created_date" => string(task.created_date),
            "completed" => task.completed,
            "completed_date" =>
                task.completed_date !== nothing ? string(task.completed_date) : "",
            "tags" => task.tags,
        )
        push!(tasks_data, task_data)
    end
    return KamilaMemory.upsert_tasks(tasks_data)
end

"""
Parse date string safely
"""
function parse_date(date_str::String)
    if isempty(date_str) || date_str == "nothing"
        return nothing
    end

    try
        return Date(date_str, "yyyy-mm-dd")
    catch
        return nothing
    end
end

"""
Get next available task ID
"""
function get_next_id(tasks::Vector{Task})
    if isempty(tasks)
        return 1
    end
    return maximum(t.id for t in tasks) + 1
end

"""
Add a new task
"""
function add_task(
    title::String;
    description::String = "",
    category::String = "general",
    priority::Int = 2,
    estimated_time::Int = 30,
    due_date::Union{Date,Nothing} = nothing,
    tags::Vector{String} = String[],
)
    tasks = load_tasks()
    new_id = get_next_id(tasks)

    new_task = Task(
        new_id,
        title,
        description,
        category,
        priority,
        estimated_time,
        due_date,
        Date(now()),
        false,
        nothing,
        tags,
    )

    push!(tasks, new_task)
    save_tasks(tasks)

    # Track activity
    KamilaMemory.track_activity(true)

    return new_task
end

"""
List all tasks
"""
function list_tasks(;
    completed::Union{Bool,Nothing} = nothing,
    category::Union{String,Nothing} = nothing,
)
    tasks = load_tasks()

    # Filter tasks
    if completed !== nothing
        tasks = filter(t -> t.completed == completed, tasks)
    end

    if category !== nothing
        tasks = filter(t -> t.category == category, tasks)
    end

    # Sort by priority (high to low) and then by creation date
    sort!(tasks, by = t -> (-t.priority, t.created_date))

    return tasks
end

"""
Delete a task
"""
function delete_task(task_id::Int)
    tasks = load_tasks()
    original_length = length(tasks)

    tasks = filter(t -> t.id != task_id, tasks)

    if length(tasks) < original_length
        save_tasks(tasks)
        return true
    end
    return false
end

"""
Complete a task
"""
function complete_task(task_id::Int)
    tasks = load_tasks()

    for task in tasks
        if task.id == task_id
            task.completed = true
            task.completed_date = Date(now())
            save_tasks(tasks)

            # Add achievement
            KamilaMemory.add_achievement("Task Completed", "Completed: $(task.title)")
            KamilaMemory.track_activity(true)

            return true
        end
    end

    return false
end

"""
Get pending tasks (not completed)
"""
function get_pending_tasks()
    return list_tasks(completed = false)
end

"""
Get overdue tasks
"""
function get_overdue_tasks()
    today = Date(now())
    pending = get_pending_tasks()

    return filter(t -> t.due_date !== nothing && t.due_date < today, pending)
end

"""
Generate optimized timetable for today
"""
function generate_timetable(; hours_available::Int = 8, work_start::Time = Time(9, 0))
    pending = get_pending_tasks()

    if isempty(pending)
        return []
    end

    # Calculate total available minutes
    available_minutes = hours_available * 60

    # Sort by priority and due date
    sort!(
        pending,
        by = t ->
            (-t.priority, t.due_date !== nothing ? t.due_date : Date(now()) + Day(1000)),
    )

    scheduled = []
    current_time = work_start
    used_minutes = 0

    for task in pending
        if used_minutes + task.estimated_time <= available_minutes
            push!(scheduled, (task, current_time))
            used_minutes += task.estimated_time
            current_time = current_time + Minute(task.estimated_time)
        else
            break  # No more time available
        end
    end

    return scheduled
end

"""
Calculate task statistics
"""
function get_task_stats()
    all_tasks = load_tasks()
    pending = get_pending_tasks()
    overdue = get_overdue_tasks()
    completed_today = filter(t -> t.completed && t.completed_date == Date(now()), all_tasks)

    return Dict(
        "total_tasks" => length(all_tasks),
        "pending_tasks" => length(pending),
        "overdue_tasks" => length(overdue),
        "completed_today" => length(completed_today),
        "completion_rate" =>
            length(all_tasks) > 0 ?
            round(
                (length(filter(t -> t.completed, all_tasks)) / length(all_tasks)) * 100,
                digits = 1,
            ) : 0.0,
        "total_estimated_time" => sum(t.estimated_time for t in pending; init = 0),
        "categories" => unique(t.category for t in all_tasks),
    )
end

"""
Generate daily task report
"""
function generate_daily_report()
    stats = get_task_stats()
    overdue = get_overdue_tasks()
    today_schedule = generate_timetable()

    report = []
    push!(report, "📋 Daily Task Report - $(string(Date(now())))")
    push!(report, "")
    push!(report, "📊 Overview:")
    push!(report, "  • Total tasks: $(stats["total_tasks"])")
    push!(report, "  • Pending: $(stats["pending_tasks"])")
    push!(report, "  • Overdue: $(stats["overdue_tasks"])")
    push!(report, "  • Completed today: $(stats["completed_today"])")
    push!(report, "  • Completion rate: $(stats["completion_rate"])%")
    push!(report, "")

    if !isempty(overdue)
        push!(report, "⚠️  Overdue Tasks:")
        for task in overdue
            push!(report, "  • $(task.title) (Due: $(task.due_date))")
        end
        push!(report, "")
    end

    if !isempty(today_schedule)
        push!(report, "🗓️  Today's Schedule:")
        for (task, start_time) in today_schedule
            end_time = start_time + Minute(task.estimated_time)
            push!(
                report,
                "  • $(start_time)-$(end_time): $(task.title) ($(task.estimated_time)min)",
            )
        end
    else
        push!(report, "🗓️  No tasks scheduled for today")
    end

    return join(report, "\n")
end

"""
Export tasks to JSON
"""
function export_tasks(filename::String)
    tasks = load_tasks()
    tasks_data = []

    for task in tasks
        task_data = Dict(
            "id" => task.id,
            "title" => task.title,
            "description" => task.description,
            "category" => task.category,
            "priority" => task.priority,
            "estimated_time" => task.estimated_time,
            "due_date" => task.due_date !== nothing ? string(task.due_date) : "",
            "created_date" => string(task.created_date),
            "completed" => task.completed,
            "completed_date" =>
                task.completed_date !== nothing ? string(task.completed_date) : "",
            "tags" => task.tags,
        )
        push!(tasks_data, task_data)
    end

    write(filename, JSON.json(tasks_data, 2))
    return true
end

end # module
