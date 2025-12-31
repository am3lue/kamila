using Test
using JSON

# Create a mock environment
module KamilaTestEnv

    # Mock TaskManager
    module TaskManager
        using Dates
        
        struct Task
            id::Int
            title::String
            priority::Int
        end

        function add_task(title; kwargs...)
            return Task(1, title, get(kwargs, :priority, 2))
        end

        function get_pending_tasks()
            return [Task(1, "Test Task", 2)]
        end

        function complete_task(id)
            return true
        end
    end

    # Mock OllamaInterface
    module OllamaInterface
        function query_ollama(prompt; kwargs...)
            return Dict("success" => true, "response" => "Mock response")
        end
    end

    # Include the source files. 
    # We need to use `include` such that `using ..OllamaInterface` works.
    # But `include` essentially pastes code. 
    # If `Agent` is defined as `module Agent ... end`, it expects to be inside `Kamila`.
    
    # Let's verify how we can load `Agent`.
    # `Agent` does `using ..OllamaInterface`. This means `Agent` expects to be a sibling of `OllamaInterface`
    # inside some parent module.
    
    # So we are inside `KamilaTestEnv`. We have defined `OllamaInterface`.
    # Now we include `tools.jl` (AgentTools) and `agent.jl` (Agent).
    
    # AgentTools uses `..TaskManager`. So we defined `TaskManager` above.
    include("../src/ai/tools.jl")
    
    # Agent uses `..AgentTools` and `..OllamaInterface`.
    include("../src/ai/agent.jl")

end

using .KamilaTestEnv.AgentTools
using .KamilaTestEnv.Agent

@testset "Kamila Agent Tests" begin
    
    @testset "Agent Tools" begin
        # Test 1: get_all_tools
        tools = get_all_tools()
        @test length(tools) > 0
        @test any(t -> t.name == "run_shell_command", tools)

        # Test 2: run_shell_command
        output = AgentTools.execute_tool("run_shell_command", Dict("command" => "echo 'hello world'"))
        @test strip(output) == "hello world"

        # Test 3: write_file and read_file
        test_file = "test_agent_file.txt"
        test_content = "This is a test content."
        
        # Write
        write_output = AgentTools.execute_tool("write_file", Dict("file_path" => test_file, "content" => test_content))
        @test contains(write_output, "Successfully wrote")
        @test isfile(test_file)

        # Read
        read_output = AgentTools.execute_tool("read_file", Dict("file_path" => test_file))
        @test read_output == test_content

        # Cleanup
        rm(test_file)
    end

    @testset "Agent Logic" begin
        # Test parse_response with simple JSON
        json_resp = "{\"tool\": \"list_files\", \"args\": {\"path\": \".\"}}"
        is_tool, name, args = Agent.parse_response(json_resp)
        @test is_tool == true
        @test name == "list_files"
        @test args["path"] == "."

        # Test parse_response with Markdown block
        md_resp = """
        Here is the tool call:
        ```json
        {
            "tool": "read_file",
            "args": {
                "file_path": "test.txt"
            }
        }
        ```
        """
        is_tool, name, args = Agent.parse_response(md_resp)
        @test is_tool == true
        @test name == "read_file"
        @test args["file_path"] == "test.txt"
        
        # Test invalid JSON inside code block
        invalid_resp = """
        ```json
        { invalid json }
        ```
        """
        is_tool, _, _ = Agent.parse_response(invalid_resp)
        @test is_tool == false
    end
end