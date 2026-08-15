"""
test/vision_test.jl — Tests of the 08.1 vision module.

The mock Ollama server is started by test/run.jl (vision target), so the
vision model is reachable at the module-load OLLAMA_HOST. Covers: path/MIME
validation, size guard, describe + qa via the mocked vision endpoint, the
missing/empty-model `:external` error path, `image_contains` verify kind, and
memory storage of image descriptions.
"""

using Test
using JSON
using Dates

using .Kamila
const VIS = Kamila.Vision
const MDB = Kamila.MemoryDB
const VERIFY = Kamila.Verify
const ERR = Kamila.Errors
const MOCK = TEST_SANDBOX[]["mock_server"]

# A minimal valid 1x1 PNG (magic bytes + IHDR). Enough for MIME detection.
const PNG_BYTES = UInt8[
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,  # signature
    0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,  # IHDR
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,  # 1x1
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89,
    0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41, 0x54,  # IDAT
    0x08, 0xd7, 0x63, 0xf8, 0xcf, 0xc0, 0x00, 0x00, 0x00, 0x05, 0x00, 0x01,
    0xff, 0x45, 0x2e, 0x2c, 0x2b, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,
    0x44, 0xae, 0x42, 0x60, 0x82,  # IEND
]

function write_png(path::String)
    open(path, "w") do io
        write(io, PNG_BYTES)
    end
    return path
end

@testset "Vision" begin
    @testset "validate_image_path accepts PNG and rejects non-images" begin
        img = write_png(joinpath(TEST_SANDBOX[]["allowed"], "pixel.png"))
        @test VIS.validate_image_path(img) == img

        # JPEG magic
        jpg = joinpath(TEST_SANDBOX[]["allowed"], "photo.jpg")
        write(jpg, UInt8[0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46])
        @test VIS.validate_image_path(jpg) == jpg

        # Text file with .png extension — magic bytes must reject it.
        fake = joinpath(TEST_SANDBOX[]["allowed"], "fake.png")
        write(fake, "this is not an image")
        @test_throws ERR.KamilaError VIS.validate_image_path(fake)

        # Missing file
        @test_throws ERR.KamilaError VIS.validate_image_path(joinpath(TEST_SANDBOX[]["allowed"], "nope.png"))
    end

    @testset "oversized images are rejected with :validation" begin
        big = joinpath(TEST_SANDBOX[]["allowed"], "big.png")
        open(big, "w") do io
            write(io, PNG_BYTES)
            write(io, zeros(UInt8, 11 * 1024 * 1024))
        end
        err = try
            VIS.validate_image_path(big)
            nothing
        catch e
            e
        end
        @test err isa ERR.KamilaError
        @test ERR.error_category(err) == :validation
    end

    @testset "describe_image returns the mocked description and stores a memory" begin
        OllamaMockServer.set_script!(MOCK;
            chat_lines = [OllamaMockServer.chat_line(content = "A single red pixel.", done = true)],
        )
        img = write_png(joinpath(TEST_SANDBOX[]["allowed"], "pixel2.png"))

        desc = VIS.describe_image(img; store = true)
        @test desc isa String
        @test occursin("red pixel", desc)

        # Stored as a recallable memory.
        rows = MDB.query_all("SELECT * FROM memories WHERE kind = 'image'")
        @test any(r -> occursin("red pixel", string(r.content)), rows)
    end

    @testset "qa_image answers a question about the image" begin
        OllamaMockServer.set_script!(MOCK;
            chat_lines = [OllamaMockServer.chat_line(content = "Yes, it contains a red pixel.", done = true)],
        )
        img = write_png(joinpath(TEST_SANDBOX[]["allowed"], "pixel3.png"))
        ans = VIS.qa_image(img, "Does it contain a red pixel?")
        @test occursin("red pixel", ans)

        @test_throws ERR.KamilaError VIS.qa_image(img, "   ")
    end

    @testset "missing/empty model reply yields :external, never a guess" begin
        # Empty content from the model → categorized external error.
        OllamaMockServer.set_script!(MOCK;
            chat_lines = [OllamaMockServer.chat_line(content = "", done = true)],
        )
        img = write_png(joinpath(TEST_SANDBOX[]["allowed"], "pixel4.png"))
        err = try
            VIS.describe_image(img)
            nothing
        catch e
            e
        end
        @test err isa ERR.KamilaError
        @test ERR.error_category(err) == :external
    end

    @testset "vision tool returns text via execute path" begin
        OllamaMockServer.set_script!(MOCK;
            chat_lines = [OllamaMockServer.chat_line(content = "A screenshot of a desktop.", done = true)],
        )
        img = write_png(joinpath(TEST_SANDBOX[]["allowed"], "pixel5.png"))
        out = Kamila.AgentTools.execute_tool("vision", Dict("file_path" => img, "task" => "describe"))
        @test occursin("desktop", out)

        # Non-image path rejected with a clear error, not a crash.
        bad = joinpath(TEST_SANDBOX[]["allowed"], "notes.txt")
        write(bad, "plain text")
        errout = Kamila.AgentTools.execute_tool("vision", Dict("file_path" => bad))
        @test occursin("Unsupported", errout) || occursin("non-image", errout)
    end

    @testset "image_contains verify kind works (mocked)" begin
        OllamaMockServer.set_script!(MOCK;
            chat_lines = [OllamaMockServer.chat_line(content = "YES", done = true)],
        )
        img = write_png(joinpath(TEST_SANDBOX[]["allowed"], "pixel6.png"))
        spec = VERIFY.VerifySpec(Dict("kind" => "image_contains", "target" => img, "expected" => "red"))
        @test VERIFY.is_verifiable(spec)
        res = VERIFY.verify(spec, "")
        @test res.ok
        @test occursin("YES", res.evidence)
    end
end
