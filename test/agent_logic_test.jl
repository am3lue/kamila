using Test
using JSON

module MockAgentEnv
module OllamaInterface
function query_ollama(args...; kwargs...) end
end
module AgentTools
function get_all_tools()
    return []
end
end
module TTS
function speak(text) end
end
module ResponseParser
function parse_response(text)
    return (false, "", Dict{String,Any}(), String(text))
end
end

include("../src/ai/agent.jl")
end

using .MockAgentEnv.Agent

@testset "Robust Agent Logic Tests" begin
    @testset "Response Parsing - Standard" begin
        json_resp = "```json\n{\"tool\": \"list_files\", \"args\": {\"path\": \".\"}}\n```"
        is_tool, name, args, thought = Agent.parse_response(json_resp)
        @test is_tool == true
        @test name == "list_files"
        @test args["path"] == "."
    end

    @testset "Response Parsing - AI Reasoning" begin
        resp = "I need to check the directory. ```json\n{\"tool\": \"ls\"}\n```"
        is_tool, name, args, thought = Agent.parse_response(resp)
        @test is_tool == true
        @test name == "ls"
        @test contains(thought, "I need to check")
    end

    @testset "Response Parsing - AI Mistakes" begin
        json_comma = "{\"tool\": \"read_file\", \"args\": {\"file\": \"test.txt\"},}"
        is_tool, name, args, thought = Agent.parse_response(json_comma)
        @test is_tool == true
        @test name == "read_file"
    end

    @testset "Response Parsing - Flat Structure" begin
        json_flat = "{\"tool\": \"complete_task\", \"task_id\": 123}"
        is_tool, name, args, thought = Agent.parse_response(json_flat)
        @test is_tool == true
        @test name == "complete_task"
        @test args["task_id"] == 123
    end
end
