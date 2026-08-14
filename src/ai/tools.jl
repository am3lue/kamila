module AgentTools

using Dates
using ..FileAccess
using ..KamilaMemory
using ..TaskManager
using ..SystemMonitor
using ..OllamaInterface
using ..KamilaLog
using ..Errors
using ..ModelRouter
using ..Confirm
using ..Permission
using ..Search
using ..MemoryDB
using ..Episodic
using ..Context

export Tool,
    get_all_tools, get_filtered_tools, execute_tool, prompt_confirm, execute_tool_structured

struct Tool
    name::String
    description::String
    parameters::Dict
    func::Function
end

# ─── Helpers ──────────────────────────────────────────────

const MAX_OUTPUT_CHARS = 5000
const MAX_SEARCH_RESULTS = 200

function safe_truncate(text::String, limit::Int = MAX_OUTPUT_CHARS)
    if length(text) > limit
        return text[1:limit] * "\n... (truncated, $(length(text) - limit) more chars)"
    end
    text
end

# ─── Confirmation helper ─────────────────────────────────
# Delegates to the `Confirm` module (see `02.1-stdin-bridge-conflict`), which
# routes the prompt to stderr and reads the answer without touching protocol
# stdout. Kept as a thin shim for backward compatibility.

function prompt_confirm(command::String; description::String = "")
    return Confirm.confirm(command; description = description)
end

# ─── Permission gate ───────────────────────────────────────
# Policy-driven authorization (see 02.2-tool-permission-redesign). `force` is
# honored only with a valid capability token issued by `Permission` when the
# policy yields :allow — a model-set `force=true` is otherwise treated per policy.

"""
Check whether a tool call may proceed under the permission policy. Returns
`nothing` when authorized; throws `KamilaError(:permission)` when denied.
  - policy :allow -> authorized (also issues no token; already allowed)
  - policy :deny  -> throws
  - policy :ask   -> requires a valid capability token OR an interactive/bridge
                     confirmation; a successful confirmation is remembered for
                     the session so identical calls aren't re-prompted.
"""
function _authorize!(tool::String, args::Dict; description::String = "")
    decision, rule = Permission._evaluate_with_rule(tool, args)

    if decision == :allow
        return nothing
    elseif decision == :deny
        throw(
            Errors.KamilaError(
                :permission,
                "Action blocked by permission policy: $(_describe_tool_call(tool, args))",
                details = Dict("tool" => tool, "args" => args, "rule" => rule),
            ),
        )
    end

    # :ask — a capability token (force) or a user confirmation is required.
    token = get(args, "capability", "")
    if !isempty(token) && Permission.verify_capability(tool, args, token)
        return nothing
    end

    approved = Confirm.confirm(
        _describe_tool_call(tool, args);
        description = description,
        rule = rule,
    )
    if !approved
        throw(
            Errors.KamilaError(
                :permission,
                "Action denied by user: $(_describe_tool_call(tool, args))",
                details = Dict("tool" => tool, "args" => args, "rule" => rule),
            ),
        )
    end
    Permission.remember_decision(tool, args, :allow)
    return nothing
end

function _describe_tool_call(tool::String, args::Dict)
    if tool == "run_shell_command"
        return string(get(args, "command", ""))
    elseif tool == "write_file"
        return "write_file " * string(get(args, "file_path", ""))
    end
    return tool
end

# ─── 1. run_shell_command ─────────────────────────────────

function run_shell_command(args::Dict)
    command = get(args, "command", "")
    if isempty(command)
        return "Error: command is required"
    end

    description = get(args, "description", "")
    timeout_seconds = get(args, "timeout_seconds", 30)

    _authorize!("run_shell_command", args; description = description)

    try
        # Use timeout command for safety. Backticks build a Cmd so each
        # value is a single argv element; bash -c receives the full string.
        timeout_cmd = `timeout $timeout_seconds bash -c $command`
        output = read(timeout_cmd, String)
        truncated = safe_truncate(output)
        return "Command executed successfully:\n$truncated"
    catch e
        if occursin("timeout", string(e))
            return "Error: Command timed out after $(timeout_seconds)s: $command"
        end
        return "Error executing command: $e"
    end
end

# ─── 2. read_file ─────────────────────────────────────────

"""
Rethrow categorized `KamilaError`s so structured callers can react; convert
unexpected exceptions to a human-readable string for legacy string callers.
"""
function _handle_tool_error(e, context::AbstractString)
    if e isa Errors.KamilaError
        rethrow(e)
    end
    return "Error $context: $(Errors.error_string(e))"
end

