"""
test/skill_test.jl — Tests for the skill registry (05.2): built-in seeding,
enable/disable effects on get_all_tools(), JSON spec install, version bumps,
user-dir skill loading, learn_skill gating, the shell template allowlist, the
skills.* bridge routes, and persistence across re-initialization.
"""

using Test
using JSON
using Dates

using .Kamila
const SK = Kamila.Skills
const AT = Kamila.AgentTools
const MDB = Kamila.MemoryDB
const BR = Kamila.KamilaBridge

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

function reset_seed_flag()
    # Force re-seeding on the next registry access within this process.
    SK._SEEDED[] = false
    return nothing
end

@testset "Skills" begin
    @testset "schema v6 migration" begin
        with_fresh_db() do
            @test MDB.schema_version() >= 7
            tables = [r.name for r in MDB.query_all(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='skills'",
            )]
            @test "skills" in tables
            cols = [r.name for r in MDB.query_all("PRAGMA table_info(skills)")]
            for c in ["id", "name", "version", "spec", "description", "impl_type",
                "impl_ref", "enabled", "source", "created_at", "updated_at"]
                @test c in cols
            end
        end
    end

    @testset "built-in seeding" begin
        with_fresh_db() do
            reset_seed_flag()
            SK.seed_builtins!()
            all_skills = SK.load_all()
            @test length(all_skills) >= 14
            names = [s.name for s in all_skills]
            for expected in ["run_shell_command", "read_file", "write_file",
                "memory_query", "decompose_goal"]
                @test expected in names
            end
            builtin = SK.get_skill("run_shell_command")
            @test builtin !== nothing
            @test builtin.source == "builtin"
            @test builtin.enabled
            @test builtin.impl_type == "julia"
            @test haskey(builtin.spec, "properties")
            reset_seed_flag()
        end
    end

    @testset "registry drives get_all_tools (enable/disable)" begin
        with_fresh_db() do
            reset_seed_flag()
            tools = AT.get_all_tools()
            @test any(t -> t.name == "run_shell_command", tools)

            SK.disable!("run_shell_command")
            tools = AT.get_all_tools()
            @test !any(t -> t.name == "run_shell_command", tools)
            @test any(t -> t.name == "read_file", tools)

            SK.enable!("run_shell_command")
            tools = AT.get_all_tools()
            @test any(t -> t.name == "run_shell_command", tools)
            reset_seed_flag()
        end
    end

    @testset "install / uninstall JSON spec" begin
        with_fresh_db() do
            reset_seed_flag()
            spec = Dict{String,Any}(
                "name" => "my_greeter",
                "description" => "Say hello via a shell echo",
                "parameters" => Dict{String,Any}(
                    "type" => "object",
                    "properties" => Dict{String,Any}(
                        "input" => Dict{String,Any}("type" => "string"),
                    ),
                    "required" => ["input"],
                ),
                "impl_type" => "shell",
                "impl_ref" => "echo hello {input}",
                "version" => "1.0.0",
            )
            s = SK.install!(spec)
            @test s.name == "my_greeter"
            @test s.enabled
            @test s.source == "user"

            tools = AT.get_all_tools()
            @test any(t -> t.name == "my_greeter", tools)
            result = AT.execute_tool_structured("my_greeter", Dict("input" => "world"))
            @test result["ok"]
            @test occursin("hello world", result["result"])

            SK.uninstall!("my_greeter")
            tools = AT.get_all_tools()
            @test !any(t -> t.name == "my_greeter", tools)
            reset_seed_flag()
        end
    end

    @testset "built-in cannot be uninstalled" begin
        with_fresh_db() do
            reset_seed_flag()
            @test_throws SK.Errors.KamilaError SK.uninstall!("read_file")
            reset_seed_flag()
        end
    end

    @testset "version bump preserves enabled flag" begin
        with_fresh_db() do
            reset_seed_flag()
            spec = Dict{String,Any}(
                "name" => "v_skill",
                "description" => "v1",
                "impl_type" => "prompt",
                "impl_ref" => "step one",
                "version" => "1.0.0",
            )
            SK.install!(spec)
            SK.disable!("v_skill")

            spec2 = Dict{String,Any}(
                "name" => "v_skill",
                "description" => "v2",
                "impl_type" => "prompt",
                "impl_ref" => "step one, refined",
                "version" => "2.0.0",
            )
            s = SK.install!(spec2; source = "user")
            @test s.version == "2.0.0"
            @test !s.enabled   # preserved the disabled state
            reset_seed_flag()
        end
    end

    @testset "learn_skill registers disabled agent skill" begin
        with_fresh_db() do
            reset_seed_flag()
            r = SK.learn_skill(
                Dict{String,Any}(
                    "name" => "weekly_report",
                    "procedure" => "1. query memory summary 2. format markdown",
                    "impl_type" => "prompt",
                ),
            )
            @test r["ok"]
            s = SK.get_skill("weekly_report")
            @test s !== nothing
            @test s.source == "agent"
            @test !s.enabled
            @test s.impl_ref == "1. query memory summary 2. format markdown"

            # invalid impl_type rejected
            bad = SK.learn_skill(
                Dict{String,Any}(
                    "name" => "bad_skill",
                    "procedure" => "x",
                    "impl_type" => "julia",
                ),
            )
            @test !bad["ok"]
            @test bad["category"] == "validation"

            # disabled agent skill is not exposed to the agent
            tools = AT.get_all_tools()
            @test !any(t -> t.name == "weekly_report", tools)

            # enabling it exposes the prompt skill
            SK.enable!("weekly_report")
            tools = AT.get_all_tools()
            @test any(t -> t.name == "weekly_report", tools)
            result = AT.execute_tool_structured("weekly_report", Dict{String,Any}())
            @test result["result"] == "1. query memory summary 2. format markdown"
            reset_seed_flag()
        end
    end

    @testset "shell template allowlist rejects rm" begin
        with_fresh_db() do
            reset_seed_flag()
            spec = Dict{String,Any}(
                "name" => "danger_shell",
                "description" => "dangerous",
                "impl_type" => "shell",
                "impl_ref" => "rm {input}",
                "parameters" => Dict{String,Any}(
                    "type" => "object",
                    "properties" => Dict{String,Any}(
                        "input" => Dict{String,Any}("type" => "string"),
                    ),
                ),
            )
            s = SK.install!(spec)
            result = AT.execute_tool_structured("danger_shell", Dict("input" => "target.txt"))
            @test !result["ok"]
            @test occursin("validation", result["result"])
            reset_seed_flag()
        end
    end

    @testset "max skills cap" begin
        with_fresh_db() do
            reset_seed_flag()
            for i in 1:100
                try
                    SK.install!(
                        Dict{String,Any}(
                            "name" => "cap_skill_$i",
                            "description" => "c$i",
                            "impl_type" => "prompt",
                            "impl_ref" => "p",
                        ),
                    )
                catch
                end
            end
            @test length(SK.load_all()) <= SK.MAX_SKILLS
            @test_throws SK.Errors.KamilaError SK.install!(
                Dict{String,Any}(
                    "name" => "overflow",
                    "description" => "o",
                    "impl_type" => "prompt",
                    "impl_ref" => "p",
                ),
            )
            reset_seed_flag()
        end
    end

    @testset "user-dir skills load with isolated sandbox" begin
        with_fresh_db() do
            reset_seed_flag()
            dir = mktempdir()
            old_dir = SK.USER_SKILLS_DIR[]
            SK.USER_SKILLS_DIR[] = dir
            SK._USER_LOADED[] = false
            write(
                joinpath(dir, "greet_user.jl"),
                """
                register_skill(
                    Dict("name" => "user_greeter", "description" => "user skill",
                         "impl_type" => "prompt", "impl_ref" => "hello from user dir"),
                    (args) -> "hello",
                )
                """,
            )
            # a broken file must not abort the process
            write(joinpath(dir, "broken.jl"), "this is not julia &&&")
            try
                SK.load_user_skills!()
                s = SK.get_skill("user_greeter")
                @test s !== nothing
                @test s.source == "user"
                @test s.enabled
                tools = AT.get_all_tools()
                @test any(t -> t.name == "user_greeter", tools)
            finally
                SK.USER_SKILLS_DIR[] = old_dir
                SK._USER_LOADED[] = false
                rm(dir; recursive = true, force = true)
            end
            reset_seed_flag()
        end
    end

    @testset "persistence across re-init" begin
        old_db = get(ENV, "KAMILA_DB", nothing)
        dir = mktempdir()
        ENV["KAMILA_DB"] = joinpath(dir, "persist.db")
        try
            MDB.reset!()
            reset_seed_flag()
            SK.install!(
                Dict{String,Any}(
                    "name" => "persist_skill",
                    "description" => "p",
                    "impl_type" => "prompt",
                    "impl_ref" => "persist me",
                ),
            )
            MDB.reset!()   # simulate process restart: fresh handle

            # NOTE: within one process the `_SEEDED` flag and registration live in
            # module memory; we reset the flag to force a reload from the DB.
            reset_seed_flag()
            s = SK.get_skill("persist_skill")
            @test s !== nothing
            @test s.impl_ref == "persist me"
        finally
            MDB.reset!()
            rm(dir; recursive = true, force = true)
            old_db === nothing ? delete!(ENV, "KAMILA_DB") : ENV["KAMILA_DB"] = old_db
        end
    end

    @testset "skills.* bridge routes" begin
        with_fresh_db() do
            reset_seed_flag()
            out = capture_stdout() do
                BR.dispatch(
                    Dict(
                        "type" => "request",
                        "id" => "s1",
                        "method" => "skills.list",
                        "params" => Dict{String,Any}(),
                    ),
                )
            end
            events = Dict{String,Any}[JSON.parse(l) for l in split(strip(out), "\n") if !isempty(strip(l))]
            resp = findfirst(e -> get(e, "type", "") == "response", events)
            @test resp !== nothing
            @test events[resp]["id"] == "s1"
            @test get(events[resp], "error", nothing) === nothing
            @test length(events[resp]["result"]["skills"]) >= 14

            out = capture_stdout() do
                BR.dispatch(
                    Dict(
                        "type" => "request",
                        "id" => "s2",
                        "method" => "skills.install",
                        "params" => Dict("spec" => Dict(
                            "name" => "route_skill",
                            "description" => "r",
                            "impl_type" => "prompt",
                            "impl_ref" => "r",
                        )),
                    ),
                )
            end
            events = Dict{String,Any}[JSON.parse(l) for l in split(strip(out), "\n") if !isempty(strip(l))]
            resp = findfirst(e -> get(e, "type", "") == "response", events)
            @test events[resp]["result"]["name"] == "route_skill"

            out = capture_stdout() do
                BR.dispatch(
                    Dict(
                        "type" => "request",
                        "id" => "s3",
                        "method" => "skills.disable",
                        "params" => Dict("name" => "route_skill"),
                    ),
                )
            end
            events = Dict{String,Any}[JSON.parse(l) for l in split(strip(out), "\n") if !isempty(strip(l))]
            resp = findfirst(e -> get(e, "type", "") == "response", events)
            @test events[resp]["result"]["enabled"] == false

            out = capture_stdout() do
                BR.dispatch(
                    Dict(
                        "type" => "request",
                        "id" => "s4",
                        "method" => "skills.uninstall",
                        "params" => Dict("name" => "route_skill"),
                    ),
                )
            end
            events = Dict{String,Any}[JSON.parse(l) for l in split(strip(out), "\n") if !isempty(strip(l))]
            resp = findfirst(e -> get(e, "type", "") == "response", events)
            @test events[resp]["result"]["removed"] == true
            reset_seed_flag()
        end
    end
end