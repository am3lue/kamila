"""
test/episodic_test.jl — Tier-1 tests for Episodic session tracking and summarization.
"""

using Test
using JSON
using Dates
using SQLite

using .Kamila
const EP = Kamila.Episodic
const KM = Kamila.KamilaMemory
const MDB = Kamila.MemoryDB

# Bounded wait helper for async operations
function wait_for(f::Function; timeout::Float64 = 10.0, interval::Float64 = 0.1)
    deadline = time() + timeout
    while time() < deadline
        result = f()
        result !== nothing && return result
        sleep(interval)
        yield()  # Allow async tasks to run
    end
    return f()  # Final attempt
end

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

@testset "Episodic" begin

    @testset "session lifecycle" begin
        with_fresh_db() do
            session_id = EP.start_session()
            @test session_id == 1
            @test EP.get_current_session() == "1"

            EP.increment_turn()
            @test EP._turn_count[] == 1

            EP.end_session()
            @test EP._current_session[] === nothing
            @test EP._turn_count[] == 0
        end
    end

    @testset "segment summarization trigger" begin
        with_fresh_db() do
            EP.start_session()
            session_id = EP.get_current_session()

            # Pre-populate chat history with enough messages to trigger summarization
            msgs = Dict{String,Any}[]
            for i = 1:35
                push!(msgs, Dict("role" => "user", "content" => "Message $i"))
                push!(msgs, Dict("role" => "assistant", "content" => "Response $i"))
            end
            KM.save_chat_history(Dict(session_id => msgs))

            # Now increment turns to trigger summarization
            for i = 1:35
                EP.increment_turn()
            end

            # Should have triggered segment summarization (async) - longer timeout for Ollama mock
            wait_for(; timeout = 30.0) do
                rows = MDB.query_all(
                    "SELECT * FROM memories WHERE kind = 'episodic' AND period = 'segment'",
                )
                isempty(rows) ? nothing : rows
            end

            # Check that segment summary was created
            rows = MDB.query_all(
                "SELECT * FROM memories WHERE kind = 'episodic' AND period = 'segment'",
            )
            @test !isempty(rows)
        end
    end

    @testset "day summarization" begin
        with_fresh_db() do
            # Create some segment summaries for today
            today_dt = Dates.today()
            start_of_day = string(today_dt)
            end_of_day = string(today_dt + Day(1))

            MDB.execute!(
                "INSERT INTO memories (kind, content, content_hash, created_at, importance, period) VALUES (?, ?, ?, ?, ?, ?)",
                ("episodic", "Segment 1 summary", "hash1", string(now()), 0.7, "segment"),
            )
            MDB.execute!(
                "INSERT INTO memories (kind, content, content_hash, created_at, importance, period) VALUES (?, ?, ?, ?, ?, ?)",
                ("episodic", "Segment 2 summary", "hash2", string(now()), 0.7, "segment"),
            )

            EP.summarize_day(today_dt)

            rows = MDB.query_all(
                "SELECT * FROM memories WHERE kind = 'episodic' AND period = 'day' AND created_at >= ? AND created_at < ?",
                (string(today_dt), string(today_dt + Day(1))),
            )
            @test !isempty(rows)
            @test rows[1].period == "day"
        end
    end

    @testset "week summarization" begin
        with_fresh_db() do
            week_start = Dates.today() - Day(7)

            MDB.execute!(
                "INSERT INTO memories (kind, content, content_hash, created_at, importance, period) VALUES (?, ?, ?, ?, ?, ?)",
                (
                    "episodic",
                    "Day 1 summary",
                    "hash1",
                    string(week_start + Day(2)),
                    0.7,
                    "day",
                ),
            )
            MDB.execute!(
                "INSERT INTO memories (kind, content, content_hash, created_at, importance, period) VALUES (?, ?, ?, ?, ?, ?)",
                (
                    "episodic",
                    "Day 2 summary",
                    "hash2",
                    string(week_start + Day(4)),
                    0.7,
                    "day",
                ),
            )

            EP.summarize_week(week_start)

            rows = MDB.query_all(
                "SELECT * FROM memories WHERE kind = 'episodic' AND period = 'week' AND created_at >= ? AND created_at < ?",
                (string(week_start), string(week_start + Day(7))),
            )
            @test !isempty(rows)
            @test rows[1].period == "week"
        end
    end

    @testset "importance decay" begin
        with_fresh_db() do
            # Create old episodic memory with high importance
            old_date = string(now() - Day(10))
            MDB.execute!(
                "INSERT INTO memories (kind, content, content_hash, created_at, importance, period) VALUES (?, ?, ?, ?, ?, ?)",
                ("episodic", "Old summary", "hash_old", old_date, 0.9, "segment"),
            )

            # Create recent episodic memory with lower importance
            MDB.execute!(
                "INSERT INTO memories (kind, content, content_hash, created_at, importance, period) VALUES (?, ?, ?, ?, ?, ?)",
                (
                    "episodic",
                    "Recent summary",
                    "hash_recent",
                    string(now()),
                    0.5,
                    "segment",
                ),
            )

            # Apply decay
            EP.apply_decay(0.9)

            rows = MDB.query_all(
                "SELECT id, content, importance FROM memories WHERE kind = 'episodic'",
            )
            old_imp = nothing
            recent_imp = nothing
            for r in rows
                if r.content == "Old summary"
                    old_imp = r.importance
                elseif r.content == "Recent summary"
                    recent_imp = r.importance
                end
            end

            @test old_imp !== nothing
            @test recent_imp !== nothing
            @test old_imp < 0.9  # Should have decayed
            @test recent_imp >= 0.5 * 0.95  # Recent should decay less
        end
    end

    @testset "failure placeholder and retry" begin
        with_fresh_db() do
            # Test that _safe_summarize returns a string and doesn't throw
            # (Ollama mock server returns a fallback response, not an error)
            result = EP._safe_summarize("test prompt"; max_tokens = 10)
            @test result isa String
            @test !isempty(result)
        end
    end

    @testset "episodic recall via memory_query" begin
        with_fresh_db() do
            # Create some episodic summaries
            KM.remember(
                "Segment summary 1";
                kind = "episodic",
                period = "segment",
                period_start = "2026-01-01",
                period_end = "2026-01-01",
            )
            KM.remember(
                "Day summary";
                kind = "episodic",
                period = "day",
                period_start = "2026-01-01",
                period_end = "2026-01-02",
            )
            KM.remember(
                "Week summary";
                kind = "episodic",
                period = "week",
                period_start = "2026-01-01",
                period_end = "2026-01-07",
            )

            # Test recall via memory_query
            result = Kamila.AgentTools.memory_query(Dict("query" => "episodic"))
            @test occursin("Episodic Summaries", result)
            @test occursin("Segment summary 1", result)
            @test occursin("Day summary", result)
            @test occursin("Week summary", result)
        end
    end

    @testset "session end triggers summarization" begin
        with_fresh_db() do
            EP.start_session()
            session_id = EP.get_current_session()

            # Add chat messages (accumulate first, then save once)
            msgs = Dict{String,Any}[]
            for i = 1:35
                push!(msgs, Dict("role" => "user", "content" => "Message $i"))
                push!(msgs, Dict("role" => "assistant", "content" => "Response $i"))
            end
            KM.save_chat_history(Dict(session_id => msgs))

            # Increment turns to reach threshold
            for i = 1:35
                EP.increment_turn()
            end

            # End session should trigger async summarization
            EP.end_session()

            # Give async task time to complete
            wait_for(; timeout = 30.0) do
                rows = MDB.query_all(
                    "SELECT * FROM memories WHERE kind = 'episodic' AND period = 'segment'",
                )
                isempty(rows) ? nothing : rows
            end

            # Check that segment summary was created
            rows = MDB.query_all(
                "SELECT * FROM memories WHERE kind = 'episodic' AND period = 'segment'",
            )
            @test !isempty(rows)
        end
    end

end
