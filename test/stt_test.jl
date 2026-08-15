"""
test/stt_test.jl — Tests of the 08.2 speech-to-text module.

The mock Ollama server is started by test/run.jl (stt target), so the whisper
backend is reachable at the module-load OLLAMA_HOST. Covers: path/format
validation, transcription via the mocked `/api/generate` endpoint, the
no-backend `:external` error, the `transcribe_audio` tool, and the bridge
`audio.transcribe` / `audio.record` routes.
"""

using Test
using JSON
using Dates

using .Kamila
const STT = Kamila.STT
const ERR = Kamila.Errors
const BR = Kamila.KamilaBridge
const MOCK = TEST_SANDBOX[]["mock_server"]

# A minimal WAV header (RIFF....WAVE magic) — enough for MIME detection.
const WAV_BYTES = UInt8[
    0x52, 0x49, 0x46, 0x46,  # RIFF
    0x24, 0x00, 0x00, 0x00,  # chunk size (unused by detection)
    0x57, 0x41, 0x56, 0x45,  # WAVE
    0x66, 0x6d, 0x74, 0x20,  # fmt_
]

function write_wav(path::String)
    open(path, "w") do io
        write(io, WAV_BYTES)
    end
    return path
end

function parse_bridge_output(output::String)
    events = Dict{String,Any}[]
    for line in split(output, "\n")
        isempty(strip(line)) && continue
        try
            push!(events, JSON.parse(line))
        catch
        end
    end
    return events
end

function find_event(events, type::String)
    return filter(e -> get(e, "type", "") == type, events)
end

