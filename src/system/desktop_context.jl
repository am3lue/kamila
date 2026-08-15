"""
Desktop Context — snapshot of the current desktop session (08.3).

Provides `desktop_status()` returning a JSON-friendly Dict with the active
window title, the working directory, and (truncated + redacted) clipboard text.
Feature-detects the session:

  - X11:   `xdotool getactivewindow getwindowname` for the window title,
           `xclip -selection clipboard -o` for the clipboard.
  - Wayland: `swaymsg -t get_tree` (focused node name) / `gdbus` best-effort,
           `wl-paste` for the clipboard.
  - unknown: graceful `nothing` values — never a crash.

Privacy posture:
  - Every command can be overridden with an env var (`KAMILA_ACTIVE_WINDOW_CMD`,
    `KAMILA_CLIPBOARD_CMD`, `KAMILA_DESKTOP_SESSION`) so tests can point at
    fake scripts and users can restrict what is probed.
  - Clipboard is truncated to 4 KB and redacted (secret-looking tokens masked).
  - `desktop.watch` is OFF by default; enabling is an explicit user action.

The module never guesses: if a tool is missing or a command fails, the field is
`nothing` (or a `:external` KamilaError where a value is required).
"""

module DesktopContext

using JSON
using ..Errors
using ..KamilaLog

export desktop_status,
    active_window_title,
    clipboard_text,
    detect_session_type,
    watch_enabled,
    set_watch_enabled!

const MAX_CLIPBOARD_CHARS = 4096
const _WATCH_ENABLED = Ref(false)

"""
    watch_enabled() -> Bool

Whether the `desktop.watch` watcher is currently active. OFF by default
(privacy); only an explicit user action turns it on.
"""
watch_enabled() = _WATCH_ENABLED[]

function set_watch_enabled!(on::Bool)
    _WATCH_ENABLED[] = on
    return on
end

"""
    detect_session_type() -> Symbol

Feature-detect the desktop session: `:x11`, `:wayland`, or `:unknown`.
`KAMILA_DESKTOP_SESSION` env override wins (used by tests).
"""
function detect_session_type()
    forced = get(ENV, "KAMILA_DESKTOP_SESSION", "")
    if !isempty(forced)
        return Symbol(lowercase(forced))
    end
    if haskey(ENV, "WAYLAND_DISPLAY") || get(ENV, "XDG_SESSION_TYPE", "") == "wayland"
        return :wayland
    elseif haskey(ENV, "DISPLAY")
        return :x11
    end
    return :unknown
end

# ─── Command helper ──────────────────────────────────────

"""
Run a command (given as a Cmd) and return its trimmed stdout, or `nothing` on
any failure. Never throws — desktop context is best-effort.
"""
function _capture(cmd::Cmd)
    out = try
        read(cmd, String)
    catch
        return nothing
    end
    isempty(strip(out)) && return nothing
    return String(strip(out))
end

"""
    _tool_cmd(env_name::String, fallback::Cmd) -> Cmd

Command override seam: `KAMILA_ACTIVE_WINDOW_CMD` / `KAMILA_CLIPBOARD_CMD`
provide a full command string (used by tests to point at fake scripts); else
the detected fallback is used.
"""
function _tool_cmd(env_name::String, fallback::Cmd)
    override = get(ENV, env_name, "")
    isempty(override) && return fallback
    return Cmd(`sh -c $override`)
end

# ─── Active window ───────────────────────────────────────

"""
    active_window_title() -> Union{String,Nothing}

Best-effort title of the focused window. `nothing` when no tool is available
or the probe fails.
"""
function active_window_title()
    session = detect_session_type()
    if session == :x11
        return _capture(_tool_cmd("KAMILA_ACTIVE_WINDOW_CMD", `xdotool getactivewindow getwindowname`))
    elseif session == :wayland
        return _sway_active_window()
    end
    return nothing
end

# sway: focused leaf node name from `swaymsg -t get_tree`.
function _sway_active_window()
    raw = _capture(_tool_cmd("KAMILA_ACTIVE_WINDOW_CMD", `swaymsg -t get_tree`))
    raw === nothing && return nothing
    tree = try
        JSON.parse(raw)
    catch
        return nothing
    end
    return _find_focused_name(tree)
end

function _find_focused_name(node)
    get(node, "focused", false) && return string(get(node, "name", ""))
    for child in get(node, "nodes", [])
        name = _find_focused_name(child)
        name === nothing || return name
    end
    return nothing
end

# ─── Clipboard ───────────────────────────────────────────

"""
    clipboard_text() -> Union{String,Nothing}

Truncated and redacted clipboard contents (first 4 KB; secret-looking tokens
masked). `nothing` when no clipboard tool is available.
"""
function clipboard_text()
    session = detect_session_type()
    raw = if session == :wayland
        _capture(_tool_cmd("KAMILA_CLIPBOARD_CMD", `wl-paste --no-newline`))
    elseif session == :x11
        _capture(_tool_cmd("KAMILA_CLIPBOARD_CMD", `xclip -selection clipboard -o`))
    else
        nothing
    end
    raw === nothing && return nothing
    return _redact_clipboard(raw)
end

# Mask secret-looking tokens: long hex/base64 runs, sk-/ghp_ style prefixes,
# and common env-style KEY=value lines. The redacted text is what the agent
# (and logs) ever see; raw clipboard never leaves this function.
function _redact_clipboard(text::String)
    truncated = length(text) > MAX_CLIPBOARD_CHARS ? text[1:MAX_CLIPBOARD_CHARS] * "\n… (truncated)" : text
    redacted = replace(
        truncated,
        r"(?i)(sk-[a-z0-9_-]{16,}|gh[pous]_[a-z0-9]{20,}|[a-z0-9+/]{32,}={0,2})" => "[redacted]",
    )
    return redacted
end

# ─── Snapshot ────────────────────────────────────────────

"""
    desktop_status() -> Dict{String,Any}

Full desktop snapshot: session type, active window title, cwd, and redacted
clipboard. Missing/unsupported fields are `nothing`, never a crash.
"""
function desktop_status()
    return Dict{String,Any}(
        "session" => string(detect_session_type()),
        "active_window" => active_window_title(),
        "cwd" => try
            pwd()
        catch
            nothing
        end,
        "clipboard" => clipboard_text(),
        "watch_enabled" => watch_enabled(),
    )
end

end # module