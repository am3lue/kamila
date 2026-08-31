"""
test/log_test.jl — Tests of the KamilaLog module: level filtering, human and
JSON formatting, the request context, the stderr sink, and file rotation.

Note: `KamilaLog.initialize()` reads KAMILA_LOG* env vars at module load time
(inside src/Kamila.jl include). Level/format/file-sink behavior is exercised
here through the runtime API (set_level, set_json_format, open_file_sink) so
the tests don't depend on process-wide env ordering.
"""

using Test
using JSON

using .Kamila
const L = Kamila.KamilaLog

# Capture stderr so we can assert on log lines without spamming test output.
function with_captured_stderr(f::Function)
    mktemp() do path, io
        redirect_stderr(() -> f(), io)
        flush(io)
        close(io)
        return read(path, String)
    end
end

@testset "KamilaLog" begin
    @testset "levels are honored (KAMILA_LOG=error silences info/debug)" begin
        L.set_level("error")
        out = with_captured_stderr() do
            L.debug("should be hidden")
            L.info("should be hidden too")
            L.warn("also hidden")
            L.error("visible error")
            L.fatal("visible fatal")
        end
        @test !occursin("should be hidden", out)
        @test occursin("visible error", out)
        @test occursin("visible fatal", out)
    end

    @testset "set_level accepts integer ranks" begin
        L.set_level(L.ERROR)
        @test L.log_level() == L.ERROR
        out = with_captured_stderr() do
            L.info("nope")
        end
        @test !occursin("nope", out)
    end

    @testset "human-readable format includes module and fields" begin
        L.set_level("debug")
        L.set_json_format(false)
        out = with_captured_stderr() do
            L.info("hello log"; mod = "logtest", fields = Dict("a" => 1, "b" => "two"))
        end
        @test occursin("hello log", out)
        @test occursin("logtest", out)
        @test occursin("a=1", out)
        @test occursin("b=two", out)
    end

    @testset "JSON format emits parseable objects with ts/level/origin/kind/msg" begin
        L.set_json_format(true)
        out = with_captured_stderr() do
            L.info("json log"; mod = "logtest", kind = "request", fields = Dict("k" => "v"))
        end
        line = first(filter(!isempty, split(out, "\n")))
        data = JSON.parse(line)
        @test data["level"] == "info"
        @test data["origin"] == "logtest"
        @test data["kind"] == "request"
        @test data["msg"] == "json log"
        @test haskey(data, "ts")
        @test data["fields"]["k"] == "v"
    end

    @testset "context id is attached to log lines" begin
        L.set_json_format(false)
        out = with_captured_stderr() do
            L.with_context("req-123") do
                L.info("contextual"; mod = "logtest")
            end
        end
        @test occursin("[req-123]", out)

        # Context is restored after with_context.
        out2 = with_captured_stderr() do
            L.info("no context"; mod = "logtest")
        end
        @test !occursin("req-123", out2)
    end

    @testset "JSON format carries context field" begin
        L.set_json_format(true)
        out = with_captured_stderr() do
            L.with_context("req-9") do
                L.info("ctx json"; mod = "logtest")
            end
        end
        line = first(filter(!isempty, split(out, "\n")))
        data = JSON.parse(line)
        @test data["context"] == "req-9"
    end

    @testset "file sink writes and rotation archives" begin
        mktempdir() do dir
            file = joinpath(dir, "app.log")
            L.open_file_sink(file)
            try
                L.info("to file"; mod = "logtest")
            finally
                L.close_file_sink()
            end
            contents = read(file, String)
            @test occursin("to file", contents)

            # Force a rotation by pre-filling the file past the threshold.
            L.open_file_sink(file)
            try
                write(file, repeat("x", 5 * 1024 * 1024))
                L.info("after rotate"; mod = "logtest")
            finally
                L.close_file_sink()
            end
            @test isfile("$file.1")
            @test filesize("$file.1") >= 5 * 1024 * 1024
            @test filesize(file) < 5 * 1024 * 1024
        end
    end

    # Reset to a clean default state so later targets aren't affected.
    L.set_level("info")
    L.set_json_format(false)
    L.close_file_sink()
end
