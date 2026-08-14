"""
test/agent_stream_test.jl — Tests of `AgentStream` response parsing (02.5).

The stream loop accumulates chunks before parsing (`parse_response(accumulated)`),
so chunks that arrive split mid-JSON must still parse once joined. These tests
verify that round-trip, and that `AgentStream` and `Agent` share the single
canonical parser (identical results on the same input).
"""

using Test
using JSON
using .Kamila

const AS = Kamila.AgentStream
const A = Kamila.Agent

@testset "AgentStream" begin
    @testset "partial chunks split mid-JSON accumulate correctly" begin
        # A JSON tool call delivered in chunks that split mid-string/mid-brace.
        chunks = [
            "```json\n{\"tool\": \"li",
            "st_directory\", \"args\": {\"pat",
            "h\": \".\", \"show_hidden\"",
            ": true}}\n```",
        ]
        accumulated = join(chunks)
        is_tool, tool_name, args, _ = AS.parse_response(accumulated)
        @test is_tool == true
        @test tool_name == "list_directory"
        @test args["path"] == "."
        @test args["show_hidden"] == true
    end

    @testset "chunks split inside a string value" begin
        chunks = [
            "{\"tool\": \"write_file\", \"args\": {\"file_path\": \"a.tx",
            "t\", \"content\": \"hello, then go",
            "odbye\"}}",
        ]
        is_tool, tool_name, args, _ = AS.parse_response(join(chunks))
        @test is_tool == true
        @test tool_name == "write_file"
        @test args["content"] == "hello, then goodbye"
        @test args["file_path"] == "a.txt"
    end

    @testset "trailing comma across chunk boundary" begin
        chunks = ["{\"tool\": \"read_file\", \"args\": {\"file_path\": \"b.txt\"", ",}}"]
        is_tool, tool_name, args, _ = AS.parse_response(join(chunks))
        @test is_tool == true
        @test tool_name == "read_file"
        @test args["file_path"] == "b.txt"
    end

    @testset "same parser as Agent (single implementation)" begin
        inputs = [
            "```json\n{\"tool\": \"ls\", \"args\": {\"path\": \".\"}}\n```",
            "{\"tool\": \"grep_search\", \"args\": {\"pattern\": \"err\"},}",
            "I have no tool call here.",
        ]
        for input in inputs
            @test AS.parse_response(input) == A.parse_response(input)
        end
    end

    @testset "extract_tool_from_json delegates to canonical extract_tool" begin
        data = JSON.parse("{\"tool\": \"web_search\", \"args\": {\"query\": \"julia\"}}")
        is_tool, tool_name, args, _ = AS.extract_tool_from_json(data)
        @test is_tool == true
        @test tool_name == "web_search"
        @test args["query"] == "julia"
    end
end
