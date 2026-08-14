"""
Permission — declarative, persistent tool-permission policy.

Replaces the binary "ask for every shell command, allow everything else" model
(02.2-tool-permission-redesign). Every tool call is checked against a policy
file (`~/.kamila_policy.json`):

    {"tool": "run_shell_command", "match": "ls|cat|pwd", "action": "allow", "scope": "pattern"},
    {"tool": "run_shell_command", "match": "rm|mv|shutdown|reboot|mkfs|sudo", "action": "deny", "scope": "pattern"},
    {"tool": "write_file", "match": "*", "action": "ask", "scope": "tool"}

and a `default_action` (`allow` | `deny` | `ask`). First matching rule wins; the
policy's `session_remember` caches decisions for identical `(tool, args)` within
the process so agents don't re-prompt for the same action repeatedly.

`force` is never a free flag: a tool may only bypass a prompt with a capability
token — an HMAC over `(tool, args)` signed with a per-session secret. Tokens are
issued by `issue_capability` (only when the policy yields `:allow`) and checked
by `verify_capability`. A forged token is rejected.

Every decision is appended to an in-memory audit ring (last 50) and emitted as a
structured `permission.decision` log event.
"""

module Permission

using JSON
using SHA
using Dates
using ..KamilaLog
using ..Errors

export evaluate,
    get_policy,
    set_policy,
    reset_policy,
    recent_decisions,
    issue_capability,
    verify_capability,
    remember_decision,
    clear_session_cache,
    clear_policy_cache,
    POLICY_FILE,
    starter_policy

# ─── Policy file ───────────────────────────────────────────

const POLICY_FILE =
    Ref{String}(get(ENV, "KAMILA_POLICY_FILE", joinpath(homedir(), ".kamila_policy.json")))

# Session secret + decision cache. Reset per process.
const _SESSION_SECRET = Ref{Vector{UInt8}}(rand(UInt8, 32))
const _SESSION_DECISIONS = Dict{Tuple{String,String},Symbol}()
const _SESSION_LOCK = ReentrantLock()
const _SESSION_CACHE_MAX = 100

const _AUDIT = Vector{Dict{String,Any}}()
const _AUDIT_LOCK = ReentrantLock()
const _MAX_AUDIT = 50

const _POLICY_CACHE = Ref{Any}(nothing)

"""
The starter policy written on first run. Dangerous shell patterns denied;
safe ones allowed; unknown actions require confirmation.
"""
function starter_policy()
    return Dict{String,Any}(
        "version" => 1,
        "rules" => [
            Dict{String,Any}(
                "tool" => "run_shell_command",
                "match" => "ls|cat|pwd",
                "action" => "allow",
                "scope" => "pattern",
            ),
            Dict{String,Any}(
                "tool" => "run_shell_command",
                "match" => "rm|mv|shutdown|reboot|mkfs|sudo",
                "action" => "deny",
                "scope" => "pattern",
            ),
            Dict{String,Any}(
                "tool" => "write_file",
                "match" => "*",
                "action" => "ask",
                "scope" => "tool",
            ),
        ],
        "default_action" => "ask",
        "session_remember" => true,
        "max_asks_per_session" => 20,
    )
end

"""
Load the current policy; `nothing` cached value means "not loaded yet".
"""
function get_policy()
    cached = _POLICY_CACHE[]
    if cached !== nothing
        return cached
    end
    policy = try
        if isfile(POLICY_FILE[])
            data = JSON.parsefile(POLICY_FILE[])
            if data isa AbstractDict && haskey(data, "rules")
                data
            else
                starter_policy()
            end
        else
            starter_policy()
        end
    catch
        starter_policy()
    end
    _POLICY_CACHE[] = policy
    return policy
end

"""
Persist `policy` to the policy file and invalidate the cache. Returns Bool.
"""
function set_policy(policy::AbstractDict)
    try
        write(POLICY_FILE[], JSON.json(policy, 2))
        _POLICY_CACHE[] = nothing
        return true
    catch
        return false
    end
end

"""
Write the starter policy to disk (only if the file does not already exist).
"""
function ensure_policy_file()
    isfile(POLICY_FILE[]) && return nothing
    write(POLICY_FILE[], JSON.json(starter_policy(), 2))
    _POLICY_CACHE[] = nothing
    return nothing
end

"""
Restore the starter policy (documented recovery path when a user locks
themselves out by denying everything).
"""
function reset_policy()
    set_policy(starter_policy())
end

# ─── Session cache ─────────────────────────────────────────

"""
Normalize `args` into a canonical string for cache-keying: sorted key=value
pairs joined by `;`. Nested dicts are JSON-serialized so different content maps
to different keys.
"""
function _args_key(args)
    parts = String[]
    for k in sort(collect(keys(args)))
        v = args[k]
        v isa AbstractDict || v isa AbstractVector ? push!(parts, "$k=$(JSON.json(v))") :
        push!(parts, "$k=$v")
    end
    return join(parts, ";")
end

function _session_key(tool::String, args)
    return (tool, _args_key(args))
end

"""
Remember a decision for the session. Called by tools after a user approves an
`:ask`, so the identical action isn't re-prompted (capped to keep memory bounded).
"""
function remember_decision(tool::String, args, decision::Symbol)
    key = _session_key(tool, args)
    lock(_SESSION_LOCK) do
        if length(_SESSION_DECISIONS) >= _SESSION_CACHE_MAX
            # Evict the oldest entry (Dict iteration is insertion-ordered).
            first_key = first(keys(_SESSION_DECISIONS))
            delete!(_SESSION_DECISIONS, first_key)
        end
        _SESSION_DECISIONS[key] = decision
    end
    return nothing
end

