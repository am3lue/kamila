# 08 — Perception

**Category goal:** Give Kamila **multimodal input** beyond text. Today it perceives only through text files, web snippets, and `/proc` telemetry (the AGI-assessment §3.2 "perception" gap). This category adds vision (image understanding), speech input (STT) to complement the existing `TTS` output (`src/ai/tts.jl`), and desktop-awareness (screenshots / active window / clipboard).

**Honest framing:** these add *modes* of grounding. They do not by themselves produce AGI; they remove a hard modality ceiling. Each is design-level with concrete, shippable increments.

---

## Sequencing

1. `08.1-vision` — image understanding tool (base for 08.3).
2. `08.2-speech` — speech-to-text (echo of TTS; works headless with the daemon).
3. `08.3-desktop-awareness` — screenshot + window/clipboard introspection (needs 08.1 for image meaning).

---

## Shared template reminder

Each sub-plan follows: Objective → Current State → Design → Work Breakdown → Acceptance Criteria → Risks & Mitigations → Dependencies → Definition of Done.

---

## Depends on
- `01-foundations`, `02-agent-reliability`, `03-memory-v2`.
- `08.3` additionally on `08.1`.

## Blocks
- Nothing shipping; informs `09-agi-research` grounding.