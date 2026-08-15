"""
Preferences — user preference learning (07.3).

Learns and honors user preferences across responses and tool-usage habits.
Explicit feedback (thumbs up/down + reason) is a strong signal (weight 1.0);
implicit signals (e.g. user retries/edits after an action) are weak (0.2) and
never outvote explicit ones. A committed value only flips when a clear margin
(minimum event count) is reached within the aggregation window, and every
change is logged with rationale.

Design notes:
- Values start from a committed baseline (`tone=narrated`, `verbosity=normal`).
- `preferences` table stores committed values with their source and timestamp;
  `preference_events` stores every raw signal for auditability.
- All changes are revocable via `revert` (restores committed_default).
"""

module Preferences

using Dates
using SQLite
using ..KamilaLog
using ..MemoryDB

export record_signal,
    commit_preference,
    get_preference,
    all_preferences,
    active_preferences,
    revert_preference,
    preference_history,
    preference_history_all,
    set_baseline

# ─── Configuration ─────────────────────────────────────────

const WEIGHT_EXPLICIT = 1.0
const WEIGHT_IMPLICIT = 0.2
const MIN_EVENTS_TO_FLIP = 5
const WINDOW_EVENTS = 30

# ─── Baselines ─────────────────────────────────────────────

const BASELINES = Dict{String,String}(
    "tone" => "narrated",
    "verbosity" => "normal",
    "default_tool" => "",
    "confirm_threshold" => "1.0",
)

"""
    set_baseline(key::String, value::String)

Set (or overwrite) the committed baseline for `key`. Used to seed defaults.
"""
function set_baseline(key::String, value::String)
    BASELINES[key] = value
    return value
end

# ─── Recording ─────────────────────────────────────────────

"""
    record_signal(key::String, value::String; explicit::Bool, session::String="")

Record one preference signal. `explicit=true` (thumbs up/down) weighs 1.0;
implicit signals weigh 0.2. Applies the aggregation rule: a value commits only
when it reaches `MIN_EVENTS_TO_FLIP` weighted events in the window AND beats
the current committed value's weight. Returns `(committed::Bool, current_value)`.
"""
function record_signal(
    key::String,
    value::String;
    explicit::Bool,
    session::String = "",
)
    weight = explicit ? WEIGHT_EXPLICIT : WEIGHT_IMPLICIT

    MemoryDB.execute!(
        """INSERT INTO preference_events (key, value, weight, explicit, session, ts)
           VALUES (?, ?, ?, ?, ?, ?)""",
        (key, value, weight, explicit ? 1 : 0, session, string(now())),
    )
    KamilaLog.info(
        "preference.signal: $key=$value (explicit=$explicit, weight=$weight)";
        mod = "preference",
    )

    return _aggregate(key, value)
end

function _aggregate(key::String, candidate::String)
    current = get_preference(key)
    events = MemoryDB.query_all(
        """SELECT key, value, weight, explicit, ts FROM preference_events
           WHERE key = ? ORDER BY id DESC LIMIT ?""",
        (key, WINDOW_EVENTS),
    )

    weights = Dict{String,Float64}()
    explicit_weights = Dict{String,Float64}()
    for r in events
        v = string(r.value)
        w = Float64(r.weight)
        weights[v] = get(weights, v, 0.0) + w
        if r.explicit == 1
            explicit_weights[v] = get(explicit_weights, v, 0.0) + w
        end
    end

    # Only flip when there is a clear margin of weighted events for a value
    # different from the current one.
    if isempty(weights)
        return false, current
    end
    best_value = ""
    best_weight = -Inf
    for (v, w) in weights
        if w > best_weight
            best_value = v
            best_weight = w
        end
    end

    total_weight = sum(values(weights))
    # The flip requires a margin of EXPLICIT signals — implicit-only aggregates
    # (however large) can never outvote explicit feedback.
    explicit_margin = get(explicit_weights, best_value, 0.0) >=
                      MIN_EVENTS_TO_FLIP * WEIGHT_EXPLICIT
    majority = total_weight > 0 && best_weight / total_weight >= 0.5

    if best_value != current && best_value == candidate && explicit_margin && majority
        commit_preference(key, best_value; explicit = true)
        return true, best_value
    end

    return false, current
end

