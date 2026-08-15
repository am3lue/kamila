# 08 — Perception

**Category goal:** Give Kamila **multimodal input** beyond text. Today it perceives only through text files, web snippets, and `/proc` telemetry (the AGI-assessment §3.2 "perception" gap). This category adds vision (image understanding), speech input (STT) to complement the existing `TTS` output (`src/ai/tts.jl`), and desktop-awareness (screenshots / active window / clipboard).

**Honest framing:** these add *modes* of grounding. They do not by themselves produce AGI; they remove a hard modality ceiling. Each is design-level with concrete, shippable increments. `08.1`, `08.2`, and `08.3` are fully implemented.

---

## Sequencing

1. [x] `08.1-vision` — **DONE** (2026-08-15): `module Vision` in `src/ai/vision.jl` (`describe_image(path; store)`, `qa_image`, magic-byte MIME detection PNG/JPEG/GIF, 10 MB size guard, base64 via the existing Ollama chat stream, `:external` error on empty model reply — never a guess), `vision` tool in `AgentTools`, default `:vision` `ModelConfig` (`llava`), `"vision"` capability mapping, and an `:image_contains` verify kind in `src/planning/verify.jl`. Descriptions can be stored as recallable memories (`kind="image"`). Tests: `test/vision_test.jl` (18). Full suite 4721 pass / 2 broken.
2. [x] `08.2-speech` — **DONE** (2026-08-15): `module STT` in `src/system/stt.jl` (Ollama whisper → `whisper-cli` → `vosk` backend detection; magic-byte MIME check WAV/MP3/OGG/FLAC; `:external` error when no backend — never a guess; `record_clip` via `arecord`/`parecord`), `transcribe_audio` tool (capability `"audio"`), bridge `audio.transcribe`/`audio.record` routes, `ai.query` `audio_file` param (transcript injected as a user message), and TUI `/record` draft-correction. Tests: `test/stt_test.jl` (27). Full suite 4751 pass / 2 broken.
3. [x] `08.3-desktop-awareness` — **DONE** (2026-08-15): `module DesktopContext` in `src/system/desktop_context.jl` (X11/Wayland feature detection, active window via `xdotool`/`swaymsg`, truncated + redacted clipboard, graceful degradation, watch off by default), `module Screenshot` in `src/system/screenshot.jl` (capture → `08.1` vision describe → image deleted, description-only), `desktop_status`/`screenshot_describe` tools (capability `"desktop.read"`), bridge `desktop.status`/`desktop.screenshot`/`desktop.watch` routes (watch publishes `desktop.activity` events), TUI `/context` `/watch` `/shot`. Tests: `test/desktop_context_test.jl` (32). Full suite 4789 pass / 2 broken.

---

## Shared template reminder

Each sub-plan follows: Objective → Current State → Design → Work Breakdown → Acceptance Criteria → Risks & Mitigations → Dependencies → Definition of Done.

---

## Depends on
- `01-foundations`, `02-agent-reliability`, `03-memory-v2`.
- `08.3` additionally on `08.1`.

## Blocks
- Nothing shipping; informs `09-agi-research` grounding.