# Kamila — AGI Readiness Assessment (Deep Research Report)

**Date:** 2026-08-07
**Scope:** All of `src/` (15 Julia modules), `src/ai/tools.jl` skill registry, agent loop, memory system, security layer, bridge protocol, Node.js TUI, tests, and docs.
**Question:** Are Kamila's current skills sufficient for the assistant to be an AGI (Artificial General Intelligence)?

---

## 1. Executive Verdict

> **No.** Kamila's skills are a necessary *interface* layer, but they constitute roughly 5% of what AGI requires.

The 13 registered tools are stateless I/O ports. All cognition is delegated to an Ollama-hosted LLM (`gpt-oss:120b-cloud` via `config/Modelfile.online`, the `kamila1` model). An LLM plus 13 narrow tools is a capable **domain-specific agent**, not a general intelligence. The gap between Kamila and AGI is architectural — it cannot be closed by "adding a few more tools."

---

## 2. What Kamila Actually Has ("the skills")

### 2.1 The 13 registered tools — `src/ai/tools.jl:692`

| # | Tool | What it does | Notes |
|---|------|--------------|-------|
| 1 | `run_shell_command` | Execute a bash command | Requires stdin confirmation |
| 2 | `read_file` | Read text files (line ranges, byte caps) | Text only |
| 3 | `write_file` | Write/append files | Whitelisted dirs only |
| 4 | `list_directory` | List dirs with sizes/dates | |
| 5 | `add_task` | Create task | |
| 6 | `list_tasks` | List tasks w/ filters | |
| 7 | `complete_task` | Mark task done | Adds "achievement" |
| 8 | `web_search` | DuckDuckGo HTML scrape | Fragile |
| 9 | `file_find` | Find files by substring | Depth-limited |
| 10 | `grep_search` | Regex content search | Shells out to grep |
| 11 | `system_status` | CPU/mem/disk/health | Fake CPU fallback |
| 12 | `set_reminder` | Desktop notifications | |
| 13 | `memory_query` | Read JSON memory back | No semantic recall |

### 2.2 The agent machinery

- **JSON tool-calling loop:** `src/ai/agent.jl:138` (regex/JSON extraction from free text), `src/ai/agent_stream.jl:56` (autonomous loop), `src/bridge.jl:312` (TUI-facing loop).
- **Modes:** chat / plan / test / execute — `src/bridge.jl:94`, prompt templates in `src/ai/agent.jl:73-136`.
- **Model router with fallback chain:** `src/ai/model_router.jl` (chat/code/quick/vision/default).
- **Persistent storage:** flat JSON at `~/.kamila_memory.json` — `src/memory/memory.jl`.
- **Security sandbox:** Linux-only, password auth, whitelisted dirs — `src/security/*`.
- **Bridge protocol:** JSON-RPC over stdin/stdout to the Node.js TUI (`src/bridge.jl:870`, `tui/src/bridge.js`).

---

## 3. Why This Is Not AGI

### 3.1 Tools ≠ intelligence — the model is the bottleneck

The skills do no thinking; they are functions invoked by the model. All reasoning is outsourced to `gpt-oss:120b-cloud` (the `kamila1` online model; `kamila2`/`qwen3:8b` is the offline fallback). That model is a next-token predictor with well-documented limits:

- hallucination / no reliable grounding,
- no persistent state across sessions,
- fixed context window,
- no self-correction mechanism built into the weights.

Tool use extends the model's **reach** (what it can act on) but not its **generality** (what it can figure out). This is the central confusion: giving an LLM a shell does not make it general-purpose — it makes it an LLM with a shell.

### 3.2 Generalization breadth ≈ zero

AGI, by definition, must handle *any* intellectual task a human can. Kamila's perception is confined to:

- text files in 6 whitelisted directories (`src/Kamila.jl:10`),
- DuckDuckGo HTML search snippets (`src/ai/tools.jl:406`),
- `/proc`, `df`, `ps` system telemetry (`src/system/monitor.jl`),
- a JSON todo list.

There is no vision path, no audio/multimodal input, no sensors, no robotics, no arbitrary novel task. It is a domain-locked personal terminal assistant.

### 3.3 No learning or self-improvement — the fatal gap

AGI implies *acquiring new skills from experience*. Kamila's "memory" (`src/memory/memory.jl:46-72`) is a flat JSON dictionary of tasks/goals/achievements/percentages. Critically:

- nothing ever updates the model's weights,
- no skill is ever added at runtime (the tool registry is a hardcoded constant, `src/ai/tools.jl:692`),
- no reinforcement learning, no curriculum, no behavior refinement from feedback.

It is a **fixed-policy agent**. This single missing pillar is disqualifying on its own.

### 3.4 No real memory

- `MAX_CHAT_HISTORY = 20` (`src/bridge.jl:48`) and `MAX_HISTORY = 10` (`src/ai/agent.jl:11`) — a sliding-window forget.
- No embeddings, no semantic/episodic retrieval, no associative recall, no forgetting curves.
- `memory_query` merely reads the same JSON fields back (`src/ai/tools.jl:606-670`).

An AGI needs a long-term memory architecture that *retrieves the right thing at the right time*. Kamila has none.

