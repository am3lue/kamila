"""
Confirm — pluggable command-confirmation service.

Solves the `02.1-stdin-bridge-conflict`: `run_shell_command` must never call
`readline(stdin)` directly, because inside the bridge process stdin is the
JSON-RPC protocol channel. Instead, confirmation is routed through a backend:

  - `InteractiveConfirm` — the classic CLI prompt. The banner goes to **stderr**
    (never protocol stdout) and the answer is read from stdin. Used in
    interactive (non-bridge) mode.
  - `BridgeConfirm` — emits a `{"type":"confirm_request",...}` JSON event on
    stdout, registers a pending confirmation keyed by a request id, and waits
    for a `{"type":"confirm_response","id":...,"allow":bool}` line that the
    bridge main loop resolves (instead of treating it as a protocol request).

A pre-approval allowlist (`~/.kamila_allowlist.json`) is checked before any
prompting; allowlisted commands skip confirmation entirely. A confirmation that
gets no response times out to **deny**.
"""

module Confirm

using JSON
using ..KamilaLog

export confirm, set_backend, resolve_confirm, is_allowlisted, set_timeout_seconds

# Which backend is active: :interactive (CLI) or :bridge (JSON protocol).
const _BACKEND = Ref{Symbol}(:interactive)

# Pending bridge confirmations: request id => Channel{Bool}(1).
const _PENDING = Dict{String,Channel{Bool}}()
const _PENDING_LOCK = ReentrantLock()
const _NEXT_ID = Ref{Int}(0)

# How long a bridge confirmation waits for a response before defaulting to deny.
const _TIMEOUT_SECONDS = Ref{Float64}(30.0)

# Allowlist file path (env override keeps tests isolated).
const ALLOWLIST_FILE = Ref{String}(
    get(ENV, "KAMILA_ALLOWLIST_FILE", joinpath(homedir(), ".kamila_allowlist.json")),
)

function set_backend(backend::Symbol)
    _BACKEND[] = backend
    return nothing
end

function set_timeout_seconds(seconds::Real)
    _TIMEOUT_SECONDS[] = Float64(seconds)
    return nothing
end

"""
Read the allowlist and check whether `command` may run without prompting.
"""
function is_allowlisted(command::String)
    isfile(ALLOWLIST_FILE[]) || return false
    try
        data = JSON.parsefile(ALLOWLIST_FILE[])
        commands = get(data, "commands", Any[])
        return command in commands
    catch
        KamilaLog.debug("allowlist unreadable"; mod = "confirm")
        return false
    end
end

"""
Confirm `command` should be executed. `force=true` bypasses the prompt entirely.
`rule` names the permission rule that fired (for display in the bridge modal).
"""
function confirm(
    command::String;
    description::String = "",
    force::Bool = false,
    rule::String = "",
)
    force && return true
    is_allowlisted(command) && return true

    if _BACKEND[] == :bridge
        return _bridge_confirm(command; description, rule)
    end
    return _interactive_confirm(command; description, rule)
end

# ─── Interactive backend ──────────────────────────────────

function _interactive_confirm(command::String; description::String = "", rule::String = "")
    println(stderr, "\n⚠️  The agent wants to execute:")
    println(stderr, "   $command")
    if !isempty(description)
        println(stderr, "   Purpose: $description")
    end
    if !isempty(rule)
        println(stderr, "   Policy: $rule")
    end
    print(stderr, "Allow? (y/N/! = force): ")
    flush(stderr)
    user_response = strip(readline(stdin))
    return lowercase(user_response) == "y" || user_response == "!"
end

# ─── Bridge backend ───────────────────────────────────────

function _next_id()
    _NEXT_ID[] += 1
    return string(time_ns(), "-", _NEXT_ID[])
end

function _bridge_confirm(command::String; description::String = "", rule::String = "")
    id = _next_id()
    channel = Channel{Bool}(1)

    lock(_PENDING_LOCK) do
        _PENDING[id] = channel
    end

    # The banner and the request event both go to the protocol stdout — the TUI
    # renders them, and the user's y/N comes back as a confirm_response line.
    println(stderr, "⏳ Command requires confirmation (id=$id): $command")
    println(
        JSON.json(
            Dict(
                "type" => "confirm_request",
                "id" => id,
                "tool" => "run_shell_command",
                "command" => command,
                "description" => description,
                "rule" => rule,
            ),
        ),
    )
    flush(stdout)

    result = false
    timer = Timer(_TIMEOUT_SECONDS[]) do tm
        try
            put!(channel, false)  # timeout -> deny
        catch
        end
    end
    try
        result = take!(channel)
    finally
        close(timer)
        lock(_PENDING_LOCK) do
            delete!(_PENDING, id)
        end
    end
    return result
end

"""
Resolve a pending bridge confirmation with the user's decision. Called by the
bridge main loop when it receives a `confirm_response` line.
"""
function resolve_confirm(id::String, allow::Bool)
    channel = lock(_PENDING_LOCK) do
        get(_PENDING, id, nothing)
    end
    if channel === nothing
        KamilaLog.warn(
            "confirm_response for unknown id";
            mod = "confirm",
            fields = Dict("id" => id),
        )
        return nothing
    end
    try
        put!(channel, allow)
    catch
    end
    return nothing
end

end # module Confirm
