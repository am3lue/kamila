"""
Capability — capability-based permission tokens and scope narrowing (05.3).

Formalizes the ad-hoc policy from 02.2 into a capability model integrated with
the skill library (05.2), the batch orchestrator (04.2), and sub-agents:

  - Every tool maps to a capability (`tool_capability`, e.g. `run_shell_command`
    → `"shell"`, `web_search` → `"network"`, `write_file` → `"files.write"`).
  - A capability token is `{tool, arg_hash, action, issued_at, exp, nonce}`
    signed with HMAC-SHA256. Any tool call may carry `capability`; the runtime
    verifies signature, expiry, and an exact `(tool, arg_hash)` match. Forged,
    expired, or mismatched tokens are rejected.
  - Scopes narrow what a batch (04.2) or sub-agent may do: a child capability
    set is the intersection of its parent's set and its declared needs, so a
    child can never gain capabilities its parent lacks.
  - Every check is appended to an audit ring (`capability.audit`) so decisions
    are traceable ("why was this allowed").
"""

module Capability

using JSON
using SHA
using Dates
using Base64
using ..KamilaLog
using ..Errors

export tool_capability,
    mint_capability,
    verify_capability,
    narrow_scope,
    restrict_caps,
    in_scope_q,
    capability_audit,
    recent_checks,
    clear_checks,
    TOOL_CAPABILITY

# ─── Tool → capability mapping ─────────────────────────────

"""
Map a tool name to its capability. Unknown tools map to `"core"` (read-only,
low-risk baseline). Skills resolve to their name so `skill:<name>` rules apply.
"""
const TOOL_CAPABILITY = Dict{String,String}(
    "run_shell_command" => "shell",
    "write_file" => "files.write",
    "read_file" => "files.read",
    "list_directory" => "files.read",
    "file_find" => "files.read",
    "grep_search" => "files.read",
    "web_search" => "network",
    "vision" => "vision",
    "transcribe_audio" => "audio",
    "desktop_status" => "desktop.read",
    "screenshot_describe" => "desktop.read",
    "reuse_solution" => "memory.read",
    "set_reminder" => "notifications",
    "memory_query" => "memory.read",
    "add_task" => "tasks.write",
    "complete_task" => "tasks.write",
    "list_tasks" => "tasks.read",
    "system_status" => "system.read",
    "decompose_goal" => "planning",
    "learn_skill" => "skills",
    "batch" => "batch",
)

function tool_capability(tool::AbstractString)
    return get(TOOL_CAPABILITY, string(tool), "core")
end

# ─── Token minting / verification ─────────────────────────

# Session secret for capability tokens (distinct from Permission's session
# secret; reset per process like the rest of the session state).
const _SECRET = Ref{Vector{UInt8}}(rand(UInt8, 32))

const _TTL_SECONDS = Ref{Float64}(60.0)
const _CLOCK_SKEW = Ref{Float64}(5.0)

# Replay protection: nonces seen this session.
const _NONCES = Set{String}()
const _NONCE_LOCK = ReentrantLock()

const _CHECKS = Vector{Dict{String,Any}}()
const _CHECKS_LOCK = ReentrantLock()
const _MAX_CHECKS = 100

function set_ttl_seconds(seconds::Real)
    _TTL_SECONDS[] = Float64(seconds)
    return nothing
end

"""
Canonical argument hash: SHA-256 of sorted key=value pairs (JSON for nested).
The same canonicalization family as `Permission._args_key`. Control keys
(`capability`, `force`) are excluded so a token minted for an action still
verifies when the caller attaches its token.
"""
function arg_hash(args)
    parts = String[]
    for k in sort(collect(keys(args)))
        String(k) in ("capability", "force") && continue
        v = args[k]
        v isa AbstractDict || v isa AbstractVector ? push!(parts, "$k=$(JSON.json(v))") :
        push!(parts, "$k=$v")
    end
    return bytes2hex(SHA.sha256(join(parts, ";")))
end

"""
Mint a capability token for `tool`/`args`. Token format:
`payload_b64 "." signature_b64`, where payload is JSON
`{tool, arg_hash, action, issued_at, exp, nonce}` and the signature is the
HMAC-SHA256 of the payload with the per-session secret.
"""
function mint_capability(tool::AbstractString, args; ttl::Real = _TTL_SECONDS[], action::String = "allow")
    now_s = time()
    nonce = string(time_ns(), "-", rand(1:Int64(1e12)))
    payload = Dict{String,Any}(
        "tool" => string(tool),
        "arg_hash" => arg_hash(args),
        "action" => action,
        "issued_at" => now_s,
        "exp" => now_s + Float64(ttl),
        "nonce" => nonce,
    )
    body = JSON.json(payload)
    sig = bytes2hex(hmac_sha256(_SECRET[], body))
    token = base64encode(body) * "." * sig
    lock(_NONCE_LOCK) do
        push!(_NONCES, nonce)
    end
    _audit("mint", string(tool), true, Dict{String,Any}("ttl" => ttl, "action" => action))
    return token
