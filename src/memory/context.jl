"""
Context — Query-aware context injection with token budget and provenance labels.
"""

module Context

using JSON
using Dates
using ..Kamila
using ..KamilaLog
using ..MemoryDB
using ..KamilaMemory
using ..TaskManager
using ..Vectors
using ..Episodic

export build_context, ContextProvider, ContextBlock, DEFAULT_CONTEXT_BUDGET, MAX_CONTEXT_BUDGET

# Configuration
const DEFAULT_CONTEXT_BUDGET = 2000
const MAX_CONTEXT_BUDGET = 3000

"""
ContextBlock represents a single injectable context piece with provenance.
"""
struct ContextBlock
    priority::Int          # Lower = higher priority (1 = highest)
    est_tokens::Int        # Estimated token count
    text::String           # The context text
    label::String          # Provenance label for the model/user
    source::String         # Source identifier for debugging
end

"""
Abstract provider interface. Each provider implements `provide(query, session, mode)`.
"""
abstract type ContextProvider end

"""
Provider result: (priority, est_tokens, text, label, source)
"""
struct ProviderResult
    priority::Int
    est_tokens::Int
    text::String
    label::String
    source::String
end

# ════════════════════════════════════════════════════════════════════
# Providers
# ════════════════════════════════════════════════════════════════════

"""
EpisodicProvider — top-k day/week summaries via recall, decayed.
"""
struct EpisodicProvider <: ContextProvider end

function (::EpisodicProvider)(query::String, session::String, mode::String)
    results = ProviderResult[]
    
    # Recall episodic summaries relevant to query
    episodic_results = KamilaMemory.recall(query; k = 5, kinds = ["episodic"])
    
    if !isempty(episodic_results)
        # Apply decay based on age
        now_dt = now()
        for (i, r) in enumerate(episodic_results)
            age_days = (now_dt - DateTime(r.created_at)).value / (1000 * 60 * 60 * 24)
            decay_factor = 0.95 ^ age_days
            priority = min(1 + i, 5)  # Priority 2-6
            
            # Only include if decayed importance is still meaningful
            effective_importance = float(r.importance) * decay_factor
            effective_importance < 0.15 && continue
            
            date_str = something(first(split(string(r.created_at), " ")), "unknown")
            label = "# [memory: episodic-recall (score $(round(effective_importance * 100))%, $date_str)]"
            text = "$(r.content)"
            est_tokens = length(text) ÷ 4  # Rough token estimate
            
            push!(results, ProviderResult(priority, est_tokens, text, label, "episodic"))
        end
    end
    
    return results
end

"""
MemoryProvider — top-k semantic recalls for the query.
"""
struct MemoryProvider <: ContextProvider end

function (::MemoryProvider)(query::String, session::String, mode::String)
    results = ProviderResult[]
    
    # Recall non-episodic memories (chat, task, goal, note)
    kinds = ["chat", "task", "goal", "note"]
    recall_results = KamilaMemory.recall(query; k = 8, kinds = kinds)
    
    if !isempty(recall_results)
        for (i, r) in enumerate(recall_results)
            priority = 2 + i  # Priority 3-10
            label = "# [memory: $(r.kind)-recall (score $(round(float(r.score) * 100))%)]"
            text = "$(r.content)"
            est_tokens = length(text) ÷ 4
            
            push!(results, ProviderResult(priority, est_tokens, text, label, "memory"))
        end
    end
    
    return results
end

"""
GoalProvider — active goals only when query relates (keyword/semantic gate).
"""
struct GoalProvider <: ContextProvider end

function (::GoalProvider)(query::String, session::String, mode::String)
    results = ProviderResult[]
    
    goals = KamilaMemory.get_active_goals()
    if isempty(goals)
        return results
    end
    
    # Semantic gate: check if query relates to any goal
    query_lower = lowercase(query)
    related_goals = filter(goals) do g
        goal_text = lowercase(g["goal"])
        # Keyword overlap check
        any(word -> occursin(word, query_lower) && length(word) > 3, split(goal_text))
    end
    
    # Safety floor: always include top-3 by priority
    sort!(goals, by = g -> -get(g, "priority", 1))
    safety_goals = goals[1:min(3, length(goals))]
    
    # Combine related + safety (deduplicate by id)
    seen = Set{Int}()
    combined = []
    for g in vcat(related_goals, safety_goals)
        gid = g["id"]
        gid in seen && continue
        push!(seen, gid)
        push!(combined, g)
    end
    
    if !isempty(combined)
        text_parts = String[]
        for (i, g) in enumerate(combined)
            push!(text_parts, "  - $(g["goal"]) [P:$(g["priority"])]")
        end
        text = "Active Goals:\n" * join(text_parts, "\n")
        label = "# [memory: active-goals (gate: semantic + priority-floor)]"
        est_tokens = length(text) ÷ 4
        push!(results, ProviderResult(3, est_tokens, text, label, "goals"))
    end
    
    return results
