"""
Memory System for Kamila
Handles persistent storage and memory management via SQLite DB.
"""

module KamilaMemory

using JSON
using Dates
using SQLite
using Base.Threads
using ..Kamila
using ..KamilaLog
using ..MemoryDB
using ..Vectors
using ..Events
import ..Plan as PlanModule
import ..Decompose as DecomposeModule

export initialize_memory,
    get_memory_stats,
    get_today_achievements,
    add_goal,
    get_active_goals,
    complete_goal,
    decompose_goal,
    link_goal_plan,
    goal_progress,
    generate_summary,
    load_memory,
    save_memory,
    track_activity,
    add_achievement,
    remember,
    recall,
    delete_memory

const MEMORY_FILE = Kamila.MEMORY_FILE

function _task_row_to_dict(row)
    # row is already a NamedTuple from query_all
    tags = row.tags === nothing || row.tags === missing ? String[] : JSON.parse(row.tags)
    return Dict(
        "id" => row.id,
        "title" => row.title,
        "description" => something(row.description, ""),
        "category" => something(row.category, "general"),
        "priority" => something(row.priority, 2),
        "estimated_time" => something(row.estimated_time, 30),
        "due_date" => something(row.due_date, ""),
        "created_date" => something(row.created_date, ""),
        "completed" => row.completed == 1,
        "completed_date" => something(row.completed_date, ""),
        "tags" => tags,
    )
end

# SQLite NULL columns materialize as `missing`, not `nothing`. Coerce so callers
# can rely on `=== nothing`.
_undef(v) = v isa Missing ? nothing : v

function _goal_row_to_dict(row)
    return Dict(
        "id" => row.id,
        "goal" => row.goal,
        "category" => something(row.category, "general"),
        "priority" => something(row.priority, 1),
        "completed" => row.completed == 1,
        "status" => something(_undef(get(row, :status, nothing)), row.completed == 1 ? "completed" : "active"),
        "plan_id" => _undef(get(row, :plan_id, nothing)),
        "progress" => _undef(get(row, :progress, nothing)),
        "created_date" => something(row.created_date, ""),
        "completed_date" => something(row.completed_date, ""),
    )
end

function _achievement_row_to_dict(row)
    return Dict(
        "title" => row.title,
        "description" => something(row.description, ""),
        "date" => something(row.date, ""),
    )
end

function _next_id(db, table::String)
    rows =
        SQLite.DBInterface.execute(db, "SELECT COALESCE(MAX(id), 0) + 1 as id FROM $table")
    return first(rows).id
end

function _insert_achievement(db, title::String, description::String, date::String)
    id = _next_id(db, "achievements")
    SQLite.execute(
        db,
        "INSERT INTO achievements (id, title, description, date) VALUES (?,?,?,?)",
        (id, title, description, date),
    )
end

function get_tasks(; filters...)
    rows = MemoryDB.query_all("SELECT * FROM tasks ORDER BY id")
    tasks = [_task_row_to_dict(r) for r in rows]
    if !isempty(filters)
        completed = get(filters, :completed, nothing)
        category = get(filters, :category, nothing)
        if completed !== nothing
            tasks = filter(t -> t["completed"] == completed, tasks)
        end
        if category !== nothing
            tasks = filter(t -> t["category"] == category, tasks)
        end
    end
    return tasks
end

function upsert_task(task::AbstractDict)
    MemoryDB.transaction() do db
        id = get(task, "id", 0)
        if id == 0
            id = _next_id(db, "tasks")
        end
        tags = JSON.json(get(task, "tags", String[]))
        completed = get(task, "completed", false) ? 1 : 0
        SQLite.execute(
            db,
            "INSERT OR REPLACE INTO tasks (id, title, description, category, priority, estimated_time, due_date, created_date, completed, completed_date, tags) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (
                id,
                get(task, "title", ""),
                get(task, "description", ""),
                get(task, "category", "general"),
                get(task, "priority", 2),
                get(task, "estimated_time", 30),
                get(task, "due_date", ""),
                get(task, "created_date", ""),
                completed,
                get(task, "completed_date", ""),
                tags,
            ),
        )
    end
    return true
end