function read_file(args::Dict)
    file_path = get(args, "file_path", "")
    if isempty(file_path)
        throw(Errors.KamilaError(:validation, "file_path is required"))
    end

    start_line = get(args, "start_line", 0)
    end_line = get(args, "end_line", 0)
    max_bytes = get(args, "max_bytes", 0)

    try
        validated_path = FileAccess.validate_path(file_path)
        if !isfile(validated_path)
            throw(
                Errors.KamilaError(
                    :notfound,
                    "File does not exist: $file_path",
                    details = Dict("file_path" => file_path),
                ),
            )
        end

        # Detect binary file
        if !is_text_file(validated_path)
            throw(
                Errors.KamilaError(
                    :unsupported,
                    "Cannot read binary file. Use a text-based file.",
                    details = Dict("file_path" => file_path),
                ),
            )
        end

        content = read(validated_path, String)
        lines = split(content, "\n")

        if max_bytes > 0 && length(content) > max_bytes
            content = content[1:max_bytes]
            lines = split(content, "\n")
        end

        if start_line > 0 && end_line > 0
            start_line = max(1, start_line)
            end_line = min(end_line, length(lines))
            lines = lines[start_line:end_line]
            content = join(lines, "\n")
            return "File: $file_path (lines $start_line-$end_line of $(length(lines))):\n$content"
        elseif start_line > 0
            lines = lines[start_line:min(start_line + 50, length(lines))]
            content = join(lines, "\n")
            return "File: $file_path (from line $start_line):\n$content"
        end

        return "File: $file_path ($(length(lines)) lines, $(length(content)) bytes):\n$content"
    catch e
        return _handle_tool_error(e, "reading file '$file_path'")
    end
end

function is_text_file(path::String)
    try
        open(path) do f
            bytes = read(f, 1024)
            # Check for null bytes (binary indicator)
            return !(0x00 in bytes)
        end
    catch
        return false
    end
end

function extract_error(e)
    return Errors.error_string(e)
end

# ─── 3. write_file ────────────────────────────────────────

function write_file(args::Dict)
    file_path = get(args, "file_path", "")
    content = get(args, "content", "")

    if isempty(file_path)
        return "Error: file_path is required"
    end

    _authorize!("write_file", args)

    append_mode = get(args, "append", false)
    create_backup = get(args, "create_backup", false)

    try
        validated_path = FileAccess.validate_path(file_path)

        # Create parent directory if needed
        parent = dirname(validated_path)
        if !isdir(parent)
            mkpath(parent)
        end

        # Backup existing file
        if create_backup && isfile(validated_path)
            backup_path = validated_path * ".bak"
            cp(validated_path, backup_path; force = true)
        end

        if append_mode
            open(validated_path, "a") do f
                write(f, content)
            end
            return "Successfully appended $(length(content)) bytes to $file_path"
        else
            write(validated_path, content)
            return "Successfully wrote $(length(content)) bytes to $file_path"
        end
    catch e
        return _handle_tool_error(e, "writing file '$file_path'")
    end
end

# ─── 4. list_directory ────────────────────────────────────

function list_directory_tool(args::Dict)
    path = get(args, "path", ".")
    show_hidden = get(args, "show_hidden", false)
    sort_by = get(args, "sort_by", "name")
    max_depth = get(args, "max_depth", 1)

    try
        validated_path = FileAccess.validate_path(path)
        if !isdir(validated_path)
            return "Error: Directory does not exist: $path"
        end

        entries = readdir(validated_path; join = true)

        if !show_hidden
            entries = filter(e -> !startswith(basename(e), '.'), entries)
        end

        if sort_by == "name"
            sort!(entries, by = basename)
        elseif sort_by == "size"
            sort!(entries, by = e -> isfile(e) ? stat(e).size : 0)
        elseif sort_by == "date"
            sort!(entries, by = e -> stat(e).mtime, rev = true)
        end

        if max_depth > 1
            entries = collect_recursive(validated_path, max_depth, show_hidden)
        end

        if isempty(entries)
            return "Directory is empty: $path"
        end

        result = ["Directory: $path ($(length(entries)) items)"]
        for entry in entries
            name = basename(entry)
            type_str = isdir(entry) ? "📁" : (islink(entry) ? "🔗" : "📄")
            size_str = ""
            date_str = ""
            try
                st = stat(entry)
                size_str = isfile(entry) ? " $(format_bytes(st.size))" : ""
                date_str = " $(Dates.format(st.mtime, "yyyy-mm-dd HH:MM"))"
            catch
            end
            push!(result, "  $type_str $name$size_str$date_str")
        end

        return join(result, "\n")
    catch e
        return _handle_tool_error(e, "listing directory '$path'")
    end
end