"""
    commit_preference(key::String, value::String; source::String="", explicit::Bool=false)

Force-commit `value` for `key` (upsert into `preferences`). `source` is the
rationale string surfaced in the preferences panel. Logs the change.
"""
function commit_preference(
    key::String,
    value::String;
    source::String = "explicit feedback",
    explicit::Bool = false,
)
    MemoryDB.execute!(
        """INSERT INTO preferences (key, value, committed_default, source, ts)
           VALUES (?, ?, ?, ?, ?)
           ON CONFLICT(key) DO UPDATE SET
               value = excluded.value,
               source = excluded.source,
               ts = excluded.ts""",
        (
            key,
            value,
            get(BASELINES, key, nothing),
            explicit ? "explicit" : source,
            string(now()),
        ),
    )
    KamilaLog.info(
        "preference.commit: $key=$value (source=$source)";
        mod = "preference",
    )
    return value
end

# ─── Reading ───────────────────────────────────────────────

"""
    get_preference(key::String)

Current committed value for `key`, or its baseline when nothing committed.
"""
function get_preference(key::String)
    try
        rows = MemoryDB.query_all(
            "SELECT value FROM preferences WHERE key = ?",
            (key,),
        )
        if !isempty(rows)
            return string(rows[1].value)
        end
    catch e
        KamilaLog.warn("preference.read_failed: $e"; mod = "preference")
    end
    return get(BASELINES, key, "")
end

"""
    all_preferences()

All committed preference rows `(key, value, source, ts)`.
"""
function all_preferences()
    rows = MemoryDB.query_all(
        "SELECT key, value, source, ts FROM preferences ORDER BY key",
    )
    return [
        Dict{String,Any}(
            "key" => string(r.key),
            "value" => string(r.value),
            "source" => string(r.source),
            "ts" => string(r.ts),
        ) for r in rows
    ]
end

"""
    active_preferences()

The committed preferences that differ from their baseline — these are the ones
surfaced to the model (the `# preferences` block). Skips keys whose value
equals their committed default.
"""
function active_preferences()
    out = Dict{String,String}()
    for p in all_preferences()
        key = p["key"]
        value = p["value"]
        baseline = get(BASELINES, key, get(BASELINES, key, ""))
        if value != baseline
            out[key] = value
        end
    end
    return out
end

"""
    revert_preference(key::String)

Restore `key` to its committed baseline. Returns the restored value.
"""
function revert_preference(key::String)
    baseline = get(BASELINES, key, "")
    try
        MemoryDB.execute!(
            "DELETE FROM preferences WHERE key = ?",
            (key,),
        )
    catch e
        KamilaLog.warn("preference.revert_failed: $e"; mod = "preference")
    end
    KamilaLog.info("preference.revert: $key -> $baseline"; mod = "preference")
    return baseline
end

"""
    preference_history(key::String; limit::Int=30)

Recent raw signal events for `key` (for the preferences panel audit view).
"""
function preference_history(key::String; limit::Int = 30)
    rows = MemoryDB.query_all(
        """SELECT id, key, value, weight, explicit, session, ts
           FROM preference_events WHERE key = ? ORDER BY id DESC LIMIT ?""",
        (key, limit),
    )
    return [
        Dict{String,Any}(
            "id" => Int(r.id),
            "key" => string(r.key),
            "value" => string(r.value),
            "weight" => Float64(r.weight),
            "explicit" => r.explicit == 1,
            "session" => r.session === nothing ? "" : string(r.session),
            "ts" => string(r.ts),
        ) for r in rows
    ]
end

"""
    preference_history_all(; limit::Int=50)

Recent raw signal events across all keys (for the preferences panel audit view).
"""
function preference_history_all(; limit::Int = 50)
    rows = MemoryDB.query_all(
        """SELECT id, key, value, weight, explicit, session, ts
           FROM preference_events ORDER BY id DESC LIMIT ?""",
        (limit,),
    )
    return [
        Dict{String,Any}(
            "id" => Int(r.id),
            "key" => string(r.key),
            "value" => string(r.value),
            "weight" => Float64(r.weight),
            "explicit" => r.explicit == 1,
            "session" => r.session === nothing ? "" : string(r.session),
            "ts" => string(r.ts),
        ) for r in rows
    ]
end

end # module
