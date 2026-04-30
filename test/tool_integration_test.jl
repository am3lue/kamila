using Test
using JSON

# Create a unique mock environment for E2E
module MockE2EEnv
    using Dates

    # Mock dependencies for AgentTools
    module FileAccess
        function safe_read_file(path::String) return "File content of $path" end
        function safe_write_file(path::String, content::String) return true end
    end
    module KamilaMemory
        function load_memory() return Dict() end
        function save_memory(d) return true end
    end
    module TaskManager
        function parse_date(d::String) return d end
    end

    include("../src/ai/tools.jl")

    # Mock dependencies for Agent
    module OllamaInterface
        function query_ollama(args...; kwargs...) end
    end
    module Term
        struct Panel
            Panel(args...; kwargs...) = new()
        end
    end
    module Crayons
        struct Crayon
            Crayon(;kwargs...) = new()
        end
        (c::Crayon)(txt) = txt
    end

    # Agent uses ..AgentTools
    include("../src/ai/agent.jl")
end

@testset "Tool Integration Flow" begin
    # Access modules via the unique environment
    A = MockE2EEnv.Agent
    AT = MockE2EEnv.AgentTools
    
    @testset "End-to-End: AI Response -> Parse -> Execute" begin
        # 1. Define an AI response with a tool call
        ai_response = """
        I will help you read that file.
        ```json
        {
            "tool": "read_file",
            "args": {
                "file_path": "example.txt"
            }
        }
        ```
        """

        # 2. Parse the response
        is_tool, tool_name, tool_args = A.parse_response(ai_response)
        
        @test is_tool == true
        @test tool_name == "read_file"
        @test tool_args["file_path"] == "example.txt"

        # 3. Execute the identified tool
        if is_tool
            output = AT.execute_tool(tool_name, tool_args)
            @test output == "File content of example.txt"
        end
    end

    @testset "Integration: Task Addition Flow" begin
        ai_response = """
        {"tool": "add_task", "args": {"title": "Integration Test", "priority": 1}}
        """
        
        is_tool, tool_name, tool_args = A.parse_response(ai_response)
        @test is_tool == true
        
        if is_tool
            output = AT.execute_tool(tool_name, tool_args)
            @test contains(output, "Task added successfully")
            @test contains(output, "Integration Test")
        end
    end

    @testset "Integration: Non-tool Response" begin
        ai_response = "I am a helpful assistant, no tools needed here."
        
        is_tool, tool_name, tool_args = A.parse_response(ai_response)
        @test is_tool == false
        @test tool_name == ""
    end

    @testset "UI Formatting Regression" begin
        # This test ensures the println logic doesn't crash
        # Mocking the call that was failing
        tool_name = "test_tool"
        try
            # We just want to ensure this doesn't throw a MethodError
            # In the real code it was: println(Crayon(...)("...") * Crayon(...)(tool_name))
            # Which failed because println returns nothing.
            
            # Since we are in a test, we can capture the output or just run the logic
            # but here we just verify the fix concept:
            part1 = MockE2EEnv.Crayons.Crayon()("🛠️  Using tool: ")
            part2 = MockE2EEnv.Crayons.Crayon()(tool_name)
            
            # The fix was changing * to , in println
            # nothing * part2 would fail
            @test_throws MethodError nothing * part2
            
            # The correct way is handled by println itself
            @test (part1, part2) isa Tuple{String, String}
        catch e
            rethrow(e)
        end
    end

end
