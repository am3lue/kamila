"""
test/security_test.jl — Tier-1 tests of the real `FileAccess`, `Auth`, and
`OSCheck` modules against an isolated sandbox (no mocks).
"""

using Test
using JSON
using SHA

using .Kamila
const FA = Kamila.FileAccess
const AUTH = Kamila.Auth
const OSCheck = Kamila.OSCheck

@testset "Security" begin
    @testset "OSCheck" begin
        @test OSCheck.is_linux_os() == Sys.islinux()
        @test OSCheck.is_linux_os() == true

        info = OSCheck.get_system_info()
        for key in [
            "os_name",
            "kernel_version",
            "arch",
            "word_size",
            "cpu_threads",
            "total_memory_gb",
            "free_memory_gb",
            "uptime",
            "is_linux",
        ]
            @test haskey(info, key)
        end
        @test info["is_linux"] == true
        @test info["arch"] isa Symbol
        @test info["cpu_threads"] >= 1

        @test OSCheck.verify_os_compatibility() == true

        report = OSCheck.generate_compatibility_report()
        @test occursin("System Compatibility Report", report)
        @test occursin("Linux Compatible: ✅ Yes", report)

        distro = OSCheck.get_linux_distro()
        @test distro != ""
        @test OSCheck.enforce_platform_restriction() === nothing
    end

    @testset "FileAccess is_path_allowed" begin
        allowed_dir = TEST_SANDBOX[]["allowed"]
        @test FA.is_path_allowed(joinpath(allowed_dir, "file.txt")) == true
        @test FA.is_path_allowed(allowed_dir) == true
        @test FA.is_path_allowed(joinpath(allowed_dir, "sub", "deep.txt")) == true

        # Outside allowed dirs: /etc, /home of the *sandbox* is the temp root,
        # but a sibling dir under root is not allowed (allowed dir is root/allowed).
        @test FA.is_path_allowed("/etc/passwd") == false
        @test FA.is_path_allowed("/tmp/outside.txt") == false
        @test FA.is_path_allowed(joinpath(TEST_SANDBOX[]["root"], "other.txt")) == false
    end

    @testset "FileAccess safe read/write/list/delete" begin
        allowed_dir = TEST_SANDBOX[]["allowed"]
        file = joinpath(allowed_dir, "note.txt")

        @test FA.safe_write_file(file, "hello security") == true
        @test FA.safe_read_file(file) == "hello security"

        listing = FA.safe_list_directory(allowed_dir)
        @test any(f -> basename(f) == "note.txt", listing)

        @test FA.safe_delete_file(file) == true
        @test !isfile(file)

        # Reading a missing file raises
        @test_throws ErrorException FA.safe_read_file(joinpath(allowed_dir, "nope.txt"))

        # Reading outside allowed dir raises
        @test_throws ErrorException FA.safe_read_file("/etc/passwd")
        @test_throws ErrorException FA.safe_write_file("/tmp/evil.txt", "x")

        # Listing a missing dir raises
        @test_throws ErrorException FA.safe_list_directory(joinpath(allowed_dir, "missing"))
    end

    @testset "FileAccess safe_create_directory / move / stat / exists" begin
        allowed_dir = TEST_SANDBOX[]["allowed"]
        sub = joinpath(allowed_dir, "made")
        @test FA.safe_create_directory(sub) == true
        @test isdir(sub)
        # idempotent
        @test FA.safe_create_directory(sub) == true

        src = joinpath(allowed_dir, "a.txt")
        dst = joinpath(sub, "b.txt")
        FA.safe_write_file(src, "move me")
        @test FA.safe_move_file(src, dst) == true
        @test !isfile(src)
        @test isfile(dst)

        @test FA.safe_stat_file(dst) isa Base.Filesystem.StatStruct
        @test FA.safe_exists(dst) == true
        @test FA.safe_exists(joinpath(allowed_dir, "ghost.txt")) == false

        # moving a missing source raises
        @test_throws ErrorException FA.safe_move_file(
            joinpath(allowed_dir, "ghost.txt"),
            dst,
        )

        # create dir outside allowed raises
        @test_throws ErrorException FA.safe_create_directory("/tmp/evil_dir")
    end

    @testset "FileAccess explain_file_content and get_file_type" begin
        allowed_dir = TEST_SANDBOX[]["allowed"]
        file = joinpath(allowed_dir, "code.jl")
        FA.safe_write_file(file, "function foo()\nend")
        explanation = FA.explain_file_content(file)
        @test occursin("File Analysis: code.jl", explanation)
        @test occursin("Julia Source Code", explanation)

        @test FA.get_file_type("x.jl") == "Julia Source Code"
        @test FA.get_file_type("x.md") == "Markdown Document"
        @test FA.get_file_type("x.unknown_ext") == "Unknown File"
        @test FA.get_file_type("NO_EXT") == "Unknown File"
    end

    @testset "FileAccess report and helpers" begin
        report = FA.generate_security_report()
        @test occursin("Security Report", report)
        @test occursin("OS Check", report)

        dirs = FA.get_allowed_directories()
        @test dirs isa AbstractVector{<:AbstractString}
        @test !isempty(dirs)

        ok, base = FA.is_subdirectory_allowed(joinpath(TEST_SANDBOX[]["allowed"], "x"))
        @test ok == true
        @test base == TEST_SANDBOX[]["allowed"]

        ok2, base2 = FA.is_subdirectory_allowed("/etc/passwd")
        @test ok2 == false
        @test base2 == ""
    end

    @testset "Auth set_password / verify / change" begin
        # sandbox config file
        cfg = TEST_SANDBOX[]["config_file"]
        isfile(cfg) && rm(cfg; force = true)

        @test AUTH.is_auth_configured() == false
        @test AUTH.set_password("correct horse battery") == true
        @test AUTH.is_auth_configured() == true

        @test AUTH.verify_password("correct horse battery") == true
        @test AUTH.verify_password("wrong password") == false

        # change_password_to
        @test AUTH.change_password_to("correct horse battery", "new pass 123") == true
        @test AUTH.verify_password("new pass 123") == true
        @test AUTH.verify_password("correct horse battery") == false

        # changing with wrong current fails
        @test AUTH.change_password_to("wrong", "other") == false

        status = AUTH.get_auth_status()
        @test status["configured"] == true
        @test status["locked"] == false
        @test status["failed_attempts"] == 0

        # reset_auth removes the file
        @test AUTH.reset_auth() == true
        @test AUTH.is_auth_configured() == false
        @test AUTH.reset_auth() == true  # no config to reset is still true
        isfile(cfg) && rm(cfg; force = true)
    end

    @testset "Auth save/load config and lock" begin
        cfg = TEST_SANDBOX[]["config_file"]
        isfile(cfg) && rm(cfg; force = true)

        @test AUTH.set_password("pass")
        # Simulate failed attempts and lock state via config
        config = AUTH.load_auth_config()
        config["failed_attempts"] = 3
        config["locked"] = true
        @test AUTH.save_auth_config(config) == true

        status = AUTH.get_auth_status()
        @test status["locked"] == true
        @test status["failed_attempts"] == 3

        @test AUTH.unlock_account() == true
        status = AUTH.get_auth_status()
        @test status["locked"] == false
        @test status["failed_attempts"] == 0

        # load_auth_config on missing file returns Dict()
        isfile(cfg) && rm(cfg; force = true)
        @test isempty(AUTH.load_auth_config())
        @test AUTH.verify_password("anything") == false
        isfile(cfg) && rm(cfg; force = true)
    end
end