@testset "STT" begin
    @testset "validate_audio_path accepts WAV and rejects non-audio" begin
        wav = write_wav(joinpath(TEST_SANDBOX[]["allowed"], "note.wav"))
        @test STT.validate_audio_path(wav) == wav

        # MP3 ID3 magic
        mp3 = joinpath(TEST_SANDBOX[]["allowed"], "voice.mp3")
        write(mp3, UInt8[0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00])
        @test STT.validate_audio_path(mp3) == mp3

        # OGG magic
        ogg = joinpath(TEST_SANDBOX[]["allowed"], "clip.ogg")
        write(ogg, UInt8[0x4f, 0x67, 0x67, 0x53, 0x00, 0x02])
        @test STT.validate_audio_path(ogg) == ogg

        # FLAC magic
        flac = joinpath(TEST_SANDBOX[]["allowed"], "song.flac")
        write(flac, UInt8[0x66, 0x4c, 0x61, 0x43, 0x00, 0x00])
        @test STT.validate_audio_path(flac) == flac

        # Text file with .wav extension — magic bytes must reject it.
        fake = joinpath(TEST_SANDBOX[]["allowed"], "fake.wav")
        write(fake, "this is not audio")
        @test_throws ERR.KamilaError STT.validate_audio_path(fake)

        # Missing file
        @test_throws ERR.KamilaError STT.validate_audio_path(joinpath(TEST_SANDBOX[]["allowed"], "nope.wav"))
    end

    @testset "oversized audio is rejected with :validation" begin
        big = joinpath(TEST_SANDBOX[]["allowed"], "big.wav")
        open(big, "w") do io
            write(io, WAV_BYTES)
            write(io, zeros(UInt8, 101 * 1024 * 1024))
        end
        err = try
            STT.validate_audio_path(big)
            nothing
        catch e
            e
        end
        @test err isa ERR.KamilaError
        @test ERR.error_category(err) == :validation
    end

    @testset "transcribe returns text via the mocked backend" begin
        OllamaMockServer.set_script!(MOCK;
            generate_lines = [OllamaMockServer.generate_line(response = "Hello there.", done = true)],
        )
        with_env(Dict("KAMILA_STT_BACKEND" => "ollama", "KAMILA_STT_MODEL" => "whisper-test"), () -> begin
            wav = write_wav(joinpath(TEST_SANDBOX[]["allowed"], "note2.wav"))
            result = STT.transcribe(wav)
            @test result isa Dict
            @test occursin("Hello", get(result, "text", ""))
            @test haskey(result, "confidence")
        end)
    end

    @testset "missing/empty backend reply yields :external, never a guess" begin
        OllamaMockServer.set_script!(MOCK;
            generate_lines = [OllamaMockServer.generate_line(response = "", done = true)],
        )
        with_env(Dict("KAMILA_STT_BACKEND" => "ollama", "KAMILA_STT_MODEL" => "whisper-test"), () -> begin
            wav = write_wav(joinpath(TEST_SANDBOX[]["allowed"], "note3.wav"))
            err = try
                STT.transcribe(wav)
                nothing
            catch e
                e
            end
            @test err isa ERR.KamilaError
            @test ERR.error_category(err) == :external
        end)
    end

    @testset "no backend yields :external error" begin
        # Sandbox has no whisper-cli/vosk, and the mock tags list no whisper
        # model, so auto-detection must find nothing.
        with_env(Dict("KAMILA_STT_BACKEND" => nothing), () -> begin
            @test STT.detect_backend() === nothing
            wav = write_wav(joinpath(TEST_SANDBOX[]["allowed"], "note4.wav"))
            err = try
                STT.transcribe(wav)
                nothing
            catch e
                e
            end
            @test err isa ERR.KamilaError
            @test ERR.error_category(err) == :external
        end)
    end

    @testset "transcribe_audio tool returns text via execute path" begin
        OllamaMockServer.set_script!(MOCK;
            generate_lines = [OllamaMockServer.generate_line(response = "Turn off the lights.", done = true)],
        )
        with_env(Dict("KAMILA_STT_BACKEND" => "ollama", "KAMILA_STT_MODEL" => "whisper-test"), () -> begin
            wav = write_wav(joinpath(TEST_SANDBOX[]["allowed"], "note5.wav"))
            out = Kamila.AgentTools.execute_tool("transcribe_audio", Dict("file_path" => wav))
            @test occursin("lights", out)

            # Non-audio path rejected with a clear error, not a crash.
            bad = joinpath(TEST_SANDBOX[]["allowed"], "notes.txt")
            write(bad, "plain text")
            errout = Kamila.AgentTools.execute_tool("transcribe_audio", Dict("file_path" => bad))
            @test occursin("Unsupported", errout) || occursin("non-audio", errout)
        end)
    end

    @testset "record_clip with a fake recorder yields transcribed text" begin
        OllamaMockServer.set_script!(MOCK;
            generate_lines = [OllamaMockServer.generate_line(response = "Recorded words.", done = true)],
        )
        fake = joinpath(TEST_SANDBOX[]["allowed"], "fake_recorder.sh")
        write(fake, "#!/bin/sh\ncp \"\$(dirname \"\$1\")/note.wav\" \"\$1\"\n")
        chmod(fake, 0o755)
        write_wav(joinpath(TEST_SANDBOX[]["allowed"], "note.wav"))
        with_env(
            Dict("KAMILA_STT_BACKEND" => "ollama", "KAMILA_STT_MODEL" => "whisper-test"),
            () -> begin
                result = STT.record_clip(1; recorder = fake)
                @test occursin("Recorded", get(result, "text", ""))
            end,
        )
    end

    @testset "bridge audio.transcribe and audio.record routes" begin
        OllamaMockServer.set_script!(MOCK;
            generate_lines = [OllamaMockServer.generate_line(response = "Bridge words.", done = true)],
        )
        with_env(Dict("KAMILA_STT_BACKEND" => "ollama", "KAMILA_STT_MODEL" => "whisper-test"), () -> begin
            wav = write_wav(joinpath(TEST_SANDBOX[]["allowed"], "note6.wav"))

            out = capture_stdout() do
                BR.dispatch(
                    Dict(
                        "type" => "request",
                        "id" => "at1",
                        "method" => "audio.transcribe",
                        "params" => Dict("file_path" => wav),
                    ),
                )
            end
            events = parse_bridge_output(out)
            @test events[1]["type"] == "response"
            @test occursin("Bridge", get(events[1]["result"], "text", ""))

            # Missing file_path rejected.
            out = capture_stdout() do
                BR.dispatch(
                    Dict(
                        "type" => "request",
                        "id" => "at2",
                        "method" => "audio.transcribe",
                        "params" => Dict(),
                    ),
                )
            end
            events = parse_bridge_output(out)
            @test events[1]["type"] == "error"
            @test events[1]["code"] == 400

            # record_clip via the fake recorder through the route.
            fake = joinpath(TEST_SANDBOX[]["allowed"], "fake_recorder2.sh")
            write(fake, "#!/bin/sh\ncp \"\$(dirname \"\$1\")/note.wav\" \"\$1\"\n")
            chmod(fake, 0o755)
            out = capture_stdout() do
                BR.dispatch(
                    Dict(
                        "type" => "request",
                        "id" => "ar1",
                        "method" => "audio.record",
                        "params" => Dict("seconds" => 1, "recorder" => fake),
                    ),
                )
            end
            events = parse_bridge_output(out)
            @test events[1]["type"] == "response"
            @test occursin("Bridge", get(events[1]["result"], "text", ""))

            # ai.query with audio_file transcribes and injects the text as a
            # user message through the normal pipeline.
            OllamaMockServer.set_script!(MOCK;
                chat_lines = [OllamaMockServer.chat_line(content = "heard the clip.", done = true)],
            )
            out = capture_stdout() do
                BR.dispatch(
                    Dict(
                        "type" => "request",
                        "id" => "aq1",
                        "method" => "ai.query",
                        "params" => Dict("audio_file" => wav),
                    ),
                )
            end
            events = parse_bridge_output(out)
            @test length(find_event(events, "stream_end")) == 1
            chunks = join([get(e, "chunk", "") for e in find_event(events, "stream")])
            @test occursin("heard the clip", chunks)
        end)
    end
end
