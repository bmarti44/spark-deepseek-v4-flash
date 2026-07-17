# Independent review ROUND 5: DeepSeek-V4-Flash on DGX Spark (state as of 2026-07-17)

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

## Round-3 addendum — what changed since your round-2 report (score 59.3)
Your round-2 findings were remediated in commits b658097 (PROTOCOL v6, verifier
boundary) and 82780f9 (ops/security/docs). Specifically:
- 36_audit recounts GSM8K/MMLU from pinned rows (recomputed expected + re-rendered
  prompt hashes), re-executes all 164 HumanEval programs, enforces exact suite sizes,
  emits binding digests; 34_decision recomputes soak gates from raw arrays, verifies
  bindings against current files, cross-checks envelope exceptions vs speed cells;
  decision.json tracked; 35_soak health gate needs >=30 probes.
- 01_memwatch: breach kill precedes logging, start-ticks identity guard; serve scripts
  have startup cleanup traps; 40_auth_helper is a streaming reverse proxy holding its
  slot for the whole response (unit tests in scripts/tests/); 41_install fails closed
  on tailscale/funnel verification; gitleaks mandatory; docker image + caddy pinned.
- PRODUCT CONTEXT: results/DECISION-OVERRIDE.md — Brian overrode serving to LLAMACPP
  (1M-context roadmap; ds4 parked). Docs describe both verdict and override.
Verify the remediations hold (including running the auth-helper unit tests yourself and
your own tamper attempt against the v6 audit), score the same six areas, and report
anything still below 90 with concrete failure scenarios. The bar remains: ALL areas >=90.

## Round-4 addendum — what changed since your round-3 report (overall 77.3)
All 14 round-3 highs were remediated in commit b84024a (PROTOCOL v7). Read that
commit's diff and docs/review-r3-2026-07-17.md (your own round-3 report) first.
Highlights: 34_decision now verifies the full MANIFEST in-process, hashes current
scripts/31 against its manifest line, cross-checks audit correct_recount vs acc
files, binds speed identity (metadata + manifest-pinned tokenizer digest) and soak
identity, validates timestamp monotonicity/bounds/spacing, and has
--validate-evidence-only. 31/36 enforce the HumanEval docker RepoDigest pin; audits
were regenerated (fresh 328-program docker re-execution) and decision.json refreshed
(verdict unchanged). Memwatch kills the verified engine group on TERM/INT/HUP while
armed with a disarm handshake; serve scripts publish a provisional start-group
target and kill engine before watchdog in cleanup. Auth helper authorizes before
consuming rate tokens (separate unauth bucket), 128-conn cap, 10 s header timeout.
New scripts/42_verify_exposure.sh shared with the installer. Ledger namespacing via
DSV4_LEDGER_NAMESPACE. MANIFEST is now 56 entries incl. model pins, vendored
tokenizer, grandfather + gitleaks pins. PROTOCOL headline fixed; the GSM8K holdout
grandfather is pinned to the entry content hash in configs/pins/.

The operator already verified: coordinated acc+audit-digest tamper is rejected
(recount cross-check), script-31 tamper is rejected (in-process manifest check),
auth tests 7/7 pass outside the sandbox.

Score the same six areas; run your own adversarial checks where your sandbox
allows. The bar remains: ALL areas >=90. Do not re-report items whose remediation
holds; scores should reflect the current tree.

## Round-5 addendum — what changed since your round-4 report (overall 84.5)
All 7 round-4 highs and the named mediums were remediated in commit 02e119c
(PROTOCOL v8). Read that diff and docs/review-r4-2026-07-17.md (your round-4 report)
first. Highlights: authenticated DISARM record replaces target-file removal (missing
target while armed = fail-closed kill; PGID re-verified before every signal; status
reports DEGRADED unless genuinely armed); serve scripts bind the binary to the
COMMITTED build manifest and shard sizes to the weights manifest (full hashing via
DSV4_VERIFY_WEIGHTS=full; the operator verified the resident binary matches);
34_decision reapplies script 30's per-rep predicates + recomputes TTFT medians,
enforces soak endpoint coverage and per-request index/token/TTFT/rotation checks,
validates humaneval_runtime provenance, and uses suffix-based model-path identity;
36_audit requires exactly one started + one completed ledger pair per holdout
(grandfather content-hash pinned); 41_install refuses non-llamacpp without
--acknowledge-decision-override; REPRODUCING gained Tailscale prerequisites, DGX OS
docker install with pinned-digest pull/tag, reproducer-generated build manifests in
all commands, and requirements-harness.lock; MANIFEST is 59 entries incl.
.gitleaks.toml and weight manifests. Audits and decision were regenerated under v8
(fresh docker re-execution); verdict unchanged.

Score the same six areas; run your own adversarial checks where the sandbox allows.
The bar remains: ALL areas >=90. Score the current tree, not history.
