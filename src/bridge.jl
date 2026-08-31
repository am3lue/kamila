module KamilaBridge

using JSON
using Dates

using ..Kamila
using ..KamilaLog
using ..Errors
using ..OllamaInterface
using ..ModelRouter
using ..AgentStream
using ..Agent
using ..AgentTools
using ..SystemMonitor
using ..Events
using ..TaskManager
using ..KamilaMemory
using ..Episodic
using ..MemoryDB
using ..Context
using ..FileAccess
using ..OSCheck
using ..Desktop
using ..Auth
using ..CodeTracker
using ..TTS
using ..Confirm
using ..Permission
using ..Capability
using ..Experience
using ..Preferences
using ..STT
using ..DesktopContext
using ..Screenshot
using ..Orchestrator.Executive
import ..Plan
using ..Decompose
using ..Skills

export run_bridge

# ─── Protocol Helpers ─────────────────────────────────────

function write_json(data::Dict)
    println(JSON.json(data))
    flush(stdout)
end

"""
Forward daemon/event-bus events to the TUI as `notification` protocol events
(06.1). Only informational kinds are forwarded; the bridge merely observes.
"""
function _forward_daemon_event(e::AbstractDict)
    kind = string(get(e, "kind", ""))
    if kind in ("notification", "health.alert", "file.created", "file.updated")
        try
            write_json(
                Dict(
                    "type" => "notification",
                    "kind" => kind,
                    "title" => string(get(e, "title", "Kamila")),
                    "body" => string(get(e, "body", "")),
                    "source" => string(get(e, "source", "system")),
                ),
            )
        catch
        end
    end
    return nothing
end

function send_response(id::String, result)
    write_json(Dict("type" => "response", "id" => id, "result" => result))
end

function send_error(id::String, error_msg::String, code::Int = 400)
    # Derive a category from the numeric code when the caller didn't supply one.
    cat =
        code == 403 ? :permission :
        code == 404 ? :notfound :
        code == 401 ? :permission :
        code == 504 ? :timeout :
        code == 503 ? :network : code == 400 ? :validation : :internal
    payload = Dict{String,Any}(
        "type" => "error",
        "id" => id,
        "error" => error_msg,
        "code" => code,
        "category" => Errors.category_name(cat),
        "retryable" => Errors.is_retryable(Errors.KamilaError(cat, error_msg)),
    )
    write_json(payload)
end

function send_error(id::String, e::Errors.KamilaError)
    write_json(
        Dict{String,Any}(
            "type" => "error",
            "id" => id,
            "error" => e.message,
            "code" => e.code,
            "category" => Errors.category_name(e.category),
            "retryable" => e.retryable,
            "details" => e.details,
        ),
    )
end

function send_stream_chunk(id, chunk; kind::String = "content")
    write_json(
        Dict{String,Any}(
            "type" => "stream",
            "id" => string(id),
            "chunk" => string(chunk),
            "kind" => kind,
        ),
    )
end

function send_stream_end(id::String; model::String = "")
    payload = Dict{String,Any}("type" => "stream_end", "id" => id)
    if !isempty(model)
        payload["model"] = model
    end
    write_json(payload)
end

# ─── Chat History ────────────────────────────────────────
const MAX_CHAT_HISTORY = 20
const chat_messages = Dict{String,Vector{Dict{String,Any}}}()
const CHAT_HISTORY_FILE = Kamila.CHAT_HISTORY_FILE

function get_chat_history(session::String = "default")
    return get!(chat_messages, session, Vector{Dict{String,Any}}())
end

function save_chat_history_to_disk()
    try
        data = Dict{String,Any}()
        for (k, v) in chat_messages
            data[k] = v
        end
        # Persist to DB
        KamilaMemory.save_chat_history(chat_messages)
        # Compat JSON view
        write(CHAT_HISTORY_FILE, JSON.json(data))
    catch e
        # Non-critical — just log to stderr
        KamilaLog.warn("Failed to save chat history: $e"; mod = "bridge")
    end
end

function load_chat_history_from_disk()
    try
        # Load from DB (authoritative)
        sessions = KamilaMemory.load_chat_history()
        if sessions !== nothing
            empty!(chat_messages)
            for (k, v) in sessions
                chat_messages[k] = v
            end
        end
        # Compat JSON view (write current state)
        data = Dict{String,Any}()
        for (k, v) in chat_messages
            data[k] = v
        end
        write(CHAT_HISTORY_FILE, JSON.json(data))
    catch e
        KamilaLog.warn("Failed to load chat history: $e"; mod = "bridge")
    end
end

function reset_chat_history_internal(session::String = "default")
    chat_messages[session] = Vector{Dict{String,Any}}()
    save_chat_history_to_disk()
end

function reset_chat_history(id::String, params::AbstractDict)
    session = get(params, "session", "default")
    reset_chat_history_internal(session)
    send_response(id, Dict("success" => true))
end

function handle_chat_history(id::String, params::AbstractDict)
    session = get(params, "session", "default")
    history = get_chat_history(session)
    # Return a JSON-safe, role/content view for the TUI to hydrate.
    rows = [
        Dict(
            "role" => string(get(msg, "role", "user")),
            "content" => string(get(msg, "content", "")),
            "created_at" => string(get(msg, "created_at", get(msg, "time", ""))),
        ) for msg in history
    ]
    send_response(id, Dict("session" => session, "messages" => rows))
end

# ─── Mode System ─────────────────────────────────────────
const MODES = ["chat", "plan", "test", "execute"]
const ACTIVE_MODE = Ref{String}("chat")

function get_mode_prompt(mode::String)
    if mode == "plan"
        return Agent.get_planning_prompt()
    elseif mode == "test"
        return Agent.get_testing_prompt()
    elseif mode == "execute"
        return Agent.get_execution_prompt()
    else
        return Agent.get_chat_system_prompt()
    end
end

function handle_mode_get(id::String, params::AbstractDict)
    send_response(id, Dict("mode" => ACTIVE_MODE[]))
end

function handle_mode_set(id::String, params::AbstractDict)
    mode = get(params, "mode", "")
    if mode in MODES
        ACTIVE_MODE[] = mode
        reset_chat_history_internal()
        send_response(id, Dict("mode" => mode, "success" => true))
    else
        send_error(id, "Invalid mode. Available: $(join(MODES, ", "))", 400)
    end
end

# ─── System Handlers ──────────────────────────────────────

