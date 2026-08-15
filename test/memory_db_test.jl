"""
test/memory_db_test.jl — Tier-1 tests for the MemoryDB SQLite storage engine.
"""

using Test
using JSON
using Dates
using SQLite

using .Kamila
const MDB = Kamila.MemoryDB
const KM = Kamila.KamilaMemory
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

@testset "MemoryDB" begin

    @testset "schema version starts at 6 after init" begin
        with_fresh_db() do
            db = MDB.ensure_open()
            @test MDB.schema_version(db) == 10
        end
    end

    @testset "migration is idempotent" begin
        with_fresh_db() do
            db = MDB.ensure_open()
            v1 = MDB.schema_version(db)
            MDB.migrate!(db)
            v2 = MDB.schema_version(db)
            @test v1 == v2 == 10
            # Run again - should be no-op
            MDB.migrate!(db)
            @test MDB.schema_version(db) == 10
        end
    end

    @testset "migration imports legacy JSON" begin
        with_fresh_db() do
            # Create a legacy JSON file
            mktempdir() do dir
                legacy = joinpath(dir, "legacy.json")
                legacy_data = Dict(
                    "user_alias" => "LegacyUser",
                    "tasks" => [
                        Dict(
                            "id" => 1,
                            "title" => "Legacy Task",
                            "completed" => false,
                            "tags" => ["tag1"],
                        ),
                    ],
                    "goals" =>
                        [Dict("id" => 1, "goal" => "Legacy Goal", "completed" => true)],
                    "achievements" => [
                        Dict(
                            "id" => 1,
                            "title" => "Legacy Achievement",
                            "date" => "2026-01-01",
                        ),
                    ],
                    "usage_stats" => Dict(
                        "useful_activities" => 5,
                        "total_activities" => 10,
                        "productivity_percentage" => 50.0,
                    ),
                    "last_updated" => "2026-01-01T00:00:00",
                )
                write(legacy, JSON.json(legacy_data))

                # Point MEMORY_FILE to legacy and trigger migration
                old_mem = get(ENV, "KAMILA_MEMORY_FILE", nothing)
                ENV["KAMILA_MEMORY_FILE"] = legacy
                try
                    MDB.reset!()
                    db = MDB.ensure_open()
                    @test MDB.schema_version(db) == 10
                    # Check imported data
                    alias =
                        MDB.query_all("SELECT value FROM kv WHERE key = ?", "user_alias")
                    @test length(alias) == 1
                    @test alias[1].value == "LegacyUser"

                    tasks = MDB.query_all("SELECT * FROM tasks")
                    @test length(tasks) == 1
                    @test tasks[1].title == "Legacy Task"

                    goals = MDB.query_all("SELECT * FROM goals")
                    @test length(goals) == 1
                    @test goals[1].goal == "Legacy Goal"
                    @test goals[1].completed == 1

                    achievements = MDB.query_all("SELECT * FROM achievements")
                    @test length(achievements) == 1
                    @test achievements[1].title == "Legacy Achievement"

                    stats =
                        MDB.query_all("SELECT value FROM kv WHERE key = ?", "usage_stats")
                    @test length(stats) == 1
                    parsed = JSON.parse(stats[1].value)
                    @test parsed["useful_activities"] == 5
                    @test parsed["total_activities"] == 10
                    @test parsed["productivity_percentage"] == 50.0
                finally
                    old_mem === nothing ? delete!(ENV, "KAMILA_MEMORY_FILE") :
                    ENV["KAMILA_MEMORY_FILE"] = old_mem
                end
            end
        end
    end

    @testset "transaction commits and rolls back" begin
        with_fresh_db() do
            MDB.ensure_open()
            # Successful commit
            MDB.transaction() do db
                SQLite.execute(
                    db,
                    "INSERT INTO tasks (id, title, completed) VALUES (?, ?, ?)",
                    (1, "Task 1", 0),
                )
            end
            tasks = MDB.query_all("SELECT * FROM tasks")
            @test length(tasks) == 1
            @test tasks[1].title == "Task 1"

            # Rollback on error
            @test_throws ErrorException MDB.transaction() do db
                SQLite.execute(
                    db,
                    "INSERT INTO tasks (id, title, completed) VALUES (?, ?, ?)",
                    (2, "Task 2", 0),
                )
                throw(ErrorException("rollback!"))
            end
            tasks = MDB.query_all("SELECT * FROM tasks")
            @test length(tasks) == 1  # Task 2 not committed
            @test tasks[1].title == "Task 1"
        end
    end

    @testset "execute! and query_all work" begin
        with_fresh_db() do
            MDB.ensure_open()
            MDB.execute!(
                "INSERT INTO tasks (id, title, completed) VALUES (?, ?, ?)",
                10,
                "Exec Task",
                1,
            )
            rows = MDB.query_all("SELECT * FROM tasks WHERE id = ?", 10)
            @test length(rows) == 1
            @test rows[1].title == "Exec Task"
            @test rows[1].completed == 1
        end
    end

    @testset "WAL mode enabled" begin
        with_fresh_db() do
            db = MDB.ensure_open()
            rows = MDB.query_all("PRAGMA journal_mode")
            # For file DBs it's "wal", for in-memory it's "memory"
            @test rows[1].journal_mode in ("wal", "memory")
        end
    end

    @testset "reset! closes handle" begin
        with_fresh_db() do
            db1 = MDB.ensure_open()
            MDB.reset!()
            db2 = MDB.ensure_open()
            @test db1 !== db2
        end
    end