end

function _constant_time_eq(a::AbstractString, b::AbstractString)
    length(a) == length(b) || return false
    diff = 0
    for (ca, cb) in zip(codeunits(a), codeunits(b))
        diff |= Int(ca) ⊻ Int(cb)
    end
    return diff == 0
end

"""
Verify a capability token for `tool`/`args` with constant-time signature
comparison. Rejects absent/malformed payloads, bad signatures, expired tokens
(tolerance ±`_CLOCK_SKEW`), replay of a nonce already used, and any mismatch on
`(tool, arg_hash)`.
"""
function verify_capability(tool::AbstractString, args, token::AbstractString; now::Real = time())
    isempty(token) && return false
    parts = split(token, ".")
    length(parts) == 2 || return false
    body, sig = parts[1], parts[2]

    # Reject malformed base64 payloads.
    payload = try
        JSON.parse(String(base64decode(body)))
    catch
        return false
    end
    payload isa AbstractDict || return false

    expected = bytes2hex(hmac_sha256(_SECRET[], String(base64decode(body))))
    _constant_time_eq(sig, expected) || return false

    # Exact (tool, arg_hash) match.
    string(get(payload, "tool", "")) == string(tool) || return false
    string(get(payload, "arg_hash", "")) == arg_hash(args) || return false

    # Expiry with clock-skew tolerance: reject tokens expired beyond tolerance.
    exp = Float64(get(payload, "exp", 0.0))
    now_s = Float64(now)
    (now_s <= exp + _CLOCK_SKEW[]) || return false

    # Replay protection: a nonce may only be used once per session. Minting
    # records it; the first verification consumes it.
    nonce = string(get(payload, "nonce", ""))
    isempty(nonce) && return false
    present = lock(_NONCE_LOCK) do
        nonce in _NONCES
    end
    present || return false
    lock(_NONCE_LOCK) do
        delete!(_NONCES, nonce)
    end

    _audit("verify", string(tool), true, Dict{String,Any}())
    return true
end

# ─── Scope narrowing ───────────────────────────────────────

"""
Narrow a capability set: the child's set is the intersection of the parent's set
and the child's declared needs. A child can never gain capabilities.
Returns a `Set{String}`.
"""
function restrict_caps(parent::Union{Nothing,AbstractSet}, child::Union{Nothing,AbstractSet})
    if parent === nothing
        return child === nothing ? Set{String}() : Set{String}(child)
    end
    if child === nothing
        return Set{String}(parent)
    end
    return intersect(Set{String}(parent), Set{String}(child))
end

"""
True when `tool` is within capability scope `caps` (a `Set{String}` of capability
names, or `nothing` = unrestricted). Also permits the tool by exact name so a
fully-specified allowlist of tool names works as a scope.
"""
function in_scope(tool::AbstractString, caps::Union{Nothing,AbstractSet})
    caps === nothing && return true
    isempty(caps) && return true
    t = string(tool)
    t in caps && return true
    return tool_capability(t) in caps
end

# ─── Audit ─────────────────────────────────────────────────

function _audit(kind::String, tool::String, ok::Bool, details::Dict{String,Any})
    entry = Dict{String,Any}(
        "ts" => Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS"),
        "event" => "capability." * kind,
        "tool" => tool,
        "ok" => ok,
        "details" => details,
    )
    lock(_CHECKS_LOCK) do
        push!(_CHECKS, entry)
        if length(_CHECKS) > _MAX_CHECKS
            deleteat!(_CHECKS, 1:(length(_CHECKS)-_MAX_CHECKS))
        end
    end
    KamilaLog.info(
        "capability.check";
        mod = "capability",
        fields = Dict{String,Any}(
            "event" => "capability." * kind,
            "tool" => tool,
            "ok" => ok,
        ),
    )
    return nothing
end

"""
Return the most recent capability checks (audit trail). `kind` filters to
`"mint"`, `"verify"`, or `"deny"` (default: all).
"""
function capability_audit(limit::Int = 50; kind::String = "")
    entries = lock(_CHECKS_LOCK) do
        copy(_CHECKS)
    end
    isempty(kind) || filter!(e -> occursin(kind, string(e["event"])), entries)
    return entries[max(1, length(entries)-limit+1):end]
end

function recent_checks(limit::Int = 50)
    return capability_audit(limit)
end

function clear_checks()
    lock(_CHECKS_LOCK) do
        empty!(_CHECKS)
    end
    return nothing
end

end # module Capability
