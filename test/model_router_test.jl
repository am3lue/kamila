"""
test/model_router_test.jl — Tests of the ModelRouter: default model config
(kamila1 online / kamila2 offline), selection priority, built-in validation,
and the chat-stream fallback chain including thinking relay.

The mock Ollama server is started by test/run.jl before src/Kamila.jl loads,
so the router's `OLLAMA_HOST` const points at the mock.
"""

using Test
using JSON

using .Kamila
const MR = Kamila.ModelRouter
const OI = Kamila.OllamaInterface

@testset "ModelRouter" begin
    @testset "DEFAULT_MODELS: kamila1 (p1) online, kamila2 (p2) offline" begin
        cfg = MR.DEFAULT_MODELS

        chat_models = [m for m in cfg if m.task_type == :chat]
        @test length(chat_models) == 2
        @test chat_models[1].name == "kamila1"
        @test chat_models[1].priority == 1
        @test chat_models[2].name == "kamila2"
        @test chat_models[2].priority == 2

        code_models = [m for m in cfg if m.task_type == :code]
        @test code_models[1].name == "kamila1"
        @test code_models[2].name == "kamila2"

        quick_models = [m for m in cfg if m.task_type == :quick]
        @test length(quick_models) == 1
        @test quick_models[1].name == "qwen2.5-coder:0.5b"
    end

    @testset "select_model picks kamila1 for chat/code, quick for :quick" begin
        @test MR.select_model(:chat).name == "kamila1"
        @test MR.select_model(:code).name == "kamila1"
        @test MR.select_model(:quick).name == "qwen2.5-coder:0.5b"
    end

    @testset "select_model_fallback chain order is kamila1 -> kamila2" begin
        chain = MR.select_model_fallback(:chat)
        @test [m.name for m in chain] == ["kamila1", "kamila2"]
    end

    @testset "validate_model accepts built-in Kamila models" begin
        @test MR.validate_model("kamila1")
        @test MR.validate_model("kamila2")
        @test MR.validate_model("kamila:latest")
    end

    @testset "is_error_response" begin
        @test MR.is_error_response("")
        @test MR.is_error_response("❌ All models failed")
        @test MR.is_error_response("error: timeout")
        @test !MR.is_error_response("a normal reply")
    end

    @testset "get_router_config falls back to defaults when no config file" begin
        @test MR.get_router_config() == MR.DEFAULT_MODELS
    end

    @testset "get_active_model defaults to kamila1" begin
        MR.ACTIVE_MODEL[] = ""
        @test MR.get_active_model() == "kamila1"
    end

    @testset "thinking relay: StreamItem tagged, excluded from answer" begin
        mock = TEST_SANDBOX[]["mock_server"]
        MR.ACTIVE_MODEL[] = ""
        OllamaMockServer.reset_chat_request_count!(mock)
        OllamaMockServer.set_script!(
            mock;
            chat_lines = [
                OllamaMockServer.chat_line_thinking(
                    thinking = "Let me reason through this...",
                    content = "Final answer here.",
                    done = true,
                ),
            ],
        )

        messages = [Dict("role" => "user", "content" => "hi")]
        model_ref = Ref{String}("")
        items = collect(MR.query_router_chat_stream(messages; model_ref = model_ref))

        thinking = [it for it in items if it.is_thinking]
        content = [it for it in items if !it.is_thinking]

        @test !isempty(thinking)
        @test occursin(
            "Let me reason through this...",
            join([it.text for it in thinking], ""),
        )
        @test !occursin(
            "Let me reason through this...",
            join([it.text for it in content], ""),
        )
        @test occursin("Final answer here.", join([it.text for it in content], ""))
        @test model_ref[] == "kamila1"
    end

    @testset "fallback: kamila1 fails -> kamila2 answers (model_ref updated)" begin
        mock = TEST_SANDBOX[]["mock_server"]
        MR.ACTIVE_MODEL[] = ""
        OllamaMockServer.reset_chat_request_count!(mock)
        OllamaMockServer.set_chat_scripts!(
            mock,
            [
                [
                    OllamaMockServer.chat_line(
                        content = "❌ Model 'kamila1' error: boom",
                        done = true,
                    ),
                ],
                [
                    OllamaMockServer.chat_line(
                        content = "Offline reply from kamila2.",
                        done = true,
                    ),
                ],
            ],
        )

        messages = [Dict("role" => "user", "content" => "test fallback")]
        model_ref = Ref{String}("")
        items = collect(MR.query_router_chat_stream(messages; model_ref = model_ref))

        answer = join([it.text for it in items if !it.is_thinking], "")
        @test occursin("Offline reply from kamila2.", answer)
        @test !occursin("boom", answer)
        @test model_ref[] == "kamila2"
    end

    @testset "all models fail -> error StreamItem" begin
        mock = TEST_SANDBOX[]["mock_server"]
        MR.ACTIVE_MODEL[] = ""
        OllamaMockServer.reset_chat_request_count!(mock)
        OllamaMockServer.set_chat_scripts!(
            mock,
            [
                [
                    OllamaMockServer.chat_line(
                        content = "❌ Model 'kamila1' error: boom",
                        done = true,
                    ),
                ],
                [
                    OllamaMockServer.chat_line(
                        content = "❌ Model 'kamila2' error: gone",
                        done = true,
                    ),
                ],
            ],
        )

        messages = [Dict("role" => "user", "content" => "test failure")]
        items = collect(MR.query_router_chat_stream(messages))

        answer = join([it.text for it in items if !it.is_thinking], "")
        @test occursin("All models failed", answer)
    end
end
