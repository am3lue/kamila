"""
test/experience_test.jl — Tests of the 07.1 experience store.

Covers the `experience` table (migration 8), async batched recording with
dedupe, verified/failed outcome retention, deterministic vector recall
(seeded embed cache, no live Ollama), verified-only filtering, prune cap,
JSONL export, and the non-blocking write path.
"""

using Test
using JSON
using Dates

using .Kamila
const EX = Kamila.Experience
const MDB = Kamila.MemoryDB
const VEC = Kamila.Vectors
const PLAN = Kamila.Plan

function with_fresh_db(f::Function)
    old_db = get(ENV, "KAMILA_DB", nothing)
    ENV["KAMILA_DB"] = ":memory:"
    try
        MDB.reset!()
        # Clear the process-global write buffer so rows enqueued by earlier
        # targets (e.g. plan mark_step hooks) never leak into this fresh DB.
        lock(EX._BUFFER_LOCK) do
            empty!(EX._BUFFER)
        end
        f()
    finally
        MDB.reset!()
        lock(EX._BUFFER_LOCK) do
            empty!(EX._BUFFER)
        end
        old_db === nothing ? delete!(ENV, "KAMILA_DB") : ENV["KAMILA_DB"] = old_db
    end
end

# Deterministic embeddings: seed the cache so `similar_solution` scores the
# planted prompt higher than unrelated ones without any live Ollama.
function seed_embed(text::String, vec::Vector{Float32})
    VEC._EMBED_CACHE[VEC._content_hash(text)] = vec
end

function reset_embed_cache!()
    lock(VEC._CACHE_LOCK) do
        empty!(VEC._EMBED_CACHE)
    end
end

# ─── 1. Schema ────────────────────────────────────────────

@testset "experience table exists (migration 8)" begin
    with_fresh_db() do
        db = MDB.ensure_open()
        @test MDB.schema_version(db) >= 8
        cols = MDB.query_all("PRAGMA table_info(experience)")
        names = sort([c.name for c in cols])
        @test "ts" in names
        @test "kind" in names
        @test "verified" in names
        @test "feedback" in names
        @test "result" in names
        @test "args" in names
    end
end

# ─── 2. Record + dedupe + count ───────────────────────────

@testset "record batches, dedupes, and counts" begin
    with_fresh_db() do
        @test EX.enabled()

        # Two identical rows in sequence collapse to one.
        EX.record(
            kind = "tool",
            prompt = "install python on ubuntu",
            tool = "run_shell_command",
            args = Dict("command" => "apt install python"),
            result = "done",
            verified = true,
        )
        EX.record(
            kind = "tool",
            prompt = "install python on ubuntu",
            tool = "run_shell_command",
            args = Dict("command" => "apt install python"),
            result = "done",
            verified = true,
        )
        # A different row is kept.
        EX.record(
            kind = "tool",
            prompt = "deploy to cluster",
            tool = "run_shell_command",
            result = "kubectl ok",
            verified = true,
        )
        @test EX.count() == 2

        rows = MDB.query_all("SELECT * FROM experience ORDER BY id")
        @test rows[1].verified == 1
        @test rows[1].kind == "tool"
        @test rows[2].kind == "tool"
    end
end

# ─── 3. Verified + negative retention ─────────────────────

@testset "verified and negative outcomes are both retained" begin
    with_fresh_db() do
        EX.record(kind = "plan", goal = "g", plan_id = "p1", step_id = 1,
            prompt = "configure git", tool = "run_shell_command",
            result = "ok", verified = true)
        EX.record(kind = "plan", goal = "g", plan_id = "p2", step_id = 1,
            prompt = "provision infra", tool = "run_shell_command",
            result = "permission denied", verified = false)

        @test EX.count() == 2

        # similar_solution defaults to verified-only.
        reset_embed_cache!()
        seed_embed("configure git", Float32[1.0, 0.0, 0.0])
        seed_embed("provision infra", Float32[0.9, 0.1, 0.0])
        res = EX.similar_solution("configure git")
        @test length(res) == 1
        @test res[1]["verified"] == true
        @test res[1]["plan_id"] == "p1"

        # verified_only=false returns both (both above the similarity floor).
        res_all = EX.similar_solution("configure git"; verified_only = false)
        @test length(res_all) == 2
        @test any(r -> !r["verified"], res_all)
    end
end

# ─── 4. Paraphrased recall ranks the planted solution ─────

