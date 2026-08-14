"""
test/task_manager_test.jl — Tier-1 tests of the real `TaskManager` module against
an isolated temp MEMORY_FILE (no mocks).
"""

using Test
using Dates
using JSON

using .Kamila
const TM = Kamila.TaskManager

reset_memory_file!(TEST_SANDBOX[]["memory_file"])

@testset "TaskManager" begin
    @testset "parse_date handles formats and garbage" begin
        @test TM.parse_date("2026-08-07") == Date(2026, 8, 7)
        @test TM.parse_date("") === nothing
        @test TM.parse_date("nothing") === nothing
        @test TM.parse_date("not a date") === nothing
        @test TM.parse_date("07/08/2026") === nothing
        @test TM.parse_date("2026-8-7") == Date(2026, 8, 7)
    end

    @testset "add_task creates task with defaults" begin
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
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
    end

    @testset "add_task increments ids and persists" begin
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
        TM.add_task("One")
        TM.add_task("Two")
        TM.add_task("Three")
        reloaded = TM.load_tasks()
        @test length(reloaded) == 3
        @test sort([t.id for t in reloaded]) == [1, 2, 3]
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
    end

    @testset "list_tasks filters and sorts" begin
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
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
    end

    @testset "complete_task and delete_task" begin
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
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
    end

    @testset "get_pending_tasks excludes completed" begin
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
        TM.add_task("Pending A")
        TM.add_task("Pending B")
        TM.add_task("Done A")
        TM.complete_task(3)
        pending = TM.get_pending_tasks()
        @test length(pending) == 2
        @test all(t -> !t.completed, pending)
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
    end

    @testset "get_overdue_tasks only overdue ones" begin
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
        TM.add_task("Overdue"; due_date = Date(now()) - Day(2))
        TM.add_task("Due today"; due_date = Date(now()))
        TM.add_task("Future"; due_date = Date(now()) + Day(3))
        TM.add_task("No due date")
        overdue = TM.get_overdue_tasks()
        @test length(overdue) == 1
        @test overdue[1].title == "Overdue"
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
    end

    @testset "generate_timetable respects hours_available" begin
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
        TM.add_task("Short task"; estimated_time = 30, priority = 4)
        TM.add_task("Long task"; estimated_time = 120, priority = 3)
        TM.add_task("Skipped"; estimated_time = 500, priority = 2)

        scheduled = TM.generate_timetable(hours_available = 3)
        @test length(scheduled) == 2
        scheduled_titles = [t.title for (t, _) in scheduled]
        @test "Skipped" ∉ scheduled_titles
        @test scheduled_titles == ["Short task", "Long task"]

        # Start time progression: 30 min + 120 min from 09:00
        @test scheduled[1][2] == Time(9, 0)
        @test scheduled[2][2] == Time(9, 30)

        # No time available: 0 minutes can't fit the 30-min task.
        @test isempty(TM.generate_timetable(hours_available = 0))
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
    end

    @testset "get_task_stats" begin
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
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
    end

    @testset "generate_daily_report" begin
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
        report = TM.generate_daily_report()
        @test occursin("Daily Task Report", report)
        @test occursin("Total tasks: 0", report)

        TM.add_task("Report task"; estimated_time = 60)
        report = TM.generate_daily_report()
        @test occursin("Today's Schedule", report)
        @test occursin("Report task", report)
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
    end

    @testset "export_tasks writes JSON array" begin
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
        reset_memory_file!(TEST_SANDBOX[]["memory_file"])
    end
end
