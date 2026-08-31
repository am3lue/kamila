"""
Desktop Context — snapshot of the current desktop session (08.3).

Provides `desktop_status()` returning a JSON-friendly Dict with the active
window title, the working directory, and (truncated + redacted) clipboard text.
Feature-detects the session:

  - X11:   `xdotool getactivewindow getwindowname` for the window title,
           `xclip -selection clipboard -o` (fallback `xsel -b -o`) for the
           clipboard.
  - Wayland + KDE Plasma: `kdotool getactivewindow getwindowname` when
           installed, otherwise a temporary KWin scripting module loaded via
           `qdbus6`/`qdbus` (`Scripting.loadScript` + `Script.run`, result read
           back from the kwin journal); clipboard via the Klipper D-Bus
           interface (`org.kde.klipper /klipper getClipboardContents`).
  - Wayland (other compositors): `swaymsg -t get_tree` (focused node name),
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

# ─── KDE Plasma detection ────────────────────────────────

"""
    _is_kde_plasma() -> Bool

True when the running desktop is KDE Plasma (Wayland or X11). Uses the same
env variables the session itself sets. Overridable via `KAMILA_DESKTOP_KDE`.
"""
function _is_kde_plasma()
    forced = get(ENV, "KAMILA_DESKTOP_KDE", "")
    if !isempty(forced)
        return lowercase(forced) in ("1", "true", "yes")
    end
    desktop = get(ENV, "XDG_CURRENT_DESKTOP", "")
    session = get(ENV, "DESKTOP_SESSION", "")
    kde_full = get(ENV, "KDE_FULL_SESSION", "")
    return occursin("KDE", desktop) || startswith(session, "plasma") || kde_full == "true"
end

"""
    _find_qdbus() -> Union{Cmd,Nothing}

The `qdbus6` binary (Plasma 6), falling back to `qdbus`. `nothing` when
neither exists.
"""
function _find_qdbus()
    q6 = Sys.which("qdbus6")
    q6 === nothing || return `$q6`
    q = Sys.which("qdbus")
    q === nothing && return nothing
    return `$q`
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
        if _is_kde_plasma()
            return _kde_active_window()
        end
        return _sway_active_window()
    end
    return nothing
end

# KDE Plasma: prefer kdotool; fall back to a temporary KWin scripting module.
# The KWin-script path is heavy (spawns qdbus subprocesses, writes a temp .js,
# sleep(0.4), then scrapes the journal), so its result is cached for a short TTL
# to avoid ~1s of child-process churn when a desktop watcher polls frequently.
const _KWIN_TITLE_CACHE = Ref{Union{Nothing,Tuple{Float64,Union{Nothing,String}}}}(nothing)
const _KWIN_TTL = 2.0

function _kde_active_window()
    title = _capture(_tool_cmd("KAMILA_ACTIVE_WINDOW_CMD", `kdotool getactivewindow getwindowname`))
    title === nothing || return title

    cached = _KWIN_TITLE_CACHE[]
    if cached !== nothing
        t0, val = cached
        (time() - t0) < _KWIN_TTL && return val
    end
    val = _kde_kwin_script_title()
    _KWIN_TITLE_CACHE[] = (time(), val)
    return val
end

# Load a small KWin scripting module that prints the focused window caption,
# run it, capture the result from the kwin journal, then unload it. This is
# the only non-interactive path on Plasma 6 where `queryWindowInfo` would
# block on user input. Best-effort: any failure returns `nothing`.
function _kde_kwin_script_title()
    qdbus = _find_qdbus()
    qdbus === nothing && return nothing
    script = tempname() * ".js"
    write(script, "print(\"KAMILA_ACTIVE=\" + (workspace.activeWindow ? workspace.activeWindow.caption : \"none\"));\n")
    try
        id = _capture(`$qdbus org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript $script`)
        id === nothing && return nothing
        id = strip(id)
        isempty(id) && return nothing
        run(`$qdbus org.kde.KWin /Scripting/Script$id org.kde.kwin.Script.run`)
        sleep(0.4)
        title = _journal_kwin_title()
        try
            run(`$qdbus org.kde.KWin /Scripting/Script$id org.kde.kwin.Script.stop`)
        catch
        end
        try
            run(`$qdbus org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript $script`)
        catch
        end
        return title
    catch
        return nothing
    finally
        isfile(script) && rm(script; force = true)
    end
end

# Scan the kwin journal for the most recent `KAMILA_ACTIVE=` marker we printed.
function _journal_kwin_title()
    out = _capture(`journalctl _COMM=kwin_wayland --since "20 seconds ago" --no-pager -o cat`)
    out === nothing && return nothing
    title = nothing
    for line in reverse(split(out, "\n"))
        idx = findfirst("KAMILA_ACTIVE=", line)
        if idx !== nothing
            val = strip(line[(last(idx) + 1):end])
            title = val == "none" ? nothing : val
            break
        end
    end
    return title
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
        if _is_kde_plasma()
            _kde_clipboard()
        else
            _capture(_tool_cmd("KAMILA_CLIPBOARD_CMD", `wl-paste --no-newline`))
        end
    elseif session == :x11
        raw_cmd = _tool_cmd("KAMILA_CLIPBOARD_CMD", `xclip -selection clipboard -o`)
        raw_override = get(ENV, "KAMILA_CLIPBOARD_CMD", "") != ""
        raw = if raw_override
            _capture(raw_cmd)
        else
            xc = _capture(raw_cmd)
            xc === nothing ? _capture(`xsel -b -o`) : xc
        end
    else
        nothing
    end
    raw === nothing && return nothing
    return _redact_clipboard(raw)
end

# KDE Plasma clipboard via the Klipper D-Bus interface (qdbus6 on Plasma 6).
function _kde_clipboard()
    qdbus = _find_qdbus()
    qdbus === nothing && return nothing
    return _capture(_tool_cmd("KAMILA_CLIPBOARD_CMD", `$qdbus org.kde.klipper /klipper org.kde.klipper.klipper.getClipboardContents`))
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