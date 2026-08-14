# 05 — Tools v2 & Skills

**Category goal:** Upgrade the tool system from 13 hardcoded Julia functions invoked via fragile text-JSON scraping into a **schema-defined, natively function-called, runtime-growable skill library** with a capability-based permission model. This is where the tool surface becomes extensible enough to support autonomy and learning.

**Why:** The AGI assessment (§3.7) flagged the regex-scraped JSON tool calling and the hardcoded registry (`get_all_tools()` at `src/ai/tools.jl:692`). `05.1` is the real fix that `02.5` only patched; `05.2` makes skills a first-class, persistent, growing artifact; `05.3` formalizes the permission model `02.2` began.

---

## Sequencing

1. `05.1-native-function-calling` — Ollama JSON-schema tool calling (protocol-level, replaces text scraping as primary path).
2. `05.2-skill-library` — skills become registered, versioned, persisted artifacts (needs 05.1).
3. `05.3-permission-model` — capability-based permission system (needs `02.2`, formalized).

---

## Shared template reminder

Each sub-plan follows: Objective → Current State → Design → Work Breakdown → Acceptance Criteria → Risks & Mitigations → Dependencies → Definition of Done.

---

## Links

- [05.1 Native function calling](05.1-native-function-calling.md)
- [05.2 Skill library](05.2-skill-library.md)
- [05.3 Permission model](05.3-permission-model.md)

## Depends on
- `01-foundations`, `02-agent-reliability`, `03-memory-v2`, `04-planning-engine`.

## Blocks
- `06-autonomy`, `07-learning`, `08-perception`.