@testset "paraphrased recall returns the planted verified solution" begin
    with_fresh_db() do
        EX.record(kind = "tool", prompt = "how do I set up a git repo",
            tool = "run_shell_command", result = "git init; add; commit", verified = true)
        EX.record(kind = "tool", prompt = "order a pizza online",
            tool = "run_shell_command", result = "pizza", verified = true)

        reset_embed_cache!()
        # Query vector near the git prompt, far from pizza.
        q = Float32[1.0, 0.0, 0.0]
        seed_embed("how do I set up a git repo", Float32[0.95, 0.05, 0.0])
        seed_embed("order a pizza online", Float32[0.6, 0.6, 0.0])
        seed_embed("initialize version control for my project", q)

        res = EX.similar_solution("initialize version control for my project"; k = 2)
        @test length(res) == 2
        @test res[1]["tool"] == "run_shell_command"
        @test occursin("git", res[1]["result"])
        @test res[1]["score"] > res[2]["score"]
    end
end

# ─── 5. Non-blocking write path ───────────────────────────

@testset "record is non-blocking and never throws" begin
    with_fresh_db() do
        # A batch of distinct records: enqueue returns quickly; flush is async.
        for i in 1:20
            @test EX.record(kind = "tool", prompt = "task $i",
                tool = "run_shell_command", result = "r$i", verified = true)
        end
        # Nothing throws, rows land on flush.
        n = EX.count()
        @test n == 20
    end
end

# ─── 6. Prune cap ─────────────────────────────────────────

@testset "pruning keeps the table bounded" begin
    with_fresh_db() do
        # Temporarily shrink the cap to exercise pruning deterministically.
        old_max = EX.MAX_ROWS[]
        EX.MAX_ROWS[] = 10
        try
            for i in 1:15
                EX.record(kind = "tool", prompt = "seed row $i",
                    tool = "run_shell_command", result = "x$i", verified = true)
            end
            @test EX.count() <= 10
        finally
            EX.MAX_ROWS[] = old_max
        end
    end
end

# ─── 7. Export JSONL ──────────────────────────────────────

@testset "export yields valid JSONL" begin
    with_fresh_db() do
        EX.record(kind = "plan", goal = "g", plan_id = "p1", step_id = 1,
            prompt = "first", tool = "run_shell_command", result = "ok", verified = true)
        EX.record(kind = "tool", prompt = "second", tool = "write_file",
            result = "wrote", verified = false, feedback = -1)

        mktempdir() do dir
            path = joinpath(dir, "exp.jsonl")
            n = EX.export_rows(path)
            @test n == 2

            lines = [JSON.parse(strip(l)) for l in eachline(path) if !isempty(strip(l))]
            @test length(lines) == 2
            @test lines[1]["kind"] == "plan"
            @test lines[1]["verified"] == true
            @test lines[2]["verified"] == false
            @test lines[2]["feedback"] == -1
        end
    end
end

# ─── 8. Plan integration: mark_step records experience ────

@testset "plan mark_step writes experience rows" begin
    with_fresh_db() do
        p = PLAN.create(
            "experience integration plan",
            [(description = "s1", depends_on = Int[], tool = "read_file",
                args = Dict("file_path" => "/dev/null"))],
        )
        PLAN.start(p)
        PLAN.mark_step(p, 1, :running)
        PLAN.mark_step(p, 1, :verified, "read ok")

        # Async flush completes on the count() call.
        @test EX.count() == 1
        rows = MDB.query_all("SELECT * FROM experience")
        @test rows[1].kind == "plan"
        @test rows[1].verified == 1
        @test rows[1].plan_id == p.id
        @test rows[1].prompt == "s1"

        # A failed step records a negative row (training data).
        p2 = PLAN.create(
            "experience failure plan",
            [(description = "s1", depends_on = Int[], tool = "read_file",
                args = Dict("file_path" => "/dev/null"))],
        )
        PLAN.start(p2)
        PLAN.mark_step(p2, 1, :running)
        PLAN.mark_step(p2, 1, :failed, "boom"; retryable = false)
        @test EX.count() == 2
        rows2 = MDB.query_all("SELECT * FROM experience ORDER BY id")
        @test rows2[2].verified == 0
        @test rows2[2].plan_id == p2.id
    end
end

# ─── 9. Opt-out ───────────────────────────────────────────

@testset "experience can be disabled" begin
    with_fresh_db() do
        old = EX.ENABLED[]
        EX.ENABLED[] = false
        try
            @test !EX.enabled()
            @test EX.record(kind = "tool", prompt = "x", tool = "y", result = "z") == false
            @test EX.count() == 0
        finally
            EX.ENABLED[] = old
        end
    end
end
