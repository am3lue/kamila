"""
ResponseParser — the single canonical text→tool-call parser (02.5).

Both `Agent` and `AgentStream` delegate here so there is exactly one
implementation. Hardening goals:

  - Never crash on any input (all paths are `catch`-guarded).
  - Extract candidate JSON blocks by balanced-brace scanning that *respects
    strings and escapes* (so nested `{}` and `", }"` inside values survive),
    never a greedy `{.*}` or a global regex.
  - Repair trailing commas with a string-aware tokenizer — commas directly
    before `}`/`]` *outside* strings are dropped; commas inside string values
    are left untouched.
  - Extract `thought` from the surrounding text (fences removed), falling back
    to a `thought`/`reasoning`/`explanation` key inside the JSON when the
    surrounding text is empty.
"""

module ResponseParser

using JSON
using ..KamilaLog

export parse_tool_response, parse_response, repair_trailing_commas, extract_candidates

const MAX_SCAN_CHARS = 50_000

"""
Try to parse a candidate as JSON. On failure, attempt string-aware trailing-comma
repair; if that also fails, record a structured `parse_error` log and return
`nothing` so the caller moves to the next candidate.
"""
function try_parse(json_str::AbstractString)
    try
        return JSON.parse(json_str)
    catch e1
        repaired = repair_trailing_commas(json_str)
        if repaired != json_str
            try
                return JSON.parse(repaired)
            catch e2
                log_parse_error(e2)
                return nothing
            end
        end
        log_parse_error(e1)
        return nothing
    end
end

function log_parse_error(e)
    KamilaLog.debug("parse_error"; mod = "parser", fields = Dict("error" => string(e)))
    return nothing
end

"""
Remove trailing commas that appear directly before `}` or `]` *outside of
strings*. Walks the input char-by-char tracking string state and escapes, so a
value like `"hi, then"` is never corrupted.
"""
function repair_trailing_commas(json_str::AbstractString)
    io = IOBuffer()
    in_string = false
    escaped = false
    n = ncodeunits(json_str)
    i = 1
    while i <= n
        c = json_str[i]
        if in_string
            write(io, c)
            if escaped
                escaped = false
            elseif c == '\\'
                escaped = true
            elseif c == '"'
                in_string = false
            end
            i = nextind(json_str, i)
            continue
        end
        if c == '"'
            in_string = true
            write(io, c)
            i = nextind(json_str, i)
            continue
        end
        if c == ','
            j = nextind(json_str, i)
            while j <= n && isspace(json_str[j])
                j = nextind(json_str, j)
            end
            if j <= n && (json_str[j] == '}' || json_str[j] == ']')
                i = nextind(json_str, i)
                continue
            end
        end
        write(io, c)
        i = nextind(json_str, i)
    end
    return String(take!(io))
end

"""
Scan `text` and append balanced `{...}` blocks (top-level objects) to
`candidates`. Respects strings and escapes so braces inside string values don't
count. Caps the scan at `MAX_SCAN_CHARS`.
"""
function scan_balanced!(candidates::Vector{String}, text::AbstractString)
    n = min(ncodeunits(text), MAX_SCAN_CHARS)
    # Back off to a valid char boundary if the cap splits a multi-byte char.
    n < ncodeunits(text) && (n = prevind(text, n + 1))
    depth = 0
    in_string = false
    escaped = false
    start = 0
    i = 1
    while i <= n
        c = text[i]
        if in_string
            if escaped
                escaped = false
            elseif c == '\\'
                escaped = true
            elseif c == '"'
                in_string = false
            end
        else
            if c == '"'
                in_string = true
            elseif c == '{'
                depth += 1
                if depth == 1
                    start = i
                end
            elseif c == '}'
                depth -= 1
                if depth == 0 && start > 0
                    push!(candidates, text[start:i])
                    start = 0
                end
            end
        end
        i = nextind(text, i)
    end
    return nothing
end

# Fences: ```json ... ``` (with optional language tag). Returns the full matches
# so callers can strip them from surrounding text for `thought`.
const _FENCE_RE = r"```[^\n]*\n?(.*?)\n?```"s

"""
Extract candidate JSON strings from `text`:
  1. JSON inside markdown fences, in document order.
  2. If no fenced JSON found, balanced-brace scan of the whole text.
Returns `(candidates, fence_blocks)` — the fence full-match strings are used to
derive the surrounding-text `thought`.
"""
function extract_candidates(text::AbstractString)
    candidates = String[]
    fence_blocks = String[]
    for m in eachmatch(_FENCE_RE, text)
        push!(fence_blocks, m.match)
        content = m.captures[1]
        if content !== nothing
            scan_balanced!(candidates, content)
        end
    end
    if isempty(candidates)
        scan_balanced!(candidates, text)
    end
    return candidates, fence_blocks
end

"""
Extract the tool call from a parsed JSON object. Recognizes alternate key names
for tool and args (the same set the legacy parsers accepted).
"""
function extract_tool(data)
    tool_name = ""
    for key in ["tool", "name", "function", "tool_name", "call", "command"]
        if haskey(data, key) && data[key] isa String
            tool_name = data[key]
            break
        end
    end
    isempty(tool_name) && return (false, "", Dict{String,Any}(), "")

    args = Dict{String,Any}()
    for key in ["args", "arguments", "parameters", "params", "input", "props"]
        if haskey(data, key) && (data[key] isa Dict || data[key] isa AbstractDict)
            args = Dict{String,Any}(String(k) => v for (k, v) in data[key])
            break
        end
    end
    if isempty(args)
        args = Dict{String,Any}(String(k) => v for (k, v) in data)
        for key in [
            "tool",
            "name",
            "function",
            "tool_name",
            "call",
            "command",
            "thought",
            "reasoning",
            "explanation",
        ]
            delete!(args, key)
        end
    end
    return (true, tool_name, args, thought_from(data))
end

function thought_from(data)
    for key in ["thought", "reasoning", "explanation"]
        if haskey(data, key) && data[key] isa String
            return data[key]
        end
    end
    return ""
end

"""
Canonical entry point. Returns `(is_tool, tool_name, args, thought, error)`.
`error` is `nothing` on success (or when no JSON was found); a short message on
a final parse failure.
"""
function parse_tool_response(text::AbstractString)
    clean_response = String(strip(text))
    isempty(clean_response) && return (false, "", Dict{String,Any}(), "", nothing)

    candidates, fence_blocks = extract_candidates(clean_response)
    isempty(candidates) && return (false, "", Dict{String,Any}(), clean_response, nothing)

    # Thought = surrounding text (fences removed). When no fences matched, the
    # bare-JSON candidate is removed so a JSON-only response yields "" and falls
    # back to the JSON `thought` key.
    thought = clean_response
    for block in fence_blocks
        thought = replace(thought, block => "")
    end
    if isempty(fence_blocks)
        for cand in candidates
            thought = replace(thought, cand => "")
        end
    end
    thought = strip(thought)

    for json_str in candidates
        data = try_parse(json_str)
        data === nothing && continue
        is_tool, tool_name, args, json_thought = extract_tool(data)
        if is_tool
            final_thought = isempty(thought) ? json_thought : thought
            return (true, tool_name, args, final_thought, nothing)
        end
    end

    return (false, "", Dict{String,Any}(), clean_response, nothing)
end

"""
Backward-compatible 4-tuple wrapper used by `Agent.parse_response` and
`AgentStream.parse_response` (`(is_tool, tool_name, args, thought)`).
"""
function parse_response(text::String)
    is_tool, tool_name, args, thought, _ = parse_tool_response(text)
    return (is_tool, tool_name, args, thought)
end

end # module ResponseParser
