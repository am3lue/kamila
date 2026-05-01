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
        is_tool, name, args, thought = Agent.parse_response(json_resp)
        @test is_tool == true
        @test name == "list_files"
        @test args["path"] == "."
    end

    @testset "Response Parsing - AI Reasoning" begin
        # Text + JSON
        resp = "I need to check the directory. ```json\n{\"tool\": \"ls\"}\n```"
        is_tool, name, args, thought = Agent.parse_response(resp)
        @test is_tool == true
        @test name == "ls"
        @test contains(thought, "I need to check")
    end

    @testset "Response Parsing - AI Mistakes" begin
        # Trailing comma
        json_comma = "{\"tool\": \"read_file\", \"args\": {\"file\": \"test.txt\"},}"
        is_tool, name, args, thought = Agent.parse_response(json_comma)
        @test is_tool == true
        @test name == "read_file"
    end

    @testset "Response Parsing - Flat Structure" begin
        # AI might put everything at top level
        json_flat = "{\"tool\": \"complete_task\", \"task_id\": 123}"
        is_tool, name, args, thought = Agent.parse_response(json_flat)
        @test is_tool == true
        @test name == "complete_task"
        @test args["task_id"] == 123
    end
end
