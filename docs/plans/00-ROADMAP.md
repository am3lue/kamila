# Kamila — Engineering Roadmap

**Last updated:** 2026-08-07
**Companion assessment:** [`../AGI_ASSESSMENT.md`](../AGI_ASSESSMENT.md)

This roadmap is the master index for every plan under `docs/plans/`. Each category has a README (sequencing + rationale) and numbered sub-plans. Sub-plans follow one template:

> Objective → Current State (code citations) → Design (+ alternatives) → Work Breakdown (file paths, tasks, done-criteria) → Acceptance Criteria → Risks & Mitigations → Dependencies → Definition of Done.

---

## 1. Phases at a glance

| Phase | Name | Categories | Gate | Shippable result |
|-------|------|-----------|------|------------------|
| **P1** | Foundations & Reliability | `01-foundations`, `02-agent-reliability` | Test suite green, CI green | A hardened, honest narrow agent (no fake telemetry, no stdin deadlock, stable web search, robust parsing) |
| **P2** | Agent Architecture v2 | `03-memory-v2`, `04-planning-engine`, `05-tools-v2-skills` | All P2 plans Done | Real long-term memory, plan state machine, native function calling, runtime-growable skill library |
| **P3** | Autonomy | `06-autonomy` | P2 stable for 2 weeks | Proactive daemon, goal engine, orchestrator — Kamila acts without being asked |
| **P4** | Learning | `07-learning` | P3 stable | Experience store, local fine-tuning pipeline, preference learning |
| **P5** | Perception | `08-perception` | P4 stable | Vision, speech, desktop-awareness input paths |
| **R** | AGI Research | `09-agi-research` | Continuous, no gate | Research notes, prototypes, honest status — **not** ship commitments |

Phase **P1 → R** ordering is a hard dependency: do not start a later category while an earlier one is red.

---

## 2. Category dependency graph

```
01-foundations ──► 02-agent-reliability ──► 03-memory-v2 ──► 04-planning-engine ──► 05-tools-v2-skills
                                                      │                              │
                                                      └──────────────┬───────────────┘
                                                                     ▼
                                                               06-autonomy
                                                                     │
                                                                     ▼
                                                               07-learning
                                                                     │
                                                                     ▼
                                                               08-perception
                                                                     │
                                                                     ▼
                                                          09-agi-research (research)
```

Rules:
- `01.1-test-infra` and `01.2-ci-pipeline` block **everything** (no red plan may start without a green suite).
- `03-memory-v2` must land before `04-planning-engine` (plans need memory to persist).
- `04.3-verification-loop` needs `04.1-plan-state-machine`.
- `05.1-native-function-calling` replaces the regex parser from `02.5-parser-hardening`; the two must be reconciled (02.5 is the stopgap, 05.1 is the real fix).
- `06-autonomy` depends on `03` + `04` + `05`.

---

## 3. Effort & risk per sub-plan

Legend: **M** = mocks, **T** = testable, **A** = acceptance, **R** = risk. Effort S/M/L, risk Low/Med/High.

### 01 — Foundations
| Plan | Effort | Risk | Blocks |
|------|--------|------|--------|
| 01.1 test-infra | L | Med | All |
| 01.2 ci-pipeline | S | Low | All |
| 01.3 observability | M | Med | All |
| 01.4 error-taxonomy | S | Low | 02.x |
| 01.5 fast-models-and-thinking | M | Low | 01.6 (streaming/thinking protocol) |
| 01.6 tui-chat-rendering | M | Med | future UI work |

### 02 — Agent Reliability
| Plan | Effort | Risk | Blocks |
|------|--------|------|--------|
| 02.1 stdin-bridge-conflict | S | Med | 06-autonomy |
| 02.2 tool-permission-redesign | M | High | 05.3 |
| 02.3 real-telemetry | M | Low | — |
| 02.4 web-search-reliability | M | Med | — |
| 02.5 parser-hardening | M | Med | 05.1 |

