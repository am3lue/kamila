
push!(LOAD_PATH, joinpath(@__DIR__, "../src"))

# We need to include the main module file to load the hierarchy
include("../src/Kamila.jl")

using .Kamila
using .Kamila.AgentTools
using .Kamila.FileAccess
using Test

@testset "Security Tests" begin
    # Setup: Create a dummy file in an allowed directory
    desktop_path = joinpath(homedir(), "Desktop")
    # Ensure directory exists (it should in the real env, but for safety)
    if !isdir(desktop_path)
        mkpath(desktop_path)
    end
    
    test_file = joinpath(desktop_path, "test_safe_file.txt")
    write(test_file, "This is safe content")

    @testset "File Access Restrictions" begin
        # Test 1: Read allowed file
        println("Testing allowed file read...")
        result = AgentTools.read_file(Dict("file_path" => test_file))
        @test result == "This is safe content"

        # Test 2: Read restricted file (e.g., /etc/passwd or /etc/hosts)
        println("Testing restricted file read...")
        # Use a file that definitely exists on Linux but is restricted
        restricted_file = "/etc/hosts"
        result = AgentTools.read_file(Dict("file_path" => restricted_file))
        @test startswith(result, "Error reading file")
        @test occursin("outside of allowed directories", result)

        # Test 3: Write allowed file
        println("Testing allowed file write...")
        new_content = "Updated content"
        result = AgentTools.write_file(Dict("file_path" => test_file, "content" => new_content))
        @test startswith(result, "Successfully wrote")
        @test read(test_file, String) == new_content

        # Test 4: Write restricted file
        println("Testing restricted file write...")
        restricted_write = "/tmp/evil_script.sh" # /tmp is not in ALLOWED_DIRS
        result = AgentTools.write_file(Dict("file_path" => restricted_write, "content" => "evil"))
        @test startswith(result, "Error writing file")
        @test occursin("outside of allowed directories", result)
    end

    # Clean up
    rm(test_file, force=true)
end