function collect_recursive(root::String, max_depth::Int, show_hidden::Bool)
    results = String[]
    for (r, dirs, files) in walkdir(root; topdown = true)
        depth = length(splitpath(relpath(r, root)))
        depth > max_depth && continue

        for f in files
            if !show_hidden && startswith(f, '.')
                continue
            end
            push!(results, joinpath(r, f))
        end

        if depth < max_depth
            for d in dirs
                if !show_hidden && startswith(d, '.')
                    continue
                end
                push!(results, joinpath(r, d))
            end
        end
    end
    results
end

function format_bytes(bytes::Int)
    if bytes < 1024
        return "$bytes B"
    elseif bytes < 1024^2
        return "$(round(bytes / 1024, digits=1)) KB"
    elseif bytes < 1024^3
        return "$(round(bytes / 1024^2, digits=1)) MB"
    else
        return "$(round(bytes / 1024^3, digits=2)) GB"
    end
end

# ─── 5. add_task ──────────────────────────────────────────

function add_task_tool(args::Dict)
    title = get(args, "title", "")
    if isempty(title)
        return "Error: Task title is required"
    end

    description = get(args, "description", "")
    category = get(args, "category", "general")
    priority = parse_int_param(get(args, "priority", 2), 2)
    estimated_time = parse_int_param(get(args, "estimated_time", 30), 30)
    tags_str = get(args, "tags", "")

    tags = if isempty(tags_str)
        String[]
    else
        String[strip(t) for t in split(tags_str, ",") if !isempty(strip(t))]
    end

    due_date_str = get(args, "due_date", "")
    due_date = isempty(due_date_str) ? nothing : TaskManager.parse_date(due_date_str)

    try
        task = TaskManager.add_task(
            title,
            description = description,
            category = category,
            priority = priority,
            estimated_time = estimated_time,
            due_date = due_date,
            tags = tags,
        )
        return "✅ Task added: [$(task.id)] $(task.title) (Priority: $(task.priority), Category: $(task.category))"
    catch e
        return "Error adding task: $e"
    end
end

function parse_int_param(val, default::Int)
    if val isa Integer
        return Int(val)
    elseif val isa String
        p = tryparse(Int, val)
        return p === nothing ? default : p
    elseif val isa AbstractFloat
        return Int(round(val))
    else
        return default
    end
end

# ─── 6. list_tasks ────────────────────────────────────────

function list_tasks_tool(args::Dict)
    filter_str = get(args, "filter", "pending")
    category = get(args, "category", "")
    priority = get(args, "priority", 0)

    try
        tasks = if filter_str == "all"
            TaskManager.list_tasks()
        elseif filter_str == "completed"
            TaskManager.list_tasks(completed = true)
        elseif filter_str == "overdue"
            TaskManager.get_overdue_tasks()
        else
            TaskManager.get_pending_tasks()
        end

        if !isempty(category)
            tasks = filter(t -> t.category == category, tasks)
        end

        if priority isa Integer && priority > 0
            tasks = filter(t -> t.priority == priority, tasks)
        end

        if isempty(tasks)
            return "No tasks found matching your filters."
        end

        lines = ["📋 Tasks ($(length(tasks)) found):"]
        for t in tasks
            due = t.due_date !== nothing ? " (due: $(t.due_date))" : ""
            tags = !isempty(t.tags) ? " [$(join(t.tags, ", "))]" : ""
            status = t.completed ? "✅" : "⬜"
            push!(
                lines,
                "  $status [$(t.id)] $(t.title) — P:$(t.priority) $(t.category)$due$tags",
            )
        end

        return join(lines, "\n")
    catch e
        return "Error listing tasks: $e"
    end
end

# ─── 7. complete_task ─────────────────────────────────────

function complete_task_tool(args::Dict)
    task_id = parse_int_param(get(args, "task_id", 0), 0)

    if task_id <= 0
        return "Error: Valid numeric task_id is required"
    end

    try
        if TaskManager.complete_task(task_id)
            return "✅ Task $task_id marked as completed."
        else
            return "Error: Task $task_id not found."
        end
    catch e
        return "Error completing task: $e"
    end
end

# ─── 8. web_search ────────────────────────────────────────

function web_search(args::Dict)
    query = get(args, "query", "")
    if isempty(query)
        return "Error: query is required"
    end

    max_results = clamp(get(args, "max_results", 5), 1, 20)

    results = Search.search(query; max_results = max_results)
    if results === nothing
        throw(
            Errors.KamilaError(
                :external,
                "Web search unavailable (rate-limited or no results) for '$query'.",
                retryable = true,
                details = Dict("query" => query),
            ),
        )
    end

    lines = String[]
    for r in results
        title = get(r, :title, "")
        url = get(r, :url, "")
        snippet = get(r, :snippet, "")
        push!(lines, "• $title\n  $url\n  $snippet")
    end

    return "🌐 Web search results for '$query':\n\n$(join(lines, "\n\n"))"
