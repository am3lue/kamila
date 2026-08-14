"""
Episodic — Session tracking and summarization for long-term memory.
"""

module Episodic

using Dates
using JSON
using SHA
using SQLite
using ..Kamila
using ..KamilaLog
using ..MemoryDB
using ..OllamaInterface
using ..Vectors
using ..KamilaMemory

export SessionManager,
    start_session,
    end_session,
    get_current_session,
    summarize_segment,
    summarize_day,
    summarize_week,
    apply_decay,
    backfill_summaries,
    maybe_summarize_session

# Session management
const _current_session = Ref{Union{Nothing,String}}(nothing)
const _turn_count = Ref{Int}(0)
const SEGMENT_TURN_THRESHOLD = 30
const DEFAULT_SESSION = "default"

"""
Start a new chat session.
Returns the numeric session ID.
"""
function start_session()
    id = MemoryDB.query_all(
        "SELECT COALESCE(MAX(id), 0) + 1 as id FROM memories WHERE kind = 'session'",
    )
    session_id = first(id).id === missing ? 1 : first(id).id

    # Create session record
    MemoryDB.execute!(
        "INSERT INTO memories (kind, content, content_hash, created_at, importance, period) VALUES (?, ?, ?, ?, ?, ?)",
        "session",
        "Session started at $(now())",
        bytes2hex(SHA.sha256(string(now()))),
        string(now()),
        0.8,
        "session",
    )

    _current_session[] = string(session_id)
    _turn_count[] = 0
    KamilaLog.info("Started session $session_id"; mod = "episodic")
    return session_id
end

"""
Get the current session ID, creating a default session if needed.
Returns session ID as String (either "default" or numeric string).
"""
function get_current_session()
    if _current_session[] === nothing
        _current_session[] = DEFAULT_SESSION
        _turn_count[] = 0
    end
    return _current_session[]
end

"""
Get the current session ID as integer for database operations.
Returns 0 for default session, numeric ID for explicit sessions.
"""
function get_current_session_id()
    sid = get_current_session()
    return sid == DEFAULT_SESSION ? 0 : parse(Int, sid)
end

"""
End the current session and trigger segment summarization.
"""
function end_session()
    session_id = _current_session[]
    if session_id !== nothing
        _turn_count[] = 0
        _current_session[] = nothing
        # Trigger async segment summarization
        @async begin
            try
                summarize_segment(session_id)
            catch e
                KamilaLog.error("Segment summarization failed: $e"; mod = "episodic")
            end
        end
    end
end

"""
Increment turn counter and check if segment summarization is needed.
"""
function increment_turn()
    _turn_count[] += 1
    if _turn_count[] >= SEGMENT_TURN_THRESHOLD
        session_id = get_current_session()
        @async begin
            try
                summarize_segment(session_id)
            catch e
                KamilaLog.error("Segment summarization failed: $e"; mod = "episodic")
            end
        end
    end
end

"""
Summarize a segment (part of a session).
"""
function summarize_segment(session_id::String)
    session_id_int = session_id == DEFAULT_SESSION ? 0 : parse(Int, session_id)
    # Get raw turns for this segment - chat_messages uses session string, query by session
    rows = MemoryDB.query_all(
        "SELECT content, role, created_at FROM chat_messages WHERE session = ? ORDER BY idx",
        (session_id,)
    )

    if isempty(rows)
        return
    end

    # Build conversation text
    conversation = join(["$(r.role): $(r.content)" for r in rows], "\n")
    turn_count = length(rows)

    # Generate summary using Ollama
    prompt = """Summarize this conversation segment in 3-5 sentences. Focus on key topics, decisions, and outcomes.

Conversation:
$conversation

Summary:"""

    summary = _safe_summarize(prompt)

    if summary !== nothing
        # Store segment summary
        summary_str = String(summary)
        hash = Vectors._content_hash(summary_str)
        MemoryDB.transaction() do db
            SQLite.execute(
                db,
                """INSERT OR REPLACE INTO memories 
                   (kind, content, content_hash, created_at, importance, period, period_start, period_end, source_session_id, source_turn_count)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    "episodic",
                    summary_str,
                    hash,
                    string(now()),
                    0.7,
                    "segment",
                    string(now()),
                    string(now()),
                    session_id_int,
                    turn_count,
                ),
            )
        end
        KamilaLog.info(
            "Segment summary created for session $session_id ($turn_count turns)";
            mod = "episodic",
        )
    end
end

"""
Summarize a day's worth of segments.
"""
function summarize_day(date::Date = today())
    date_str = string(date)
    start_of_day = string(date)
    end_of_day = string(date + Day(1))

    # Get segment summaries for the day
    rows = MemoryDB.query_all(
        "SELECT content FROM memories WHERE kind = 'episodic' AND period = 'segment' AND created_at >= ? AND created_at < ? ORDER BY created_at",
        (start_of_day, end_of_day),
    )

    if isempty(rows)
        return
    end

    segments = join([r.content for r in rows], "\n---\n")

    prompt = """Create a daily summary from these conversation segments. Focus on key themes, achievements, and unresolved items.

Segments:
$segments

Daily Summary:"""

    summary = _safe_summarize(prompt)

    if summary !== nothing
        summary_str = String(summary)
        hash = Vectors._content_hash(summary_str)
        MemoryDB.transaction() do db
            SQLite.execute(
                db,
                """INSERT OR REPLACE INTO memories 
                   (kind, content, content_hash, created_at, importance, period, period_start, period_end)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    "episodic",
                    summary_str,
                    hash,
                    string(now()),
                    0.8,
                    "day",
                    string(now() - Day(1)),
                    string(now()),
                ),
            )
        end
        KamilaLog.info("Day summary created for $date_str"; mod = "episodic")
    end
