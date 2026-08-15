"""
TuneImport — build a LoRA-friendly chat dataset from 07.1 experience (07.2).

Reads a `07.1` experience JSONL export (`Experience.export_rows`) and converts
verified rows into `{system, user, assistant}` exemplars, then dedupes,
applies quality heuristics (length, verification, a conservative PII
heuristic) and caps the dataset size. The output is a plain JSONL that a
fine-tuning job (`src/learning/tune/train.jl`) and the eval harness
(`src/learning/eval.jl`) can consume.

Design notes:
- Only `verified=true` rows become exemplars by default (failed attempts are
  training negatives for `07.3`, not tuned-in behavior).
- Dedupe key is the (prompt, tool, result) triple so repeated tasks collapse.
- PII heuristic is intentionally conservative and regex-based: emails, phone
  numbers, and long secret-looking tokens are excluded. It is a *heuristic*,
  not a guarantee — `tuning-notes.md` documents this honestly.
- `cap` bounds the first-pass dataset (e.g. ≤ 2,000 examples).
"""

module TuneImport

using JSON
using ..KamilaLog

export import_experience, build_exemplar, quality_ok, dedupe_exemplars

# ─── Quality heuristics ────────────────────────────────────

const MIN_PROMPT_LEN = 8
const MIN_RESULT_LEN = 8
const MAX_EXEMPLAR_LEN = 8192

# Conservative, intentionally simple PII/sensitive-data patterns.
const PII_PATTERNS = [
    r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}",        # email
    r"\b\d{3}[-.\s]?\d{3}[-.\s]?\d{4}\b",                     # phone
    r"\b(sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|AKIA[A-Z0-9]{16})\b",  # keys
]

"""
    has_pii(text::String)

True when the text matches a conservative PII/sensitive-data heuristic.
"""
function has_pii(text::String)
    for pat in PII_PATTERNS
        occursin(pat, text) && return true
    end
    return false
end

"""
    quality_ok(row::Dict; verified_only::Bool=true)

Quality gate for a single exported experience row: must be verified (when
`verified_only`), have a non-trivial prompt/result, and contain no heuristic
PII match.
"""
function quality_ok(row::AbstractDict; verified_only::Bool = true)
    verified_only && !Bool(get(row, "verified", false)) && return false
    prompt = string(get(row, "prompt", ""))
    result = string(get(row, "result", ""))
    length(strip(prompt)) < MIN_PROMPT_LEN && return false
    length(strip(result)) < MIN_RESULT_LEN && return false
    length(prompt) > MAX_EXEMPLAR_LEN && return false
    length(result) > MAX_EXEMPLAR_LEN && return false
    has_pii(prompt) && return false
    has_pii(result) && return false
    return true
end

# ─── Exemplar building ─────────────────────────────────────

const DEFAULT_SYSTEM_PROMPT = """You are KAMILA — a warm, intelligent AI
assistant on Linux that helps with coding, electronics, and everyday tasks.
Respond with concrete, working output."""

"""
    build_exemplar(row::Dict; system::String=DEFAULT_SYSTEM_PROMPT)

Convert one experience row into a chat exemplar `{system, user, assistant}`.
The prompt becomes the user turn; the tool result is the assistant answer.
A short goal prefix is prepended when present and distinct from the prompt.
"""
function build_exemplar(
    row::AbstractDict;
    system::String = DEFAULT_SYSTEM_PROMPT,
)
    prompt = strip(string(get(row, "prompt", "")))
    result = strip(string(get(row, "result", "")))
    goal = strip(string(get(row, "goal", "")))
    tool = string(get(row, "tool", ""))

    user = prompt
    if !isempty(goal) && !occursin(goal, prompt)
        user = "$goal\n\n$prompt"
    end

    return Dict{String,Any}(
        "system" => system,
        "user" => user,
        "assistant" => result,
        "tool" => tool,
        "verified" => Bool(get(row, "verified", false)),
    )
end

"""
    dedupe_exemplars(exemplars)

Collapse exemplars that share a `(user, assistant)` content pair.
"""
function dedupe_exemplars(exemplars::Vector{<:AbstractDict})
    seen = Set{Tuple{String,String}}()
    out = Dict{String,Any}[]
    for ex in exemplars
        key = (string(get(ex, "user", "")), string(get(ex, "assistant", "")))
        key in seen && continue
        push!(seen, key)
        push!(out, ex)
    end
    return out
end

# ─── Import ────────────────────────────────────────────────

"""
    import_experience(export_path::String; out_path, cap=2000,
                      verified_only=true, system=DEFAULT_SYSTEM_PROMPT)

Read `07.1` experience JSONL at `export_path`, convert verified rows to chat
exemplars, dedupe, cap, and write JSONL to `out_path`. Returns the number of
exemplars written.
"""
function import_experience(
    export_path::String;
    out_path::String,
    cap::Int = 2000,
    verified_only::Bool = true,
    system::String = DEFAULT_SYSTEM_PROMPT,
)
    exemplars = Dict{String,Any}[]
    open(export_path, "r") do io
        for line in eachline(io)
            isempty(strip(line)) && continue
            row = try
                JSON.parse(line)
            catch
                continue
            end
            row isa AbstractDict || continue
            quality_ok(row; verified_only = verified_only) || continue
            push!(exemplars, build_exemplar(row; system = system))
            length(exemplars) >= cap && break
        end
    end

    exemplars = dedupe_exemplars(exemplars)
    if length(exemplars) > cap
        exemplars = exemplars[1:cap]
    end

    open(out_path, "w") do io
        for ex in exemplars
            write(io, JSON.json(ex) * "\n")
        end
    end
    KamilaLog.info(
        "tune.import: wrote $(length(exemplars)) exemplars to $out_path";
        mod = "tune",
    )
    return length(exemplars)
end

"""
    import_jsonl(jsonl_path::String)

Read a plain exemplar JSONL file (as written by `import_experience`) back into
a vector of Dicts. Used by the eval harness and tests.
"""
function import_jsonl(jsonl_path::String)
    rows = Dict{String,Any}[]
    open(jsonl_path, "r") do io
        for line in eachline(io)
            isempty(strip(line)) && continue
            row = try
                JSON.parse(line)
            catch
                continue
            end
            row isa AbstractDict && push!(rows, row)
        end
    end
    return rows
end

end # module