function handle_system_status(id::String, params::AbstractDict)
    stats = SystemMonitor.get_system_stats()
    if haskey(stats, "error")
        return send_error(id, stats["error"], 500)
    end
    send_response(
        id,
        Dict(
            "cpu" => Dict(
                "usage_percent" => get(stats, "cpu", Dict())["usage_percent"],
                "threads" => get(stats, "cpu", Dict())["threads"],
            ),
            "memory" => Dict(
                "used_percent" => round(
                    get(get(stats, "memory", Dict()), "used_percent", 0),
                    digits = 1,
                ),
                "used_gb" =>
                    round(get(get(stats, "memory", Dict()), "used_gb", 0), digits = 1),
                "free_gb" =>
                    round(get(get(stats, "memory", Dict()), "free_gb", 0), digits = 1),
                "total_gb" =>
                    round(get(get(stats, "memory", Dict()), "total_gb", 0), digits = 1),
            ),
            "disk" => get(stats, "disk", Dict()),
            "uptime" => get(stats, "uptime", Dict()),
            "health" => get(stats, "is_healthy", Dict()),
            "thermal" => get(stats, "thermal", []),
            "network" => get(stats, "network", []),
            "timestamp" => get(stats, "timestamp", ""),
        ),
    )
end

# ─── Task Handlers ────────────────────────────────────────

function handle_tasks_list(id::String, params::AbstractDict)
    try
        tasks = TaskManager.get_pending_tasks()
        result = [
            Dict(
                "id" => t.id,
                "title" => t.title,
                "category" => t.category,
                "priority" => t.priority,
                "estimated_time" => t.estimated_time,
                "due_date" => t.due_date !== nothing ? string(t.due_date) : "",
                "tags" => t.tags,
            ) for t in tasks
        ]
        send_response(id, result)
    catch e
        send_error(id, "Failed to list tasks: $e", 500)
    end
end

function handle_tasks_stats(id::String, params::AbstractDict)
    try
        stats = TaskManager.get_task_stats()
        send_response(id, stats)
    catch e
        send_error(id, "Failed to get task stats: $e", 500)
    end
end

function handle_tasks_add(id::String, params::AbstractDict)
    title = get(params, "title", "")
    if isempty(title)
        return send_error(id, "title is required", 400)
    end
    try
        task = TaskManager.add_task(
            title,
            description = get(params, "description", ""),
            category = get(params, "category", "general"),
            priority = get(params, "priority", 2),
            estimated_time = get(params, "estimated_time", 30),
            due_date = TaskManager.parse_date(get(params, "due_date", "")),
        )
        send_response(
            id,
            Dict(
                "id" => task.id,
                "title" => task.title,
                "category" => task.category,
                "priority" => task.priority,
            ),
        )
    catch e
        send_error(id, "Failed to add task: $e", 500)
    end
end

function handle_tasks_complete(id::String, params::AbstractDict)
    task_id = get(params, "task_id", 0)
    if task_id <= 0
        return send_error(id, "task_id is required", 400)
    end
    try
        result = TaskManager.complete_task(task_id)
        if result
            send_response(id, Dict("success" => true, "task_id" => task_id))
        else
            send_error(id, "Task $task_id not found", 404)
        end
    catch e
        send_error(id, "Failed to complete task: $e", 500)
    end
end

function handle_tasks_delete(id::String, params::AbstractDict)
    task_id = get(params, "task_id", 0)
    if task_id <= 0
        return send_error(id, "task_id is required", 400)
    end
    try
        TaskManager.delete_task(task_id)
        send_response(id, Dict("success" => true))
    catch e
        send_error(id, "Failed to delete task: $e", 500)
    end
end

# ─── AI Handlers ──────────────────────────────────────────

function handle_ai_status(id::String, params::AbstractDict)
    status = OllamaInterface.get_ai_status()
    send_response(id, status)
end

function handle_ai_models(id::String, params::AbstractDict)
    info = OllamaInterface.get_model_info()
    models = get(info, "models", [])
    result = [
        Dict(
            "name" => get(m, "name", ""),
            "size" => get(m, "size", 0),
            "parameter_size" => get(get(m, "details", Dict()), "parameter_size", ""),
            "capabilities" => get(m, "capabilities", []),
        ) for m in models
    ]
    send_response(id, result)
end

