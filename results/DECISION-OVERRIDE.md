# Product override of the benchmark verdict (2026-07-17)

The frozen decision rule selected **ds4** (`results/DECISION.md`): composite 86.03 vs
81.62 and faster at every measured context ≤28K. That verdict stands as the benchmark
record and is not modified.

**Brian overrode the serving choice: the production endpoint is `llamacpp`.**

Reason: the product requirement changed the decision axis. The endpoint must serve very
large contexts (target 1M tokens, phase-2 spec: aggressive per-turn prompt caching,
<10s-prefill full-fidelity threshold, retrieval skim mode above it, corpus ingest with
saved-state restore). ds4's measured envelope on this host is ≤~28K prompt tokens
(warm >28K fails; `results/envelope-exception-ds4.json`), which cannot meet the
requirement. llama.cpp is the only candidate measured working at larger contexts and is
the basis of both committed phase-2 plans (`docs/bigctx-plan-{fable,sol}-2026-07-16.md`).

Consequences:
- P4/P5 productionize **llamacpp** (port 8011 chain: Caddy → auth helper → engine).
- ds4 remains benchmarked, reproducible, and available as the fast small-context
  alternative; no further ds4 work is planned.
- llama.cpp speed work (e.g. the 0dc74e3 fusion rebuild) proceeds on the phase-2 track
  under protocol versioning.
