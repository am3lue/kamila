"""
KamilaLog — leveled, structured, routeable logging.

Writes to stderr by default so the bridge's stdout JSON-RPC protocol stream is
never polluted by log traffic. Supports:

  - Levels: debug < info < warn < error < fatal (default: info).
  - `KAMILA_LOG` env override for the level (e.g. `KAMILA_LOG=debug`).
  - `KAMILA_LOG_FORMAT=json` for
    `{"ts","level","origin","kind","msg","fields",...}` lines (the module
    field is `origin`; `kind` is the event category), otherwise human-readable
    `[level] origin[kind]: msg field=value`.
  - `KAMILA_LOG_FILE` for an optional file sink with simple size-based rotation
    (archive at 5 MB, keep 3 archives).
  - A thread-local `context` (e.g. a bridge request id) so multi-step work is
    traceable end-to-end.
"""

module KamilaLog

using Dates
using Printf

export LogLevel,
    Level,
    debug,
    info,
    warn,
    error,
    fatal,
    log,
    log_level,
    set_context,
    with_context,
    current_context,
    rotation_files

const DEBUG = 10
const INFO = 20
const WARN = 30
const ERROR = 40
const FATAL = 50

const _LEVEL_NAMES = Dict(
    DEBUG => "debug",
    INFO => "info",
    WARN => "warn",
    ERROR => "error",
    FATAL => "fatal",
)

const _LEVEL = Ref{Int}(INFO)
const _FORMAT_JSON = Ref{Bool}(false)
const _FILE_IO = Ref{Union{Nothing,IOStream}}(nothing)
const _FILE_PATH = Ref{String}("")
const _FILE_LOCK = ReentrantLock()

# Thread-local context (e.g. bridge request id).
const _CONTEXT = Ref{Any}(nothing)
const _CONTEXT_LOCK = ReentrantLock()
const _MAX_FILE_BYTES = 5 * 1024 * 1024
const _MAX_ARCHIVES = 3

"""
Parse a level name ("debug", "info", ...) to its integer rank. Unknown names
fall back to `info`.
"""
function parse_level(name::AbstractString)
    lower = lowercase(strip(name))
    for (rank, lname) in _LEVEL_NAMES
        lname == lower && return rank
    end
    return INFO
end

function initialize()
    level = get(ENV, "KAMILA_LOG", "")
    if !isempty(level)
        _LEVEL[] = parse_level(level)
    end

    format = get(ENV, "KAMILA_LOG_FORMAT", "")
    _FORMAT_JSON[] = lowercase(strip(format)) == "json"

    file = get(ENV, "KAMILA_LOG_FILE", "")
    if !isempty(file)
        dir = dirname(file)
        if !isempty(dir) && !isdir(dir)
            try
                mkpath(dir)
            catch e
            end
        end
        try
            open_file_sink(file)
        catch e
            error("KamilaLog: cannot open log file $file: $e")
        end
    end
    return nothing
end

function set_level(level::Union{Int,AbstractString})
    _LEVEL[] = level isa Int ? level : parse_level(level)
    return _LEVEL[]
end

log_level() = _LEVEL[]

function set_json_format(json::Bool)
    _FORMAT_JSON[] = json
    return json
end

is_json_format() = _FORMAT_JSON[]

"""
Open (or reopen) the file sink. Rotates existing archives first.
"""
function open_file_sink(file::AbstractString)
    lock(_FILE_LOCK) do
        if _FILE_IO[] !== nothing
            try
                close(_FILE_IO[])
            catch e
            end
        end
        _FILE_IO[] = open(file, "a")
        _FILE_PATH[] = String(file)
    end
    return _FILE_IO[]
end

function close_file_sink()
    lock(_FILE_LOCK) do
        if _FILE_IO[] !== nothing
            try
                close(_FILE_IO[])
            catch e
            end
            _FILE_IO[] = nothing
            _FILE_PATH[] = ""
        end
    end
    return nothing
end

