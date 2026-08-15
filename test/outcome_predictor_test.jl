"""
test/outcome_predictor_test.jl — Tests of the 09.1 research prototype.

Covers: exact-key lookup (predicts only with evidence, never guesses),
held-out evaluation (coverage / accuracy / baseline / delta / false-veto),
the majority-class baseline, and loading samples from the experience store.
Research prototype — assertions reflect the mechanics, not a production
commitment (see the 09.1 notebook go/no-go).
"""

using Test
using JSON

using .Kamila
const OP = Kamila.OutcomePredictor
const ERR = Kamila.Errors

@testset "OutcomePredictor" begin
    @testset "build_lookup + predict_outcome are exact-key, never guess" begin
        samples = OP.OutcomeSample[
            OP.OutcomeSample("read_file", Dict("file_path" => "/a.txt"), "ok", true),
            OP.OutcomeSample("run_shell_command", Dict("command" => "ls"), "listed", true),
            OP.OutcomeSample("write_file", Dict("file_path" => "/x", "content" => "hi"), "denied", false),
        ]
        lookup = OP.build_lookup(samples)
        @test length(lookup) == 3

        # Exact match returns the prior outcome.
        pred = OP.predict_outcome(lookup, "read_file", Dict("file_path" => "/a.txt"))
        @test pred !== nothing
        @test pred.verified == true

        # Same args in different key order → same key (sorted).
        pred2 = OP.predict_outcome(lookup, "write_file", Dict("content" => "hi", "file_path" => "/x"))
        @test pred2 !== nothing
        @test pred2.verified == false

        # Unseen args → nothing (never a guess).
        @test OP.predict_outcome(lookup, "read_file", Dict("file_path" => "/b.txt")) === nothing
        @test OP.predict_outcome(lookup, "web_search", Dict("query" => "x")) === nothing
    end

    @testset "control keys are excluded from the key" begin
        a = OP.OutcomeSample("read_file", Dict("file_path" => "/a.txt", "capability" => "tok"), "ok", true)
        b = OP.OutcomeSample("read_file", Dict("file_path" => "/a.txt"), "ok", true)
        @test OP._args_key(a.args) == OP._args_key(b.args)
    end

    @testset "evaluate reports coverage/accuracy/baseline/false-veto" begin
        # Repeated keys so held-out calls have training evidence: 2 safe keys
        # (read_file) and 2 failing keys (write_file), each seen multiple times.
        safe = ["/r1.txt", "/r2.txt"]
        bad = ["/w1.txt", "/w2.txt"]
        samples = OP.OutcomeSample[]
        for i in 1:4, p in safe
            push!(samples, OP.OutcomeSample("read_file", Dict("file_path" => p), "ok", true))
        end
        for i in 1:4, p in bad
            push!(samples, OP.OutcomeSample("write_file", Dict("file_path" => p), "denied", false))
        end
        r = OP.evaluate(samples; train_ratio = 0.7, seed = 7)
        @test r["coverage"] > 0.5
        @test r["accuracy"] >= 0.9
        @test r["baseline_acc"] >= 0.4
        # False-veto: predictor never marks a covered-safe call as failed here.
        @test r["false_veto"] == 0.0
        @test haskey(r, "delta")
    end

    @testset "empty evaluation degrades to zeros, no crash" begin
        r = OP.evaluate(OP.OutcomeSample[])
        @test r["coverage"] == 0.0
        @test r["accuracy"] == 0.0
        @test r["delta"] == 0.0
        @test r["false_veto"] == 0.0
    end

    @testset "majority_baseline chooses the dominant label" begin
        ok = [OP.OutcomeSample("t", Dict(), "", true) for _ in 1:3]
        bad = [OP.OutcomeSample("t", Dict(), "", false) for _ in 1:1]
        @test OP.majority_baseline(vcat(ok, bad)) == true
        @test OP.majority_baseline(OP.OutcomeSample[]) == false
    end

    @testset "load_experience_samples reads the experience store" begin
        # Record a couple of verified rows through the 07.1 seam, then load.
        Kamila.Experience.record(tool = "read_file", args = Dict("file_path" => "/exp.txt"), result = "ok", verified = true)
        Kamila.Experience.record(tool = "run_shell_command", args = Dict("command" => "ls"), result = "listed", verified = false)
        samples = OP.load_experience_samples()
        @test length(samples) >= 2
        @test any(s -> s.tool == "read_file" && s.verified, samples)
        @test any(s -> s.tool == "run_shell_command" && !s.verified, samples)
    end
end