end

"""
TaskProvider — pending/overdue tasks, capped (default 10, sorted by priority).
"""
struct TaskProvider <: ContextProvider end

function (::TaskProvider)(query::String, session::String, mode::String)
    results = ProviderResult[]
    
    pending = TaskManager.get_pending_tasks()
    overdue = TaskManager.get_overdue_tasks()
    
    isempty(pending) && isempty(overdue) && return results
    
    # Combine and sort: overdue first, then by priority (dedup by id)
    seen_ids = Set{Int}()
    all_tasks = TaskManager.Task[]
    for t in vcat(overdue, pending)
        t.id in seen_ids && continue
        push!(seen_ids, t.id)
        push!(all_tasks, t)
    end
    sort!(all_tasks, by = t -> (-t.priority, t.due_date !== nothing ? t.due_date : Date(now()) + Day(1000)))
    
    # Cap at 10
    capped = all_tasks[1:min(10, length(all_tasks))]
    
    text_parts = String[]
    for t in capped
        due_str = t.due_date !== nothing ? " (due: $(t.due_date))" : ""
        push!(text_parts, "  - [#$(t.id)] $(t.title) [P:$(t.priority)]$(due_str)")
    end
    
    text = "Pending Tasks:\n" * join(text_parts, "\n")
    label = "# [memory: pending-tasks (capped at 10, priority-sorted)]"
    est_tokens = length(text) ÷ 4
    push!(results, ProviderResult(4, est_tokens, text, label, "tasks"))
    
    return results
end

"""
PlanProvider — current active plan steps (from 04.1, when present).
Degrades gracefully if plan module not available.
"""
struct PlanProvider <: ContextProvider end

function (::PlanProvider)(query::String, session::String, mode::String)
    results = ProviderResult[]
    
    # Try to load plan module if available
    if isdefined(Main.Kamila, :PlanManager)
        try
            plans = Main.Kamila.PlanManager.get_active_plans()
            if !isempty(plans)
                text_parts = String[]
                for p in plans
                    push!(text_parts, "  - $(p["title"]): $(p["status"])")
                end
                text = "Active Plans:\n" * join(text_parts, "\n")
                label = "# [memory: active-plans]"
                est_tokens = length(text) ÷ 4
                push!(results, ProviderResult(2, est_tokens, text, label, "plans"))
            end
        catch
            # PlanManager not available or error — degrade gracefully
        end
    end
    
    return results
end

"""
HistoryProvider — recent turns ranked by relevance via embeddings (when enabled).
"""
struct HistoryProvider <: ContextProvider end

function (::HistoryProvider)(query::String, session::String, mode::String)
    results = ProviderResult[]
    
    # Get history for current session only
    history = Episodic.get_session_history(session)
    if isempty(history)
        return results
    end
    
    # If embeddings available, rank by relevance
    if Vectors.embeddings_available()
        qvec = Vectors.embed(query)
        if qvec !== nothing
            scored = []
            for h in history
                hvec = Vectors.embed(h["content"])
                if hvec !== nothing
                    sim = Vectors.cosine(qvec, hvec)
                    push!(scored, (sim, h))
                end
            end
            sort!(scored, by = x -> -x[1])
            history = [h for (_, h) in scored]
        end
    end
    
    # Take last 5 turns (most relevant first if ranked, otherwise most recent)
    recent = history[1:min(5, length(history))]
    
    if !isempty(recent)
        text_parts = String[]
        for h in recent
            role = get(h, "role", "unknown")
            content = get(h, "content", "")
            push!(text_parts, "  $role: $content")
        end
        text = "Recent Conversation (session-scoped):\n" * join(text_parts, "\n")
        label = "# [memory: session-history (ranked by relevance)]"
        est_tokens = length(text) ÷ 4
        push!(results, ProviderResult(1, est_tokens, text, label, "history"))
    end
    
    return results
end

# ════════════════════════════════════════════════════════════════════
# Budget Packer
# ════════════════════════════════════════════════════════════════════