end

# ─── 9. file_find ─────────────────────────────────────────

function file_find(args::Dict)
    pattern = get(args, "pattern", "")
    if isempty(pattern)
        return "Error: pattern is required"
    end

    search_path = get(args, "path", ".")
    max_results = clamp(get(args, "max_results", 50), 1, MAX_SEARCH_RESULTS)

    try
        validated_path = FileAccess.validate_path(search_path)
        if !isdir(validated_path)
            return "Error: Directory does not exist: $search_path"
        end

        results = String[]
        # Limit walk depth to avoid searching entire filesystem
        for (root, dirs, files) in walkdir(validated_path; topdown = true)
            # Limit to 5 levels deep
            rel = relpath(root, validated_path)
            depth = rel == "." ? 0 : length(splitpath(rel))
            depth > 5 && (dirs = []; continue)

            for f in files
                if occursin(pattern, f)
                    push!(results, joinpath(root, f))
                    length(results) >= max_results && break
                end
            end
            length(results) >= max_results && break
        end

        if isempty(results)
            return "No files matching '$pattern' found in '$search_path'."
        end

        return "🔍 Found $(length(results)) files matching '$pattern':\n$(join(results, "\n"))"
    catch e
        return _handle_tool_error(e, "finding files")
    end
end

# ─── 10. grep_search ──────────────────────────────────────

function grep_search(args::Dict)
    pattern = get(args, "pattern", "")
    if isempty(pattern)
        return "Error: pattern is required"
    end

    search_path = get(args, "path", ".")
    max_results = clamp(get(args, "max_results", 20), 1, 100)
    file_pattern = get(args, "include", "")

    try
        validated_path = FileAccess.validate_path(search_path)
        if !isdir(validated_path)
            return "Error: Directory does not exist: $search_path"
        end

        # Build grep command
        cmd_parts = ["grep", "-rnI", "--no-messages"]
        if !isempty(file_pattern)
            push!(cmd_parts, "--include=" * file_pattern)
        end
        push!(cmd_parts, "-m", "1")  # max 1 match per file
        push!(cmd_parts, "'$pattern'")
        push!(cmd_parts, "'$validated_path'")

        cmd = join(cmd_parts, " ") * " 2>/dev/null | head -$max_results"
        result = read(`bash -c $cmd`, String)

        result = strip(result)
        if isempty(result)
            return "No matches found for '$pattern' in '$search_path'."
        end

        return "📝 Grep results for '$pattern' in '$search_path':\n$result"
    catch e
        return _handle_tool_error(e, "searching file contents")
    end
end

# ─── 11. system_status ────────────────────────────────────

function system_status_tool(args::Dict)
    try
        stats = SystemMonitor.get_system_stats()
        if haskey(stats, "error")
            return "Error: $(stats["error"])"
        end

        health = get(stats, "is_healthy", Dict("score" => 0, "status" => "unknown"))
        health_issues = get(health, "issues", String[])
        alerts = SystemMonitor.get_system_alerts()

        lines = String[]
        push!(lines, "🖥️  System Status — $(stats["timestamp"])")
        push!(lines, "")
        push!(
            lines,
            "  OS: $(stats["os_info"]["os_name"]) $(stats["os_info"]["kernel_version"])",
        )
        push!(lines, "  Kernel: $(stats["os_info"]["arch"])")
        push!(lines, "  Uptime: $(stats["uptime"]["formatted"])")
        push!(lines, "")
        push!(lines, "⚡ Performance:")

        cpu_val = get(get(stats, "cpu", Dict()), "usage_percent", nothing)
        cpu_render = cpu_val === nothing ? "unavailable" : "$(cpu_val)% (measured)"
        push!(
            lines,
            "  CPU:    $cpu_render ($(get(get(stats, "cpu", Dict()), "threads", "?")) threads)",
        )
        push!(
            lines,
            "  Memory: $(stats["memory"]["used_percent"])% (measured) ($(stats["memory"]["free_gb"]) GB free / $(stats["memory"]["total_gb"]) GB total)",
        )

        if haskey(stats["disk"], "root")
            root = stats["disk"]["root"]
            push!(
                lines,
                "  Disk /: $(root["use_percent"]) ($(root["used"])/$(root["size"]))",
            )
        end
        push!(lines, "  Processes: $(stats["processes"]["running"]) running")
        push!(lines, "")
        push!(lines, "🏥 Health: $(health["score"])/100 ($(health["status"]))")

        if !isempty(alerts)
            push!(lines, "")
            push!(lines, "⚠️  Alerts:")
            for a in alerts
                push!(lines, "  $a")
            end
        end

        return join(lines, "\n")
    catch e
        return "Error getting system status: $e"
    end
end

