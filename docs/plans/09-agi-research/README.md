# 09 — AGI Research

**Category goal:** Track the genuinely open research problems rather than pretend we are "building AGI." Each plan here is a **research notebook** — a place-holder for hypotheses, prototypes, and honest status — not a commit-level implementation plan. The roadmap (00) does **not** treat these as ship commitments.

The three research threads map to the gaps identified in `../AGI_ASSESSMENT.md`:

1. `09.1-world-model` — internal models of consequences for planning (responsibility for §3.5 "no causal world model").
2. `09.2-continual-learning` — safely updating capabilities without forgetting (responsibility for §3.3 "no learning").
3. `09.3-intrinsic-motivation` — self-generated goals and exploration (responsibility for §3.6 "no intrinsic agency").

**Ground rule:** any effort here is gated on **P1–P3 (01–06)** being stable, and any result that looks promising must first pass the normal engineering gates (tests, CI, permissions) before touching production.

---

## Sequencing & status

1. `09.1-world-model` — **prototype**: exact-key outcome predictor over the `07.1` experience store + held-out eval harness (`src/research/outcome_predictor.jl`, `test/outcome_predictor_test.jl`). Honest status: scaffolding validated (22 tests); go/no-go **not yet decided** — the production DB currently holds 0 experience rows, so the "beats random by >20pts / false-veto <2%" rubric cannot be measured yet. Seam is ready for real data.
2. `09.2-continual-learning` — **prototype (scaffolding only)**: `longitudinal_split` in `src/learning/eval.jl` measures per-skill regression holds GPU-free via the injected runner (`test/eval_test.jl`). Real LoRA runs need a GPU (07.2 substrate); **not yet run** — honest status.
3. `09.3-intrinsic-motivation` — **prototype**: curiosity novelty tie-breaker in `Orchestrator.Executive` (`novelty_score`, `set_curiosity!`; off by default, only reorders already-planned work). `test/executive_test.jl`. Go/no-go needs a real 2-week A/B; **not yet decided**.

---

## Each research doc contains
- Hypothesis (testable claim).
- Prior art (key references/approaches to survey).
- Sketched approach, cost estimate, and open risks.
- **Status** — `none → reading → prototype → validated → abandoned`.
- Explicit **go/no-go** rubric.

---

## Links
- [09.1 World model](09.1-world-model.md)
- [09.2 Continual learning](09.2-continual-learning.md)
- [09.3 Intrinsic motivation](09.3-intrinsic-motivation.md)