### 03 — Memory v2
| Plan | Effort | Risk | Blocks |
|------|--------|------|--------|
| 03.1 storage-engine | L | Med | 03.2, 03.3, 03.4 |
| 03.2 embeddings-retrieval | M | Med | 03.4 |
| 03.3 episodic-summarization | M | Med | 03.4 |
| 03.4 context-injection | M | Low | 04, 06 |

### 04 — Planning Engine
| Plan | Effort | Risk | Blocks |
|------|--------|------|--------|
| 04.1 plan-state-machine | L | High | 04.2, 04.3, 04.4 |
| 04.2 tool-orchestration | M | Med | 06 |
| 04.3 verification-loop | M | Med | 06 |
| 04.4 task-decomposition | M | Med | 06 |

### 05 — Tools v2
| Plan | Effort | Risk | Blocks |
|------|--------|------|--------|
| 05.1 native-function-calling | M | Med | 05.2 |
| 05.2 skill-library | M | Med | 06 |
| 05.3 permission-model | M | High | 06 |

### 06 — Autonomy
| Plan | Effort | Risk | Blocks |
|------|--------|------|--------|
| 06.1 proactive-daemon | L | High | — |
| 06.2 goal-engine | M | Med | 06.3 |
| 06.3 orchestrator | L | High | — |

### 07 — Learning
| Plan | Effort | Risk | Blocks |
|------|--------|------|--------|
| 07.1 experience-store | M | Med | 07.2, 07.3 |
| 07.2 local-fine-tuning | L | High | — |
| 07.3 preference-learning | M | High | — |

### 08 — Perception
| Plan | Effort | Risk | Blocks |
|------|--------|------|--------|
| 08.1 vision | M | Med | 08.3 |
| 08.2 speech | M | Med | 08.3 |
| 08.3 desktop-awareness | L | High | — |

### 09 — AGI Research (research, no effort commitment)
| Plan | Status |
|------|--------|
| 09.1 world-model | Research notes + prototype |
| 09.2 continual-learning | Research notes + prototype |
| 09.3 intrinsic-motivation | Research notes + prototype |

---

## 4. Architectural decisions already taken (rationale in sub-plans)

1. **Storage:** move from flat JSON (`~/.kamila_memory.json`) to SQLite for memory + skills (`03.1`). JSON stays for export/compat.
2. **Function calling:** adopt Ollama's native JSON-schema tools API; keep the text-JSON parser as a stopgap only (`02.5`, replaced by `05.1`).
3. **Planning:** a persisted `Plan` state machine replaces the bare `while iteration < max_iterations` loop (`04.1`).
4. **Permissions:** capability-based permission checks decoupled from tool implementations (`02.2` → `05.3`).
5. **Telemetry:** never fabricate data; any unavailable metric returns `nothing`/`unknown` explicitly (`02.3`).
6. **TUI chat rendering:** a message store + incremental renderer replaces string-splitting the rendered buffer; message identity and click-to-copy come from a line→message map, never from scanning display text (`01.6`).

---

## 5. Definition of Done (project-wide)

A plan is Done when **all** of these hold:
- [ ] All `Acceptance Criteria` in the plan pass as automated tests (not manual checks).
- [ ] `01.1` suite runs green via `01.2` CI on a pull request.
- [ ] No mocked dependency is silently trusted in production paths touched by the plan.
- [ ] Docs updated (this roadmap + relevant category README).
- [ ] No new security regression (paths validated, commands confirmed, no secrets logged).

---

## 6. How to use this roadmap

1. Start at `01-foundations/README.md`.
2. Work sub-plans in numbered order within a category.
3. Mark a sub-plan Done in the plan file's `Definition of Done` checklist.
4. Update this roadmap's tables when effort/risk changes materially.

_Nothing in `09-agi-research` is a commitment to ship; those plans are honest research scoping, tracked to avoid cargo-culting the word "AGI"._