function handle_ai_query(id::String, params::AbstractDict)
    prompt = get(params, "prompt", "")
    audio_file = get(params, "audio_file", "")
    if isempty(prompt) && !isempty(audio_file)
        # Voice input: transcribe the clip and feed the transcript through the
        # normal prompt pipeline as a user message (08.2).
        try
            transcript = STT.transcribe(audio_file)
            prompt = string(get(transcript, "text", ""))
        catch e
            return send_error(id, "Audio transcription failed: $(Errors.error_string(e))", 500)
        end
    end
    if isempty(prompt)
        return send_error(id, "prompt is required", 400)
    end
    try
        temperature = get(params, "temperature", -1.0)
        max_tokens = get(params, "max_tokens", -1)
        task_type = Symbol(get(params, "task_type", "chat"))
        prefer_model = get(params, "model", "")

        mode = get(params, "mode", ACTIVE_MODE[])
        sys_prompt = get_mode_prompt(mode)

        # Get current session ID for session-scoped history
        session_id = Episodic.get_current_session()
        history = Episodic.get_session_history(session_id)

        KamilaLog.info(
            "ai query start";
            mod = "ai",
            kind = "request",
            fields = Dict(
                "task_type" => string(task_type),
                "mode" => mode,
                "history_len" => length(history),
                "prefer_model" => prefer_model,
            ),
        )

        # Inject query-aware memory context for chat mode
        if mode == "chat"
            context_str = Context.build_context(prompt; session = session_id, mode = mode)
            if !isempty(context_str)
                sys_prompt = sys_prompt * context_str
            end
        end

        # Build messages: system + history + user
        # history entries from the DB carry extra fields (e.g. Int "idx"),
        # so copy only role/content as Strings — appending Dict{String,Any}
        # into a Dict{String,String} vector would fail on convert(String, Int).
        messages = Dict{String,String}[Dict("role" => "system", "content" => sys_prompt)]
        for h in history
            push!(
                messages,
                Dict{String,String}(
                    "role" => string(get(h, "role", "")),
                    "content" => string(get(h, "content", "")),
                ),
            )
        end
        push!(messages, Dict("role" => "user", "content" => prompt))

        full_response = ""
        max_tool_loops = 5
        model_ref = Ref{String}("")

        for loop = 1:max_tool_loops
            channel = ModelRouter.query_router_chat_stream(
                messages,
                temperature = temperature,
                max_tokens = max_tokens,
                task_type = task_type,
                prefer_model = prefer_model,
                model_ref = model_ref,
            )

            KamilaLog.debug(
                "ai loop iteration";
                mod = "ai",
                kind = "request",
                fields = Dict("loop" => loop, "max_loops" => max_tool_loops, "model" => model_ref[]),
            )

            # Accumulate the content stream; relay thinking separately.
            raw_response::String = ""
            thinking_text::String = ""
            for item in channel
                if item.is_thinking
                    thinking_text *= item.text
                    KamilaLog.debug(
                        "ai token";
                        mod = "ai",
                        kind = "stream",
                        fields = Dict("phase" => "thinking", "chars" => length(item.text)),
                    )
                    send_stream_chunk(id, item.text; kind = "thinking")
                else
                    raw_response *= item.text
                    KamilaLog.debug(
                        "ai token";
                        mod = "ai",
                        kind = "stream",
                        fields = Dict("phase" => "content", "chars" => length(item.text)),
                    )
                end
            end

            # Check for tool call
            is_tool, tool_name, tool_args, thought = Agent.parse_response(raw_response)

            if is_tool
                # Reasoning ("thinking") is relayed to the TUI but is never part
                # of the final answer, history, or tool-call parsing.
                if !isempty(thought)
                    send_stream_chunk(id, thought)
                    full_response *= thought
                end

                # Emit tool_call event for TUI
                args_str = string(tool_args)
                args_len = length(args_str)
                args_log = args_len > 200 ? args_str[1:200] * "… (truncated)" : args_str
                KamilaLog.info(
                    "ai tool call";
                    mod = "ai",
                    kind = "tool",
                    fields = Dict("name" => tool_name, "args_len" => args_len, "args" => args_log),
                )
                write_json(
                    Dict(
                        "type" => "tool_call",
                        "id" => id,
                        "name" => tool_name,
                        "args" => tool_args,
                        "thought" => thought,
                    ),
                )

                # Execute tool
                tool_result = try
                    AgentTools.execute_tool(tool_name, tool_args)
                catch e
                    "Error: $e"
                end

                # Emit tool_result event for TUI
                KamilaLog.debug(
                    "ai tool result";
                    mod = "ai",
                    kind = "tool",
                    fields = Dict("name" => tool_name, "result_len" => length(tool_result)),
                )
                write_json(
                    Dict(
                        "type" => "tool_result",
                        "id" => id,
                        "name" => tool_name,
                        "result" => tool_result,
                    ),
                )

                # Add assistant response + tool result as context for next loop
                push!(messages, Dict("role" => "assistant", "content" => raw_response))
                push!(
                    messages,
                    Dict(
                        "role" => "user",
                        "content" => "Tool result: $(tool_result)\nContinue naturally.",
                    ),
                )
            else
                # Normal response — stream to TUI and finish
                send_stream_chunk(id, raw_response)
                full_response *= raw_response
                break
            end
        end

        send_stream_end(id; model = model_ref[])

        KamilaLog.info(
            "ai query complete";
            mod = "ai",
            kind = "response",
            fields = Dict("chars" => length(full_response), "model" => model_ref[]),
        )

        # Only mutate history on success
        session_id = Episodic.get_current_session()
        session_key = string(session_id)
        session_history = get_chat_history(session_key)
        push!(
            session_history,
            Dict("role" => "user", "content" => prompt, "session_id" => session_id),
        )
        push!(
            session_history,
            Dict(
                "role" => "assistant",
                "content" => full_response,
                "session_id" => session_id,
            ),
        )

        # Truncate history to last MAX_CHAT_HISTORY exchanges
        if length(session_history) > MAX_CHAT_HISTORY * 2
            session_history = session_history[(end-MAX_CHAT_HISTORY*2+1):end]
            chat_messages[session_key] = session_history
        end

        save_chat_history_to_disk()

        # Increment turn counter and check if segment summarization is needed
        Episodic.increment_turn()
        Episodic.maybe_summarize_session()
    catch e
        send_error(id, "AI query failed: $e", 500)
    end
end

function handle_ai_agent_query(id::String, params::AbstractDict)
    prompt = get(params, "prompt", "")
    if isempty(prompt)
        return send_error(id, "prompt is required", 400)
    end
    try
        system_prompt = get(params, "system", "")
        task_type = Symbol(get(params, "task_type", "chat"))
        model = get(params, "model", "")
        max_iterations = get(params, "max_iterations", 5)
        native = get(params, "native_tools", false)   # 05.1: prefer native tool_calls

        KamilaLog.info(
            "ai agent query start";
            mod = "ai",
            kind = "request",
            fields = Dict("task_type" => string(task_type), "max_iterations" => max_iterations, "native_tools" => native),
        )

        if native
            channel = AgentStream.run_agent_stream_native(
                prompt,
                system_prompt = system_prompt,
                task_type = task_type,
                model = model,
                max_iterations = max_iterations,
            )
        else
            channel = AgentStream.run_agent_stream(
                prompt,
                system_prompt = system_prompt,
                task_type = task_type,
                model = model,
                max_iterations = max_iterations,
            )
        end

        for event in channel
            if event isa AgentStream.TokenEvent
                KamilaLog.debug("ai agent token"; mod = "ai", kind = "stream", fields = Dict("chars" => length(event.token)))
                send_stream_chunk(id, event.token)
            elseif event isa AgentStream.ToolCallEvent
                args_str = string(event.args)
                args_len = length(args_str)
                args_log = args_len > 200 ? args_str[1:200] * "… (truncated)" : args_str
                KamilaLog.info("ai agent tool call"; mod = "ai", kind = "tool", fields = Dict("name" => event.name, "args_len" => args_len, "args" => args_log))
                write_json(
                    Dict(
                        "type" => "tool_call",
                        "id" => id,
                        "name" => event.name,
                        "args" => event.args,
                        "thought" => event.thought,
                    ),
                )
            elseif event isa AgentStream.ToolResultEvent
                write_json(
                    Dict(
                        "type" => "tool_result",
                        "id" => id,
                        "name" => event.name,
                        "result" => event.result,
                    ),
                )
            elseif event isa AgentStream.ErrorEvent
                write_json(
                    Dict(
                        "type" => "error",
                        "id" => id,
                        "error" => event.message,
                        "code" => 500,
                    ),
                )
                break
            elseif event isa AgentStream.DoneEvent
                break
            end
        end
        send_stream_end(id)
    catch e
        send_error(id, "Agent query failed: $e", 500)
    end
end

function handle_ai_test_connection(id::String, params::AbstractDict)
    result = OllamaInterface.test_ollama_connection()
    send_response(id, Dict("connected" => result))
end

function handle_ai_setup_model(id::String, params::AbstractDict)
    result = OllamaInterface.setup_kamila_model()
    send_response(id, result)
end

