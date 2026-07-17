# Independent review ROUND 2: DeepSeek-V4-Flash on DGX Spark (state as of 2026-07-17)

You are reviewing this repository READ-ONLY. Do not modify, create, or delete any file.
Do NOT send any request to 127.0.0.1:8011 or 127.0.0.1:8012.

## Context
This repo benchmarked two single-Spark serving stacks for DeepSeek-V4-Flash and has now
REACHED A VERDICT (results/DECISION.md): candidate A (entrpi/ds4, DSpark profile) won —
composite 86.03 vs 81.62, 18.7 vs 13.9 tok/s @4K — with a documented envelope exception
(A serves <=~28K-token prompts; B is the full-context fallback).

Your round-1 review (tasks/review-2026-07-16-sol-high.md → docs/ scored it 38/100
overall) drove PROTOCOL v3 hardening: all 37 high/critical issues were remediated
(commit b283cab and successors). Since round 1, this landed:
- PROTOCOL.md v3 (decision-layer hardening), v4 (HumanEval stop-list removal),
  v5 (ast.parse-validating extractor + scripts/37_rescore_humaneval.py offline re-grade)
- scripts/34_decision.py: requires --soak-evidence + --audit-evidence, deep validation
  recomputing summaries from raw arrays, suite_valid/envelope-exception enforcement,
  sole-candidate floors
- scripts/35_soak.py (frozen constants, prompt rotation, 10 gates) + committed soak
  evidence both stacks; scripts/36_audit_accuracy.py full recount + SyntaxError taxonomy
  → results/audit-{ds4,llamacpp}.json (both PASS, 0 syntax errors)
- scripts/01_memwatch.sh watchdog-first with breach=immediate SIGKILL; serve scripts
  start watchdog BEFORE engine with identity handshake
- Complete accuracy evidence both stacks incl. v5 re-graded HumanEval
  (A 147/164, B 121/164); results/DECISION.md committed
- REPRODUCING.md, docs/runbook.md, docs/threat-model.md committed
- Research/plan docs for phase-2 (docs/research-*.md, docs/bigctx-plan-*.md)

## Your job
Score the SAME six areas as round 1, 0-100 each, issues tagged low/medium/high/critical.
The bar Brian set: iterate until ALL areas >= 90. Be adversarial and concrete; also
verify remediations actually hold (don't re-report fixed issues unless the fix is wrong).

Areas:
1. memory-safety — scripts/20, 21, 01_memwatch.sh, 02_membudget, residency lock
2. benchmark-validity — scripts/30-34 + PROTOCOL v4/v5 fairness: was the extractor
   change + offline re-grade sound and symmetric? Could v5 candidate ordering
   (fenced / splice / post-hoc stop-cut / longest-parseable-prefix, first that
   ast.parses) unfairly credit either stack? Check results/DECISION.md numbers against
   raw results/ JSON yourself.
3. soak-and-audit — scripts/35, 36, 37: gameability, gate soundness, edge cases
4. security — scripts/40_auth_helper.py, configs/caddy/Caddyfile, systemd units,
   scripts/41_install_service.sh, setup/04-production-hardening.sh, lint_secrets.sh,
   githooks; key handling end-to-end
5. reproducibility — REPRODUCING.md + docs/runbook.md now exist: could a stranger with
   one DGX Spark actually reproduce the verdict AND the production install? Stale or
   wrong instructions are HIGH here.
6. process-integrity — MANIFEST coverage (39 entries) vs load-bearing files, PROTOCOL
   v1-v5 versioning discipline, holdout ledger, transcript auditability, git history
   as witness (docs/threat-model.md scope)

## Output format (strict)
For each area: `## <area> — score NN/100` then bullets, each starting with
`[critical]`/`[high]`/`[medium]`/`[low]`, with file:line references and a concrete
failure scenario. If none, justify the score explicitly. End with `## Summary` table:
area | score | #critical | #high, an overall score, and the top 3 actions that would
most raise sub-90 areas.