function upsert_tasks(tasks::Vector)
    MemoryDB.transaction() do db
        SQLite.execute(db, "DELETE FROM tasks")
        for task in tasks
            id = get(task, "id", 0)
            if id == 0
                id = _next_id(db, "tasks")
            end
            tags = JSON.json(get(task, "tags", String[]))
            completed = get(task, "completed", false) ? 1 : 0
            SQLite.execute(
                db,
                "INSERT INTO tasks (id, title, description, category, priority, estimated_time, due_date, created_date, completed, completed_date, tags) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                (
                    id,
                    get(task, "title", ""),
                    get(task, "description", ""),
                    get(task, "category", "general"),
                    get(task, "priority", 2),
                    get(task, "estimated_time", 30),
                    get(task, "due_date", ""),
                    get(task, "created_date", ""),
                    completed,
                    get(task, "completed_date", ""),
                    tags,
                ),
            )
        end
    end
    return true
end

function delete_task(id::Int)
    MemoryDB.execute!("DELETE FROM tasks WHERE id = ?", id)
    return true
end

function complete_task_db(id::Int)
    MemoryDB.execute!(
        "UPDATE tasks SET completed = 1, completed_date = ? WHERE id = ?",
        string(now()),
        id,
    )
    return true
end

function get_goals()
    rows = MemoryDB.query_all("SELECT * FROM goals ORDER BY id")
    return [_goal_row_to_dict(r) for r in rows]
end

function add_goal(goal_text::String, category::String = "general", priority::Int = 1)
    MemoryDB.transaction() do db
        id = _next_id(db, "goals")
        SQLite.execute(
            db,
            "INSERT INTO goals (id, goal, category, priority, completed, progress, status, created_date, completed_date) VALUES (?,?,?,?,0,0,'active',?,?)",
            (id, goal_text, category, priority, string(now()), ""),
        )
    end
    return true
end

"""
Derive a goal's progress from its linked plan (verified steps / total steps).
Returns `nothing` when the goal has no plan. Refreshable `00`-style computed
cache: the stored `progress` column is updated in place.
"""
function goal_progress(goal_id::Int)
    rows = MemoryDB.query_all("SELECT * FROM goals WHERE id = ?", (goal_id,))
    isempty(rows) && return nothing
    plan_id = _undef(get(first(rows), :plan_id, nothing))
    plan_id === nothing && return nothing
    plan = PlanModule.load(plan_id)
    plan === nothing && return nothing
    total = length(plan.steps)
    total == 0 && return 0
    verified = count(s -> s.status == :verified, plan.steps)
    progress = round(Int, verified / total * 100)
    MemoryDB.execute!(
        "UPDATE goals SET progress = ? WHERE id = ?",
        (progress, goal_id),
    )
    return progress
end

"""
Link a goal to an existing plan and refresh its derived progress.
"""
function link_goal_plan(goal_id::Int, plan_id::String)
    plan = PlanModule.load(plan_id)
    plan === nothing && return false
    MemoryDB.execute!(
        "UPDATE goals SET plan_id = ? WHERE id = ?",
        (plan_id, goal_id),
    )
    goal_progress(goal_id)
    return true
end

"""
Decompose a goal into a plan and link it. On success returns the new `plan_id`.
"""
function decompose_goal(goal_id::Int; max_steps::Int = 6)
    rows = MemoryDB.query_all("SELECT * FROM goals WHERE id = ?", (goal_id,))
    isempty(rows) && return nothing
    goal_text = first(rows).goal
    plan = DecomposeModule.decompose_to_plan(goal_text; max_steps = max_steps)
    link_goal_plan(goal_id, plan.id)
    return plan.id
end

function complete_goal(goal_id::Int)
    return MemoryDB.transaction() do db
        rows = MemoryDB.query_all("SELECT * FROM goals WHERE id = ?", (goal_id,))
        isempty(rows) && return false
        goal = first(rows)
        plan_id = _undef(get(goal, :plan_id, nothing))
        if plan_id !== nothing
            # Completion is gated on the linked plan being completed.
            plan = PlanModule.load(plan_id)
            if plan !== nothing && plan.status != :completed
                return false
            end
        end
        SQLite.execute(
            db,
            "UPDATE goals SET completed = 1, status = 'completed', completed_date = ? WHERE id = ?",
            (string(now()), goal_id),
        )
        _insert_achievement(
            db,
            "Goal Completed: $(goal.goal)",
            "Successfully completed goal in $(goal.category) category",
            string(today()),
        )
        return true
    end
end