function handle_ai_explain_file(id::String, params::AbstractDict)
    file_path = get(params, "path", "")
    content = get(params, "content", "")
    if isempty(file_path) || isempty(content)
        return send_error(id, "path and content are required", 400)
    end
    try
        explanation = OllamaInterface.explain_file_with_ai(file_path, content)
        send_response(id, Dict("explanation" => explanation))
    catch e
        send_error(id, "Failed to explain file: $e", 500)
    end
end

# ─── Memory Handlers ──────────────────────────────────────

function handle_memory_stats(id::String, params::AbstractDict)
    try
        stats = KamilaMemory.get_memory_stats()
        achievements = KamilaMemory.get_today_achievements()
        goals = KamilaMemory.get_active_goals()
        send_response(
            id,
            Dict(
                "stats" => stats,
                "todays_achievements" => length(achievements),
                "goals" => [
                    Dict(
                        "id" => g["id"],
                        "goal" => g["goal"],
                        "category" => g["category"],
                        "priority" => g["priority"],
                        "progress" => get(g, "progress", 0),
                        "plan_id" => get(g, "plan_id", nothing),
                    ) for g in goals
                ],
            ),
        )
    catch e
        send_error(id, "Failed to get memory stats: $e", 500)
    end
end

function handle_memory_add_goal(id::String, params::AbstractDict)
    goal = get(params, "goal", "")
    if isempty(goal)
        return send_error(id, "goal is required", 400)
    end
    try
        category = get(params, "category", "general")
        priority = get(params, "priority", 1)
        result = KamilaMemory.add_goal(goal, category, priority)
        if result
            send_response(id, Dict("success" => true))
        else
            send_error(id, "Failed to add goal", 500)
        end
    catch e
        send_error(id, "Failed to add goal: $e", 500)
    end
end

function handle_memory_complete_goal(id::String, params::AbstractDict)
    goal_id = get(params, "goal_id", 0)
    if goal_id <= 0
        return send_error(id, "goal_id is required", 400)
    end
    try
        result = KamilaMemory.complete_goal(goal_id)
        send_response(id, Dict("success" => result))
    catch e
        send_error(id, "Failed to complete goal: $e", 500)
    end
end

function handle_memory_goals(id::String, params::AbstractDict)
    try
        goals = KamilaMemory.get_active_goals()
        result = [
            Dict(
                "id" => g["id"],
                "goal" => g["goal"],
                "category" => g["category"],
                "priority" => g["priority"],
                "status" => get(g, "status", "active"),
                "progress" => get(g, "progress", 0),
                "plan_id" => get(g, "plan_id", nothing),
            ) for g in goals
        ]
        send_response(id, result)
    catch e
        send_error(id, "Failed to list goals: $e", 500)
    end
end

# ─── Goal Engine Handlers (06.2) ──────────────────────────

function handle_goal_decompose(id::String, params::AbstractDict)
    goal_id = get(params, "goal_id", 0)
    if goal_id <= 0
        return send_error(id, "goal_id is required", 400)
    end
    try
        plan_id = KamilaMemory.decompose_goal(goal_id)
        plan_id === nothing && return send_error(id, "Goal not found", 404)
        send_response(id, Dict("success" => true, "plan_id" => plan_id))
    catch e
        send_error(id, "Failed to decompose goal: $e", 500)
    end
end

function handle_goal_link_plan(id::String, params::AbstractDict)
    goal_id = get(params, "goal_id", 0)
    plan_id = get(params, "plan_id", "")
    if goal_id <= 0 || isempty(plan_id)
        return send_error(id, "goal_id and plan_id are required", 400)
    end
    try
        ok = KamilaMemory.link_goal_plan(goal_id, plan_id)
        ok || return send_error(id, "Plan not found", 404)
        send_response(id, Dict("success" => true))
    catch e
        send_error(id, "Failed to link plan: $e", 500)
    end
end

function handle_goal_progress(id::String, params::AbstractDict)
    goal_id = get(params, "goal_id", 0)
    if goal_id <= 0
        return send_error(id, "goal_id is required", 400)
    end
    try
        progress = KamilaMemory.goal_progress(goal_id)
        progress === nothing && return send_error(id, "Goal not found or no linked plan", 404)
        send_response(id, Dict("goal_id" => goal_id, "progress" => progress))
    catch e
        send_error(id, "Failed to compute goal progress: $e", 500)
    end
end

# ─── Orchestrator Handlers (06.3) ─────────────────────────

function handle_orchestrator_status(id::String, _params)
    try
        send_response(id, Executive.status())
    catch e
        send_error(id, "Failed to get orchestrator status: $e", 500)
    end
end

function handle_orchestrator_advance_now(id::String, params::AbstractDict)
    try
        plan_id = get(params, "plan_id", nothing)
        plan_id === nothing && return send_error(id, "plan_id is required", 400)
        result = Executive.advance_now(; plan_id = String(plan_id))
        send_response(id, result)
    catch e
        send_error(id, "Failed to advance work: $e", 500)
    end
end

function handle_orchestrator_toggle_auto(id::String, params::AbstractDict)
    try
        on = Bool(get(params, "auto_execute", false))
        Executive.set_auto_execute(on)
        send_response(id, Dict("auto_execute" => Executive.auto_execute()))
    catch e
        send_error(id, "Failed to toggle auto-execute: $e", 500)
    end
end

function handle_orchestrator_pause(id::String, _params)
    try
        Executive.pause()
        send_response(id, Dict("paused" => true))
    catch e
        send_error(id, "Failed to pause orchestrator: $e", 500)
    end
end

# ─── Experience Handlers (07.1) ───────────────────────────

function handle_experience_reuse(id::String, params::AbstractDict)
    try
        description = get(params, "description", "")
        if isempty(description)
            return send_error(id, "description is required", 400)
        end
        k = clamp(Int(get(params, "k", 1)), 1, 10)
        results = Experience.similar_solution(description; k = k)
        send_response(id, Dict("results" => results, "count" => length(results)))
    catch e
        send_error(id, "Failed to search experience: $e", 500)
    end
end

function handle_experience_search(id::String, params::AbstractDict)
    try
        query = get(params, "query", "")
        if isempty(query)
            return send_error(id, "query is required", 400)
        end
        k = clamp(Int(get(params, "k", 10)), 1, 50)
        verified = get(params, "verified", true) === nothing ? nothing :
                   Bool(get(params, "verified", true))
        results = Experience.search(query; k = k, verified = verified)
        send_response(id, Dict("results" => results, "count" => length(results)))
    catch e
        send_error(id, "Failed to search experience: $e", 500)
    end
end