### 3.5 No long-horizon planning or self-verification

The agent loop is a bare `while iteration < max_iterations` (`src/ai/agent_stream.jl:56`), with:

- **one tool call at a time** — "You can only call ONE tool at a time" (`src/ai/agent.jl:43`),
- no plan state machine, no tree search, no backtracking/undo,
- no causal world model, no consequence simulation,
- "Check" is a *prompt suggestion*, not an enforced mechanism (`src/ai/agent.jl:33-38`).

AGI requires persistent goal structures and consequence modeling; Kamila has neither.

### 3.6 No intrinsic agency

AGI exhibits self-directed goals, curiosity, and autonomy. Kamila is purely reactive: request → respond. Its "goals" are strings typed by the user (`src/memory/memory.jl:114-135`); nothing self-generates objectives, explores, or initiates behavior (the only proactive behavior is `set_reminder` → `notify-send`).

### 3.7 Narrow-agent defects in the current implementation

Beyond the conceptual gap, several defects cap even narrow usefulness:

| Defect | Location | Consequence |
|--------|----------|-------------|
| `readline(stdin)` inside `run_shell_command` | `src/ai/tools.jl:49` | Competes with the bridge's JSON-RPC stdin loop (`src/bridge.jl:852`); confirmation prompt and protocol loop fight for the same input. |
| Tool-calling via regex/JSON scraping | `src/ai/agent.jl:138-211` | Brittle vs. native function-calling APIs. |
| `web_search` string-splits DuckDuckGo HTML | `src/ai/tools.jl:414` | Breaks on any HTML change. |
| `get_cpu_usage` falls back to `rand(10:80)` | `src/system/monitor.jl:168` | Fabricated telemetry masquerading as real. |
| Trailing-comma JSON cleanup `replace(r",\s*([}\]])", ...)` | `src/ai/agent.jl:164` | Heuristic, not a parser. |

### 3.8 Research consensus (2026)

The active research position is that LLM + tool-use produces strong **narrow agents**, not AGI. The pillars that every credible AGI roadmap shares are missing here:

1. **Continual / meta-learning** — absent.
2. **Long-horizon planning with a world model** — absent.
3. **Persistent episodic + semantic memory with retrieval** — absent.
4. **Intrinsic motivation / self-directed exploration** — absent.
5. **Cross-modal grounding** — absent.

---

## 4. Scorecard

| AGI requirement | Kamila status | Evidence |
|-----------------|---------------|----------|
| Broad perception | ✗ | Text-only; 6 dirs (`src/Kamila.jl:10`) |
| Arbitrary reasoning | ✗ | Delegated to one LLM (`config/Modelfile.online`) |
| Learning / self-improvement | ✗ | Fixed registry (`src/ai/tools.jl:692`) |
| Episodic / semantic memory | ✗ | Flat JSON, 10-turn window (`src/memory/memory.jl:46`) |
| Planning / self-verification | ✗ | 10-iteration loop, 1 tool at a time (`src/ai/agent_stream.jl:56`) |
| Agency / intrinsic goals | ✗ | Purely reactive |
| General tool skills | ~5% | 13 fixed functions (`src/ai/tools.jl:692-827`) |

**Bottom line:** Kamila is a competent *narrow AI* personal assistant — not an AGI, and not on a path to AGI as currently architected.

---

## 5. Recommended Paths (ordered by effort/impact)

### Tier A — Fix the narrow agent (1–2 days)
1. Replace stdin confirmation with a pre-approval allowlist + `--yes` flag to resolve the `src/bridge.jl` / `src/ai/tools.jl:49` conflict.
2. Swap `web_search` for a stable API (e.g., DDG lite endpoint or a real search API) — `src/ai/tools.jl:396`.
3. Remove the `rand(10:80)` CPU fallback; compute real usage from two `/proc/stat` samples — `src/system/monitor.jl:139`.
4. Adopt native Ollama function-calling (JSON-schema tools) instead of regex scraping — `src/ai/agent.jl:138`.

### Tier B — Move toward a genuinely autonomous agent (1–2 weeks)
1. **Real memory:** embeddings + vector recall for semantic/episodic retrieval; replace the 10/20-turn windows.
2. **Plan state machine:** persistent plan object with steps, dependency tracking, backtracking/undo, and enforced verify-before-done.
3. **Parallel tool calls** and async sub-agents.
4. **Skill self-registration:** allow the agent to define and persist new tool functions at runtime.

### Tier C — Honest steps toward "AGI-like" behavior (research, months+)
1. **Learning loop:** feedback → experience store → policy refinement (RLHF/RLAIF on local data).
2. **World model / simulator** for consequence prediction before acting.
3. **Intrinsic motivation:** curiosity-driven exploration and self-generated goals.
4. **Multimodal perception** (vision/audio) beyond text.
5. **Continual learning** that updates weights without catastrophic forgetting.

---

## 6. Conclusion

Kamila's skills are a clean, secure, well-organized tool surface — a good foundation for a **personal terminal agent**. They are not, and cannot by themselves become, AGI. The determining factor is not the skill count but the absence of **learning, memory architecture, planning, and agency** in the system design.
