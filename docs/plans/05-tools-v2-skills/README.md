# 05 — Tools v2 & Skills

**Category goal:** Upgrade the tool system from 13 hardcoded Julia functions invoked via fragile text-JSON scraping into a **schema-defined, natively function-called, runtime-growable skill library** with a capability-based permission model. This is where the tool surface becomes extensible enough to support autonomy and learning.

**Why:** The AGI assessment (§3.7) flagged the regex-scraped JSON tool calling and the hardcoded registry (`get_all_tools()` at `src/ai/tools.jl:692`). `05.1` is the real fix that `02.5` only patched; `05.2` makes skills a first-class, persistent, growing artifact; `05.3` formalizes the permission model `02.2` began.

---

## Sequencing

1. `05.1-native-function-calling` — Ollama JSON-schema tool calling (protocol-level, replaces text scraping as primary path). ✅ **DONE** — `ToolSpec` module + schema derivation/validation, `tools` array wired through `query_ollama_chat_stream` → `query_router_chat_stream` → `run_agent_stream_native` with text-parse fallback; system prompt trimmed to name+hint list; `test/tool_spec_test.jl` 48/48. Full suite 4268 pass / 2 broken.
2. `05.2-skill-library` — skills become registered, versioned, persisted artifacts (needs 05.1). ✅ **DONE** — schema v5 `skills` table + migration, `Skills` loader module (seed built-ins, install/uninstall/enable/disable/version bump, user-dir sandboxed loading, `learn_skill` self-registration gated `enabled=false`, shell template allowlist + forbidden-command blocklist), `register_tool_source!` hook so `get_all_tools()` derives from the registry, `skills.*` bridge routes; `test/skill_test.jl` 65/65. Full suite 4335 pass / 2 broken.
3. `05.3-permission-model` — capability-based permission system (needs `02.2`, formalized). ✅ **DONE** — `Capability` module (tool→cap map, HMAC tokens with exp+nonce, one-shot replay, `restrict_caps` scope intersection, audit), `default_capabilities` + `cap:`/`skill:` rules in `Permission`, `force` confirmed hint-only, scope propagation batch→sub-agent→`run_agent_sync`, skill `required_capabilities` gating, `capability.audit` bridge route; `test/capability_test.jl` 62/62. Full suite 4397 pass / 2 broken.

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