"""
Rotate the active log file: archive the current contents to `<file>.1` (shifted
up on each rotation) and truncate the active file. Keep `_MAX_ARCHIVES`.
"""
function rotate!(file::AbstractString)
    lock(_FILE_LOCK) do
        for i = _MAX_ARCHIVES:-1:1
            src = i == 1 ? file : "$file.$(i - 1)"
            dst = "$file.$i"
            if isfile(src)
                try
                    mv(src, dst; force = true)
                catch e
                end
            end
        end
        if _FILE_IO[] !== nothing
            try
                close(_FILE_IO[])
            catch e
            end
            _FILE_IO[] = open(file, "a")
        end
    end
    return nothing
end

rotation_files(file::AbstractString) = String["$file.$i" for i = 1:_MAX_ARCHIVES]

function _file_size(file::AbstractString)
    try
        return filesize(file)
    catch
        return 0
    end
end

"""
Write a line to all enabled sinks. `fields` must be a `Dict{String,<:Any}` or
`nothing`. `kind` categorizes the event (e.g. "request", "stream", "tool",
"memory", "security", "system", "error", "lifecycle") so entries are
filterable by origin (`mod`), kind, what (`msg`) and criticality (`level`).
Returns `nothing`.
"""
function write_line(level::Int, mod::String, msg::String, fields; kind::String = "log")
    if _FORMAT_JSON[]
        entry = Dict{String,Any}(
            "ts" => string(now()),
            "level" => get(_LEVEL_NAMES, level, "info"),
            "origin" => mod,
            "kind" => kind,
            "msg" => msg,
        )
        ctx = current_context()
        if ctx !== nothing
            entry["context"] = ctx
        end
        if fields isa AbstractDict && !isempty(fields)
            entry["fields"] = fields
        end
        line = JSON.json(entry)
    else
        lname = get(_LEVEL_NAMES, level, "info")
        ctx = current_context()
        ctx_part = ctx === nothing ? "" : " [$ctx]"
        fields_part = ""
        if fields isa AbstractDict && !isempty(fields)
            kv = join([string(k, "=", v) for (k, v) in fields], " ")
            fields_part = " $kv"
        end
        line = "[$lname] $mod[$kind]$ctx_part: $msg$fields_part"
    end

    println(stderr, line)
    flush(stderr)

    file_io = _FILE_IO[]
    if file_io !== nothing
        try
            write(file_io, line * "\n")
            flush(file_io)
        catch e
        end
    end
    return nothing
end

function _rotate_if_needed()
    lock(_FILE_LOCK) do
        file = _FILE_PATH[]
        isempty(file) && return
        if _file_size(file) >= _MAX_FILE_BYTES
            rotate!(file)
        end
    end
    return nothing
end

"""
Set the thread-local logging context (e.g. a request id). Returns the previous
context so callers can restore it.
"""
function set_context(ctx)
    lock(_CONTEXT_LOCK) do
        old = _CONTEXT[]
        _CONTEXT[] = ctx
        return old
    end
end

current_context() =
    lock(_CONTEXT_LOCK) do
        _CONTEXT[]
    end

"""
Run `f` with `ctx` as the logging context, restoring the previous context after.
"""
function with_context(f::Function, ctx)
    old = set_context(ctx)
    try
        return f()
    finally
        _CONTEXT[] = old
    end
end

# ─── Leveled API ──────────────────────────────────────────

function log(level::Int, msg::AbstractString; mod::String = "kamila", kind::String = "log", fields = nothing)
    level >= _LEVEL[] || return nothing
    _rotate_if_needed()
    write_line(level, mod, String(msg), fields; kind = kind)
    return nothing
end

debug(msg::AbstractString; kwargs...) = log(DEBUG, msg; kwargs...)
info(msg::AbstractString; kwargs...) = log(INFO, msg; kwargs...)
warn(msg::AbstractString; kwargs...) = log(WARN, msg; kwargs...)
error(msg::AbstractString; kwargs...) = log(ERROR, msg; kwargs...)
fatal(msg::AbstractString; kwargs...) = log(FATAL, msg; kwargs...)

# Load JSON for the file formatter.
using JSON

initialize()

end # module KamilaLog