function handle_experience_export(id::String, params::AbstractDict)
    try
        path = get(params, "path", "")
        if isempty(path)
            return send_error(id, "path is required", 400)
        end
        n = Experience.export_rows(path)
        send_response(id, Dict("path" => path, "rows" => n))
    catch e
        send_error(id, "Failed to export experience: $e", 500)
    end
end

# ─── Preference Handlers (07.3) ───────────────────────────

function handle_feedback_record(id::String, params::AbstractDict)
    try
        key = string(get(params, "key", ""))
        value = string(get(params, "value", ""))
        if isempty(key) || isempty(value)
            return send_error(id, "key and value are required", 400)
        end
        explicit = Bool(get(params, "explicit", true))
        session = string(get(params, "session", ""))
        committed, current = Preferences.record_signal(
            key,
            value;
            explicit = explicit,
            session = session,
        )
        send_response(
            id,
            Dict("committed" => committed, "value" => current, "key" => key),
        )
    catch e
        send_error(id, "Failed to record feedback: $e", 500)
    end
end

function handle_preferences_get(id::String, params::AbstractDict)
    try
        all = Preferences.all_preferences()
        active = Preferences.active_preferences()
        send_response(id, Dict("preferences" => all, "active" => active))
    catch e
        send_error(id, "Failed to read preferences: $e", 500)
    end
end

function handle_preferences_revert(id::String, params::AbstractDict)
    try
        key = string(get(params, "key", ""))
        if isempty(key)
            return send_error(id, "key is required", 400)
        end
        restored = Preferences.revert_preference(key)
        send_response(id, Dict("key" => key, "restored" => restored))
    catch e
        send_error(id, "Failed to revert preference: $e", 500)
    end
end

function handle_preferences_history(id::String, params::AbstractDict)
    try
        key = string(get(params, "key", ""))
        limit = clamp(Int(get(params, "limit", 30)), 1, 200)
        rows = isempty(key) ? Preferences.preference_history_all(limit = limit) :
               Preferences.preference_history(key; limit = limit)
        send_response(id, Dict("events" => rows))
    catch e
        send_error(id, "Failed to read preference history: $e", 500)
    end
end

# ─── File Handlers ────────────────────────────────────────

function handle_file_list(id::String, params::AbstractDict)
    path = get(params, "path", ".")
    try
        files = FileAccess.safe_list_directory(path)
        entries = [
            Dict(
                "name" => basename(f),
                "path" => f,
                "is_dir" => isdir(f),
                "size" => isfile(f) ? stat(f).size : 0,
                "modified" => string(stat(f).mtime),
            ) for f in files
        ]
        send_response(id, entries)
    catch e
        send_error(id, "Failed to list directory: $e", 403)
    end
end

# ─── Model Handlers ───────────────────────────────────────

function handle_model_list(id::String, params::AbstractDict)
    try
        configured = ModelRouter.get_router_config()
        discovered = ModelRouter.discover_models()
        active = ModelRouter.get_active_model()
        send_response(
            id,
            Dict(
                "active" => active,
                "configured" => [ModelRouter.modelconfig_to_dict(c) for c in configured],
                "available" => discovered,
                "task_types" => [string(t) for t in ModelRouter.MODEL_TYPES],
            ),
        )
    catch e
        send_error(id, "Failed to list models: $e", 500)
    end
end

function handle_model_select(id::String, params::AbstractDict)
    name = get(params, "name", "")
    if isempty(name)
        return send_error(id, "name is required", 400)
    end
    try
        if !ModelRouter.validate_model(name)
            return send_error(id, "Model '$name' not found on Ollama.", 404)
        end
        ModelRouter.set_active_model(name)
        send_response(id, Dict("active" => name))
    catch e
        send_error(id, "Failed to select model: $e", 500)
    end
end

function handle_model_configure(id::String, params::AbstractDict)
    action = get(params, "action", "")
    if action == "set"
        models_data = get(params, "models", [])
        models = [ModelRouter.modelconfig_from_dict(m) for m in models_data]
        ModelRouter.save_router_config(models)
        send_response(id, Dict("success" => true, "count" => length(models)))
    elseif action == "discover"
        models = ModelRouter.discover_models()
        send_response(id, Dict("available" => models))
    elseif action == "reset"
        ModelRouter.save_router_config(deepcopy(ModelRouter.DEFAULT_MODELS))
        send_response(id, Dict("success" => true))
    else
        send_error(id, "Unknown action: $action", 400)
    end
end

# ─── Desktop Handlers ─────────────────────────────────────

function handle_desktop_stats(id::String, params::AbstractDict)
    try
        stats = Desktop.get_desktop_stats()
        send_response(id, stats)
    catch e
        send_error(id, "Failed to get desktop stats: $e", 500)
    end
end

function handle_desktop_organize(id::String, params::AbstractDict)
    try
        create_folders = get(params, "create_folders", true)
        move_files = get(params, "move_files", false)
        result = Desktop.organize_desktop(
            create_folders = create_folders,
            move_files = move_files,
        )
        send_response(id, result)
    catch e
        send_error(id, "Failed to organize desktop: $e", 500)
    end
end

function handle_desktop_clean(id::String, params::AbstractDict)
    try
        days_old = get(params, "days_old", 30)
        result = Desktop.clean_desktop(days_old = days_old)
        send_response(id, result)
    catch e
        send_error(id, "Failed to clean desktop: $e", 500)
    end
end

function handle_desktop_suggest(id::String, params::AbstractDict)
    try
        suggestions = Desktop.suggest_desktop_organization()
        send_response(id, Dict("suggestions" => suggestions))
    catch e
        send_error(id, "Failed to get suggestions: $e", 500)
    end
end

function handle_desktop_health(id::String, params::AbstractDict)
    try
        report = Desktop.generate_desktop_health_report()
        send_response(id, Dict("report" => report))
    catch e
        send_error(id, "Failed to get desktop health: $e", 500)
    end
end

# ─── Auth Handlers ────────────────────────────────────────

# ─── Permission ───────────────────────────────────────────

function handle_permission_get(id::String, params::AbstractDict)
    policy = Permission.get_policy()
    send_response(
        id,
        Dict(
            "policy" => policy,
            "capabilities" => Dict{String,Any}(
                "tool_map" => Capability.TOOL_CAPABILITY,
                "granted" => [
                    cap for cap in union(
                        get(policy, "default_capabilities", Any[]),
                        [
                            string(rule["tool"])[5:end]
                            for rule in get(policy, "rules", Any[])
                            if startswith(string(get(rule, "tool", "")), "cap:") &&
                               string(get(rule, "action", "")) == "allow"
                        ],
                    )
                ],
            ),
        ),
    )
end