# ─── 12. set_reminder ─────────────────────────────────────

function set_reminder(args::Dict)
    message = get(args, "message", "")
    if isempty(message)
        return "Error: message is required"
    end

    _authorize!("set_reminder", args)

    delay_minutes = parse_int_param(get(args, "delay_minutes", 0), 0)
    urgency = get(args, "urgency", "normal")  # normal, critical, low

    try
        if delay_minutes > 0
            # Schedule delayed notification
            cmd = "sleep $(delay_minutes * 60) && notify-send -u $urgency 'Kamila Reminder' $(shell_escape_simple(message))"
            spawn_cmd = `bash -c $cmd`
            @async run(spawn_cmd)
            return "✅ Reminder set: \"$message\" in $delay_minutes minutes. (urgency: $urgency)"
        else
            run(`notify-send -u $urgency "Kamila Reminder" "$message"`, wait = false)
            return "✅ Reminder sent: \"$message\""
        end
    catch e
        return "Error setting reminder: $e"
    end
end

function shell_escape_simple(s::String)
    "'" * replace(s, "'" => "'\\''") * "'"
end

# ─── 13. memory_query ─────────────────────────────────────

function memory_query(args::Dict)
    query_type = get(args, "query", "summary")

    try
        if query_type == "summary"
            stats = KamilaMemory.get_memory_stats()
            return """
📊 Memory Summary
  User: $(stats["user_alias"])
  Tasks: $(stats["total_tasks"]) total, $(stats["completed_tasks"]) completed
  Achievements: $(stats["total_achievements"])
  Active Goals: $(stats["active_goals"])
  Productivity: $(stats["productivity_percentage"])%
  Last Updated: $(stats["last_updated"])
"""
        elseif query_type == "achievements"
            memory = KamilaMemory.load_memory()
            achievements = get(memory, "achievements", Dict[])
            if isempty(achievements)
                return "🏆 No achievements yet. Start completing tasks to earn some!"
            end
            lines = ["🏆 Achievements ($(length(achievements)) total):"]
            for a in achievements
                push!(lines, "  • $(a["title"]) ($(a["date"]))")
            end
            return join(lines, "\n")

        elseif query_type == "goals"
            goals = KamilaMemory.get_active_goals()
            if isempty(goals)
                memory = KamilaMemory.load_memory()
                all_goals = get(memory, "goals", Dict[])
                completed = [g for g in all_goals if get(g, "completed", false)]
                if isempty(completed)
                    return "🎯 No goals found. Add a goal to start tracking!"
                else
                    return "🎯 All goals completed! Great job! 🎉"
                end
            end
            lines = ["🎯 Active Goals ($(length(goals))):"]
            for g in goals
                pct = get(g, "progress", 0)
                bar = repeat("▓", pct ÷ 10) * repeat("░", 10 - pct ÷ 10)
                push!(
                    lines,
                    "  [$bar] [$(g["id"])] $(g["goal"]) (P:$(g["priority"]), $(g["category"]))",
                )
            end
            return join(lines, "\n")

        elseif query_type == "productivity"
            stats = KamilaMemory.get_memory_stats()
            pct = stats["productivity_percentage"]
            rating =
                pct >= 80 ? "Excellent" :
                pct >= 60 ? "Good" : pct >= 40 ? "Fair" : "Needs Improvement"
            return """
📈 Productivity Report
  Score: $(pct)% ($rating)
  Total Activities: $(stats["total_activities"])
  Active Goals: $(stats["active_goals"])
  Tasks Completed: $(stats["completed_tasks"])/$(stats["total_tasks"])
"""

        elseif query_type == "search"
            query = get(args, "query", "")
            k = get(args, "k", 5)
            isempty(strip(query)) && return "Search query cannot be empty."
            results = KamilaMemory.recall(query; k = k)
            if isempty(results)
                return "No relevant memories found for: \"$query\""
            end
            lines = ["🔍 Search results for: \"$query\" ($(length(results)) matches):"]
            for (i, r) in enumerate(results)
                kind_icon =
                    r.kind == "chat" ? "💬" :
                    r.kind == "task" ? "📋" : r.kind == "goal" ? "🎯" : "📝"
                score_str = r.score >= 0.5 ? "HIGH" : r.score >= 0.3 ? "MED" : "LOW"
                push!(
                    lines,
                    "  $kind_icon [$i] ($(r.kind), $(score_str) $(round(r.score * 100))%) $(r.content[1:min(80, length(r.content))])",
                )
            end
            return join(lines, "\n")

        elseif query_type == "episodic"
            # Return recent episodic summaries (segments, days, weeks)
            rows = MemoryDB.query_all(
                "SELECT kind, period, period_start, period_end, content, created_at, importance FROM memories WHERE kind = 'episodic' ORDER BY created_at DESC LIMIT ?",
                (20,),
            )
            if isempty(rows)
                return "No episodic summaries found."
            end
            lines = ["📅 Episodic Summaries ($(length(rows))):"]
            for (i, r) in enumerate(rows)
                period_icon =
                    r.period == "segment" ? "📌" :
                    r.period == "day" ? "📅" : r.period == "week" ? "📆" : "📝"
                imp = round(r.importance * 100)
                date_str = r.period_start === nothing ? r.created_at : r.period_start
                push!(
                    lines,
                    "  $period_icon [$i] ($(r.period), importance: $(round(r.importance * 100))%) $(date_str): $(r.content[1:min(100, length(r.content))])",
                )
            end
            return join(lines, "\n")

        elseif query_type == "context"
            # Debug: show what would be injected for the current query
            debug_query = get(args, "query_text", "")
            debug = Context.build_context_debug(debug_query; session = Episodic.get_current_session(), mode = "chat")
            providers_str = join([
                "  - $(p.provider_name): $(hasproperty(p, :est_tokens) ? p.est_tokens : "error") tokens" 
                for p in debug["providers"]
            ], "\n")
            packed_str = join([
                "  - [P$(get(b, "priority", "?"))] $(get(b, "est_tokens", "?")) tok: $(get(b, "label", "")) — $(get(b, "text_preview", ""))" 
                for b in debug["packed"]
            ], "\n")
            return """
            🔍 Context Injection Debug
            Query: $(debug["query"])
            Session: $(debug["session"])
            Budget: $(debug["budget"]) tokens
            Used: $(debug["used_tokens"]) tokens
            Blocks: $(debug["blocks_count"])

            Providers queried:
            $(providers_str)

            Packed blocks:
            $(packed_str)
            """
        else
            return "Available queries: summary, achievements, goals, productivity, search, episodic, context"
        end
    catch e
        return "Error querying memory: $e"
    end
