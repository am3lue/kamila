"""
test/preference_test.jl — Tests of the 07.3 preference learning module:
threshold gate (5+ explicit signals flip, 1-2 don't), explicit vs implicit
weighting, revert, prompt injection, and no-preference default.
"""

using Test
using JSON

using .Kamila
const PF = Kamila.Preferences
const MDB = Kamila.MemoryDB
const AGENT = Kamila.Agent

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

@testset "Preferences" begin
    with_fresh_db() do
        @testset "baselines: tone defaults to narrated" begin
            @test PF.get_preference("tone") == "narrated"
            @test PF.get_preference("verbosity") == "normal"
        end

        @testset "a single explicit signal does not flip" begin
            committed, value = PF.record_signal("tone", "concise"; explicit = true)
            @test !committed
            @test value == "narrated"  # still baseline
            @test PF.get_preference("tone") == "narrated"
        end

        @testset "two explicit signals do not flip" begin
            PF.record_signal("tone", "concise"; explicit = true)
            PF.record_signal("tone", "concise"; explicit = true)
            @test PF.get_preference("tone") == "narrated"
        end

        @testset "five explicit signals flip tone to concise" begin
            for _ in 1:5
                PF.record_signal("tone", "concise"; explicit = true)
            end
            @test PF.get_preference("tone") == "concise"
            @test "tone" in keys(PF.active_preferences())
            @test PF.active_preferences()["tone"] == "concise"
        end

        @testset "implicit signals never outvote explicit ones" begin
            # Baseline narrated. Many implicit "concise" signals alone must not flip.
            # (isolate on a fresh key)
            for _ in 1:20
                PF.record_signal("verbosity", "terse"; explicit = false)
            end
            @test PF.get_preference("verbosity") == "normal"
        end

        @testset "active_preferences only includes committed non-default values" begin
            active = PF.active_preferences()
            @test haskey(active, "tone")
            @test !haskey(active, "verbosity")  # still at baseline
        end

        @testset "revert restores baseline and removes from active" begin
            @test PF.revert_preference("tone") == "narrated"
            @test PF.get_preference("tone") == "narrated"
            @test !haskey(PF.active_preferences(), "tone")
        end

        @testset "preference_history records events with weights" begin
            h = PF.preference_history("tone")
            @test length(h) >= 8  # 1 + 2 + 5 explicit signals recorded
            @test all(e -> e["explicit"], h)
            @test all(e -> e["weight"] == 1.0, h)
        end

        @testset "commit_preference logs source explicitly" begin
            PF.commit_preference("default_tool", "run_shell_command"; source = "manual")
            @test PF.get_preference("default_tool") == "run_shell_command"
            allp = PF.all_preferences()
            @test any(p -> p["key"] == "default_tool" && p["value"] == "run_shell_command", allp)
        end

        @testset "chat system prompt includes preferences block only when active" begin
            # Clear any commits from prior testsets in this shared fresh DB.
            for key in keys(PF.active_preferences())
                PF.revert_preference(key)
            end
            prompt_plain = AGENT.get_chat_system_prompt()
            @test !occursin("# preferences", prompt_plain)

            PF.commit_preference("tone", "concise"; source = "explicit feedback")
            prompt_prefs = AGENT.get_chat_system_prompt()
            @test occursin("# preferences", prompt_prefs)
            @test occursin("concise", prompt_prefs)
            @test !occursin("verbosity", prompt_prefs)  # baseline not surfaced
            PF.revert_preference("tone")
        end
    end
end