function handle_permission_set(id::String, params::AbstractDict)
    policy = get(params, "policy", Dict())
    if !(policy isa AbstractDict)
        return send_error(id, "policy must be an object", 400)
    end
    if !haskey(policy, "rules") || !haskey(policy, "default_action")
        return send_error(id, "policy requires 'rules' and 'default_action'", 400)
    end
    try
        Permission.set_policy(policy)
        send_response(id, Dict("success" => true, "policy" => Permission.get_policy()))
    catch e
        send_error(id, "Failed to save policy: $e", 500)
    end
end

function handle_permission_reset(id::String, params::AbstractDict)
    try
        Permission.reset_policy()
        send_response(id, Dict("success" => true, "policy" => Permission.get_policy()))
    catch e
        send_error(id, "Failed to reset policy: $e", 500)
    end
end

function handle_permission_decisions(id::String, params::AbstractDict)
    limit = get(params, "limit", 50)
    send_response(id, Dict("decisions" => Permission.recent_decisions(limit)))
end

function handle_capability_audit(id::String, params::AbstractDict)
    limit = get(params, "limit", 50)
    kind = string(get(params, "kind", ""))
    send_response(
        id,
        Dict("checks" => Capability.capability_audit(limit; kind = kind)),
    )
end

function handle_auth_status(id::String, params::AbstractDict)
    try
        status = Auth.get_auth_status()
        send_response(id, status)
    catch e
        send_error(id, "Failed to get auth status: $e", 500)
    end
end

function handle_auth_setup(id::String, params::AbstractDict)
    password = get(params, "password", "")
    if isempty(password)
        return send_error(id, "password is required", 400)
    end
    try
        result = Auth.set_password(password)
        send_response(id, Dict("success" => result))
    catch e
        send_error(id, "Failed to setup password: $e", 500)
    end
end

function handle_auth_change_password(id::String, params::AbstractDict)
    current = get(params, "current", "")
    new = get(params, "new", "")
    if isempty(current) || isempty(new)
        return send_error(id, "current and new passwords are required", 400)
    end
    try
        result = Auth.change_password_to(current, new)
        if result
            send_response(id, Dict("success" => true))
        else
            send_error(id, "Current password is incorrect", 401)
        end
    catch e
        send_error(id, "Failed to change password: $e", 500)
    end
end

function handle_auth_reset(id::String, params::AbstractDict)
    try
        result = Auth.reset_auth()
        send_response(id, Dict("success" => result))
    catch e
        send_error(id, "Failed to reset auth: $e", 500)
    end
end

function handle_auth_verify(id::String, params::AbstractDict)
    password = get(params, "password", "")
    if isempty(password)
        return send_error(id, "password is required", 400)
    end
    try
        result = Auth.verify_password(password)
        send_response(id, Dict("valid" => result))
    catch e
        send_error(id, "Failed to verify password: $e", 500)
    end
end

# ─── Code Tracker Handlers ────────────────────────────────

function handle_code_tracker_status(id::String, params::AbstractDict)
    path = get(params, "path", pwd())
    try
        found, data = CodeTracker.get_tracker_info(path)
        send_response(id, Dict("tracking" => found, "data" => data))
    catch e
        send_error(id, "Failed to get tracker status: $e", 500)
    end
end

function handle_code_tracker_init(id::String, params::AbstractDict)
    path = get(params, "path", pwd())
    try
        success, message = CodeTracker.track_directory(path)
        if success
            send_response(id, Dict("success" => true, "message" => message))
        else
            send_error(id, message, 400)
        end
    catch e
        send_error(id, "Failed to init tracking: $e", 500)
    end
end

function handle_code_tracker_scan(id::String, params::AbstractDict)
    path = get(params, "path", pwd())
    try
        success, message, changes = CodeTracker.check_status(path)
        if success
            send_response(
                id,
                Dict("success" => true, "message" => message, "changes" => changes),
            )
        else
            send_error(id, message, 400)
        end
    catch e
        send_error(id, "Failed to scan: $e", 500)
    end
end

# ─── TTS Handlers ─────────────────────────────────────────

function handle_tts_speak(id::String, params::AbstractDict)
    text = get(params, "text", "")
    if isempty(text)
        return send_error(id, "text is required", 400)
    end
    try
        TTS.speak(text)
        send_response(id, Dict("success" => true))
    catch e
        send_error(id, "Failed to speak: $e", 500)
    end
end

# ─── Audio (STT) Handlers (08.2) ─────────────────────────

function handle_audio_transcribe(id::String, params::AbstractDict)
    file_path = get(params, "file_path", "")
    if isempty(file_path)
        return send_error(id, "file_path is required", 400)
    end
    try
        result = STT.transcribe(file_path)
        send_response(id, result)
    catch e
        send_error(id, "Transcription failed: $(Errors.error_string(e))", 500)
    end
end

function handle_audio_record(id::String, params::AbstractDict)
    seconds = Int(get(params, "seconds", 5))
    recorder = get(params, "recorder", nothing)
    try
        result = STT.record_clip(seconds; recorder = recorder)
        send_response(id, result)
    catch e
        send_error(id, "Recording failed: $(Errors.error_string(e))", 500)
    end
end

# ─── Desktop Context Handlers (08.3) ────────────────────

function handle_desktop_status(id::String, params::AbstractDict)
    try
        send_response(id, DesktopContext.desktop_status())
    catch e
        send_error(id, "Failed to get desktop context: $(Errors.error_string(e))", 500)
    end
end

function handle_desktop_screenshot(id::String, params::AbstractDict)
    try
        desc = Screenshot.screenshot_description()
        send_response(id, Dict("description" => desc))
    catch e
        send_error(id, "Screenshot failed: $(Errors.error_string(e))", 500)
    end
end

function handle_desktop_watch(id::String, params::AbstractDict)
    enable = get(params, "enable", false) == true || get(params, "enable", false) == "true"
    DesktopContext.set_watch_enabled!(enable)
    # Proactive watcher emits a desktop.activity event when enabled; the daemon
    # (06.1) polls and publishes hints from it.
    Events.publish(
        Dict(
            "kind" => "desktop.activity",
            "status" => DesktopContext.desktop_status(),
            "enabled" => enable,
            "source" => "bridge",
        ),
    )
    send_response(id, Dict("watch_enabled" => DesktopContext.watch_enabled()))
end

# ─── System Info Handlers ─────────────────────────────────

function handle_system_info(id::String, params::AbstractDict)
    try
        info = OSCheck.get_system_info()
        send_response(id, info)
    catch e
        send_error(id, "Failed to get system info: $e", 500)
    end
end

# ─── System Latency Handler ───────────────────────────────

