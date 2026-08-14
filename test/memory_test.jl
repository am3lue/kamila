"""
test/memory_test.jl — Tier-1 tests of the real `KamilaMemory` module against an
isolated temp MEMORY_FILE (no mocks).
"""

using Test
using JSON

using .Kamila
const KM = Kamila.KamilaMemory

# Reset the backing memory file before each testset.
reset_memory_file!(TEST_SANDBOX[]["memory_file"])

@testset "KamilaMemory" begin
    @testset "initialize_memory creates default file" begin
        mem_file = TEST_SANDBOX[]["memory_file"]
        isfile(mem_file) && rm(mem_file; force = true)
        KM.initialize_memory()
        @test isfile(mem_file)
        data = JSON.parsefile(mem_file)
        @test get(data, "user_alias", "") == "Blue"
        @test data["tasks"] == []
        @test data["achievements"] == []
        @test data["goals"] == []
        reset_memory_file!(mem_file)
    end

    @testset "load_memory round-trips saved data" begin
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
        data = KM.load_memory()
        @test get(data, "user_alias", "") == "Test"
        @test haskey(data, "usage_stats")

        data["user_alias"] = "Changed"
        @test KM.save_memory(data) == true
        reloaded = KM.load_memory()
        @test get(reloaded, "user_alias", "") == "Changed"
        @test haskey(reloaded, "last_updated")
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
    end

    @testset "load_memory tolerates missing/corrupt file" begin
        mem_file = TEST_SANDBOX[]["memory_file"]
        isfile(mem_file) && rm(mem_file; force = true)
        data = KM.load_memory()
        @test data isa Dict
        @test isempty(data)
        write(mem_file, "{ not valid json")
        data2 = KM.load_memory()
        @test data2 isa Dict
        @test isempty(data2)
        reset_memory_file!(mem_file)
    end

    @testset "goals lifecycle" begin
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
        @test isempty(KM.get_active_goals())

        @test KM.add_goal("Learn Julia", "coding", 1) == true
        @test KM.add_goal("Build Kamila", "project", 2) == true

        active = KM.get_active_goals()
        @test length(active) == 2
        @test get(active[1], "goal", "") == "Learn Julia"
        @test get(active[1], "category", "") == "coding"

        @test KM.complete_goal(1) == true
        @test KM.complete_goal(999) == false  # non-existent id

        active_after = KM.get_active_goals()
        @test length(active_after) == 1
        @test get(active_after[1], "id", 0) == 2
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
    end

    @testset "achievements" begin
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
        @test isempty(KM.get_today_achievements())
        @test KM.add_achievement("Test Achievement", "desc") == true
        today = KM.get_today_achievements()
        @test length(today) == 1
        @test get(today[1], "title", "") == "Test Achievement"
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
    end

    @testset "track_activity updates stats" begin
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
        KM.track_activity(true)
        KM.track_activity(true)
        KM.track_activity(false)
        stats = KM.get_memory_stats()
        @test stats["total_activities"] == 3
        @test stats["productivity_percentage"] == 66.7
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
    end

    @testset "get_memory_stats shape" begin
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
        stats = KM.get_memory_stats()
        for key in [
            "user_alias",
            "total_tasks",
            "completed_tasks",
            "total_achievements",
            "active_goals",
            "productivity_percentage",
            "total_activities",
            "last_updated",
        ]
            @test haskey(stats, key)
        end
        @test stats["user_alias"] == "Test"
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
    end

    @testset "generate_summary includes user and counts" begin
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
        summary = KM.generate_summary()
        @test occursin("MEMORY SUMMARY", summary)
        @test occursin("Test", summary)
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
    end

    @testset "export/import round-trip" begin
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
        export_path = joinpath(TEST_SANDBOX[]["root"], "memory_export.json")
        @test KM.export_memory(export_path) == true
        @test isfile(export_path)
        data = JSON.parsefile(export_path)
        @test get(data, "user_alias", "") == "Test"

        isfile(TEST_SANDBOX[]["memory_file"]) &&
            rm(TEST_SANDBOX[]["memory_file"]; force = true)
        @test KM.import_memory(export_path) == true
        reloaded = KM.load_memory()
        @test get(reloaded, "user_alias", "") == "Test"
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
    end

    @testset "reset_stats and clear_memory" begin
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
        KM.track_activity(true)
        @test KM.reset_stats() == true
        stats = KM.get_memory_stats()
        @test stats["total_activities"] == 0
        @test KM.clear_memory() == true
        @test isfile(TEST_SANDBOX[]["memory_file"])
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
    end
end