end

@testset "KamilaMemory DB-backed" begin

    @testset "load_memory/save_memory round-trip" begin
        with_fresh_db() do
            # reset_memory_file! writes default JSON, which migration imports
            reset_memory_file!(TEST_SANDBOX[]["memory_file"])
            data = KM.load_memory()
            @test get(data, "user_alias", "") == "Test"
            @test haskey(data, "usage_stats")

            data["user_alias"] = "Changed"
            @test KM.save_memory(data) == true
            reloaded = KM.load_memory()
            @test get(reloaded, "user_alias", "") == "Changed"
            @test haskey(reloaded, "last_updated")
        end
    end

    @testset "load_memory tolerates missing/corrupt JSON" begin
        with_fresh_db() do
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
    end

    @testset "goals lifecycle" begin
        with_fresh_db() do
            reset_memory_file!(TEST_SANDBOX[]["memory_file"])
            @test isempty(KM.get_active_goals())

            @test KM.add_goal("Learn Julia", "coding", 1) == true
            @test KM.add_goal("Build Kamila", "project", 2) == true

            active = KM.get_active_goals()
            @test length(active) == 2
            @test get(active[1], "goal", "") == "Learn Julia"
            @test get(active[1], "category", "") == "coding"

            @test KM.complete_goal(1) == true
            @test KM.complete_goal(999) == false

            active_after = KM.get_active_goals()
            @test length(active_after) == 1
            @test get(active_after[1], "id", 0) == 2
        end
    end

    @testset "achievements" begin
        with_fresh_db() do
            reset_memory_file!(TEST_SANDBOX[]["memory_file"])
            @test isempty(KM.get_today_achievements())
            @test KM.add_achievement("Test Achievement", "desc") == true
            today = KM.get_today_achievements()
            @test length(today) == 1
            @test get(today[1], "title", "") == "Test Achievement"
        end
    end

    @testset "track_activity updates stats" begin
        with_fresh_db() do
            reset_memory_file!(TEST_SANDBOX[]["memory_file"])
            KM.track_activity(true)
            KM.track_activity(true)
            KM.track_activity(false)
            stats = KM.get_memory_stats()
            @test stats["total_activities"] == 3
            @test stats["productivity_percentage"] == 66.7
        end
    end

    @testset "get_memory_stats shape" begin
        with_fresh_db() do
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
        end
    end

    @testset "generate_summary includes user and counts" begin
        with_fresh_db() do
            reset_memory_file!(TEST_SANDBOX[]["memory_file"])
            summary = KM.generate_summary()
            @test occursin("MEMORY SUMMARY", summary)
            @test occursin("Test", summary)
        end
    end

    @testset "export/import round-trip" begin
        with_fresh_db() do
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
        end
    end

    @testset "reset_stats and clear_memory" begin
        with_fresh_db() do
            reset_memory_file!(TEST_SANDBOX[]["memory_file"])
            KM.track_activity(true)
            @test KM.reset_stats() == true
            stats = KM.get_memory_stats()
            @test stats["total_activities"] == 0
            @test KM.clear_memory() == true
            @test isfile(TEST_SANDBOX[]["memory_file"])
        end
    end

    @testset "typed CRUD: tasks" begin
        with_fresh_db() do
            reset_memory_file!(TEST_SANDBOX[]["memory_file"])
            # add via upsert_task
            KM.upsert_task(Dict("title" => "Task A", "priority" => 3))
            KM.upsert_task(Dict("title" => "Task B", "priority" => 1))
            tasks = KM.get_tasks()
            @test length(tasks) == 2
            @test tasks[1]["title"] == "Task A"
            @test tasks[2]["title"] == "Task B"

            # complete
            KM.complete_task_db(tasks[1]["id"])
            reloaded = KM.get_tasks()
            @test reloaded[1]["completed"] == true

            # delete
            KM.delete_task(tasks[2]["id"])
            remaining = KM.get_tasks()
            @test length(remaining) == 1
            @test remaining[1]["title"] == "Task A"

            # upsert_tasks bulk replace
            KM.upsert_tasks([Dict("title" => "New Task", "id" => 100)])
            tasks2 = KM.get_tasks()
            @test length(tasks2) == 1
            @test tasks2[1]["id"] == 100
            @test tasks2[1]["title"] == "New Task"
        end
    end

    @testset "typed CRUD: chat history" begin
        with_fresh_db() do
            reset_memory_file!(TEST_SANDBOX[]["memory_file"])
            sessions = Dict(
                "default" => [
                    Dict("role" => "user", "content" => "Hello"),
                    Dict("role" => "assistant", "content" => "Hi there", "idx" => 2),
                ],
                "session2" => [Dict("role" => "user", "content" => "Another session")],
            )
            KM.save_chat_history(sessions)
            loaded = KM.load_chat_history()
            @test haskey(loaded, "default")
            @test haskey(loaded, "session2")
            @test length(loaded["default"]) == 2
            @test loaded["default"][1]["role"] == "user"
            @test loaded["default"][1]["content"] == "Hello"
            @test loaded["default"][2]["role"] == "assistant"
        end
    end

