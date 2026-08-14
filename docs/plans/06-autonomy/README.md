# 06 — Autonomy

**Category goal:** Let Kamila act **without being asked** — a background daemon that monitors, reacts, and schedules proactive work; a goal engine that turns user-entered goals into decomposed plans (`04`) and drives them forward; and an orchestrator that schedules bounded autonomous execution under capability constraints.

**Why:** The AGI assessment (§3.6) identified "purely reactive, no intrinsic agency" as a core gap. Autonomy is the first category that makes Kamila *initiate* rather than merely respond. It must be strictly bounded — the `02.2`/`05.3` permission model is the safety envelope autonomy runs inside.

---

## Sequencing

1. `06.1-proactive-daemon` — a background process/lifetime so Kamila can react to events and schedule things (needs `01.3`, `02`).
2. `06.2-goal-engine` — goals → decomposed plans → tracked progress (needs `04`, `05.2`, `03`).
3. `06.3-orchestrator` — bounded autonomous schedules that dispatch plans/daemon tasks (needs `06.1`, `06.2`, `04.2/04.3`, `05.3`).

---

## Shared template reminder

Each sub-plan follows: Objective → Current State → Design → Work Breakdown → Acceptance Criteria → Risks & Mitigations → Dependencies → Definition of Done.

---

## Links

- [06.1 Proactive daemon](06.1-proactive-daemon.md)
- [06.2 Goal engine](06.2-goal-engine.md)
- [06.3 Orchestrator](06.3-orchestrator.md)

## Depends on
- `01-foundations`, `02-agent-reliability`, `03-memory-v2`, `04-planning-engine`, `05-tools-v2-skills`.

## Blocks
- `07-learning` (needs an autonomous system to observe), `08-perception` (needs an event loop to ingest).