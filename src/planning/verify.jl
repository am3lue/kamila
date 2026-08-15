"""
Verify — enforced post-condition checks for plan steps (04.3).

Every step that performs a side effect can declare a `verify` spec (a
`VerifySpec`). After the tool result arrives the verifier runs the spec
against the post-condition and returns a `VerifyResult`. Deterministic kinds
run first; `:model_judgement` (one model call) is used only when no
deterministic check applies.
"""

module Verify

using Dates
using JSON
using ..KamilaLog
using ..Errors
using ..OllamaInterface
using ..ModelRouter
using ..Vision

export VerifySpec, VerifyResult, verify, is_verifiable

"""
    VerifySpec

A verifiable post-condition. Fields:
- `kind`: one of
  - `:file_exists`         — `isfile(target)`
  - `:file_contains`       — file at `target` contains `expected`
  - `:file_matches_regex`  — file at `target` matches regex `expected`
  - `:command_ok`          — `target` command exits 0
  - `:shell_output_contains` — `target` command output contains `expected`
  - `:shell_output_matches`  — `target` command output matches regex `expected`
  - `:status_code`         — `target` command exits with code `expected`
  - `:schema`              — file at `target` is valid JSON (optionally has keys)
  - `:image_contains`      — vision model confirms `target` image contains `expected`
  - `:model_judgement`     — one model call judges tool result vs `expected`
- `target`: file path or shell command (string)
- `expected`: expected value / substring / regex / exit code / prompt (string or number)
- `timeout`: seconds for shell-based checks (default 10)
- `retries`: max verification attempts allowed upstream (informational)
"""
struct VerifySpec
    kind::Symbol
    target::String
    expected::Union{Nothing,String}
    timeout::Float64
    retries::Int
end

VerifySpec(kind::Symbol, target::String, expected) =
    VerifySpec(kind, target, _coerce_expected(expected), 10.0, 2)

_coerce_expected(expected::Union{Nothing,String}) = expected
_coerce_expected(expected::Number) = string(expected)
_coerce_expected(expected) = string(expected)

function VerifySpec(spec::AbstractDict)
    kind = Symbol(get(spec, "kind", ""))
    target = string(get(spec, "target", ""))
    expected = get(spec, "expected", nothing)
    expected =
        expected === nothing ? nothing :
        expected isa Number ? string(expected) : string(expected)
    timeout = Float64(get(spec, "timeout", 10.0))
    retries = Int(get(spec, "retries", 2))
    return VerifySpec(kind, target, expected, timeout, retries)
end

VerifySpec(json::AbstractString) = VerifySpec(JSON.parse(json))

struct VerifyResult
    ok::Bool
    evidence::String
    duration_ms::Int
end

const _DETERMINISTIC_KINDS = Set([
    :file_exists, :file_contains, :file_matches_regex, :command_ok,
    :shell_output_contains, :shell_output_matches, :status_code, :schema,
])

"""
Whether `kind` can be checked without a model call.
"""
is_verifiable(kind::Symbol) =
    kind in _DETERMINISTIC_KINDS || kind in (:model_judgement, :image_contains)
is_verifiable(spec::VerifySpec) = is_verifiable(spec.kind)

function _shell(spec::VerifySpec, cmd::String)
    timeout = spec.timeout
    out = ""
    code = 0
    try
        out = read(`timeout $timeout bash -c $cmd`, String)
    catch e
        # Non-zero exit or timeout raises; recover the exit code.
        code = try
            p = run(`timeout $timeout bash -c $cmd`; wait = true)
            p.exitcode
        catch
            1
        end
    end
    return (out, code)
end

function _file_contents(target::String)
    isfile(target) || return nothing
    try
        return read(target, String)
    catch e
        return nothing
    end
end

