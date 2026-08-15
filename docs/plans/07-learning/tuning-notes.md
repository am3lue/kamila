# Tuning Notes — 07.2 Local Fine-Tuning

Status: prototype/design-level, not a shipped commitment. These notes track
the known unknowns honestly and document what the code in `src/learning/`
does and does not cover.

## What the pipeline does

1. **Data (`src/learning/tune/import.jl`)** — reads a `07.1` experience JSONL
   export, keeps `verified=true` rows, applies quality heuristics (length,
   verification, a conservative regex PII heuristic), dedupes on the
   `(prompt, result)` pair, and caps the dataset (default ≤ 2,000). Output is
   `{system, user, assistant}` chat exemplars in JSONL.
2. **Train (`src/learning/tune/train.jl`)** — renders a `Modelfile`
   (`FROM <small local base>` + `ADAPTER <lora>` + reused `PARAMETER`s) and,
   only when `dry_run=false`, runs `ollama create <new-model> -f <modelfile>`.
   The primary model is never mutated; the tuned model is always a new name.
   Defaults to `dry_run=true`.
3. **Eval (`src/learning/eval.jl`)** — runs base vs adapter over a hold-out set
   with an injectable `runner`, computes functional success rates, and gates
   promotion on a minimum percentage-point improvement **and** no regression on
   deny-class (safety) prompts.
4. **Promote (`src/learning/tune/promote.jl`)** — only registers the adapter in
   the ModelRouter config after the gate passes, and always `enabled=false`
   (never auto-selected; user opts in).

## Base-model choice

- Inference default is `gpt-oss:120b-cloud` (`config/Modelfile`) — far too large
  to fine-tune on consumer hardware.
- Fine-tuning target should be a **small local model** (e.g.
  `qwen2.5-coder:0.5b`, already the `:quick` fallback in `src/ai/model_router.jl`).
  Fine-tuned adapters are task-specialized for narrow, repeated tasks only.

## LoRA / QLoRA

- Ollama supports LoRA adapters via `ADAPTER <path-to-lora.gguf>` in a Modelfile,
  combined with `ollama create`.
- Producing the adapter `.gguf` (via PEFT/QLoRA on the dataset from step 1) is
  **not** implemented here — this is the gap between the prototype pipeline and
  a real training run. Hardware detection (`nvidia-smi` / Ollama GPU flag) is
  documented intent, not implemented.

## Hardware / failure modes

- Without a GPU, the pipeline still works: data prep + eval + gated promotion
  are fully testable (tests inject a canned `runner` and use `dry_run`).
- Known failure modes: small models may not improve functional success; adapter
  may degrade general chat; overfitting to the tool-call mirror.

## Eval design

- Metric is **functional success** (tool result verified / task `check_ok`), not
  loss or perplexity. ROUGE/BLEU are optional proxies; functional success is
  primary.
- Promotion requires adapter ≥ base + `min_improvement` (default +5pp) AND no
  deny-class regression. Adapters that lower deny-class success are rejected.

## To do for a real run

- [ ] Produce a LoRA adapter `.gguf` from the dataset (PEFT/QLoRA) — out of scope here.
- [ ] Sample a user-inspected curation subset before training.
- [ ] Hold-out set strictly disjoint from training rows.
- [ ] Safety (deny-class) hold-out set.
- [ ] Measure latency as well as accuracy.
