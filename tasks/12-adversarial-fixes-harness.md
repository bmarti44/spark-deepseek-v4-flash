# T-AR1 — Harness fixes from the adversarial review (protocol v2)

ONLY these files may be modified: `scripts/31_bench_accuracy.py`, `scripts/34_decision.py`, `scripts/lint_secrets.sh`. Read `PROTOCOL.md` and the adversarial findings summary below first. No git/sudo/network. Surgical edits — do not restructure working code.

## 1. scripts/31_bench_accuracy.py
a) MMLU scoring (finding: fallback credits truncated reasoning):
   - REMOVE the last-standalone-letter fallback entirely. Scoring requires an anchored match of `Answer:\s*([A-J])` (keep case-insensitive on "Answer"); take the LAST such match. No match = invalid (reason "no anchored answer"), counted incorrect.
   - Record `finish_reason` per item in transcripts (from the API response); if finish_reason == "length" AND no anchored answer, reason = "truncated without answer".
   - MMLU max_tokens: 256 → 768.
b) GSM8K: keep the anchored `Answer:` extraction, but ALSO remove the bare last-number fallback? NO — keep it (review replayed GSM8K clean; its lone fallback case scored incorrect) but record `used_fallback: true` in the transcript when the anchored form was absent.
c) Holdout ledger (finding: append-at-end, weak key):
   - Derive `config_digest` automatically: sha256 over a canonical JSON of {stack_label, server binary sha256, model manifest sha256(s), suite, split, extra_body, max_tokens, harness manifest line for this script}. Get binary/model hashes from `--config-evidence FILE...` args (one or more JSON files: the build-manifest and weights-manifest for the stack; require ≥1, hash their canonical contents). `--config-hash` becomes optional context, no longer the key.
   - Before the FIRST request of a holdout run: append `{..., "phase": "started", "started_at": ...}` to the ledger atomically (write temp + rename of the whole ledger under the existing flock). A prior `started` OR `completed` entry with the same (stack_label, suite, config_digest) → REFUSE (exit 3). On completion append a `completed` entry.
d) Per-item transcript: add `finish_reason` (all suites).

## 2. scripts/34_decision.py
a) Speed eligibility (finding: failed cells invisible): for EACH stack require the 4K cell to have ≥4 valid reps of 5; read and expose in output BOTH `median_decode` (valid-only) AND a recomputed `median_decode_all_reps` (include invalid reps that carry a numeric decode_tok_s; ignore reps with null). The RULE still uses valid-only (unchanged frozen metric) but both numbers must appear in decision.json and DECISION.md with a caveat line.
b) `--stability` arg: replace with `--soak-evidence ds4=PATH,llamacpp=PATH`; each file must exist, parse as JSON, and contain `"pass": true` plus `"kind": "soak"`; missing/failed = that stack's stability = fail.
c) DECISION.md additions (data the rule ignores, surfaced for the human): per-stack TTFT medians at 4K/16K from the speed files; a "context envelope" line per stack (ds4: warm >28K fails — hardcode the sentence with a pointer to speed-ds4-dspark.json's 28672 cell; llamacpp: 28K valid); Wilson CIs already required — also print the composite delta vs the 3.0 threshold explicitly; and a fixed caveat block noting: N=5 speed samples, composite ignores prefill/TTFT, single-run holdouts.
d) Input paths: MMLU holdout files will be v2 regenerations at the SAME paths — no change needed.

## 3. scripts/lint_secrets.sh (finding: 64-hex key can hide in exempted paths)
Replace the blanket nohex-tier for exempted files with digest-field-aware checking: exempted JSON files are scanned by a python3 helper (inline heredoc) that walks the JSON and collects every 64-hex string that is NOT the value of a key in the allowlist {sha256, source_parquet_sha256, oid, git_oid_sha1, rendered_prompt_sha256, commit, revision, config_digest, sha1} (nested keys: use the leaf key name) and NOT an element of a list under such a key; any other 64-hex → fail with file+jsonpath (redacted value). Non-JSON exempted files (*.sha256, MANIFEST): validate line format `^[0-9a-f]{64}  \S+$` — any other 64-hex-containing line fails. Keep the other secret patterns applying to all files as now. Keep --self-test passing and ADD a self-test case: a JSON with {"note": "<64hex>"} must be caught, {"sha256": "<64hex>"} must pass.

Definition of done: py_compile / bash -n; self-tests pass; running 31 with --help works. Do NOT run evals. Final message: what changed per file + deviations.