end

# ─── Tool Registry ────────────────────────────────────────

function get_filtered_tools(category::String = "all")
    all = get_all_tools()
    if category == "all"
        return all
    end
    filtered = Tool[]
    for tool in all
        if category == "plan" && tool.name in [
            "add_task",
            "list_tasks",
            "complete_task",
            "list_directory",
            "read_file",
            "system_status",
            "memory_query",
        ]
            push!(filtered, tool)
        elseif category == "test" && tool.name in [
            "run_shell_command",
            "read_file",
            "write_file",
            "grep_search",
            "file_find",
            "list_directory",
            "web_search",
        ]
            push!(filtered, tool)
        elseif category == "execute" && tool.name in [
            "run_shell_command",
            "read_file",
            "write_file",
            "list_directory",
            "system_status",
            "file_find",
        ]
            push!(filtered, tool)
        end
    end
    return filtered
end

function get_all_tools()
    return [
        Tool(
            "run_shell_command",
            "Execute a shell command on the Linux system. Use for running programs, checking system state, or automation tasks. Requires user confirmation unless the permission policy allows it. Prefer dedicated tools (list_directory, system_status, file_find) over shell whenever possible.",
            Dict(
                "command" => "The bash command to execute (required)",
                "description" => "Human-readable purpose of this command",
                "timeout_seconds" => "Timeout in seconds (default: 30)",
            ),
            run_shell_command,
        ),
        Tool(
            "list_directory",
            "List the contents of a directory with file sizes, dates, and types. Safer than run_shell_command for browsing files. Supports sorting and optional recursive listing.",
            Dict(
                "path" => "Directory path to list (default: current directory)",
                "show_hidden" => "Show hidden files (default: false)",
                "sort_by" => "Sort by: name, size, or date (default: name)",
                "max_depth" => "Recursion depth, 1 = current dir only (default: 1)",
            ),
            list_directory_tool,
        ),
        Tool(
            "read_file",
            "Read the content of a text file. Can read specific line ranges and cap by byte size. Cannot read binary files.",
            Dict(
                "file_path" => "Path to the file to read (required)",
                "start_line" => "Start reading from this line number (optional)",
                "end_line" => "Stop reading at this line number (optional)",
                "max_bytes" => "Maximum bytes to read (optional)",
            ),
            read_file,
        ),
        Tool(
            "write_file",
            "Write content to a file. Creates parent directories automatically. Can append to existing files or create a backup before overwriting. Only allowed in ~/Desktop, ~/Documents, ~/Downloads, ~/Pictures, ~/Trash, ~/Codes.",
            Dict(
                "file_path" => "Path to write to (required, must be in allowed directories)",
                "content" => "Content to write (required)",
                "append" => "Append instead of overwrite (default: false)",
                "create_backup" => "Backup existing file before writing (default: false)",
            ),
            write_file,
        ),
        Tool(
            "add_task",
            "Add a new task to the task manager. Tasks can be categorized, prioritized, tagged, and given due dates.",
            Dict(
                "title" => "Task title (required)",
                "description" => "Optional task description",
                "category" => "Task category (default: general)",
                "priority" => "Priority 1-4 where 4=highest (default: 2)",
                "estimated_time" => "Estimated time in minutes (default: 30)",
                "due_date" => "Due date in YYYY-MM-DD format (optional)",
                "tags" => "Comma-separated tags (optional, e.g. 'bug,urgent')",
            ),
            add_task_tool,
        ),
        Tool(
            "list_tasks",
            "List tasks from the task manager with optional filtering by status, category, or priority.",
            Dict(
                "filter" => "Filter: pending, completed, all, or overdue (default: pending)",
                "category" => "Filter by category (optional)",
                "priority" => "Filter by priority 1-4 (optional)",
            ),
            list_tasks_tool,
        ),
        Tool(
            "complete_task",
            "Mark a task as completed. This also records an achievement for the user.",
            Dict("task_id" => "The numeric ID of the task to complete (required)"),
            complete_task_tool,
        ),
        Tool(
            "web_search",
            "Search the web using DuckDuckGo. Returns titles, URLs, and snippets. Use for looking up documentation, troubleshooting errors, or finding information.",
            Dict(
                "query" => "The search query (required)",
                "max_results" => "Maximum number of results (default: 5, max: 20)",
            ),
            web_search,
        ),
        Tool(
            "file_find",
            "Find files by name pattern (substring match). Searches recursively within allowed directories. Faster than running 'find' through shell.",
            Dict(
                "pattern" => "Filename pattern to search for (required, case-sensitive substring)",
                "path" => "Directory to search in (default: current directory)",
                "max_results" => "Maximum results to return (default: 50, max: 200)",
            ),
            file_find,
        ),
        Tool(
            "grep_search",
            "Search for text patterns inside file contents using grep. Great for finding where a function is defined, searching logs, or locating config settings.",
            Dict(
                "pattern" => "Text pattern to search for (required, regex supported)",
                "path" => "Directory to search in (default: current directory)",
                "include" => "File pattern to restrict search (e.g. *.jl, *.py, *.md)",
                "max_results" => "Maximum results (default: 20, max: 100)",
            ),
            grep_search,
        ),
        Tool(
            "system_status",
            "Get a comprehensive snapshot of system health: CPU, memory, disk usage, process count, uptime, health score, and any active alerts. No parameters needed.",
            Dict("detail" => "Level of detail: basic or full (default: full)"),
            system_status_tool,
        ),
        Tool(
            "set_reminder",
            "Send a desktop notification immediately or schedule one for later. Uses Linux notify-send.",
            Dict(
                "message" => "Reminder message text (required)",
                "delay_minutes" => "Delay in minutes before showing (default: 0 = immediate)",
                "urgency" => "Urgency: low, normal, or critical (default: normal)",
            ),
            set_reminder,
        ),
        Tool(
            "memory_query",
            "Query Kamila's persistent memory for summary stats, achievements, goals, or productivity report. Memory stores tasks, achievements, goals, and usage statistics across sessions.",
            Dict(
                "query" => "What to query: summary (default), achievements, goals, or productivity",
            ),
            memory_query,
        ),
    ]