function get_active_goals()
    goals = get_goals()
    for g in goals
        if !get(g, "completed", false)
            # Refresh derived progress from the linked plan (best effort).
            try
                goal_progress(g["id"])
            catch
            end
        end
    end
    # Re-read so the refreshed progress is reflected in the returned dicts.
    return filter(g -> !get(g, "completed", false), get_goals())
end

function get_achievements()
    rows = MemoryDB.query_all("SELECT * FROM achievements ORDER BY id")
    return [_achievement_row_to_dict(r) for r in rows]
end

function add_achievement(title::String, description::String)
    MemoryDB.transaction() do db
        _insert_achievement(db, title, description, string(today()))
    end
    return true
end

function get_today_achievements()
    today_str = string(today())
    return filter(a -> get(a, "date", "") == today_str, get_achievements())
end

function get_usage_stats()
    raw = get_kv("usage_stats")
    if raw === nothing
        return Dict(
            "useful_activities" => 0,
            "total_activities" => 0,
            "productivity_percentage" => 0.0,
        )
    end
    try
        parsed = JSON.parse(raw)
        return Dict(
            "useful_activities" => get(parsed, "useful_activities", 0),
            "total_activities" => get(parsed, "total_activities", 0),
            "productivity_percentage" => get(parsed, "productivity_percentage", 0.0),
        )
    catch
        return Dict(
            "useful_activities" => 0,
            "total_activities" => 0,
            "productivity_percentage" => 0.0,
        )
    end
end

function record_activity(useful::Bool = true)
    stats = get_usage_stats()
    stats["total_activities"] += 1
    useful && (stats["useful_activities"] += 1)
    total = stats["total_activities"]
    useful_count = stats["useful_activities"]
    stats["productivity_percentage"] =
        total > 0 ? round(useful_count / total * 100, digits = 1) : 0.0
    set_kv("usage_stats", JSON.json(stats))
    return stats
end

function track_activity(useful::Bool = true)
    record_activity(useful)
    return true
end

function get_kv(key::String)
    rows = MemoryDB.query_all("SELECT value FROM kv WHERE key = ?", key)
    isempty(rows) ? nothing : rows[1].value
end

function set_kv(key::String, value::String)
    MemoryDB.execute!("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)", key, value)
end

function load_memory()
    try
        MemoryDB.ensure_open()
        data = Dict{String,Any}()
        alias = get_kv("user_alias")
        alias !== nothing && (data["user_alias"] = alias)
        tasks = get_tasks()
        isempty(tasks) || (data["tasks"] = tasks)
        goals = get_goals()
        isempty(goals) || (data["goals"] = goals)
        achievements = get_achievements()
        isempty(achievements) || (data["achievements"] = achievements)
        if get_kv("usage_stats") !== nothing
            data["usage_stats"] = get_usage_stats()
        end
        last = get_kv("last_updated")
        last !== nothing && (data["last_updated"] = last)
        return data
    catch e
        KamilaLog.error("Error loading memory: $e"; mod = "memory")
        return Dict()
    end
end

