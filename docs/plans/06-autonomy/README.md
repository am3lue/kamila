# 06 — Autonomy

**Category goal:** Let Kamila act **without being asked** — a background daemon that monitors, reacts, and schedules proactive work; a goal engine that turns user-entered goals into decomposed plans (`04`) and drives them forward; and an orchestrator that schedules bounded autonomous execution under capability constraints.

**Why:** The AGI assessment (§3.6) identified "purely reactive, no intrinsic agency" as a core gap. Autonomy is the first category that makes Kamila *initiate* rather than merely respond. It must be strictly bounded — the `02.2`/`05.3` permission model is the safety envelope autonomy runs inside.

---

## Sequencing

1. [x] `06.1-proactive-daemon` — **DONE** (2026-08-15): `Events` bus, `Scheduler` with `scheduled_jobs` (Migration 6), `Daemon.run()` main loop + pid file + graceful shutdown, headless permission resolution, `set_reminder` persisted, bridge→TUI notification forwarding, `--daemon/--daemon-status/--daemon-stop` CLI. Tests: `test/daemon_test.jl` (50). Full suite 4447 pass / 2 broken.
2. [x] `06.2-goal-engine` — **DONE** (2026-08-15): `goals.plan_id` + `goals.progress` derived cache (Migration 7), `link_goal_plan`/`goal_progress`/gated `complete_goal`, `decompose_goal` retro-decomposition, `goal.progress` events on plan-step verification, bridge `goal.*` routes, `memory_query goals` derived progress. Tests: `test/goal_test.jl` (24). Full suite 4471 pass / 2 broken.
3. [x] `06.3-orchestrator` — **DONE** (2026-08-15): `module Executive` (work-item collection from plans/jobs/goals, deterministic priority sort, per-day budget ledger persisted in `kv`, propose-vs-execute gate defaulting to propose-only, verify-fail pauses plan via `Plan.pause_on_failure`, interactive preemption, catch-up on boot, auditable debits), daemon `tick_once` integration, bridge `orchestrator.*` routes incl. `orchestrator.pause` kill switch. Tests: `test/executive_test.jl` (60). Full suite 4471+ pass / 2 broken.

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