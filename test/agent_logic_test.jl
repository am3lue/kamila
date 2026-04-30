using Test
using JSON

# Create a mock environment for Agent
module MockAgentEnv
    module OllamaInterface
        function query_ollama(args...; kwargs...) end
    end
    module AgentTools
        function get_all_tools() return [] end
    end
    module Term
        struct Panel
            content
            Panel(content; kwargs...) = new(content)
        end
    end
    module Crayons
        struct Crayon
            Crayon(;kwargs...) = new()
        end
        (c::Crayon)(txt) = txt
    end

    include("../src/ai/agent.jl")
end

using .MockAgentEnv.Agent

@testset "Robust Agent Logic Tests" begin
    @testset "Response Parsing - Standard" begin
        # Standard block
        json_resp = "```json\n{\"tool\": \"list_files\", \"args\": {\"path\": \".\"}}\n```"
        is_tool, name, args = Agent.parse_response(json_resp)
        @test is_tool == true
        @test name == "list_files"
        @test args["path"] == "."
    end

    @testset "Response Parsing - AI Mistakes" begin
        # Trailing comma (often breaks strict JSON parsers)
        json_comma = "{\"tool\": \"read_file\", \"args\": {\"file\": \"test.txt\"},}"
        is_tool, name, args = Agent.parse_response(json_comma)
        @test is_tool == true
        @test name == "read_file"

        # No 'json' tag in markdown
        json_no_tag = "```\n{\"tool\": \"write_file\", \"args\": {\"content\": \"hi\"}}\n```"
        is_tool, name, args = Agent.parse_response(json_no_tag)
        @test is_tool == true
        @test name == "write_file"
    end

    @testset "Response Parsing - Variation in Keys" begin
        # Using 'name' instead of 'tool'
        json_name = "{\"name\": \"shell_cmd\", \"arguments\": {\"cmd\": \"ls\"}}"
        is_tool, name, args = Agent.parse_response(json_name)
        @test is_tool == true
        @test name == "shell_cmd"
        @test args["cmd"] == "ls"

        # Using 'function' and 'parameters'
        json_func = "{\"function\": \"add_task\", \"parameters\": {\"title\": \"task1\"}}"
        is_tool, name, args = Agent.parse_response(json_func)
        @test is_tool == true
        @test name == "add_task"
        @test args["title"] == "task1"
    end

    @testset "Response Parsing - Flat Structure" begin
        # AI might put everything at top level
        json_flat = "{\"tool\": \"complete_task\", \"task_id\": 123}"
        is_tool, name, args = Agent.parse_response(json_flat)
        @test is_tool == true
        @test name == "complete_task"
        @test args["task_id"] == 123
    end

    @testset "Response Parsing - Multiple Blocks" begin
        # Should pick the first valid tool call
        resp = """
        I will first list files and then read one.
        ```json
        {"tool": "ls", "args": {}}
        ```
        Then I will read:
        ```json
        {"tool": "cat", "args": {"file": "a.txt"}}
        ```
        """
        is_tool, name, args = Agent.parse_response(resp)
        @test is_tool == true
        @test name == "ls"
    end

    @testset "Response Parsing - Garbage Text" begin
        # Text around JSON
        resp = "Here is the tool: {\"tool\": \"echo\", \"args\": {\"msg\": \"hello\"}} hope it helps!"
        is_tool, name, args = Agent.parse_response(resp)
        @test is_tool == true
        @test name == "echo"
        @test args["msg"] == "hello"
    end
end
