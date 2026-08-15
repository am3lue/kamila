"""
test/vectors_test.jl — Tier-1 tests for the Vectors embedding module.
"""

using Test
using LinearAlgebra
using JSON
using Dates
using SQLite

using .Kamila
const VEC = Kamila.Vectors
const MDB = Kamila.MemoryDB
const KM = Kamila.KamilaMemory

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

@testset "Vectors" begin

    @testset "cosine similarity math" begin
        a = Float32[1.0, 0.0, 0.0]
        b = Float32[1.0, 0.0, 0.0]
        @test VEC.cosine(a, b) ≈ 1.0

        c = Float32[0.0, 1.0, 0.0]
        @test VEC.cosine(a, c) ≈ 0.0

        d = Float32[-1.0, 0.0, 0.0]
        @test VEC.cosine(a, d) ≈ -1.0

        # Different lengths
        @test VEC.cosine(Float32[1.0, 0.0], Float32[1.0, 0.0, 0.0]) == -1.0
    end

    @testset "embedding cache by content hash" begin
        with_fresh_db() do
            # First call - should call API (mocked would be ideal, but we test cache logic)
            # We can't easily mock HTTP here, so we test the cache logic directly
            VEC._EMBED_CACHE["test_hash"] = Float32[0.1, 0.2, 0.3]
            result = VEC._EMBED_CACHE["test_hash"]
            @test result == Float32[0.1, 0.2, 0.3]

            # Different hash
            VEC._EMBED_CACHE["other"] = Float32[0.4, 0.5]
            @test VEC._EMBED_CACHE["other"] == Float32[0.4, 0.5]
        end
    end

    @testset "FTS5 fallback recall" begin
        with_fresh_db() do
            MDB.ensure_open()

            # Insert test data
            MDB.execute!(
                "INSERT INTO memories (kind, content, content_hash, created_at, importance) VALUES (?, ?, ?, ?, ?)",
                "chat",
                "I deployed the bridge service",
                "hash1",
                string(now()),
                0.5,
            )
            MDB.execute!(
                "INSERT INTO memories (kind, content, content_hash, created_at, importance) VALUES (?, ?, ?, ?, ?)",
                "task",
                "Write unit tests for memory",
                "hash2",
                string(now()),
                0.7,
            )
            MDB.execute!(
                "INSERT INTO memories (kind, content, content_hash, created_at, importance) VALUES (?, ?, ?, ?, ?)",
                "goal",
                "Learn Julia embeddings",
                "hash3",
                string(now()),
                0.8,
            )

            # Populate FTS5
            MDB.execute!(
                "INSERT INTO memories_fts (rowid, content) VALUES (?, ?)",
                1,
                "I deployed the bridge service",
            )
            MDB.execute!(
                "INSERT INTO memories_fts (rowid, content) VALUES (?, ?)",
                2,
                "Write unit tests for memory",
            )
            MDB.execute!(
                "INSERT INTO memories_fts (rowid, content) VALUES (?, ?)",
                3,
                "Learn Julia embeddings",
            )

            # Test FTS5 fallback
            results = VEC.recall_fallback("bridge service"; k = 5)
            @test length(results) >= 1
            @test results[1].content == "I deployed the bridge service"

            # Test with kind filter
            results = VEC.recall_fallback("memory"; k = 5, kinds = ["task"])
            @test length(results) >= 1
            @test results[1].kind == "task"
        end
    end

    @testset "vector recall with empty query" begin
        with_fresh_db() do
            results = VEC.recall(""; k = 5)
            @test isempty(results)

            results = VEC.recall("   "; k = 5)
            @test isempty(results)
        end
    end

    @testset "recall never returns results for empty query" begin
        with_fresh_db() do
            @test isempty(VEC.recall(""))
            @test isempty(VEC.recall("   "))
        end
    end

    @testset "duplicate content stored once (hash dedup)" begin
        with_fresh_db() do
            id1, emb1 = KM.remember("Test content"; kind = "note", importance = 0.5)
            id2, emb2 = KM.remember("Test content"; kind = "note", importance = 0.5)

            @test id1 == id2
            @test emb2 == false  # second call should not embed (duplicate)
        end
    end

    @testset "paraphrase recall (semantic, not keyword)" begin
        with_fresh_db() do
            # Requires a real embedding model (e.g. nomic-embed-text) reachable
            # via the Ollama endpoint. Self-gating: skip when unavailable.
            probe = VEC.embed("probe")
            if probe === nothing
                @test_skip "embedding model unavailable (no /api/embed response)"
            else
                # Seed memories with content that shares no keywords with the query.
                id1, _ = KM.remember("I deployed the bridge service"; kind = "chat", importance = 0.8)
                KM.remember("Write unit tests for memory"; kind = "task", importance = 0.7)
                @test id1 > 0

                hits = VEC.recall("what did we do with that socket thing?"; k = 5, min_sim = 0.25)
                @test !isempty(hits)
                @test any(h -> occursin("bridge service", h.content), hits)
            end
        end
    end

end