end

# ─── Tool Executor ────────────────────────────────────────

function _normalize_args(args)
    if args isa Dict
        return Dict{String,Any}(String(k) => v for (k, v) in args)
    end
    d = Dict{String,Any}()
    for k in keys(args)
        d[String(k)] = args[k]
    end
    return d
end

function _lookup_tool(normalized::String, tools)
    for tool in tools
        tool.name == normalized && return tool
    end
    return nothing
end

"""
Run `tool_name` with `args` and return the raw tool result. Throws on tool
failure so callers can categorize; `execute_tool`/`execute_tool_structured`
are the string-returning / structured-returning wrappers.
"""
function execute_tool_raw(tool_name::String, args)
    cmd_args = _normalize_args(args)
    normalized = normalize_tool_name(tool_name)

    KamilaLog.debug(
        "execute_tool";
        mod = "tools",
        fields = Dict(
            "tool" => normalized === nothing ? tool_name : normalized,
            "arg_count" => length(cmd_args),
        ),
    )

    if normalized === nothing
        suggestion = did_you_mean(tool_name)
        msg = "Tool '$tool_name' not found."
        suggestion !== nothing && (msg *= " Did you mean '$suggestion'?")
        msg *= " Available tools: $(join([t.name for t in get_all_tools()], ", "))"
        throw(Errors.KamilaError(:notfound, msg, details = Dict("tool" => tool_name)))
    end

    tools = get_all_tools()
    tool = _lookup_tool(normalized, tools)
    if tool === nothing
        throw(
            Errors.KamilaError(
                :notfound,
                "Tool '$tool_name' (normalized: '$normalized') not found. Available tools: $(join([t.name for t in tools], ", "))",
                details = Dict("tool" => tool_name),
            ),
        )
    end

    # Contract validation: required args per the tool schema before calling.
    missing = _missing_required_args(tool, cmd_args)
    if !isempty(missing)
        throw(
            Errors.KamilaError(
                :validation,
                "Tool '$normalized' is missing required argument(s): $(join(missing, ", ")).",
                details = Dict("tool" => normalized, "missing" => missing),
            ),
        )
    end

    result = tool.func(cmd_args)
    KamilaLog.debug(
        "tool completed";
        mod = "tools",
        fields = Dict("tool" => normalized, "result_chars" => length(result)),
    )
    return result
