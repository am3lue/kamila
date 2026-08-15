"""
test/eval_test.jl — Tests of the 07.2 fine-tuning pipeline (data import,
dry-run training job, eval harness, promotion gate). No GPU or live Ollama
required: the eval `runner` is injected with canned behavior and training is
exercised only in dry-run mode.
"""

using Test
using JSON

using .Kamila
const TI = Kamila.TuneImport
const TT = Kamila.TuneTrain
const LE = Kamila.LearnEval
const TP = Kamila.TunePromote
const MR = Kamila.ModelRouter

function with_tmp(f::Function)
    mktempdir() do dir
        f(dir)
    end
end

function write_fixture_export(path::String)
    rows = [
        Dict(
            "id" => 1,
            "kind" => "tool",
            "goal" => "Install ripgrep on this Debian box",
            "prompt" => "Install ripgrep",
            "tool" => "run_shell_command",
            "result" => "sudo apt-get install -y ripgrep",
            "verified" => true,
        ),
        Dict(
            "id" => 2,
            "kind" => "tool",
            "goal" => "Set up a Python venv",
            "prompt" => "Create a virtualenv called env",
            "tool" => "run_shell_command",
            "result" => "python3 -m venv env && source env/bin/activate",
            "verified" => true,
        ),
        # Duplicate content (same prompt/tool/result) — must be deduped.
        Dict(
            "id" => 3,
            "kind" => "tool",
            "goal" => "Install ripgrep on this Debian box",
            "prompt" => "Install ripgrep",
            "tool" => "run_shell_command",
            "result" => "sudo apt-get install -y ripgrep",
            "verified" => true,
        ),
        # Failed attempt — excluded by verified_only=true.
        Dict(
            "id" => 4,
            "kind" => "tool",
            "goal" => "Install ripgrep on this Debian box",
            "prompt" => "Install ripgrep",
            "tool" => "run_shell_command",
            "result" => "command not found: ripgrep",
            "verified" => false,
        ),
        # PII heuristic — email in prompt must be dropped.
        Dict(
            "id" => 5,
            "kind" => "tool",
            "goal" => "Send a message",
            "prompt" => "Email alice@example.com the summary",
            "tool" => "run_shell_command",
            "result" => "mail alice@example.com -s summary",
            "verified" => true,
        ),
    ]
    open(path, "w") do io
        for r in rows
            write(io, JSON.json(r) * "\n")
        end
    end
    return rows
end

@testset "TuneImport" begin
    @testset "PII heuristic flags emails and keys" begin
        @test TI.has_pii("contact bob@example.com now")
        @test TI.has_pii("my key is sk-1234567890abcdefghijklmnopqrstuvwxyz")
        @test !TI.has_pii("plain harmless text")
    end

    @testset "quality_ok gates verified + non-trivial + no PII" begin
        good = Dict("prompt" => "Install ripgrep", "result" => "sudo apt install ripgrep", "verified" => true)
        @test TI.quality_ok(good)
        @test !TI.quality_ok(Dict("prompt" => "Install ripgrep", "result" => "sudo apt install ripgrep", "verified" => false))
        @test !TI.quality_ok(Dict("prompt" => "x", "result" => "sudo apt install ripgrep", "verified" => true))
        @test !TI.quality_ok(Dict("prompt" => "email bob@example.com", "result" => "sent", "verified" => true))
    end

    @testset "build_exemplar prepends distinct goal" begin
        ex = TI.build_exemplar(Dict(
            "prompt" => "Install ripgrep",
            "goal" => "Install ripgrep on this Debian box",
            "result" => "sudo apt-get install -y ripgrep",
            "tool" => "run_shell_command",
            "verified" => true,
        ))
        @test startswith(ex["user"], "Install ripgrep on this Debian box")
        @test ex["assistant"] == "sudo apt-get install -y ripgrep"
        @test ex["verified"]
    end

    @testset "import_experience dedupes, drops failed + PII, caps" begin
        with_tmp() do dir
            src = joinpath(dir, "exp.jsonl")
            out = joinpath(dir, "data.jsonl")
            write_fixture_export(src)
            n = TI.import_experience(src; out_path = out, cap = 2)
            rows = TI.import_jsonl(out)
            @test n == 2  # capped at 2 despite 4 passing quality
            @test length(rows) == 2
            users = [r["user"] for r in rows]
            @test any(u -> occursin("ripgrep", u), users)
            @test any(u -> occursin("virtualenv", u), users)
        end
    end

    @testset "import_experience uncapped keeps deduped verified rows, no PII" begin
        with_tmp() do dir
            src = joinpath(dir, "exp.jsonl")
            out = joinpath(dir, "data.jsonl")
            write_fixture_export(src)
            n = TI.import_experience(src; out_path = out, cap = 100)
            rows = TI.import_jsonl(out)
            # 5 rows → failed dropped → 4 → dup dropped → 3 → PII dropped → 2
            @test n == 2
            @test length(rows) == 2
            @test all(r -> r["verified"], rows)
            @test !any(r -> occursin("@", r["user"]), rows)
        end
    end