function save_memory(memory_data::AbstractDict)
    try
        MemoryDB.transaction() do db
            if haskey(memory_data, "user_alias")
                set_kv("user_alias", string(memory_data["user_alias"]))
            end
            if haskey(memory_data, "last_updated")
                set_kv("last_updated", string(memory_data["last_updated"]))
            end
            if haskey(memory_data, "tasks")
                SQLite.execute(db, "DELETE FROM tasks")
                for task in memory_data["tasks"]
                    id = get(task, "id", 0)
                    if id == 0
                        id = _next_id(db, "tasks")
                    end
                    tags = JSON.json(get(task, "tags", String[]))
                    completed = get(task, "completed", false) ? 1 : 0
                    SQLite.execute(
                        db,
                        "INSERT INTO tasks (id, title, description, category, priority, estimated_time, due_date, created_date, completed, completed_date, tags) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                        (
                            id,
                            get(task, "title", ""),
                            get(task, "description", ""),
                            get(task, "category", "general"),
                            get(task, "priority", 2),
                            get(task, "estimated_time", 30),
                            get(task, "due_date", ""),
                            get(task, "created_date", ""),
                            completed,
                            get(task, "completed_date", ""),
                            tags,
                        ),
                    )
                end
            end
            if haskey(memory_data, "goals")
                SQLite.execute(db, "DELETE FROM goals")
                for goal in memory_data["goals"]
                    id = get(goal, "id", 0)
                    if id == 0
                        id = _next_id(db, "goals")
                    end
                    SQLite.execute(
                        db,
                        "INSERT INTO goals (id, goal, category, priority, completed, progress, created_date, completed_date) VALUES (?,?,?,?,?,?,?,?)",
                        (
                            id,
                            get(goal, "goal", ""),
                            get(goal, "category", "general"),
                            get(goal, "priority", 1),
                            get(goal, "completed", false) ? 1 : 0,
                            get(goal, "progress", 0),
                            get(goal, "created_date", ""),
                            get(goal, "completed_date", ""),
                        ),
                    )
                end
            end
            if haskey(memory_data, "achievements")
                SQLite.execute(db, "DELETE FROM achievements")
                for ach in memory_data["achievements"]
                    id = get(ach, "id", 0)
                    if id == 0
                        id = _next_id(db, "achievements")
                    end
                    SQLite.execute(
                        db,
                        "INSERT INTO achievements (id, title, description, date) VALUES (?,?,?,?)",
                        (
                            id,
                            get(ach, "title", ""),
                            get(ach, "description", ""),
                            get(ach, "date", ""),
                        ),
                    )
                end
            end
            if haskey(memory_data, "usage_stats")
                set_kv("usage_stats", JSON.json(memory_data["usage_stats"]))
            end
        end
        return true
    catch e
        KamilaLog.error("Error saving memory: $e"; mod = "memory")
        return false
    end
end

function initialize_memory()
    MemoryDB.ensure_open()
    if !isfile(MEMORY_FILE)
        default_memory = Dict(
            "user_alias" => "Blue",
            "tasks" => [],
            "achievements" => [],
            "goals" => [],
            "usage_stats" => Dict(
                "useful_activities" => 0,
                "total_activities" => 0,
                "productivity_percentage" => 0.0,
            ),
            "last_updated" => string(now()),
        )
        write(MEMORY_FILE, JSON.json(default_memory))
    end
end

function get_memory_stats()
    memory_data = load_memory()
    usage_stats = get(
        memory_data,
        "usage_stats",
        Dict("productivity_percentage" => 0.0, "total_activities" => 0),
    )
    return Dict(
        "user_alias" => get(memory_data, "user_alias", "Blue"),
        "total_tasks" => length(get(memory_data, "tasks", [])),
        "completed_tasks" =>
            count(x -> get(x, "completed", false), get(memory_data, "tasks", [])),
        "total_achievements" => length(get(memory_data, "achievements", [])),
        "active_goals" => length([
            g for g in get(memory_data, "goals", []) if !get(g, "completed", false)
        ]),
        "productivity_percentage" => get(usage_stats, "productivity_percentage", 0.0),
        "total_activities" => get(usage_stats, "total_activities", 0),
        "last_updated" => get(memory_data, "last_updated", "Never"),
    )
end

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

function export_memory(filename::String = "kamila_memory_export.json")
    try
        data = build_legacy_json()
        write(filename, JSON.json(data, 4))
        return true
    catch e
        KamilaLog.error("Error exporting memory: $e"; mod = "memory")
        return false
    end
end

function import_memory(filename::String)
    try
        imported_data = JSON.parsefile(filename)
        save_memory(imported_data)
        return true
    catch e
        KamilaLog.error("Error importing memory: $e"; mod = "memory")
        return false
    end
end

function clear_memory()
    MemoryDB.transaction() do db
        SQLite.execute(db, "DELETE FROM tasks")
        SQLite.execute(db, "DELETE FROM goals")
        SQLite.execute(db, "DELETE FROM achievements")
        SQLite.execute(db, "DELETE FROM kv")
        SQLite.execute(db, "DELETE FROM chat_messages")
    end
    initialize_memory()
    return true
end

function reset_stats()
    set_kv(
        "usage_stats",
        JSON.json(
            Dict(
                "useful_activities" => 0,
                "total_activities" => 0,
                "productivity_percentage" => 0.0,
            ),
        ),
    )
    return true
end

function reset_for_tests!()
    MemoryDB.reset!()
    return nothing
end