end

function execute_tool(tool_name::String, args)
    try
        return execute_tool_raw(tool_name, args)
    catch e
        return "Error executing tool '$tool_name': $(Errors.error_string(e))"
    end
end

"""
Like `execute_tool` but returns a structured Dict the bridge can consume:
  {"ok", "category", "message", "code", "retryable", "details", "result"}
```
"""
function execute_tool_structured(tool_name::String, args)
    try
        result = execute_tool_raw(tool_name, args)
        # Some tools still return error strings rather than throwing (e.g. the
        # task/desktop helpers). Detect and categorize those so callers (bridge,
        # agent retry) see the same structured shape for every failure mode.
        if result isa AbstractString
            cat = ModelRouter.error_category_of(result)
            if cat !== nothing
                return Dict{String,Any}(
                    "ok" => false,
                    "category" => Errors.category_name(cat),
                    "message" => result,
                    "code" => Errors.http_status(cat),
                    "retryable" => Errors.is_retryable(Errors.KamilaError(cat, result)),
                    "details" => Dict{String,Any}(),
                    "result" => result,
                )
            end
        end
        return Dict{String,Any}(
            "ok" => true,
            "category" => "success",
            "message" => "",
            "code" => 0,
            "retryable" => false,
            "details" => Dict{String,Any}(),
            "result" => result,
        )
    catch e
        payload = Errors.error_payload(e)
        payload["result"] = Errors.error_string(e)
        return payload
    end
end

function normalize_tool_name(name::String)
    lower = lowercase(strip(name))
    aliases = Dict(
        "list_files" => "list_directory",
        "ls" => "list_directory",
        "dir" => "list_directory",
        "search_web" => "web_search",
        "google" => "web_search",
        "find_file" => "file_find",
        "search_files" => "file_find",
        "grep" => "grep_search",
        "search_content" => "grep_search",
        "sysinfo" => "system_status",
        "sys_status" => "system_status",
        "system_info" => "system_status",
        "remind" => "set_reminder",
        "notify" => "set_reminder",
        "mem_query" => "memory_query",
        "memory" => "memory_query",
        "shell" => "run_shell_command",
        "bash" => "run_shell_command",
        "execute" => "run_shell_command",
    )
    # Known aliases map to their canonical name.
    canonical = get(aliases, lower, nothing)
    canonical !== nothing && return canonical
    # Exact canonical names pass through (case-insensitive).
    for t in get_all_tools()
        lowercase(t.name) == lower && return t.name
    end
    return nothing
end

"""
Required args are those whose schema description carries a "(required)" marker.
"""
function _missing_required_args(tool, args::Dict{String,Any})
    missing = String[]
    for (param, desc) in tool.parameters
        if occursin("required", lowercase(string(desc)))
            if !haskey(args, param) || isempty(string(get(args, param, "")))
                push!(missing, String(param))
            end
        end
    end
    return missing
end

"""
Simple suggestion for a mistyped tool name: the canonical tool name with the
highest character overlap, returned only if it is at least plausibly close.
"""
function did_you_mean(name::String)
    target = lowercase(strip(name))
    isempty(target) && return nothing
    best = nothing
    best_score = 0.0
    for t in get_all_tools()
        cand = lowercase(t.name)
        score = _similarity(target, cand)
        if score > best_score
            best = t.name
            best_score = score
        end
    end
    return best_score >= 0.5 ? best : nothing
end

function _similarity(a::String, b::String)
    isempty(a) && isempty(b) && return 1.0
    isempty(a) || isempty(b) && return 0.0
    # Jaccard of character sets is cheap and effective for short names.
    sa = Set(collect(a))
    sb = Set(collect(b))
    inter = length(intersect(sa, sb))
    union_len = length(union(sa, sb))
    return inter / union_len
end



end # module
