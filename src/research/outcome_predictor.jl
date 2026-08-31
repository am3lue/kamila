"""
OutcomePredictor — research prototype for `09.1-world-model` (NOT a ship
commitment; see docs/plans/09-agi-research/09.1-world-model.md).

Hypothesis under test: a lightweight outcome predictor — "if I run this tool
with these args, what state change / success occurs?" — trained on
`07.1-experience-store` verified outcomes, can flag steps whose predicted
outcome likely fails BEFORE executing them.

Honest scope of this prototype:
  - The predictor is a **nearest-example** model: it looks up prior
    `(tool, args)` experience rows (exact-args match first, then nearest
    prompt/result embedding). It returns a prediction only when it has
    evidence; it NEVER guesses on unseen tool/args pairs.
  - `evaluate` measures coverage, accuracy, and the false-veto rate on a
    held-out split, against a majority-class baseline — the quantities the
    go/no-go rubric needs.

Use note: predictions are advisory only. Per the plan, a predicted failure
only RAISES a flag; it never auto-denies execution without the normal
permission gate.
"""

module OutcomePredictor

using Dates
using JSON
using Random
using ..Errors
using ..KamilaLog
using ..MemoryDB
using ..Vectors
using ..Experience

export OutcomeSample,
    predict_outcome,
    build_lookup,
    evaluate,
    majority_baseline,
    load_experience_samples

struct OutcomeSample
    tool::String
    args::Any
    result::String
    verified::Bool
end

# ─── Keying ───────────────────────────────────────────────

"""
Canonical key for a tool call: tool name + sorted args. Two calls with the
same tool and equivalent args share a key; control keys are excluded.
"""
function _args_key(args)
    args isa AbstractDict || return string(args)
    parts = String[]
    for k in sort(collect(keys(args)))
        String(k) in ("capability", "force") && continue
        v = args[k]
        v isa AbstractDict || v isa AbstractVector ? push!(parts, "$k=$(JSON.json(v))") :
        push!(parts, "$k=$v")
    end
    return join(parts, ";")
end

_exact_key(tool::AbstractString, args) = string(tool) * "::" * _args_key(args)

# ─── Lookup table ─────────────────────────────────────────

"""
Build the lookup table from a vector of samples. For each exact key keeps the
most recent sample (experience rows are time-ordered). Returns a Dict.
"""
function build_lookup(samples::Vector{OutcomeSample})
    lookup = Dict{String,OutcomeSample}()
    for s in samples
        lookup[_exact_key(s.tool, s.args)] = s
    end
    return lookup
end

"""
    predict_outcome(lookup, tool, args) -> Union{Nothing,OutcomeSample}

Return the prior outcome for an identical `(tool, args)` call, or `nothing`
when there is no evidence (never a guess).
"""
function predict_outcome(lookup::AbstractDict, tool::AbstractString, args)
    key = _exact_key(tool, args)
    return get(lookup, key, nothing)
end

# ─── Evaluation ───────────────────────────────────────────

"""
    evaluate(samples; train_ratio=0.7, seed=42) -> Dict

Held-out evaluation of the exact-key predictor vs a majority-class baseline.
Returns:
  - `:coverage`        — fraction of test calls that had training evidence
  - `:accuracy`        — predictor agreement on calls it covered
  - `:baseline_acc`    — majority-class baseline accuracy on the same calls
  - `:delta`           — accuracy − baseline accuracy (the go/no-go quantity)
  - `:false_veto`      — fraction of correctly-predictable SAFE calls the
                         predictor marked as failures (go/no-go: < 2%)
"""
function evaluate(
    samples::Vector{OutcomeSample};
    train_ratio::Float64 = 0.7,
    seed::Int = 42,
)
    isempty(samples) && return Dict{String,Any}(
        "coverage" => 0.0,
        "accuracy" => 0.0,
        "baseline_acc" => 0.0,
        "delta" => 0.0,
        "false_veto" => 0.0,
        "n_test" => 0,
    )
    rng = MersenneTwister(seed)
    idx = shuffle(rng, 1:length(samples))
    n_train = max(1, round(Int, train_ratio * length(samples)))
    train = samples[idx[1:n_train]]
    test::Vector{OutcomeSample} = samples[idx[n_train+1:end]]

    lookup = build_lookup(train)

    # Majority class over the TRAIN set: the most common verified outcome.
    majority = majority_baseline(train)

    hits = 0      # predictor correct on covered calls
    covered = 0
    total = 0
    false_veto = 0
    safe_covered = 0

    for s in test
        total += 1
        pred = predict_outcome(lookup, s.tool, s.args)
        pred === nothing && continue
        covered += 1
        pred_ok = pred.verified
        true_ok = s.verified
        pred_ok == true_ok && (hits += 1)
        if true_ok            # this test call was actually safe
            safe_covered += 1
            pred_ok == false && (false_veto += 1)
        end
    end

    cov = covered / total
    acc = covered > 0 ? hits / covered : 0.0
    base = covered > 0 ? (Base.count(s -> s.verified == majority, test) / length(test)) : 0.0

    return Dict{String,Any}(
        "coverage" => round(cov, digits = 3),
        "accuracy" => round(acc, digits = 3),
        "baseline_acc" => round(base, digits = 3),
        "delta" => round(acc - base, digits = 3),
        "false_veto" => round(safe_covered > 0 ? false_veto / safe_covered : 0.0, digits = 3),
        "n_test" => total,
        "n_covered" => covered,
    )
end

"""
Majority-class baseline: the most common `verified` value among samples
(treats the outcome as the binary success/failure label).
"""
function majority_baseline(samples::Vector{OutcomeSample})
    isempty(samples) && return false
    ok = Base.count(s -> s.verified, samples)
    return ok >= length(samples) - ok
end

# ─── Data plumbing ────────────────────────────────────────

"""
Load `(tool, args, result, verified)` rows from the experience store into
`OutcomeSample`s (best-effort; rows without a tool are skipped).
"""
function load_experience_samples(; limit::Int = 1000)
    Experience.flush!()
    rows = MemoryDB.query_all(
        "SELECT tool, args, result, verified FROM experience WHERE tool IS NOT NULL AND tool != '' LIMIT $limit",
    )
    samples = OutcomeSample[]
    for r in rows
        args = try
            r.args === nothing ? Dict{String,Any}() : JSON.parse(string(r.args))
        catch
            Dict{String,Any}()
        end
        push!(samples, OutcomeSample(string(r.tool), args, string(get(r, :result, "")), r.verified == 1))
    end
    return samples
end

end # module