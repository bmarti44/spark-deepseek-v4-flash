# T3.4 — Write scripts/34_decision.py (mechanical decision report)

ONLY file you may create/modify: `scripts/34_decision.py`. No git/sudo/network. Python 3.12 stdlib.

Implements the FROZEN decision rule from the plan verbatim; it must FAIL CLOSED (exit 2 with a clear message) if any required input file/field is missing — never substitute defaults.

Inputs (repo-relative, hardcoded):
- Speed: `results/speed-ds4-dspark.json`, `results/speed-llamacpp.json` — speed metric = the cell with ctx_tokens==4096, field median_decode (fail closed if absent/None).
- Golden: `results/golden-ds4-dspark.json`, `results/golden-llamacpp.json` — eligibility requires `"pass": true`.
- Parity: `results/parity-ds4.json`, `results/parity-llamacpp.json` — eligibility requires pass true AND parity_level "exact-ids".
- Accuracy holdout/final: per stack, `results/acc-gsm8k-holdout-<stack>.json`, `results/acc-mmlu-holdout-<stack>.json`, `results/acc-humaneval-<stack>.json` where <stack> ∈ {ds4, llamacpp} (fail closed if missing).
- Stability/soak evidence is asserted by the orchestrator separately; accept a `--stability ds4=pass,llamacpp=pass` arg (required; values pass|fail).

Rule (verbatim from plan):
1. Eligibility: golden pass + parity exact-ids + stability pass. Ineligible candidates eliminated.
2. Composite = unweighted mean of the three percentages (gsm8k-holdout, mmlu-pro-holdout, humaneval accuracy × 100).
3. Speed metric = median single-stream decode tok/s at 4K ctx.
4. Both eligible: |Δcomposite| ≤ 3.0 → higher speed wins; Δcomposite > 3.0 → higher composite wins UNLESS its speed < 10 tok/s → verdict "SURFACE_TO_BRIAN" (no default).
5. Exact composite tie: higher gsm8k-holdout, then higher speed.
6. One eligible → it proceeds to candidacy (verdict "SOLE_CANDIDATE"); zero → verdict "NO_GO".

Output: `results/DECISION.md` (human table: per-candidate eligibility, composite w/ per-suite numbers + Wilson CIs, speed, verdict + which rule branch fired) AND `results/decision.json` (machine form incl. every input value used + rule branch). Print the verdict line to stdout. `--help`. Definition of done: py_compile; running against current results dir MAY fail closed (A's accuracy files don't exist yet) — that exact failure must name the missing files.

Final message: file created + deviations.
