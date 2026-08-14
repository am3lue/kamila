# 04 — Planning Engine

**Category goal:** Replace the bare `while iteration < max_iterations` agent loop with a real, persisted **plan state machine**: tasks are decomposed into ordered steps with dependencies, executed with orchestration, verified before completion, and recoverable across failures and restarts.

**Why:** The AGI assessment (§3.5) identified no plan state, no backtracking, no enforced verification, one-tool-at-a-time, and `max_iterations=10` (`src/ai/agent_stream.jl:56`) as core limitations. This category is where the agent stops being a "loop" and becomes a "planner".

---

## Sequencing

1. `04.1-plan-state-machine` — the persisted plan object + lifecycle (foundation; requires `03.1` for persistence).
2. `04.2-tool-orchestration` — parallel tool calls, sub-agent spawning (needs 04.1).
3. `04.3-verification-loop` — enforced verify-before-done (needs 04.1, `01.4`).
4. `04.4-task-decomposition` — recursive decomposition + dependency resolution (needs 04.1).

---

## Shared template reminder

Each sub-plan follows: Objective → Current State → Design → Work Breakdown → Acceptance Criteria → Risks & Mitigations → Dependencies → Definition of Done.

---

## Links

- [04.1 Plan state machine](04.1-plan-state-machine.md)
- [04.2 Tool orchestration](04.2-tool-orchestration.md)
- [04.3 Verification loop](04.3-verification-loop.md)
- [04.4 Task decomposition](04.4-task-decomposition.md)

## Depends on
- `01-foundations`, `02-agent-reliability`, `03-memory-v2`.

## Blocks
- `06-autonomy` (orchestrator needs the plan engine), `05-tools-v2-skills` (tool model integrates with plans).