function clear_session_cache()
    lock(_SESSION_LOCK) do
        empty!(_SESSION_DECISIONS)
    end
    return nothing
end

"""
Forget the cached policy so the next `get_policy` re-reads the policy file.
"""
function clear_policy_cache()
    _POLICY_CACHE[] = nothing
    return nothing
end

# ─── Audit ─────────────────────────────────────────────────

function _audit(tool::String, action::Symbol, rule; target::String = "")
    entry = Dict{String,Any}(
        "ts" => Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS"),
        "tool" => tool,
        "action" => String(action),
        "rule" => rule,
        "target" => target,
    )
    lock(_AUDIT_LOCK) do
        push!(_AUDIT, entry)
        if length(_AUDIT) > _MAX_AUDIT
            deleteat!(_AUDIT, 1:(length(_AUDIT)-_MAX_AUDIT))
        end
    end
    KamilaLog.info(
        "permission.decision";
        mod = "permission",
        fields = Dict{String,Any}(
            "tool" => tool,
            "action" => String(action),
            "rule" => rule,
        ),
    )
    return nothing
end

"""
Return the most recent audit entries (default 50).
"""
function recent_decisions(limit::Int = 50)
    lock(_AUDIT_LOCK) do
        start = max(1, length(_AUDIT) - limit + 1)
        return copy(_AUDIT[start:end])
    end
end

# ─── Rule matching ─────────────────────────────────────────

"""
Does `rule` apply to `tool` and `args`? `scope`:
  - `"tool"`/`"always"`: applies to the whole tool regardless of arguments.
  - `"pattern"`: applies when any `|`-separated prefix in `match` occurs at a word
    boundary in the tool's primary argument string (the command for
    `run_shell_command`, the file path for `write_file`). Word-boundary matching
    means `rm` blocks `rm -rf /` but not `echo confirm` (where "rm" is part of
    "confirm").
"""
function _rule_applies(rule::AbstractDict, tool::String, target::String)
    rule_tool = get(rule, "tool", "*")
    if rule_tool != "*" && rule_tool != tool
        return false
    end
    scope = get(rule, "scope", "pattern")
    if scope == "tool" || scope == "always"
        return true
    end
    match = get(rule, "match", "*")
    match == "*" && return true
    isempty(match) && return true
    for prefix in split(match, "|")
        prefix = strip(prefix)
        isempty(prefix) && continue
        if _target_has_boundary_prefix(target, prefix)
            return true
        end
    end
    return false
end

# Match `prefix` at a word boundary in `target` (substrings inside a larger word
# are ignored).
function _target_has_boundary_prefix(target::AbstractString, prefix::AbstractString)
    startswith(target, prefix) && return true
    escaped = replace(prefix, r"[.*+?^$(){}\[\]|\\]" => s -> "\\" * s)
    return occursin(Regex("(^|[^A-Za-z0-9])" * escaped), target)
end

"""
The string a pattern rule matches against for a tool.
"""
function _target_string(tool::String, args)
    if tool == "run_shell_command"
        return string(get(args, "command", ""))
    elseif tool == "write_file"
        return string(get(args, "file_path", ""))
    end
    return string(get(args, "command", "")) * " " * string(get(args, "file_path", ""))
end

"""
Evaluate the policy for `tool`/`args`. Returns `:allow`, `:deny`, or `:ask`.
First matching rule wins; then `default_action`. Session cache consulted first.
"""
function evaluate(tool::String, args)
    return first(_evaluate_with_rule(tool, args))
end

"""
Evaluate the policy and return `(decision, rule)` where `rule` names the
matching rule (or `"default"`). Shared by `evaluate` and the confirmation flow
(which shows which rule fired).
"""
function _evaluate_with_rule(tool::String, args)
    policy = get_policy()

    # Session cache first (same tool + normalized args this session), but only
    # when the policy opts into session-remembering.
    if get(policy, "session_remember", true) != false
        key = _session_key(tool, args)
        cached = lock(_SESSION_LOCK) do
            get(_SESSION_DECISIONS, key, nothing)
        end
        if cached !== nothing
            return (cached, "session")
        end
    end

    target = _target_string(tool, args)
    decision = Symbol(get(policy, "default_action", "ask"))
    rule_hit = "default"
    for rule in get(policy, "rules", Any[])
        if _rule_applies(rule, tool, target)
            decision = Symbol(get(rule, "action", "ask"))
            rule_hit = string(get(rule, "match", "*"))
            break
        end
    end
    _audit(tool, decision, rule_hit; target = target)
    return (decision, rule_hit)
end

# ─── Capability tokens ─────────────────────────────────────

"""
Issue a capability token for `tool`/`args` — HMAC-SHA256 over the canonical
tool+args with the per-session secret. Only issued when the policy yields
`:allow`; otherwise returns `""`.
"""
function issue_capability(tool::String, args)
    evaluate(tool, args) == :allow || return ""
    key = _session_key(tool, args)
    return bytes2hex(
        hmac_sha256(_SESSION_SECRET[], "kamila-capability:" * key[1] * ":" * key[2]),
    )
end

"""
Verify a capability token with constant-time comparison. Forged/absent tokens
are rejected.
"""
function verify_capability(tool::String, args, token::AbstractString)
    isempty(token) && return false
    key = _session_key(tool, args)
    expected = bytes2hex(
        hmac_sha256(_SESSION_SECRET[], "kamila-capability:" * key[1] * ":" * key[2]),
    )
    return _constant_time_eq(token, expected)
end

function _constant_time_eq(a::AbstractString, b::AbstractString)
    length(a) == length(b) || return false
    diff = 0
    for (ca, cb) in zip(codeunits(a), codeunits(b))
        diff |= Int(ca) ⊻ Int(cb)
    end
    return diff == 0
end

end # module Permission