function handle_system_latency(id::String, params::AbstractDict)
    try
        t1 = @task OllamaInterface.get_ollama_latency()
        t2 = @task SystemMonitor.get_internet_latency()
        schedule(t1)
        schedule(t2)
        ollama_ms = fetch(t1)
        internet_ms = fetch(t2)
        send_response(id, Dict("ollama_ms" => ollama_ms, "internet_ms" => internet_ms))
    catch e
        send_error(id, "Failed to measure latency: $e", 500)
    end
end

# ─── Plan routes ──────────────────────────────────────────

function handle_plan_create(id::String, params::AbstractDict)
    try
        goal = get(params, "goal", "")
        steps_raw = get(params, "steps", [])
        session = get(params, "session", "default")

        steps = [
            (
                description = get(s, "description", ""),
                depends_on = Int[Int(d) for d in get(s, "depends_on", Int[])],
                tool = get(s, "tool", ""),
                args = Dict{String,Any}(get(s, "args", Dict())),
            ) for s in steps_raw
        ]
        p = Plan.create(goal, steps; session = session)
        send_response(id, Plan._summarize(p))
    catch e
        send_error(id, "Failed to create plan: $(Errors.error_string(e))", 400)
    end
end

function handle_plan_decompose(id::String, params::AbstractDict)
    try
        goal = get(params, "goal", "")
        isempty(goal) && return send_error(id, "goal is required", 400)
        session = get(params, "session", "default")
        max_steps = Int(get(params, "max_steps", 20))
        plan = Decompose.decompose_to_plan(goal; session = session, max_steps = max_steps)
        send_response(id, Plan._summarize(plan))
    catch e
        send_error(id, "Failed to decompose goal: $(Errors.error_string(e))", 500)
    end
end

# ─── skills.* routes (05.2) ───────────────────────────────

function handle_skills_list(id::String, _params)
    try
        send_response(id, Dict("skills" => Skills.list()))
    catch e
        send_error(id, "Failed to list skills: $e", 500)
    end
end

function handle_skills_show(id::String, params::AbstractDict)
    try
        name = get(params, "name", "")
        isempty(name) && return send_error(id, "name is required", 400)
        send_response(id, Skills.show_skill(name))
    catch e
        send_error(id, "Failed to show skill: $(Errors.error_string(e))", 500)
    end
end

function handle_skills_enable(id::String, params::AbstractDict)
    try
        name = get(params, "name", "")
        isempty(name) && return send_error(id, "name is required", 400)
        Skills.enable!(name)
        send_response(id, Dict("name" => name, "enabled" => true))
    catch e
        send_error(id, "Failed to enable skill: $(Errors.error_string(e))", 500)
    end
end

function handle_skills_disable(id::String, params::AbstractDict)
    try
        name = get(params, "name", "")
        isempty(name) && return send_error(id, "name is required", 400)
        Skills.disable!(name)
        send_response(id, Dict("name" => name, "enabled" => false))
    catch e
        send_error(id, "Failed to disable skill: $(Errors.error_string(e))", 500)
    end
end

function handle_skills_install(id::String, params::AbstractDict)
    try
        spec = get(params, "spec", Dict())
        spec isa AbstractDict || return send_error(id, "spec must be an object", 400)
        source = get(params, "source", "user")
        enabled = get(params, "enabled", true)
        skill = Skills.install!(spec; source = string(source), enabled = Bool(enabled))
        send_response(id, Dict("name" => skill.name, "enabled" => skill.enabled, "source" => skill.source))
    catch e
        send_error(id, "Failed to install skill: $(Errors.error_string(e))", 500)
    end
end

function handle_skills_uninstall(id::String, params::AbstractDict)
    try
        name = get(params, "name", "")
        isempty(name) && return send_error(id, "name is required", 400)
        Skills.uninstall!(name)
        send_response(id, Dict("name" => name, "removed" => true))
    catch e
        send_error(id, "Failed to uninstall skill: $(Errors.error_string(e))", 500)
    end
end

function handle_plan_list(id::String, params::AbstractDict)
    try
        status = get(params, "status", nothing)
        status === nothing || status == "" || (status = Symbol(status))
        plans = Plan.list(; status = status)
        send_response(id, plans)
    catch e
        send_error(id, "Failed to list plans: $e", 500)
    end
end

function handle_plan_status(id::String, params::AbstractDict)
    try
        plan_id = get(params, "id", "")
        isempty(plan_id) && return send_error(id, "id is required", 400)
        p = Plan.load(plan_id)
        p === nothing && return send_error(id, "plan not found", 404)
        send_response(
            id,
            Dict(
                "id" => p.id,
                "goal" => p.goal,
                "status" => string(p.status),
                "steps" => [
                    Dict(
                        "id" => s.id,
                        "description" => s.description,
                        "status" => string(s.status),
                        "depends_on" => s.depends_on,
                        "tool" => s.tool,
                        "attempts" => s.attempts,
                        "result" => s.result,
                    ) for s in p.steps
                ],
            ),
        )
    catch e
        send_error(id, "Failed to get plan status: $e", 500)
    end
end

function handle_plan_cancel(id::String, params::AbstractDict)
    try
        plan_id = get(params, "id", "")
        isempty(plan_id) && return send_error(id, "id is required", 400)
        p = Plan.load(plan_id)
        p === nothing && return send_error(id, "plan not found", 404)
        Plan.cancel(p)
        send_response(id, Dict("id" => p.id, "status" => string(p.status)))
    catch e
        send_error(id, "Failed to cancel plan: $e", 500)
    end
end

function handle_plan_resume(id::String, params::AbstractDict)
    try
        plan_id = get(params, "id", "")
        isempty(plan_id) && return send_error(id, "id is required", 400)
        p = Plan.load(plan_id)
        p === nothing && return send_error(id, "plan not found", 404)
        Plan.resume(p)
        send_response(id, Dict("id" => p.id, "status" => string(p.status)))
    catch e
        send_error(id, "Failed to resume plan: $e", 500)
    end
end

# ─── Router ───────────────────────────────────────────────

