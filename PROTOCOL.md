# Evaluation protocol versions

The adversarial review (2026-07-16) correctly found that gate definitions changed
after observing candidate failures, while being described as "frozen". This file
makes protocol versioning explicit. **Protocol v2 is the binding version**; every
number used by the decision must come from a v2 run.

## v1 → v2 changes and why

| Change | Trigger | Fairness handling |
|---|---|---|
| golden `error_schema`: required 4xx on malformed JSON → accepts 4xx–5xx WITH a JSON error body AND a healthy follow-up probe | B (llama.cpp) returns 500 with a well-formed error object | Intent of the check is graceful failure, not a specific status code. A passes under both versions; A's golden is RERUN under v2 for a uniform record. |
| speed suite: top context cell 32256 → 28672; continuation prompt demands ≥600 words | A's engine envelope (warm >28K prompts fail; lazy session graph) and early-stop invalid reps on open-ended prompts | Both candidates' recorded speed runs used the FINAL protocol (A was rerun after the change; B only ever ran the final version). |
| MMLU-Pro scoring: last-letter fallback + 256 max_tokens → anchored `Answer: <letter>` required, `finish_reason` length without marker = invalid, max_tokens 768 | Adversarial review proved the fallback credits truncated reasoning ("I don't know" → I; 8 confirmed false credits in B's dev run) | All v1 MMLU results are VOID for both candidates. MMLU dev+holdout regenerate under v2 for both. The regeneration is a protocol correction declared before any of A's accuracy numbers existed; configs are unchanged; other suites' v1 results replayed clean and stand. |
| holdout ledger: appended at completion, caller-supplied config hash → `started` entry before first request, config digest derived from binary/weights/flags hashes | Adversarial review: interruption discloses holdout without a ledger record | Applies from v2 onward. |

## Standing rule

Any future gate/harness change after a candidate has produced results under the
current version requires: a new version entry here, voiding of affected results
for ALL candidates, and rerun under the new version. "Frozen" means frozen per
version, enforced by verification/MANIFEST.sha256.