end

@testset "TaskManager DB-backed" begin

    @testset "add_task creates task with defaults" begin
        with_fresh_db() do
            reset_memory_file!(TEST_SANDBOX[]["memory_file"])
            task = TM.add_task("Write report")
            @test task isa TM.Task
            @test task.id == 1
            @test task.title == "Write report"
            @test task.description == ""
            @test task.category == "general"
            @test task.priority == 2
            @test task.estimated_time == 30
            @test task.due_date === nothing
            @test task.completed == false
            @test task.tags == String[]
        end
    end

    @testset "add_task increments ids and persists" begin
        with_fresh_db() do
            reset_memory_file!(TEST_SANDBOX[]["memory_file"])
            TM.add_task("One")
            TM.add_task("Two")
            TM.add_task("Three")
            reloaded = TM.load_tasks()
            @test length(reloaded) == 3
            @test sort([t.id for t in reloaded]) == [1, 2, 3]
        end
    end

    @testset "list_tasks filters and sorts" begin
        with_fresh_db() do
            reset_memory_file!(TEST_SANDBOX[]["memory_file"])
            TM.add_task("Low"; priority = 1, category = "work")
            TM.add_task("High"; priority = 4, category = "work")
            TM.add_task("Med"; priority = 2, category = "home")

            all_tasks = TM.list_tasks()
            @test length(all_tasks) == 3
            @test all_tasks[1].title == "High"
            @test all_tasks[end].title == "Low"

            work = TM.list_tasks(category = "work")
            @test length(work) == 2
            @test all(t -> t.category == "work", work)

            TM.complete_task(2)
            pending = TM.list_tasks(completed = false)
            @test length(pending) == 2
            done = TM.list_tasks(completed = true)
            @test length(done) == 1
            @test done[1].title == "High"
        end
    end

    @testset "complete_task and delete_task" begin
        with_fresh_db() do
            reset_memory_file!(TEST_SANDBOX[]["memory_file"])
            task = TM.add_task("To complete")
            @test TM.complete_task(task.id) == true
            @test TM.complete_task(999) == false

            completed = TM.list_tasks(completed = true)
            @test length(completed) == 1
            @test completed[1].completed == true
            @test completed[1].completed_date == Date(now())

            @test TM.delete_task(task.id) == true
            @test TM.delete_task(task.id) == false
            @test isempty(TM.load_tasks())
        end
    end

    @testset "get_pending_tasks excludes completed" begin
        with_fresh_db() do
            reset_memory_file!(TEST_SANDBOX[]["memory_file"])
            TM.add_task("Pending A")
            TM.add_task("Pending B")
            TM.add_task("Done A")
            TM.complete_task(3)
            pending = TM.get_pending_tasks()
            @test length(pending) == 2
            @test all(t -> !t.completed, pending)
        end
    end

    @testset "get_overdue_tasks only overdue ones" begin
        with_fresh_db() do
            reset_memory_file!(TEST_SANDBOX[]["memory_file"])
            TM.add_task("Overdue"; due_date = Date(now()) - Day(2))
            TM.add_task("Due today"; due_date = Date(now()))
            TM.add_task("Future"; due_date = Date(now()) + Day(3))
            TM.add_task("No due date")
            overdue = TM.get_overdue_tasks()
            @test length(overdue) == 1
            @test overdue[1].title == "Overdue"
        end
    end

    @testset "generate_timetable respects hours_available" begin
        with_fresh_db() do
            reset_memory_file!(TEST_SANDBOX[]["memory_file"])
            TM.add_task("Short task"; estimated_time = 30, priority = 4)
            TM.add_task("Long task"; estimated_time = 120, priority = 3)
            TM.add_task("Skipped"; estimated_time = 500, priority = 2)

            scheduled = TM.generate_timetable(hours_available = 3)
            @test length(scheduled) == 2
            scheduled_titles = [t.title for (t, _) in scheduled]
            @test "Skipped" ∉ scheduled_titles
            @test scheduled_titles == ["Short task", "Long task"]

            @test scheduled[1][2] == Time(9, 0)
            @test scheduled[2][2] == Time(9, 30)

            @test isempty(TM.generate_timetable(hours_available = 0))
        end
    end

    @testset "get_task_stats" begin
        with_fresh_db() do
            reset_memory_file!(TEST_SANDBOX[]["memory_file"])
            stats = TM.get_task_stats()
            @test stats["total_tasks"] == 0
            @test stats["completion_rate"] == 0.0

            TM.add_task("A"; priority = 3, estimated_time = 60)
            TM.add_task("B"; priority = 1, estimated_time = 30)
            TM.complete_task(1)
            stats = TM.get_task_stats()
            @test stats["total_tasks"] == 2
            @test stats["pending_tasks"] == 1
            @test stats["completed_today"] == 1
            @test stats["completion_rate"] == 50.0
            @test stats["total_estimated_time"] == 30
            @test sort(collect(stats["categories"])) == ["general"]
        end
    end

    @testset "generate_daily_report" begin
        with_fresh_db() do
            reset_memory_file!(TEST_SANDBOX[]["memory_file"])
            report = TM.generate_daily_report()
            @test occursin("Daily Task Report", report)
            @test occursin("Total tasks: 0", report)

            TM.add_task("Report task"; estimated_time = 60)
            report = TM.generate_daily_report()
            @test occursin("Today's Schedule", report)
            @test occursin("Report task", report)
        end
    end

    @testset "export_tasks writes JSON array" begin
        with_fresh_db() do
            reset_memory_file!(TEST_SANDBOX[]["memory_file"])
            TM.add_task("Export me"; description = "desc", tags = ["a", "b"])
            export_path = joinpath(TEST_SANDBOX[]["root"], "tasks_export.json")
            @test TM.export_tasks(export_path) == true
            @test isfile(export_path)
            data = JSON.parsefile(export_path)
            @test data isa Vector
            @test length(data) == 1
            @test get(data[1], "title", "") == "Export me"
            @test get(data[1], "tags", []) == ["a", "b"]
        end
    end

end
