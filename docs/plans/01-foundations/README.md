# 01 — Foundations

**Category goal:** Before any new agent capability, establish the quality gates that make every later plan safe to ship: a real test infrastructure, continuous integration, structured observability, and a shared error taxonomy.

**Why this is first:** Everything downstream (memory, planning, autonomy, learning) is only as trustworthy as the ability to verify it. The current project has a mock-heavy test suite (`test/tools_test.jl` mocks `FileAccess`, `KamilaMemory`, `TaskManager`, `SystemMonitor`, `HTTP`, `OllamaInterface`), no CI, bare `println` logging, and `extract_error(e) = string(e)` as the "error taxonomy". Fixing that first is the difference between a hobby project and an engineering system.

---

## Sequencing

1. `01.1-test-infra` — rebuild the test harness (real integration where possible, strict mocks where not).
2. `01.2-ci-pipeline` — run the suite automatically on every change (needs 01.1).
3. `01.3-observability` — replace `println` ad-hoc logging with structured, leveled logging.
4. `01.4-error-taxonomy` — introduce typed error categories so callers and tools can react.
5. `01.5-fast-models-and-thinking` — dual Ollama models with fallback and thinking display.
6. `01.6-tui-chat-rendering` — message store + incremental renderer for the TUI chat surface (needs 01.5's streaming protocol).

These block **every** plan in categories 02–09.

---

## Shared template reminder

Each sub-plan follows: Objective → Current State → Design → Work Breakdown → Acceptance Criteria → Risks & Mitigations → Dependencies → Definition of Done.

---

## Implementation Status Summary (as of 2026-08-09)

| Plan | Status | Tests Passing | Key Deliverables |
|------|--------|---------------|------------------|
| **01.1-test-infra** | ✅ **Done** | 3539/3539 | Test runner, helpers, 11 test targets, coverage script, `scripts/test.sh` |
| **01.2-ci-pipeline** | ✅ **Done** | N/A | GitHub Actions (4 jobs), JuliaFormatter+Aqua+JET, ESLint, pre-commit, bridge smoke |
| **01.3-observability** | ✅ **Done** | N/A | `KamilaLog` module, structured JSON logging, file rotation, context, all `println`→stderr migrated |
| **01.4-error-taxonomy** | ✅ **Done** | N/A | `KamilaError` struct, 9 categories, structured bridge errors, agent retry logic |
| **01.5-fast-models** | ✅ **Done** | N/A | Dual models (kamila1/kamila2), fallback, thinking relay, TUI click-to-expand |
| **01.6-tui-chat-rendering** | ✅ **Done** | 25 JS tests | Message store + incremental renderer, stream/copy/thinking/hydration, multiline input + recall ring |

**All 01-foundations plans complete.** Test suite green (3539 tests), CI configured, observability and error taxonomy implemented, dual-model setup with thinking display working, and the TUI chat surface rebuilt on a store-backed incremental renderer.

---

## Links

- [01.1 Test infrastructure](01.1-test-infra.md)
- [01.2 CI pipeline](01.2-ci-pipeline.md)
- [01.3 Observability](01.3-observability.md)
- [01.4 Error taxonomy](01.4-error-taxonomy.md)
- [01.5 Fast models & thinking](01.5-fast-models-and-thinking.md)
- [01.6 TUI chat rendering](01.6-tui-chat-rendering.md)

## Depends on

- Nothing (foundations are the root of the dependency graph).

## Blocks

- Everything: `02-agent-reliability` → `09-agi-research` (plus future UI work from `01.6-tui-chat-rendering`).

---

## Additional Work Implemented (Not in Original Plans)

The following were implemented during 01-foundations but support future categories:

| Component | Purpose | Target Category |
|-----------|---------|-----------------|
| `test/agent_stream_test.jl` | Agent stream logic tests | 01.1 (extra) |
| `test/confirm_test.jl` | Confirmation dialog tests | 02.1 |
| `test/permission_test.jl` | Permission system tests | 02.2 |
| `test/monitor_test.jl` | System monitor tests | 01.3 (extra) |
| `test/search_test.jl` | Web search tests | 01.1 (extra) |
| `test/error_taxonomy_test.jl` | Error taxonomy tests | 01.4 |
| `test/log_test.jl` | Logging module tests | 01.3 |
| `test/lint_test.jl` | Lint test target | 01.2 |
| `test/memory_db_test.jl` | SQLite memory DB tests | 03.1 |
| `src/system/confirm.jl` | Confirmation helper | 02.1 |
| `src/system/code_tracker.jl` | Code change tracking | — |
| `src/system/search.jl` | Search functionality | — |
| `src/ai/response_parser.jl` | Response parsing | 02.5 / 05.1 |
| `src/ai/tts.jl` | Text-to-speech | — |
| `src/ai/agent.jl` (updated) | Agent with stream support | 01.5 |
| `tui/src/confirm.js` | Confirmation overlay | 02.1 |
| `tui/src/permission.js` | Permission panel | 02.2 |
| `tui/src/taskaction.js` | Task action overlay | — |
| `tui/src/logs.js` | Log panel | 01.3 |
| SQLite migration in memory | `kamila.db` schema v1 | 03.1 |