const ROUTES = Dict(
    "system.status" => handle_system_status,
    "system.info" => handle_system_info,
    "system.latency" => handle_system_latency,
    "tasks.list" => handle_tasks_list,
    "tasks.stats" => handle_tasks_stats,
    "tasks.add" => handle_tasks_add,
    "tasks.complete" => handle_tasks_complete,
    "tasks.delete" => handle_tasks_delete,
    "ai.status" => handle_ai_status,
    "ai.models" => handle_ai_models,
    "ai.query" => handle_ai_query,
    "chat.reset" => reset_chat_history,
    "chat.history" => handle_chat_history,
    "mode.get" => handle_mode_get,
    "mode.set" => handle_mode_set,
    "ai.agent_query" => handle_ai_agent_query,
    "ai.test_connection" => handle_ai_test_connection,
    "ai.setup_model" => handle_ai_setup_model,
    "ai.explain_file" => handle_ai_explain_file,
    "memory.stats" => handle_memory_stats,
    "memory.add_goal" => handle_memory_add_goal,
    "memory.complete_goal" => handle_memory_complete_goal,
    "memory.goals" => handle_memory_goals,
    "goal.decompose" => handle_goal_decompose,
    "goal.link_plan" => handle_goal_link_plan,
    "goal.progress" => handle_goal_progress,
    "orchestrator.status" => handle_orchestrator_status,
    "orchestrator.advance_now" => handle_orchestrator_advance_now,
    "orchestrator.toggle_auto" => handle_orchestrator_toggle_auto,
    "orchestrator.pause" => handle_orchestrator_pause,
    "experience.reuse" => handle_experience_reuse,
    "experience.search" => handle_experience_search,
    "experience.export" => handle_experience_export,
    "feedback.record" => handle_feedback_record,
    "preferences.get" => handle_preferences_get,
    "preferences.revert" => handle_preferences_revert,
    "preferences.history" => handle_preferences_history,
    "file.list" => handle_file_list,
    "model.list" => handle_model_list,
    "model.select" => handle_model_select,
    "model.configure" => handle_model_configure,
    "desktop.stats" => handle_desktop_stats,
    "desktop.organize" => handle_desktop_organize,
    "desktop.clean" => handle_desktop_clean,
    "desktop.suggest" => handle_desktop_suggest,
    "desktop.health" => handle_desktop_health,
    "auth.status" => handle_auth_status,
    "permission.get" => handle_permission_get,
    "permission.set" => handle_permission_set,
    "permission.reset" => handle_permission_reset,
    "permission.decisions" => handle_permission_decisions,
    "capability.audit" => handle_capability_audit,
    "auth.setup" => handle_auth_setup,
    "auth.change_password" => handle_auth_change_password,
    "auth.reset" => handle_auth_reset,
    "auth.verify" => handle_auth_verify,
    "code_tracker.status" => handle_code_tracker_status,
    "code_tracker.init" => handle_code_tracker_init,
    "code_tracker.scan" => handle_code_tracker_scan,
    "tts.speak" => handle_tts_speak,
    "audio.transcribe" => handle_audio_transcribe,
    "audio.record" => handle_audio_record,
    "desktop.status" => handle_desktop_status,
    "desktop.screenshot" => handle_desktop_screenshot,
    "desktop.watch" => handle_desktop_watch,
    "plan.create" => handle_plan_create,
    "plan.list" => handle_plan_list,
    "plan.status" => handle_plan_status,
    "plan.cancel" => handle_plan_cancel,
    "plan.resume" => handle_plan_resume,
    "plan.decompose" => handle_plan_decompose,
    "skills.list" => handle_skills_list,
    "skills.show" => handle_skills_show,
    "skills.enable" => handle_skills_enable,
    "skills.disable" => handle_skills_disable,
    "skills.install" => handle_skills_install,
    "skills.uninstall" => handle_skills_uninstall,
)

function dispatch(request::AbstractDict)
    req_type = get(request, "type", "")
    id = get(request, "id", "?")
    method = get(request, "method", "")
    params = get(request, "params", Dict())

    # Tag all log lines from this request with its id so a multi-step `ai.query`
    # is traceable end-to-end.
    KamilaLog.with_context(id) do
        KamilaLog.debug(
            "dispatch request";
            mod = "bridge",
            fields = Dict("method" => method),
        )

        if req_type != "request"
            return send_error(id, "Invalid message type: $req_type", 400)
        end

        if !haskey(ROUTES, method)
            return send_error(
                id,
                "Unknown method: $method. Available: $(join(keys(ROUTES), ", "))",
                404,
            )
        end

        handler = ROUTES[method]
        handler(id, params)
        KamilaLog.debug(
            "dispatch complete";
            mod = "bridge",
            fields = Dict("method" => method),
        )
    end
end

# ─── Server Loop ──────────────────────────────────────────

function readline_timeout(stream::IO, timeout_sec::Float64)
    line = ""
    t = Timer(timeout_sec) do tm
        try
            close(stream)
        catch
        end
    end
    try
        line = readline(stream)
    catch e
        if e isa EOFError
        else
            rethrow()
        end
    finally
        try
            close(t)
        catch
        end
    end
    return line
end

function run_bridge(; read_timeout::Float64 = 300.0)
    Confirm.set_backend(:bridge)
    load_chat_history_from_disk()

    # 06.1: forward daemon-sourced events to the TUI as `notification` protocol
    # events. Handlers run on the publisher's thread; the bridge only observes.
    Events.subscribe("", _forward_daemon_event)

    # No automatic session start - uses "default" session unless explicitly started
    # Users who want explicit session isolation can call Episodic.start_session()

    # Start lazy backfill embedding job for chat history
    # This embeds historical chat messages that don't have embeddings yet
    @async begin
        try
            KamilaMemory.backfill_chat_embeddings()
        catch e
            KamilaLog.warn("Backfill embedding job failed: $e"; mod = "bridge")
        end
    end

    # Record a CPU baseline now so the first user-facing system.status is a real
    # delta rather than "unavailable" (02.3).
    SystemMonitor.prime_cpu_baseline()
    write_json(Dict("type" => "ready", "version" => "0.2.0"))

    # Handlers run asynchronously so a tool waiting on a bridge confirmation
    # (see `Confirm`) never blocks the protocol loop that must resolve it.
    pending_tasks = Base.Task[]

    try
        while true
            line = readline_timeout(stdin, read_timeout)
            if isempty(line) && eof(stdin)
                break
            end
            isempty(line) && continue
            request = JSON.parse(line)

            if get(request, "type", "") == "confirm_response"
                Confirm.resolve_confirm(
                    get(request, "id", ""),
                    get(request, "allow", false),
                )
                continue
            end

            push!(pending_tasks, @async dispatch(request))
        end
    catch e
        if e isa EOFError
        elseif e isa InterruptException
        else
            try
                write_json(
                    Dict(
                        "type" => "error",
                        "id" => "?",
                        "error" => "Bridge error: $e",
                        "code" => 500,
                    ),
                )
            catch
            end
            KamilaLog.error("Bridge error: $e"; mod = "bridge")
        end
    end

    # Wait for in-flight handlers before reporting shutdown so responses are not
    # truncated at EOF.
    for t in pending_tasks
        try
            wait(t)
        catch
        end
    end

    # End the current session (triggers segment summarization)
    Episodic.end_session()

    write_json(Dict("type" => "shutdown"))
end

end # module
