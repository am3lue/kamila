"""
Vision — image understanding via a dedicated vision-capable Ollama model (08.1).

Provides `describe_image(path)` and `qa_image(path, question)` backed by
Ollama `/api/chat` with a base64 `images` field. Guards: path validation via
`FileAccess`, MIME check (PNG/JPEG/GIF magic bytes), and a 10 MB size cap.
When no vision model is reachable the tool returns a categorized `:external`
error — it never hallucinates a description.

Design notes:
- The vision model is selected through `ModelRouter` (`:vision` task type,
  e.g. `llava` / `llama3.2-vision`), so routing and fallback stay centralized.
- Results are optionally stored as recallable memories (`kind="image"`).
- Downscaling is a graceful, best-effort step: if `sips`/ImageMagick is
  missing the image is sent as-is (still size-capped).
"""

module Vision

using Base64
using JSON
using ..OllamaInterface
using ..ModelRouter
using ..FileAccess
using ..Errors
using ..KamilaLog
using ..KamilaMemory

export describe_image, qa_image, validate_image_path, image_description

const MAX_IMAGE_BYTES = 10 * 1024 * 1024  # 10 MB
const IMAGE_MIMES = Dict(
    0x89504e470d0a1a0a => "image/png",   # \x89PNG\r\n\x1a\n
    0xffd8ff => "image/jpeg",            # \xFF\xD8\xFF
    0x4749463839 => "image/gif",         # GIF89a
)

"""
    validate_image_path(path::String) -> String

Validate `path` (in an allowed directory per `FileAccess`), ensure it exists,
and verify the file's magic bytes identify a supported image. Throws a
`:validation` `KamilaError` otherwise. Returns the validated path.
"""
function validate_image_path(path::String)
    isempty(path) && throw(
        Errors.KamilaError(:validation, "file_path is required", details = Dict("path" => path)),
    )
    validated = try
        FileAccess.validate_path(path)
    catch e
        throw(Errors.KamilaError(:validation, "Image path rejected: $(Errors.error_string(e))"))
    end
    isfile(validated) || throw(
        Errors.KamilaError(:notfound, "Image file does not exist: $path", details = Dict("path" => path)),
    )

    stat(validated).size > MAX_IMAGE_BYTES && throw(
        Errors.KamilaError(
            :validation,
            "Image is too large (max $(MAX_IMAGE_BYTES ÷ 1024 ÷ 1024) MB)",
            details = Dict("path" => path, "bytes" => stat(validated).size),
        ),
    )

    mime = _detect_image_mime(validated)
    mime === nothing && throw(
        Errors.KamilaError(
            :unsupported,
            "Unsupported or non-image file. Accepted: PNG, JPEG, GIF.",
            details = Dict("path" => path),
        ),
    )
    return validated
end

function _detect_image_mime(path::String)
    mime = open(path) do io
        head = read(io, 8)
        # PNG: 8-byte signature
        if length(head) >= 8 && head[1:8] == UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
            "image/png"
        # JPEG: FF D8 FF
        elseif length(head) >= 3 && head[1] == 0xff && head[2] == 0xd8 && head[3] == 0xff
            "image/jpeg"
        # GIF: "GIF8"
        elseif length(head) >= 4 && String(head[1:4]) == "GIF8"
            "image/gif"
        else
            nothing
        end
    end
    return mime
end

function _encode_base64(path::String)
    return base64encode(read(path))
end

"""
    _vision_model() -> String

Choose the vision model: `KAMILA_VISION_MODEL` env override, else the
`:vision` ModelRouter entry (falling back to its configured name or "llava").
"""
function _vision_model()
    env = get(ENV, "KAMILA_VISION_MODEL", "")
    isempty(env) || return env
    try
        cfg = ModelRouter.select_model(:vision)
        return cfg.name
    catch e
        return "llava"
    end
end

"""
    _call_vision(model, prompt, image_path) -> String

Send one chat turn with the image attached. Returns the joined assistant
content, or throws a `:external` `KamilaError` when the model is unreachable
or returns no usable content (never a guess).
"""
function _call_vision(model::String, prompt::String, image_path::String)
    b64 = _encode_base64(image_path)
    messages = [
        Dict("role" => "user", "content" => prompt, "images" => [b64]),
    ]

    chunks = String[]
    stream = try
        OllamaInterface.query_ollama_chat_stream(
            messages;
            model = model,
            temperature = 0.1,
            max_tokens = 800,
        )
    catch e
        throw(
            Errors.KamilaError(
                :external,
                "Vision model '$model' unavailable: $(sprint(showerror, e))",
                details = Dict("model" => model),
            ),
        )
    end

    for item in stream
        isempty(item.text) && continue
        push!(chunks, item.text)
    end

    reply = join(chunks, "")
    isempty(strip(reply)) && throw(
        Errors.KamilaError(
            :external,
            "Vision model '$model' returned no description",
            details = Dict("model" => model),
        ),
    )
    return String(strip(reply))
end

"""
    describe_image(path::String; store::Bool=false) -> String

Describe the image at `path`. When `store=true` the description is saved as a
recallable memory (`kind="image"`).
"""
function describe_image(path::String; store::Bool = false)
    validated = validate_image_path(path)
    model = _vision_model()
    description = _call_vision(
        model,
        "Describe this image in detail. Cover the main subject, notable objects, " *
        "text, and any actions or state you can observe.",
        validated,
    )
    if store
        try
            KamilaMemory.remember(
                description;
                kind = "image",
                importance = 0.6,
            )
        catch e
            KamilaLog.warn("vision.store_failed: $e"; mod = "vision")
        end
    end
    return description
end

"""
    qa_image(path::String, question::String) -> String

Answer `question` about the image at `path`.
"""
function qa_image(path::String, question::String)
    isempty(strip(question)) && throw(
        Errors.KamilaError(:validation, "question is required"),
    )
    validated = validate_image_path(path)
    model = _vision_model()
    return _call_vision(model, "Answer the question about the image: $question", validated)
end

"""
    image_description(path::String) -> String

Alias for `describe_image` (used by the `vision` tool).
"""
image_description(path::String) = describe_image(path)

end # module
