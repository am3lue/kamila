using Test
using JSON
using Dates

# Create a mock environment for AgentTools
module MockKamilaEnv
    using Dates

    # Mock Kamila constants
    module Kamila
        const ALLOWED_DIRS = String[]
    end

    # Mock FileAccess
    module FileAccess
        function safe_read_file(path::String)
            return read(path, String)
        end
        function safe_write_file(path::String, content::String)
            write(path, content)
            return true
        end
    end

    # Mock KamilaMemory
    module KamilaMemory
        function load_memory()
            return Dict()
        end
        function save_memory(data)
            return true
        end
    end

    # Mock TaskManager
    module TaskManager
        function parse_date(date_str::String)
            try
                return Date(date_str)
            catch
                return nothing
            end
        end
    end

    # Now include the tools.jl file
    # We use include such that the relative path works
    include("../src/ai/tools.jl")
end

using .MockKamilaEnv.AgentTools

@testset "Kamila Tool Parts Tests" begin
    
    @testset "Discovery" begin
        tools = get_all_tools()
        @test length(tools) >= 6
        @test any(t -> t.name == "run_shell_command", tools)
        @test any(t -> t.name == "read_file", tools)
        @test any(t -> t.name == "write_file", tools)
        @test any(t -> t.name == "add_task", tools)
        @test any(t -> t.name == "list_tasks", tools)
        @test any(t -> t.name == "complete_task", tools)
    end

    @testset "File Tools" begin
        mktempdir() do tmpdir
            test_file = joinpath(tmpdir, "test.txt")
            test_content = "Hello from tests!"
            
            # Test write_file
            write_args = Dict("file_path" => test_file, "content" => test_content)
            write_result = execute_tool("write_file", write_args)
            @test contains(write_result, "Successfully wrote")
            @test isfile(test_file)
            @test read(test_file, String) == test_content
            
            # Test read_file
            read_args = Dict("file_path" => test_file)
            read_result = execute_tool("read_file", read_args)
            @test read_result == test_content
            
            # Test read_file error
            @test contains(execute_tool("read_file", Dict("file_path" => "nonexistent.txt")), "Error")
        end
    end

    @testset "Shell Command Tool" begin
        # run_shell_command requires user input. 
        # We can mock stdin by redirecting it.
        
        # Test Case 1: Denied by user
        let
            original_stdin = stdin
            (rd, wr) = redirect_stdin()
            try
                write(wr, "n\n")
                flush(wr)
                
                result = execute_tool("run_shell_command", Dict("command" => "echo 'hello'"))
                @test contains(result, "denied by user")
            finally
                redirect_stdin(original_stdin)
                close(rd)
                close(wr)
            end
        end

        # Test Case 2: Allowed by user
        let
            original_stdin = stdin
            (rd, wr) = redirect_stdin()
            try
                write(wr, "y\n")
                flush(wr)
                
                result = execute_tool("run_shell_command", Dict("command" => "echo 'hello world'"))
                @test strip(result) == "hello world"
            finally
                redirect_stdin(original_stdin)
                close(rd)
                close(wr)
            end
        end
    end

    @testset "Task Tools" begin
        # add_task
        add_result = execute_tool("add_task", Dict("title" => "Test Task", "priority" => 1))
        @test contains(add_result, "Task added successfully")
        @test contains(add_result, "Test Task")

        # list_tasks
        list_result = execute_tool("list_tasks", Dict())
        @test contains(list_result, "Pending Tasks")
        @test contains(list_result, "Review code changes")

        # complete_task
        complete_result = execute_tool("complete_task", Dict("task_id" => 1))
        @test contains(complete_result, "Task 1 marked as completed")
        
        # complete_task error
        @test contains(execute_tool("complete_task", Dict()), "Error")
    end

    @testset "Tool Execution Logic" begin
        # Test with non-Dict args (e.g. JSON Object)
        # In Julia, JSON.parse often returns Dict{String, Any} anyway, 
        # but let's test if it handles it correctly.
        
        tools = get_all_tools()
        @test execute_tool("nonexistent_tool", Dict()) == "Error: Tool 'nonexistent_tool' not found"
    end

end
