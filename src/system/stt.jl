"""
Speech-to-Text (STT) module — the input-side echo of `TTS` (08.2).

Provides `transcribe(path)` that turns an audio file into text through a
detected local backend:
  1. Ollama whisper model (e.g. `whisper:large-v3-turbo`) via `/api/generate`.
  2. `whisper.cpp` (`whisper-cli`) if installed.
  3. `vosk` (`vosk-transcriber`) if installed.
  4. otherwise an explicit `:external` "no backend" error — never a guess.

Also provides `record_clip(seconds)` for live microphone capture via
`arecord`/`parecord` (used by the `audio.record` bridge route).

Honest framing: transcription quality depends entirely on the installed
backend. This module only guarantees the seam (validation, conversion, error
categorization) — it never fabricates recognized text.
"""

module STT

using Base64
using JSON
using HTTP
using ..OllamaInterface
using ..FileAccess
using ..Errors
using ..KamilaLog

export transcribe, transcribe_audio, detect_backend, validate_audio_path, record_clip

const MAX_AUDIO_BYTES = 100 * 1024 * 1024  # 100 MB
const AUDIO_MIMES = Dict(
    "wav" => "audio/wav",
    "mp3" => "audio/mpeg",
    "ogg" => "audio/ogg",
    "flac" => "audio/flac",
)

"""
    validate_audio_path(path::String) -> String

Validate `path` (in an allowed directory per `FileAccess`), ensure it exists and
is within the size guard, and verify its magic bytes identify a supported audio
format (`.wav`, `.mp3`, `.ogg`, `.flac`). Throws a categorized `KamilaError`
otherwise. Returns the validated path.
"""
function validate_audio_path(path::String)
    isempty(path) && throw(
        Errors.KamilaError(:validation, "file_path is required", details = Dict("path" => path)),
    )
    validated = try
        FileAccess.validate_path(path)
    catch e
        throw(Errors.KamilaError(:validation, "Audio path rejected: $(Errors.error_string(e))"))
    end
    isfile(validated) || throw(
        Errors.KamilaError(:notfound, "Audio file does not exist: $path", details = Dict("path" => path)),
    )

    stat(validated).size > MAX_AUDIO_BYTES && throw(
        Errors.KamilaError(
            :validation,
            "Audio is too large (max $(MAX_AUDIO_BYTES ÷ 1024 ÷ 1024) MB)",
            details = Dict("path" => path, "bytes" => stat(validated).size),
        ),
    )

    ext = _detect_audio_mime(validated)
    ext === nothing && throw(
        Errors.KamilaError(
            :unsupported,
            "Unsupported or non-audio file. Accepted: WAV, MP3, OGG, FLAC.",
            details = Dict("path" => path),
        ),
    )
    return validated
end

function _detect_audio_mime(path::String)
    mime = open(path) do io
        head = read(io, 12)
        # WAV: RIFF....WAVE
        if length(head) >= 12 && String(head[1:4]) == "RIFF" && String(head[9:12]) == "WAVE"
            "audio/wav"
        # MP3: ID3 tag, or 0xFF 0xFB/0xF3/0xF2/0xE3 frame sync
        elseif length(head) >= 3 &&
               (String(head[1:3]) == "ID3" ||
                (head[1] == 0xff &&
                 head[2] in (0xfb, 0xf3, 0xf2, 0xe3)))
            "audio/mpeg"
        # OGG: OggS
        elseif length(head) >= 4 && String(head[1:4]) == "OggS"
            "audio/ogg"
        # FLAC: fLaC
        elseif length(head) >= 4 && String(head[1:4]) == "fLaC"
            "audio/flac"
        else
            nothing
        end
    end
    return mime
end

"""
    detect_backend() -> Union{Symbol,Nothing}

Choose the STT backend: `KAMILA_STT_BACKEND` env override first, else auto-detect
(Ollama whisper model → `whisper-cli` → `vosk-transcriber`). Returns `nothing`
when no backend is available.
"""
function detect_backend()
    forced = get(ENV, "KAMILA_STT_BACKEND", "")
    if !isempty(forced)
        return Symbol(lowercase(forced))
    end
    if _has_ollama_whisper()
        return :ollama
    elseif Sys.which("whisper-cli") !== nothing
        return :whisper_cli
    elseif Sys.which("vosk-transcriber") !== nothing
        return :vosk
    end
    return nothing
end

function _has_ollama_whisper()
    try
        data = OllamaInterface.get_model_info()
        models = get(data, "models", [])
        return any(m -> occursin("whisper", lowercase(string(get(m, "name", "")))), models)
    catch
        return false
    end
end

"""
    _stt_model() -> String

Choose the STT model: `KAMILA_STT_MODEL` env override, else the default whisper
tag. The whisper model must be pulled into the local Ollama.
"""
function _stt_model()
    env = get(ENV, "KAMILA_STT_MODEL", "")
    isempty(env) || return env
    return "whisper:large-v3-turbo"
end

