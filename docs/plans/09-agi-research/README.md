# 09 — AGI Research

**Category goal:** Track the genuinely open research problems rather than pretend we are "building AGI." Each plan here is a **research notebook** — a place-holder for hypotheses, prototypes, and honest status — not a commit-level implementation plan. The roadmap (00) does **not** treat these as ship commitments.

The three research threads map to the gaps identified in `../AGI_ASSESSMENT.md`:

1. `09.1-world-model` — internal models of consequences for planning (responsibility for §3.5 "no causal world model").
2. `09.2-continual-learning` — safely updating capabilities without forgetting (responsibility for §3.3 "no learning").
3. `09.3-intrinsic-motivation` — self-generated goals and exploration (responsibility for §3.6 "no intrinsic agency").

**Ground rule:** any effort here is gated on **P1–P3 (01–06)** being stable, and any result that looks promising must first pass the normal engineering gates (tests, CI, permissions) before touching production.

---

## Sequencing & status

1. `09.1-world-model` — notes + optional prototype (low resource).
2. `09.2-continual-learning` — depends on `07.2` fine-tuning substrate.
3. `09.3-intrinsic-motivation` — depends on `06-autonomy` operating safely.

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