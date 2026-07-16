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

## v2 → v3 changes and why (scored review of 2026-07-16, overall 38/100)

A second independent review (Codex sol high; tasks/review-2026-07-16-sol-high.md)
found the *integrity layer* gameable even though its evidence replay reproduced
every committed aggregate. v3 hardens verification WITHOUT changing any scorer,
prompt, rendering, dataset, split, or generation parameter — therefore **all v2
accuracy/speed/golden/parity results remain valid** and are not rerun.

| Change | Kind | Why it does not void v2 results |
|---|---|---|
| `34_decision.py` recomputes speed medians and soak/audit summaries from raw arrays; requires `suite_valid`; requires an accuracy-audit artifact per candidate; sole-candidate floor (composite ≥60, 4K decode ≥5 tok/s) | decision-layer, added BEFORE any decision was generated | Inputs unchanged; only how much the decision trusts them changed. |
| speed `suite_valid=false` makes a candidate ineligible unless `results/envelope-exception-<stack>.json` documents the accepted envelope | decision-layer | v2 pre-registered "4K cell is the decision metric; 28K cell = engine-envelope check". A's known warm->28K failure gets an exception file stating exactly that pre-registered scope; the exception is surfaced verbatim in DECISION.md rather than silently ignored (the review showed silence was the risk). |
| `35_soak.py` thresholds frozen as constants; caching-resistant prompt rotation; sampler/window/duration honesty gates | new tool, no soak evidence existed yet | First soak evidence is produced under v3. |
| `36_audit_accuracy.py` full-recount (every transcript), count/uniqueness checks, machine-readable pass artifact | verifier-side | Recount of unchanged transcripts; scoring identical. |
| watchdog starts before engine; memwatch fails closed; systemd preflight blocking; guard timer; auth-helper rate/concurrency limits; installer end-to-end verification | ops/security | Not part of any measurement. |
| threat model documented (docs/threat-model.md): operator-adversary is OUT of scope; public GitHub history is the witness | documentation | Scores the controls against the real setting. |

## v3 → v4 changes and why (A's HumanEval run, 2026-07-16 ~18:25 ET)

| Change | Trigger | Fairness handling |
|---|---|---|
| HumanEval generation: stop list `["\ndef ", "\nclass ", "\nif __name__", "\nprint("]` → none (generation bounded by max_tokens 512; extractor handles all styles) | A scored 0/164 with `finish_reason=stop` on EVERY item: A's quant answers each task with prose + a fenced full function re-declaration, and the `"\ndef "` stop truncated at the fence header before any body was generated. The stop list assumed base-model continuation style. | Harness defect, not a model result. HumanEval is VOID for BOTH candidates (A's 0/164 and B's v2 133/164) and reruns under v4 for both. B's rerun requires a residency swap back to B after A's remaining evidence. GSM8K and MMLU-Pro are untouched — the stop list applied only to HumanEval (`HUMANEVAL_STOPS`, used nowhere else). |

## Standing rule

Any future gate/harness change after a candidate has produced results under the
current version requires: a new version entry here, voiding of affected results
for ALL candidates, and rerun under the new version. "Frozen" means frozen per
version, enforced by verification/MANIFEST.sha256. Changes that only add
integrity checks on unchanged raw evidence (recomputation, recounting, artifact
requirements) are decision-layer hardening and do not void measurement results;
they must still be recorded here before the decision runs.