"""
    transcribe(path::String) -> Dict{String,Any}

Transcribe the audio at `path`. Returns `Dict("text" => ..., "confidence" =>
nothing)` — confidence is only populated when a backend reports it (none do
today). Throws a categorized `KamilaError` (`:validation`/`:unsupported`/
`:external`) rather than guessing.
"""
function transcribe(path::String)
    validated = validate_audio_path(path)
    backend = detect_backend()
    backend === nothing && throw(
        Errors.KamilaError(
            :external,
            "No speech-to-text backend available. Install whisper-cli or vosk, " *
            "or pull a whisper model into Ollama (KAMILA_STT_MODEL).",
        ),
    )

    text = if backend == :ollama
        _transcribe_ollama(validated)
    elseif backend == :whisper_cli
        _transcribe_whisper_cli(validated)
    elseif backend == :vosk
        _transcribe_vosk(validated)
    else
        throw(
            Errors.KamilaError(
                :external,
                "Unknown STT backend: $backend",
                details = Dict("backend" => backend),
            ),
        )
    end

    isempty(strip(text)) && throw(
        Errors.KamilaError(
            :external,
            "STT backend '$backend' returned no transcription",
            details = Dict("backend" => backend),
        ),
    )
    return Dict("text" => String(strip(text)), "confidence" => nothing)
end

"""
Alias used by the `transcribe_audio` tool: return just the recognized text.
"""
transcribe_audio(path::String) = get(transcribe(path), "text", "")

# ─── Backend implementations ─────────────────────────────

function _transcribe_ollama(path::String)
    model = _stt_model()
    b64 = base64encode(read(path))
    payload = Dict("model" => model, "prompt" => b64, "stream" => false)
    headers = ["Content-Type" => "application/json"]
    response = try
        HTTP.request(
            "POST",
            "$(OllamaInterface.OLLAMA_HOST)/api/generate",
            headers,
            JSON.json(payload);
            readtimeout = 120,
            retry = false,
            reuse_limit = 0,
            require_ssl_verification = false,
        )
    catch e
        throw(
            Errors.KamilaError(
                :external,
                "STT backend '$model' unavailable: $(sprint(showerror, e))",
                details = Dict("model" => model),
            ),
        )
    end

    response.status == 200 || throw(
        Errors.KamilaError(
            :external,
            "STT backend '$model' failed (HTTP $(response.status))",
            details = Dict("model" => model, "status" => response.status),
        ),
    )
    return _parse_generate_response(String(response.body))
end

# The Ollama response may be a single JSON object (`stream: false`) or NDJSON
# lines. Collect every `response` field, whichever shape arrives.
function _parse_generate_response(body::String)
    text = String[]
    for line in split(body, '\n'; keepempty = false)
        try
            obj = JSON.parse(line)
            r = get(obj, "response", "")
            isempty(r) || push!(text, r)
        catch
        end
    end
    return join(text, "")
end

function _transcribe_whisper_cli(path::String)
    model = get(ENV, "KAMILA_STT_MODEL", "")
    isempty(model) && throw(
        Errors.KamilaError(:external, "whisper-cli needs KAMILA_STT_MODEL set to a model file"),
    )
    out = tempname()
    cmd = `whisper-cli -m $model -f $path -otxt -of $out`
    try
        run(pipeline(cmd, stdout = devnull, stderr = devnull))
    catch e
        throw(Errors.KamilaError(:external, "whisper-cli failed: $(sprint(showerror, e))"))
    end
    txt = out * ".txt"
    isfile(txt) || throw(Errors.KamilaError(:external, "whisper-cli produced no output"))
    return String(strip(read(txt, String)))
end

function _transcribe_vosk(path::String)
    cmd = `vosk-transcriber -i $path -o -`
    try
        return String(strip(read(cmd, String)))
    catch e
        throw(Errors.KamilaError(:external, "vosk failed: $(sprint(showerror, e))"))
    end
end

# ─── Live capture (bridge `audio.record`) ────────────────

"""
    record_clip(seconds::Int; recorder=nothing) -> Dict{String,Any}

Record `seconds` of microphone audio to a temp `.wav` inside an allowed
directory, then transcribe it. The recorder command is `arecord` (preferred)
or `parecord`; pass `recorder` (or set `KAMILA_STT_RECORDER`) to override —
used by tests to point at a fake recorder script. Returns `transcribe(...)`'s
result Dict.
"""
function record_clip(seconds::Int = 5; recorder::Union{String,Nothing} = nothing)
    seconds = clamp(seconds, 1, 300)
    rec = recorder === nothing ? get(ENV, "KAMILA_STT_RECORDER", "") : recorder
    if isempty(rec)
        rec = Sys.which("arecord") !== nothing ? "arecord" :
              (Sys.which("parecord") !== nothing ? "parecord" : "")
    end
    isempty(rec) && throw(
        Errors.KamilaError(
            :external,
            "No audio recorder available (arecord/parecord). Install one to record voice.",
        ),
    )

    # Write inside an allowed directory so the captured clip can be read back
    # through `transcribe` (which validates via FileAccess).
    allowed = FileAccess.get_allowed_directories()
    isempty(allowed) && throw(Errors.KamilaError(:external, "No allowed directory for audio capture"))
    out = joinpath(allowed[1], "kamila_capture_$(string(time_ns())).wav")

    try
        if basename(rec) == "arecord"
            run(pipeline(`arecord -f cd -t wav -d $seconds $out`, stdout = devnull, stderr = devnull))
        elseif basename(rec) == "parecord"
            run(pipeline(`timeout $seconds parecord --rate=44100 --channels=1 $out`, stdout = devnull, stderr = devnull))
        else
            # Custom recorder (e.g. test fake): called as `recorder out_path`.
            run(pipeline(`$rec $out`, stdout = devnull, stderr = devnull))
        end
    catch e
        throw(Errors.KamilaError(:external, "Recording failed: $(sprint(showerror, e))"))
    end
    isfile(out) || throw(Errors.KamilaError(:external, "Recording produced no audio file"))

    try
        return transcribe(out)
    finally
        isfile(out) && rm(out; force = true)
    end
end

end # module