function save_chat_history(sessions::AbstractDict)
    MemoryDB.transaction() do db
        SQLite.execute(db, "DELETE FROM chat_messages")
        for (session, msgs) in sessions
            for (i, msg) in enumerate(msgs)
                idx = get(msg, "idx", i)
                created_at = get(msg, "created_at", get(msg, "time", string(now())))
                SQLite.execute(
                    db,
                    "INSERT INTO chat_messages (session, role, content, created_at, idx) VALUES (?,?,?,?,?)",
                    (
                        session,
                        get(msg, "role", "user"),
                        get(msg, "content", ""),
                        created_at,
                        idx,
                    ),
                )
            end
        end
    end
end

function load_chat_history()
    rows = MemoryDB.query_all("SELECT * FROM chat_messages ORDER BY session, idx")
    sessions = Dict{String,Vector{Dict{String,Any}}}()
    for r in rows
        key = r.session
        v = get!(sessions, key, Vector{Dict{String,Any}}())
        push!(
            v,
            Dict{String,Any}(
                "role" => r.role,
                "content" => something(r.content, ""),
                "created_at" => something(r.created_at, ""),
                "idx" => r.idx,
            ),
        )
    end
    return sessions
end

function build_legacy_json()
    data = Dict{String,Any}()
    alias = get_kv("user_alias")
    alias !== nothing && (data["user_alias"] = alias)
    tasks = get_tasks()
    isempty(tasks) || (data["tasks"] = tasks)
    goals = get_goals()
    isempty(goals) || (data["goals"] = goals)
    achievements = get_achievements()
    isempty(achievements) || (data["achievements"] = achievements)
    if get_kv("usage_stats") !== nothing
        data["usage_stats"] = get_usage_stats()
    end
    last = get_kv("last_updated")
    last !== nothing && (data["last_updated"] = last)
    return data
end

"""
Store content in semantic memory with embedding.
Returns (id, embedded::Bool).
"""
function remember(
    content::String;
    kind::String = "chat",
    importance::Float64 = 0.5,
    period::Union{String,Nothing} = nothing,
    period_start::Union{String,Nothing} = nothing,
    period_end::Union{String,Nothing} = nothing,
    source_session_id::Union{Int,Nothing} = nothing,
    source_turn_count::Union{Int,Nothing} = nothing,
    retryable::Bool = false,
)
    try
        return Vectors.remember_content(
            content;
            kind = kind,
            importance = importance,
            period = period,
            period_start = period_start,
            period_end = period_end,
            source_session_id = source_session_id,
            source_turn_count = source_turn_count,
            retryable = retryable,
        )
    catch e
        KamilaLog.error("remember failed: $e"; mod = "memory")
        return (0, false)
    end
end

"""
Recall relevant memories using semantic search with FTS5 fallback.
Returns vector of (id, kind, content, created_at, importance, score).
"""
function recall(
    query::String;
    k::Int = 5,
    kinds::Union{Vector{String},Nothing} = nothing,
    min_sim::Float64 = 0.25,
)
    isempty(strip(query)) && return NamedTuple[]
    return Vectors.recall(query; k = k, kinds = kinds, min_sim = min_sim)
end

"""
Delete a memory by ID.
"""
function delete_memory(id::Int)
    MemoryDB.transaction() do db
        SQLite.execute(db, "DELETE FROM memories WHERE id = ?", (id,))
        SQLite.execute(db, "DELETE FROM memories_fts WHERE rowid = ?", (id,))
    end
    return true
end

"""
Lazy backfill: embed existing chat messages that don't have embeddings yet.
Runs in batches to avoid blocking the main loop.
"""
function backfill_chat_embeddings(; batch_size::Int = 50, delay_ms::Int = 100)
    # Check if backfill already completed (simple flag)
    backfill_done = get_kv("backfill_chat_embeddings_done")
    backfill_done == "true" && return

    # Limit total backfill to 1000 rows
    rows = MemoryDB.query_all(
        """
        SELECT cm.id, cm.content, cm.session
        FROM chat_messages cm
        LEFT JOIN memories m ON m.content = cm.content AND m.kind = 'chat'
        WHERE m.id IS NULL
        ORDER BY cm.id
        LIMIT ?
        """,
        (1000,),
    )

    if isempty(rows)
        set_kv("backfill_chat_embeddings_done", "true")
        return
    end

    for (i, r) in enumerate(rows)
        Vectors.remember_content(r.content; kind = "chat", importance = 0.5)
        if i % batch_size == 0
            sleep(delay_ms / 1000)
        end
    end

    if length(rows) < 1000
        set_kv("backfill_chat_embeddings_done", "true")
    end
end

end # module
