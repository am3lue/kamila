# 07 — Learning

**Category goal:** Close the single biggest AGI gap identified in the assessment (§3.3): *no learning*. This category builds the substrate to turn Kamila's operational history into reusable knowledge and refined behavior — first as an **experience store** (record + query verified outcomes), then a **local fine-tuning pipeline** (adjust the underlying model from curated data), then **preference learning** (align behavior to user preferences over time).

**Honest framing:** none of this is "AGI gains sentience." Each plan is a bounded, verifiable step toward *behavior that improves with use*. `07.1` and `07.3` are fully implemented; `07.2`'s data pipeline + eval + gated promotion are implemented as a prototype — producing the actual LoRA `.gguf` remains an open research/hardware step, not a ship commitment.

---

## Sequencing

1. [x] `07.1-experience-store` — **DONE** (2026-08-15): `experience` table (Migration 8), `module Experience` (async batched `record` with dedupe + prune cap, vector `similar_solution`, verified-only filtering, JSONL `export_rows`), plan verified/failed outcome hooks, bridge `experience.*` routes, `reuse_solution` tool. Also fixed latent `Vectors.embed` cache-return bug. Tests: `test/experience_test.jl` (61). Full suite 4616 pass / 2 broken.
2. [x] `07.2-local-fine-tuning` — **PROTOTYPE** (2026-08-15): `src/learning/` data pipeline (`tune/import.jl`: experience → deduped/capped/PII-filtered chat exemplars), dry-run training job (`tune/train.jl`: Modelfile + `ollama create`, never mutates primary), eval harness (`eval.jl`: functional-success gate + deny-class regression guard), gated promotion (`tune/promote.jl`: ModelRouter merge, `enabled=false`). LoRA `.gguf` production is out of scope — see `tuning-notes.md`. Tests: `test/eval_test.jl` (48). Full suite 4664 pass / 2 broken.
3. [x] `07.3-preference-learning` — **DONE** (2026-08-15): `preferences` + `preference_events` tables (Migration 10), `module Preferences` (`record_signal` explicit 1.0 / implicit 0.2, 5-explicit-signal flip margin, majority window, revert, audit history), bridge `feedback.record` + `preferences.*` routes, and a `# preferences` block injected into the chat system prompt for committed (non-default) values only. Implicit signals can never outvote explicit ones. Tests: `test/preference_test.jl` (24). Full suite 4700 pass / 2 broken.

---

## Shared template reminder

Each sub-plan follows: Objective → Current State → Design → Work Breakdown → Acceptance Criteria → Risks & Mitigations → Dependencies → Definition of Done.

---

## Links

- [07.1 Experience store](07.1-experience-store.md)
- [07.2 Local fine-tuning](07.2-local-fine-tuning.md)
- [07.3 Preference learning](07.3-preference-learning.md)

## Depends on
- `01-foundations`, `03-memory-v2`, `04-planning-engine`, `06-autonomy`.

## Blocks
- Nothing shipping; informs `08-perception`, `09-agi-research`.