"""
Pack context blocks into a budget, prioritizing by priority then recency.
"""
function pack_context(blocks::Vector{ProviderResult}; budget::Int = DEFAULT_CONTEXT_BUDGET)
    # Sort by priority (ascending = higher priority first), then by estimated tokens (smaller first)
    sorted = sort(blocks, by = x -> (x.priority, x.est_tokens))
    
    packed = ProviderResult[]
    used = 0
    hard_cap = MAX_CONTEXT_BUDGET
    
    for block in sorted
        if used + block.est_tokens > budget
            # Try to truncate the text to fit
            remaining = budget - used
            if remaining > 100  # Minimum useful size
                max_chars = remaining * 4
                if length(block.text) > max_chars
                    truncated = block.text[1:max_chars] * "... [truncated]"
                    push!(packed, ProviderResult(
                        block.priority,
                        remaining,
                        truncated,
                        block.label,
                        block.source
                    ))
                    used = budget
                    break
                end
            end
            # Skip this block and lower priority ones
            continue
        end
        push!(packed, block)
        used += block.est_tokens
        used >= hard_cap && break
    end
    
    return packed, used
end

# ════════════════════════════════════════════════════════════════════
# Main Entry Point
# ════════════════════════════════════════════════════════════════════

"""
Build the context injection string for a given query.
Returns the system prompt with labeled context blocks appended.
"""
function build_context(query::String; 
                       session::String = Episodic.get_current_session(),
                       mode::String = "chat",
                       budget::Int = DEFAULT_CONTEXT_BUDGET)
    
    # Get config budget override
    config_budget = get(ENV, "KAMILA_CONTEXT_BUDGET", nothing)
    if config_budget !== nothing
        try
            budget = min(parse(Int, config_budget), MAX_CONTEXT_BUDGET)
        catch
        end
    end
    
    # Collect from all providers
    providers = ContextProvider[
        EpisodicProvider(),
        MemoryProvider(),
        PlanProvider(),
        GoalProvider(),
        TaskProvider(),
        HistoryProvider(),
    ]
    
    all_blocks = ProviderResult[]
    for provider in providers
        try
            append!(all_blocks, provider(query, session, mode))
        catch e
            KamilaLog.warn("Context provider $(typeof(provider)) failed: $e"; mod = "context")
        end
    end
    
    # Pack into budget
    packed, used = pack_context(all_blocks; budget = budget)
    
    # Log injection stats
    KamilaLog.debug("Context injection: $(length(packed)) blocks, ~$(used) tokens, budget=$(budget)"; mod = "context")
    
    # Build final string with provenance labels
    if isempty(packed)
        return ""
    end
    
    parts = String["\n\n## Injected Context (budget: $(used)/$(budget) tokens)\n"]
    for block in packed
        push!(parts, block.label)
        push!(parts, block.text)
        push!(parts, "")
    end
    
    return join(parts, "\n")
end

"""
Debug mode: return detailed breakdown of what would be injected.
"""
function build_context_debug(query::String;
                             session::String = Episodic.get_current_session(),
                             mode::String = "chat",
                             budget::Int = DEFAULT_CONTEXT_BUDGET)
    
    providers = ContextProvider[
        EpisodicProvider(),
        MemoryProvider(),
        PlanProvider(),
        GoalProvider(),
        TaskProvider(),
        HistoryProvider(),
    ]
    
    all_blocks = ProviderResult[]
    provider_entries = []
    for provider in providers
        try
            blocks = provider(query, session, mode)
            for b in blocks
                push!(provider_entries, (
                    provider_name = string(nameof(typeof(provider))),
                    priority = b.priority,
                    est_tokens = b.est_tokens,
                    label = b.label,
                    source = b.source,
                    text_preview = first(b.text, 200),
                ))
                push!(all_blocks, b)
            end
        catch e
            push!(provider_entries, (
                provider_name = string(nameof(typeof(provider))),
                error = string(e),
            ))
        end
    end
    
    packed, used = pack_context(all_blocks; budget = budget)
    
    return Dict(
        "query" => query,
        "session" => session,
        "mode" => mode,
        "budget" => budget,
        "used_tokens" => used,
        "blocks_count" => length(packed),
        "providers" => provider_entries,
        "packed" => [
            Dict(
                "priority" => b.priority,
                "est_tokens" => b.est_tokens,
                "label" => b.label,
                "source" => b.source,
                "text_preview" => first(b.text, 200)
            ) for b in packed
        ]
    )
end

end # module