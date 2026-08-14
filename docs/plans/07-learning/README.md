# 07 — Learning

**Category goal:** Close the single biggest AGI gap identified in the assessment (§3.3): *no learning*. This category builds the substrate to turn Kamila's operational history into reusable knowledge and refined behavior — first as an **experience store** (record + query verified outcomes), then a **local fine-tuning pipeline** (adjust the underlying model from curated data), then **preference learning** (align behavior to user preferences over time).

**Honest framing:** none of this is "AGI gains sentience." Each plan is a bounded, verifiable step toward *behavior that improves with use*. `07.1` is fully actionable; `07.2`/`07.3` are design-level with hard open research questions flagged — not ship commitments.

---

## Sequencing

1. `07.1-experience-store` — record verified (`04.3`) interactions as structured, queryable experience; enable "do something like this again" retrieval.
2. `07.2-local-fine-tuning` — turn curated experience into local fine-tuning datasets; pipeline for `ollama create` (design + prototype).
3. `07.3-preference-learning` — capture user preference signals to re-rank/select among responses & strategies.

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