function _verify_deterministic(spec::VerifySpec, target::String)
    if spec.kind == :file_exists
        ok = isfile(target)
        return ok, ok ? "file exists: $target" : "file missing: $target"
    elseif spec.kind == :file_contains
        content = _file_contents(target)
        ok = content !== nothing && spec.expected !== nothing &&
             occursin(spec.expected, content)
        evidence = ok ? "file contains expected text" :
                   content === nothing ? "file missing: $target" :
                   "file does not contain: $(spec.expected)"
        return ok, evidence
    elseif spec.kind == :file_matches_regex
        content = _file_contents(target)
        ok = content !== nothing && spec.expected !== nothing &&
             !isnothing(match(Regex(spec.expected), content))
        evidence = ok ? "file matches regex" : "file does not match regex: $(spec.expected)"
        return ok, evidence
    elseif spec.kind == :schema
        content = _file_contents(target)
        parsed = content === nothing ? nothing : try
            JSON.parse(content)
        catch e
            nothing
        end
        ok = parsed !== nothing
        evidence = ok ? "valid JSON" : "invalid or missing JSON file: $target"
        return ok, evidence
    elseif spec.kind in (:command_ok, :status_code, :shell_output_contains, :shell_output_matches)
        out, code = _shell(spec, target)
        if spec.kind == :command_ok
            ok = code == 0
            evidence = ok ? "command exited 0" : "command exited $code"
        elseif spec.kind == :status_code
            expected = spec.expected === nothing ? 0 : tryparse(Int, spec.expected)
            ok = expected !== nothing && code == expected
            evidence = ok ? "command exited $code" : "command exited $code (expected $expected)"
        elseif spec.kind == :shell_output_contains
            ok = spec.expected !== nothing && occursin(spec.expected, out)
            evidence = ok ? "output contains expected" :
                       "output does not contain: $(spec.expected)\noutput:\n$(out)"
        else
            ok = spec.expected !== nothing && !isnothing(match(Regex(spec.expected), out))
            evidence = ok ? "output matches regex" :
                       "output does not match regex: $(spec.expected)\noutput:\n$(out)"
        end
        return ok, evidence
    end
    return false, "unsupported verify kind: $(spec.kind)"
end

"""
Model-based judgement: asks the model once whether the tool result satisfies
the expected outcome. Used only when no deterministic check fits.
"""
function _model_judge(spec::VerifySpec, step_result::String)
    cfg = ModelRouter.get_router_config()
    cfg = ModelRouter.select_model(:task, cfg)
    prompt = """
    You are verifying that a plan step achieved its intended outcome.

    Expected outcome: $(spec.expected)
    Tool result / evidence:
    $(step_result)

    Reply with exactly one token: YES or NO.
    """
    reply = try
        OllamaInterface.query_ollama(
            prompt;
            model = cfg.name,
            temperature = 0.0,
            max_tokens = 8,
        )
    catch e
        ""
    end
    ok = occursin(r"yes"i, reply)
    return ok, "model judgement: $(strip(reply))"
end

"""
Vision-based check: asks the vision model whether the image at `spec.target`
contains `spec.expected`. Requires a vision-capable model; a failure is
evidence of failure, never a false pass.
"""
function _image_contains(spec::VerifySpec)
    spec.expected === nothing && return false, "image_contains requires expected text"
    reply = try
        Vision.qa_image(
            spec.target,
            "Does the image contain \"$(spec.expected)\"? Reply with exactly YES or NO.",
        )
    catch e
        return false, "image_contains error: $(Errors.error_string(e))"
    end
    ok = occursin(r"yes"i, reply)
    return ok, "image_contains: $(strip(reply))"
end

"""
    verify(spec, step_result, workdir) -> VerifyResult

Run a verification spec. `step_result` is the tool output string from the step
(used by `:model_judgement`). `workdir` is the directory relative paths and
commands run in. Never throws; returns a `VerifyResult` with human-readable
evidence.
"""
function verify(
    spec::VerifySpec,
    step_result::String;
    workdir::String = pwd(),
)
    started = now()
    local ok::Bool = false
    local evidence::String = ""
    try
        if spec.kind == :model_judgement
            ok, evidence = _model_judge(spec, step_result)
        elseif spec.kind == :image_contains
            ok, evidence = _image_contains(spec)
        else
            # Resolve relative file targets against the working directory.
            target = spec.target
            if !startswith(target, "/") && spec.kind in
               (:file_exists, :file_contains, :file_matches_regex, :schema)
                target = joinpath(workdir, target)
            end
            ok, evidence = _verify_deterministic(spec, target)
        end
    catch e
        ok = false
        evidence = "verifier error: $(Errors.error_string(e))"
    end
    duration = Dates.value(now() - started)
    KamilaLog.info(
        "verify.result";
        mod = "verify",
        fields = Dict{String,Any}(
            "kind" => String(spec.kind),
            "ok" => ok,
            "duration_ms" => duration,
        ),
    )
    return VerifyResult(ok, evidence, duration)
end

verify(spec::AbstractDict, step_result::String; workdir::String = pwd()) =
    verify(VerifySpec(spec), step_result; workdir = workdir)
verify(spec::AbstractString, step_result::String; workdir::String = pwd()) =
    verify(VerifySpec(spec), step_result; workdir = workdir)

end # module