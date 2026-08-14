# 02 — Agent Reliability

**Category goal:** Make the current narrow agent *honest and dependable*. This is the phase that ships: fix the real defects identified in `../AGI_ASSESSMENT.md` §3.7, remove fabricated telemetry, and make tool calling robust enough to trust.

**Why before new architecture:** Every future plan (memory, planning, autonomy) builds on an agent loop and tools. Building on a loop that can deadlock on stdin, scrape-fragile HTML, or report `rand(10:80)` as CPU usage would compound the mistakes.

---

## Sequencing

1. `02.1-stdin-bridge-conflict` — fix the `readline(stdin)` deadlock that breaks tool use inside the bridge.
2. `02.2-tool-permission-redesign` — replace ad-hoc "ask on every command" with a real approval model (needs 02.1).
3. `02.3-real-telemetry` — remove fabricated metrics; return explicit unknowns.
4. `02.4-web-search-reliability` — stop string-splitting DuckDuckGo HTML.
5. `02.5-parser-hardening` — make the JSON tool-call parser robust (stopgap; replaced by `05.1-native-function-calling`).

---

## Shared template reminder

Each sub-plan follows: Objective → Current State → Design → Work Breakdown → Acceptance Criteria → Risks & Mitigations → Dependencies → Definition of Done.

---

## Links

- [02.1 stdin/bridge conflict](02.1-stdin-bridge-conflict.md)
- [02.2 tool permission redesign](02.2-tool-permission-redesign.md)
- [02.3 real telemetry](02.3-real-telemetry.md)
- [02.4 web search reliability](02.4-web-search-reliability.md)
- [02.5 parser hardening](02.5-parser-hardening.md)

## Depends on
- `01-foundations` (tests, CI, logging, error taxonomy).

## Blocks
- `03-memory-v2`, `04-planning-engine`, `05-tools-v2-skills`, `06-autonomy` all assume a reliable tool/agent core.