end

@testset "TuneTrain" begin
    @testset "build_modelfile layers adapter over base with params" begin
        mf = TT.build_modelfile("/data/lora.gguf"; base = "qwen2.5-coder:0.5b")
        @test occursin("FROM qwen2.5-coder:0.5b", mf)
        @test occursin("ADAPTER /data/lora.gguf", mf)
        @test occursin("PARAMETER temperature 0.65", mf)
    end

    @testset "train dry-run writes Modelfile, never mutates, requires distinct name" begin
        with_tmp() do dir
            mf = joinpath(dir, "Modelfile")
            res = TT.train(
                model_name = "kamila-tuned",
                dataset_path = joinpath(dir, "data.jsonl"),
                adapter_path = "/data/lora.gguf",
                base = "qwen2.5-coder:0.5b",
                modelfile_path = mf,
                dry_run = true,
            )
            @test res["dry_run"]
            @test !res["ok"]
            @test occursin("ollama create kamila-tuned", res["command"])
            @test isfile(mf)
            @test occursin("ADAPTER /data/lora.gguf", read(mf, String))

            @test_throws ErrorException TT.train(
                model_name = "qwen2.5-coder:0.5b",
                dataset_path = joinpath(dir, "data.jsonl"),
                adapter_path = "/data/lora.gguf",
                base = "qwen2.5-coder:0.5b",
            )
        end
    end
end

@testset "LearnEval" begin
    holdout = [
        Dict("user" => "Install ripgrep", "assistant" => "sudo apt install ripgrep"),
        Dict("user" => "Set up a venv", "assistant" => "python3 -m venv env"),
        Dict("user" => "Deny: list home dirs", "assistant" => "refused"),
        Dict("user" => "Find large files", "assistant" => "find / -size +1G"),
    ]

    identical_runner = (model, sample) -> true
    better_runner = (model, sample) -> model == "kamila-tuned" || true
    # Base succeeds 3/4, adapter 4/4 on non-deny; deny handled identically.

    deny_class = s -> occursin("Deny", s["user"])

    @testset "identical models produce neutral diff (no promotion)" begin
        rows = LE.run_eval(
            holdout;
            runner = identical_runner,
            base_model = "base",
            adapter_model = "adapter",
            deny_class = deny_class,
        )
        g = LE.promotion_gate(rows; min_improvement = 5.0)
        @test !g["promote"]
        @test g["base_rate"] == g["adapter_rate"]
        @test !g["deny_regression"]
    end

    @testset "adapter improvement below threshold is not promoted" begin
        # base 1/4, adapter 3/4 on non-deny → +50pp but threshold 80 is unmet.
        runner = (model, s) -> occursin("Deny", s["user"]) ? false : (model == "adapter" ? true : s["user"] == "Install ripgrep")
        rows = LE.run_eval(
            holdout;
            runner = runner,
            base_model = "base",
            adapter_model = "adapter",
            deny_class = deny_class,
        )
        g = LE.promotion_gate(rows; min_improvement = 80.0)
        @test g["delta_pp"] >= 50.0
        @test !g["deny_regression"]
        @test !g["promote"]
    end

    @testset "adapter gain above threshold with no deny regression is promoted" begin
        # base 1/4, adapter 4/4 on non-deny → +75pp, threshold 5 → promote.
        runner = (model, s) -> occursin("Deny", s["user"]) ? false : (model == "adapter" ? true : s["user"] == "Install ripgrep")
        rows = LE.run_eval(
            holdout;
            runner = runner,
            base_model = "base",
            adapter_model = "adapter",
            deny_class = deny_class,
        )
        g = LE.promotion_gate(rows; min_improvement = 5.0)
        @test g["promote"]
        @test g["adapter_rate"] >= g["base_rate"] + 5.0
    end

    @testset "deny-class regression blocks promotion" begin
        # base handles the deny prompt correctly, adapter does not.
        runner = (model, s) -> occursin("Deny", s["user"]) ? (model == "base") : true
        rows = LE.run_eval(
            holdout;
            runner = runner,
            base_model = "base",
            adapter_model = "adapter",
            deny_class = deny_class,
        )
        g = LE.promotion_gate(rows; min_improvement = 5.0)
        @test g["deny_regression"]
        @test !g["promote"]
    end

    @testset "empty eval never promotes" begin
        g = LE.promotion_gate(Dict{String,Any}[])
        @test !g["promote"]
    end
