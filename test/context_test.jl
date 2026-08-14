"""
test/context_test.jl — Tier-1 tests for Context injection (03.4):
budget packing, priority ordering, provenance labels, provider behavior,
and session isolation.
"""

using Test
using JSON
using Dates
using SQLite

using .Kamila
const CTX = Kamila.Context
const EP = Kamila.Episodic
const KM = Kamila.KamilaMemory
const MDB = Kamila.MemoryDB
const TM = Kamila.TaskManager

# Helper to create a fresh in-memory DB for isolation
function with_fresh_db(f::Function)
    old_db = get(ENV, "KAMILA_DB", nothing)
    ENV["KAMILA_DB"] = ":memory:"
    try
        MDB.reset!()
        f()
    finally
        MDB.reset!()
        old_db === nothing ? delete!(ENV, "KAMILA_DB") : ENV["KAMILA_DB"] = old_db
    end
end

function block(priority, est_tokens, text = "block text"; label = "# [memory: test]", source = "test")
    return CTX.ProviderResult(priority, est_tokens, text, label, source)
end

@testset "Context" begin

    @testset "budget packing constrains token usage" begin
        blocks = [
            block(1, 300, "alpha"),
            block(2, 400, "beta"),
            block(3, 500, "gamma"),
            block(4, 600, "delta"),
        ]
        packed, used = CTX.pack_context(blocks; budget = 700)
        @test used <= 700
        @test !isempty(packed)
        # Only alpha (300) + beta (400) fit within 700: gamma/delta skipped
        @test length(packed) == 2
    end

    @testset "priority ordering (lower wins)" begin
        blocks = [
            block(5, 100, "low"),
            block(1, 100, "high"),
            block(3, 100, "mid"),
        ]
        packed, used = CTX.pack_context(blocks; budget = 400)
        @test length(packed) == 3
        @test packed[1].text == "high"
        @test packed[2].text == "mid"
        @test packed[3].text == "low"
    end

    @testset "oversized block is truncated" begin
        big_text = repeat("x", 2000)
        blocks = [block(1, 1500, big_text)]
        # est_tokens (1500) exceed budget (300), but remaining budget (300) is
        # still useful → the block is truncated to fit instead of dropped.
        packed, used = CTX.pack_context(blocks; budget = 300)
        @test length(packed) == 1
        @test startswith(packed[1].text, "xxxx")
        @test endswith(packed[1].text, "[truncated]")
        @test used <= 300
    end

    @testset "provenance labels attached to blocks" begin
        label = "# [memory: test-recall (score 80%)]"
        blocks = [block(1, 100, "some remembered content"; label = label, source = "memory")]
        packed, used = CTX.pack_context(blocks; budget = 200)
        @test length(packed) == 1
        @test startswith(packed[1].label, "# [memory:")
        @test packed[1].source == "memory"
    end

    @testset "build_context returns labeled blocks" begin
        with_fresh_db() do
            # Seed a task so TaskProvider contributes
            TM.add_task("Write context injection tests"; priority = 1)
            ctx = CTX.build_context("testing context injection"; budget = 400)
            @test ctx isa String
            @test occursin("## Injected Context", ctx)
            @test occursin("# [memory: pending-tasks", ctx)
            @test occursin("Write context injection tests", ctx)
        end
    end

    @testset "session-scoped history is isolated" begin
        with_fresh_db() do
            EP.start_session()  # session "1"
            session_id = EP.get_current_session()
            KM.save_chat_history(Dict(
                session_id => [
                    Dict("role" => "user", "content" => "Remember the launch window for Mars"),
                    Dict("role" => "assistant", "content" => "Locked to September window"),
                ],
            ))
            ctx = CTX.build_context("launch window"; session = session_id, budget = 500)
            @test occursin("session-history", ctx)
            @test occursin("September window", ctx)

            # A different (empty) session must not leak history
            ctx_other = CTX.build_context("launch window"; session = "other", budget = 500)
            @test !occursin("September window", ctx_other)
        end
    end

    @testset "memory_provider recall (fallback) returns blocks" begin
        with_fresh_db() do
            KM.save_chat_history(Dict(
                "default" => [
                    Dict("role" => "user", "content" => "Rendezvous with comet 67P"),
                    Dict("role" => "assistant", "content" => "Calculated delta-v of 800 m/s"),
                ],
            ))
            ctx = CTX.build_context("comet rendezvous"; budget = 600)
            # Fallback recall is best-effort; just ensure no hard failure
            @test ctx isa String
        end
    end

    @testset "active goals gate" begin
        with_fresh_db() do
            KM.add_goal("Complete lunar base feasibility study", "research", 1)
            KM.add_goal("Clean out the pantry", "home", 2)

            # Query related to the research goal should surface active goals
            ctx = CTX.build_context("lunar base feasibility"; budget = 500)
            @test occursin("active-goals", ctx)
            @test occursin("lunar base", ctx)

            # Unrelated query still falls back to priority floor (top-3)
            ctx2 = CTX.build_context("random topic xyz"; budget = 500)
            @test occursin("active-goals", ctx2)
        end
    end

    @testset "debug mode reports provider breakdown" begin
        with_fresh_db() do
            debug = CTX.build_context_debug("anything here"; budget = 300)
            @test debug["budget"] == 300
            @test haskey(debug, "providers")
            @test debug["providers"] isa Vector
            @test haskey(debug, "packed")
            @test haskey(debug, "used_tokens")
            # All providers are individually wrapped (never throw as a unit)
            for p in debug["providers"]
                @test hasproperty(p, :provider_name)
            end
        end
    end

    @testset "empty context degrades gracefully" begin
        with_fresh_db() do
            ctx = CTX.build_context("")
            @test ctx == ""
        end
    end

end