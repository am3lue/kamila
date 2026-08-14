# 03 — Memory v2

**Category goal:** Replace the flat-JSON "memory" with a real long-term memory system: a durable relational store, semantic (embedding) retrieval, episodic summarization, and a prompt-injection layer that feeds the *right* memory into the context window instead of a hardcoded block.

**Why before planning/autonomy:** `04-planning-engine` needs plans to persist; `06-autonomy` needs to remember what it was doing across restarts; `07-learning` needs a memory substrate to learn from. The current `MAX_HISTORY=10` / `MAX_CHAT_HISTORY=20` sliding windows and `memory_query` that just echoes JSON fields (`src/ai/tools.jl:606-670`) cannot support any of that.

---

## Sequencing

1. `03.1-storage-engine` — SQLite store + schema, migrations, data access layer (foundation).
2. `03.2-embeddings-retrieval` — semantic recall over stored memories (needs 03.1).
3. `03.3-episodic-summarization` — rolling episodic memory + summaries (needs 03.1).
4. `03.4-context-injection` — the prompt layer that selects what to inject (needs 03.2, 03.3).

---

## Shared template reminder

Each sub-plan follows: Objective → Current State → Design → Work Breakdown → Acceptance Criteria → Risks & Mitigations → Dependencies → Definition of Done.

---

## Links

- [03.1 Storage engine](03.1-storage-engine.md)
- [03.2 Embeddings & retrieval](03.2-embeddings-retrieval.md)
- [03.3 Episodic summarization](03.3-episodic-summarization.md)
- [03.4 Context injection](03.4-context-injection.md)

## Depends on
- `01-foundations`, `02-agent-reliability`.

## Blocks
- `04-planning-engine`, `05-tools-v2-skills`, `06-autonomy`, `07-learning`.
