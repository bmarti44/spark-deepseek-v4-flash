# Fix batch 1 (round-2 review): rebuild the verifier boundary

Fix these confirmed findings from the round-2 review. Decision-layer/verifier hardening
only: do NOT change any scorer, prompt, rendering, dataset, generation parameter, or
soak measurement. Style: match the existing scripts (stdlib-only Python, frozen
constants, explicit RuntimeError messages). Do not touch results/ files. Do not run
servers or send requests to 127.0.0.1:8010/8011/8012.

## 1. scripts/36_audit_accuracy.py — make the recount independent of producer-controlled fields
- GSM8K + MMLU: recompute `expected` from the PINNED dataset (load rows exactly like
  scripts/31 `load_pins()`+`load_jsonl()`), keyed by transcript `index`; verify the
  transcript's `task_id`/`question_id` matches the row; recompute
  `rendered_prompt_sha256` by re-rendering the pinned row through 31's `render_item`
  (+ official encoder where 31 uses it) and require equality — a nonempty string is NOT
  enough. Score the stored completion against the recomputed expected using 31's
  scorers (`score_gsm8k`, `score_mmlu`). Any mismatch of task id, prompt hash, or
  expected = audit FAIL naming the transcript.
- HumanEval: do not trust stored `scored_correct`/returncode/stderr. Re-extract with
  31's `extract_humaneval_code` and RE-EXECUTE every one of the 164 programs in the
  same docker sandbox (`run_humaneval`), comparing the fresh verdicts to stored ones;
  any divergence = FAIL. Keep the taxonomy, computed from the FRESH executions.
- Enforce exact suite sizes at audit time: gsm8k dev=100 holdout=100, mmlu dev=253
  holdout=247, humaneval=164 (take the numbers from the pinned split selection in 31 —
  use `select_indices` so they can't drift).
- Write binding hashes into results/audit-<stack>.json: sha256 of each acc-*.json file
  audited, a deterministic digest of the transcript tree (sorted filename:sha256 lines,
  sha256 of that), the evalset file sha256s, and 31's harness manifest line.

## 2. scripts/34_decision.py — stop trusting reported booleans
- Soak: recompute EVERY gate from the raw arrays in the soak JSON (error count == 0,
  min memory >= the frozen floor, sample density, window population/disjointness,
  degradation <= threshold, health probes all 200 AND a minimum probe count derived
  from duration/interval), matching 35_soak's frozen constants (import or re-declare
  them; if re-declared add a comment they must equal scripts/35). Reported `gates`
  booleans must ALSO all be true and must MATCH the recomputed values.
- Accuracy: enforce the exact suite sizes above (n and transcript counts).
- Audit binding: recompute the binding hashes from the CURRENT files (acc-*.json,
  transcript tree, evalsets) and require they equal the ones stored in the audit
  artifact; require the audit's harness manifest line to match the current
  verification/MANIFEST.sha256 entry for scripts/31.
- Envelope exception: cross-check `accepted_cells` and the failed cells against the
  candidate's speed JSON (the exception may only excuse cells that actually failed and
  must accept only cells that actually passed).
- Track results/decision.json: remove it from .gitignore if ignored, so the machine
  report is part of the witness (check why it's untracked).

## 3. scripts/35_soak.py — close the vacuous-health gate
- `health_all_ok` must require a minimum probe count: new frozen constant
  MIN_HEALTH_PROBES computed conservatively from DURATION and the probe interval
  (e.g. duration/interval/2, floored, min 10). all([]) must fail.

## 4. verification/MANIFEST.sha256
- Add: configs/versions.lock, all configs/build-manifests/*.json, evalsets/*.jsonl and
  their pins file(s), scripts/35_soak.py's dependencies if missing. Refresh entries for
  every file you modify (scripts/31 NOT modified — do not touch it). Keep the file
  sorted by path as it is now. results/ files stay OUT of the manifest (they are
  witnessed by git history + audit binding hashes instead) — add a comment line? NO:
  sha256sum -c chokes on comments; instead document this in PROTOCOL.md.

## 5. PROTOCOL.md
- Add a v6 entry table row set describing all of the above as decision-layer/verifier
  hardening (non-voiding, per the standing rule), including the manifest-scope
  clarification (results are witnessed by git + audit binding hashes, not the manifest).

## Acceptance (run these; all must pass)
- .venv-harness/bin/python scripts/36_audit_accuracy.py --stack ds4  → PASS
- .venv-harness/bin/python scripts/36_audit_accuracy.py --stack llamacpp → PASS
  (both re-execute HumanEval in docker — this takes ~10-15 min each; fine)
- .venv-harness/bin/python scripts/34_decision.py --soak-evidence
  ds4=results/soak-ds4.json,llamacpp=results/soak-llamacpp.json --audit-evidence
  ds4=results/audit-ds4.json,llamacpp=results/audit-llamacpp.json → same verdict DS4
- sha256sum -c verification/MANIFEST.sha256 → all OK
- Tamper test you must actually run and then REVERT: copy one gsm8k transcript, flip
  its `expected` to match the completion, run the audit, confirm FAIL; restore the
  original file byte-for-byte (verify with sha256sum against git).
Report at the end: files changed, acceptance results, anything you could not do.