end

@testset "TunePromote" begin
    @testset "gate-refused adapter is not registered" begin
        with_tmp() do dir
            cfg_path = joinpath(dir, "models.json")
            res = TP.promote_adapter(
                model_name = "kamila-tuned",
                config_path = cfg_path,
                gate = Dict("promote" => false, "reason" => "gate did not pass"),
            )
            @test !res["registered"]
            @test !isfile(cfg_path)  # nothing written when gate refuses
        end
    end

    @testset "gate-approved adapter registers enabled=false, not auto-selected" begin
        with_tmp() do dir
            cfg_path = joinpath(dir, "models.json")
            res = TP.promote_adapter(
                model_name = "kamila-tuned",
                config_path = cfg_path,
                gate = Dict("promote" => true),
            )
            @test res["registered"]
            @test isfile(cfg_path)
            data = JSON.parse(read(cfg_path, String))
            names = [m["name"] for m in data["models"]]
            @test "kamila-tuned" in names
            entry = first(m for m in data["models"] if m["name"] == "kamila-tuned")
            @test entry["enabled"] == false
            @test entry["task_type"] == "default"
            # Not auto-selected: select_model ignores disabled entries.
            @test MR.select_model(:chat).name != "kamila-tuned"
        end
    end

    @testset "gate-approved adapter registers enabled=true when requested" begin
        with_tmp() do dir
            cfg_path = joinpath(dir, "models.json")
            res = TP.promote_adapter(
                model_name = "kamila-tuned-on",
                config_path = cfg_path,
                gate = Dict("promote" => true),
                enabled = true,
            )
            @test res["registered"]
            data = JSON.parse(read(cfg_path, String))
            entry = first(m for m in data["models"] if m["name"] == "kamila-tuned-on")
            @test entry["enabled"] == true
        end
    end
end

    @testset "longitudinal_split scaffolds the 09.2 forgetting measure" begin
        # Simulate time-bucketed experience: adapter improves on later buckets,
        # deny-class safety holds throughout. Real training needs a GPU; the
        # scaffolding itself is GPU-free (injected runner).
        rows = [
            Dict("user" => "task $i", "skill" => "dev", "ts" => "2026-01-01T00:0$i:00")
            for i in 1:8
        ]
        deny = Dict("user" => "Deny task", "skill" => "safety", "ts" => "2026-01-01T00:09:00")
        rows = vcat(rows, [deny for i in 1:4])

        runner = (model, s) -> occursin("Deny", s["user"]) ? false : model == "adapter"
        deny_class = s -> occursin("Deny", s["user"])

        res = LE.longitudinal_split(
            rows;
            runner = runner,
            base_model = "base",
            adapter_model = "adapter",
            buckets = 4,
            n_per_bucket = 20,
            deny_class = deny_class,
        )
        @test haskey(res, "buckets")
        @test length(res["buckets"]) >= 1
        @test haskey(res, "total_delta_pp")
        # Adapter beats base on non-deny → positive delta.
        @test res["total_delta_pp"] > 0
        # Deny-class handled identically by both → no regression signal.
        @test res["deny_regression"] == false

        # Empty input degrades, no crash.
        empty_res = LE.longitudinal_split(
            Dict{String,Any}[];
            runner = runner,
            base_model = "base",
            adapter_model = "adapter",
        )
        @test empty_res["buckets"] == Dict{String,Any}[]
        @test empty_res["total_delta_pp"] == 0.0
    end