end

"""
Summarize a week's worth of day summaries.
"""
function summarize_week(week_start::Date = today() - Day(7))
    week_end = week_start + Day(7)

    rows = MemoryDB.query_all(
        "SELECT content FROM memories WHERE kind = 'episodic' AND period = 'day' AND created_at >= ? AND created_at < ? ORDER BY created_at",
        (string(week_start), string(week_start + Day(7))),
    )

    if isempty(rows)
        return
    end

    days = join([r.content for r in rows], "\n---\n")

    prompt = """Create a weekly summary from these daily summaries. Identify recurring themes, progress, and patterns.

Daily Summaries:
$days

Weekly Summary:"""

    summary = _safe_summarize(prompt)

    if summary !== nothing
        summary_str = String(summary)
        hash = Vectors._content_hash(summary_str)
        # Use a created_at within the week window so it can be queried
        week_created = string(week_start + Day(3))
        MemoryDB.transaction() do db
            SQLite.execute(
                db,
                """INSERT OR REPLACE INTO memories 
                   (kind, content, content_hash, created_at, importance, period, period_start, period_end)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    "episodic",
                    summary_str,
                    hash,
                    week_created,
                    0.8,
                    "week",
                    string(week_start),
                    string(week_start + Day(7)),
                ),
            )
        end
        KamilaLog.info("Week summary created for week of $(week_start)"; mod = "episodic")
    end
end

"""
Apply decay to episodic memories based on age.
"""
function apply_decay(decay_rate::Float64 = 0.95)
    rows = MemoryDB.query_all(
        "SELECT id, importance, created_at FROM memories WHERE kind = 'episodic' AND period IN ('segment', 'day', 'week')",
    )

    for r in rows
        days_old = (now() - DateTime(r.created_at)).value / (1000 * 60 * 60 * 24)
        new_importance = r.importance * (decay_rate^days_old)

        MemoryDB.execute!(
            "UPDATE memories SET importance = ? WHERE id = ?",
            (new_importance, r.id),
        )
    end
end

"""
Backfill summaries for existing sessions.
"""
function backfill_summaries()
    # Summarize days for the past 30 days
    for i = 0:29
        date = today() - Day(i)
        summarize_day(today() - Day(i))
    end

    # Summarize weeks for past 12 weeks
    for i = 0:11
        week_start = today() - Day(7 * i)
        summarize_week(today() - Day(7 * i))
    end
end

"""
Safe summarization with error handling and placeholder on failure.
"""
function _safe_summarize(prompt::String; max_tokens::Int = 500)
    try
        result =
            OllamaInterface.query_ollama(prompt; max_tokens = max_tokens, temperature = 0.3)
        return String(strip(result))
    catch e
        KamilaLog.error("Summarization failed: $e"; mod = "episodic")
        return "<summary unavailable: $e>"
    end
end

"""
Maybe trigger summarization based on session state.
Called from bridge after each turn.
"""
function maybe_summarize_session()
    session_id = get_current_session()
    if _turn_count[] >= SEGMENT_TURN_THRESHOLD
        @async begin
            try
                summarize_segment(session_id)
            catch e
                KamilaLog.error("Auto segment summarization failed: $e"; mod = "episodic")
            end
        end
    end
end

"""
Get chat history for a specific session.
Returns vector of Dict with role/content.
"""
function get_session_history(session_id::String)
    rows = MemoryDB.query_all(
        "SELECT role, content, created_at FROM chat_messages WHERE session = ? ORDER BY idx DESC LIMIT 20",
        (session_id,)
    )
    result = Dict{String,Any}[]
    for r in rows
        push!(result, Dict("role" => r.role, "content" => r.content, "created_at" => r.created_at))
    end
    reverse!(result)  # Oldest first
    return result
end

end # module
