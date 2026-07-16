# Independent review: DeepSeek-V4-Flash on DGX Spark (state as of 2026-07-16 ~15:15 ET)

You are reviewing this repository READ-ONLY. Do not modify, create, or delete any file.

## Context
This repo benchmarks two single-Spark serving stacks for DeepSeek-V4-Flash (284B/13B MoE)
on one DGX Spark (GB10, 119 GiB unified memory where OOM = hard system freeze) and will
serve the winner as an authenticated OpenAI-compatible endpoint over Tailscale:
- Candidate A: entrpi/ds4 engine (DSpark speculative profile, 2-bit), port 8012, no native auth.
- Candidate B: upstream llama.cpp, Unsloth UD-Q2_K_XL, port 8011, native api-key.

A previous adversarial review (docs/adversarial-review-2026-07-16.md) found real defects that
were fixed under a versioned protocol (PROTOCOL.md v2). Since then, new work landed:
- scripts/35_soak.py — sustained-load stability gate feeding scripts/34_decision.py
- scripts/36_audit_accuracy.py — verifier-owned post-run audit of accuracy evidence
- configs/build-manifests/*.json — committed config-evidence for the holdout ledger
- scripts/lint_secrets.sh — JSON-walking secret scanner with digest-file exemptions
- Production artifacts: configs/systemd/*.service, configs/caddy/Caddyfile,
  scripts/40_auth_helper.py, scripts/41_install_service.sh, setup/04-production-hardening.sh
- Current evidence in results/: golden, parity, speed for both stacks; B accuracy
  (GSM8K dev+holdout committed; HumanEval/MMLU v2 re-runs in flight — do NOT judge
  half-written result files under results/ that are not yet committed to git; judge
  committed files and all scripts/configs).

## Your job
Review ALL important aspects of the work done so far. For each area below, assign a score
0–100 and list every issue you find with severity low / medium / high / critical.
An issue is HIGH if it could change the benchmark verdict, corrupt evidence, expose the
endpoint/key, or freeze/brick the host. CRITICAL if it likely WILL do one of those.

Areas to score (one score each):
1. memory-safety — serve scripts, watchdog, membudget, residency lock (scripts/20, 21, 01, 02)
2. benchmark-validity — speed/accuracy/golden/parity harnesses + decision rule
   (scripts/30–34), incl. statistical soundness, scorer correctness, holdout hygiene
3. soak-and-audit — the NEW scripts/35_soak.py and scripts/36_audit_accuracy.py:
   can their pass verdicts be gamed, are the gates sound, edge cases (clock, sampler
   thread death, SSE parsing, windowing when reps are sparse)?
4. security — production chain: 40_auth_helper.py, Caddyfile, systemd units,
   41_install_service.sh, setup/04-production-hardening.sh, key handling, lint_secrets.sh
5. reproducibility — could a stranger with a DGX Spark reproduce this? pins, manifests,
   setup scripts, missing docs (README/REPRODUCING.md are known-TODO; judge everything else)
6. process-integrity — anti-reward-hack protocol: frozen MANIFEST coverage (is anything
   load-bearing NOT frozen?), ledger enforcement, transcript auditability

## Output format (strict)
For each area: `## <area> — score NN/100` then a bullet list of issues, each starting
with `[critical]`, `[high]`, `[medium]`, or `[low]`, with file:line references and a
concrete failure scenario. If an area has no issues, say so explicitly and justify the
score. End with a `## Summary` table: area | score | #critical | #high, plus an overall
weighted score and the top 3 actions that would most raise the scores.

Be adversarial: try to prove the evidence could be wrong, the gates gameable, the host
freezable, the key leakable. Concrete failure scenarios only — no vague concerns.
