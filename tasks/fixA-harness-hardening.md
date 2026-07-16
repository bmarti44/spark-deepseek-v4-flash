# Task fixA: harden decision/soak/audit against gaming (sol-high review remediation)

RULES (binding):
- Modify ONLY these files: scripts/34_decision.py, scripts/35_soak.py, scripts/36_audit_accuracy.py.
- Do NOT touch scripts/30–33, results/, tasks/, verification/, configs/, .githooks, setup/.
- Never delete or create any other file. Never run git commands that change state (no add/commit).
- Python 3.12, stdlib only. Keep each script self-contained. `python3 -m py_compile` must pass.
- Keep existing CLI flags working where not explicitly changed below; keep output JSON keys
  already consumed elsewhere (results/DECISION.md format may gain sections, not lose them).
- A benchmark accuracy run is IN FLIGHT using scripts/31; nothing you do may affect it.

## scripts/35_soak.py — freeze parameters, close gate loopholes
1. Freeze all thresholds as module constants and REMOVE these CLI flags: --duration-seconds,
   --max-tokens, --degradation-threshold, --min-requests, --mem-floor-gib, --window-seconds,
   --request-timeout. Constants: DURATION=1800, MAX_TOKENS=256, DEG_THRESHOLD=0.25,
   MIN_REQUESTS=30, MEM_FLOOR_GIB=12.0, WINDOW_SECONDS=300, REQUEST_TIMEOUT=600.
2. Sanitize --extra-body: reject (exit 2) any key in {"model","messages","prompt","max_tokens",
   "temperature","stream","stream_options","n","seed","stop"} — extra_body may only carry
   mode-control keys (e.g. enable_thinking / chat_template_kwargs).
3. Defeat prompt caching: build a deterministic per-request prompt by prefixing the base prompt
   with f"[soak request {index}] " and rotating through 8 distinct topic prompts (write them
   inline; index % 8). Record which prompt index each rep used.
4. MemorySampler: wrap run() body in try/except, store the exception string on self.error;
   new gates: "sampler_healthy" (no error AND thread not prematurely dead) and
   "mem_sample_density" (n_mem_samples >= 0.8 * elapsed_seconds).
5. Health probing must not starve during long requests: move health probes to their own
   daemon thread probing every 30s for the whole run; gate health_all_ok unchanged
   (all probes 200). Record every probe.
6. Window soundness gates: "windows_disjoint" (elapsed >= 2*WINDOW_SECONDS) and
   "windows_populated" (>=5 reps in EACH window). Degradation gate only meaningful if those
   hold; if they do not hold, pass=false.
7. duration honesty gate: "duration_met" (elapsed >= 0.95 * DURATION).
8. Keep ALL raw arrays in the output (reps, mem_samples, health_probes, errors) so every gate
   is recomputable by a reviewer. Update the module docstring gate list.

## scripts/36_audit_accuracy.py — full recount, emit a machine-readable pass artifact
1. Rescore EVERY transcript (not a sample) for gsm8k dev+holdout and mmlu dev+holdout using
   the frozen scorers imported from scripts/31; recount corrects and REQUIRE the recount to
   equal the result JSON's `correct` and the file count to equal its `n`. Any mismatch = FAIL.
2. HumanEval: keep the stderr taxonomy over all 164 transcripts; additionally require exactly
   164 files, unique task_ids, and stored scored_correct count == result JSON `correct`.
   Any SyntaxError/IndentationError/TabError in stderr = FAIL (extractor regression).
3. Require config_digest present on ALL holdout results (keep tolerating absence only for
   files whose ledger entry predates digests: accept a missing digest ONLY for
   acc-gsm8k-holdout-llamacpp.json — hardcode that single grandfather exception with a comment).
4. Require every transcript to carry a non-empty rendered_prompt_sha256.
5. After auditing, write results/audit-<stack>.json:
   {"kind":"accuracy-audit","pass":bool,"stack":stack,"suites":{<suite-split>:{"n":..,
   "correct_recount":..,"summary_correct":..,"match":bool}},"humaneval_taxonomy":{...},
   "generated_by":"scripts/36_audit_accuracy.py"} — plus keep the human-readable stdout.
   Exit 0 only if pass.
6. Missing result files: suites that are absent are recorded as absent; the artifact's "pass"
   covers only present suites, and lists them, so the decision layer can require completeness.

## scripts/34_decision.py — trust nothing it can recompute
1. New REQUIRED flag --audit-evidence ds4=PATH,llamacpp=PATH. Each file must parse as JSON with
   kind=="accuracy-audit", pass==true, stack matching, and its "suites" must include entries
   for gsm8k-holdout, mmlu-pro-holdout, humaneval with match==true. Otherwise that candidate
   is ineligible (failed check "accuracy audit").
2. Deep soak validation (replace the shallow kind/pass check): require kind=="soak", pass==true,
   stack_label consistent with the stack, duration_seconds_actual >= 1500, n_requests >= 30,
   gates object present with every value true; RECOMPUTE from raw arrays: median decode of
   first/last windows from `reps` (same rule as 35: t_start < window_seconds vs
   t_start >= elapsed-window; use the file's window_seconds and duration_seconds_actual),
   degradation, and min of mem_samples[].gib — each must match the file's summary within 1e-6,
   else stability fails with reason "soak summary does not match raw samples".
3. Speed: recompute the 4K and 16K median_decode from each cell's reps (valid reps only,
   same definition as the file's own summary) and require equality within 1e-6; require the
   top-level `suite_valid` field to be true. If suite_valid is false the candidate is
   INELIGIBLE unless a file results/envelope-exception-<stack>.json exists containing
   {"kind":"envelope-exception","stack":...,"reason":<non-empty string>,"accepted_cells":[...]}
   — in that case eligibility proceeds but DECISION.md must surface the exception verbatim in
   a dedicated "## Context-envelope exception" section.
4. Accuracy cross-check: require each accuracy result's `n` to match the transcript count
   claimed in the audit artifact for that suite (audit is now the source of truth for counts).
5. Sole-candidate floor: if only one candidate is eligible it must ALSO have composite >= 60.0
   and 4K median decode >= 5.0 tok/s, else verdict NO_GO (frozen constants, documented in the
   rule text).
6. DECISION.md: digests/hashes printed at most 12 hex chars (never a full 64-hex string).
7. Update the frozen-rule docstring to state all of the above as part of the mechanical rule.

## Acceptance (run these yourself; I will re-run them)
- python3 -m py_compile on all three files.
- scripts/35_soak.py --help shows no threshold flags.
- scripts/36_audit_accuracy.py --stack llamacpp runs (mmlu-holdout may be absent/in-flight —
  absent suites must not crash it) and writes results/audit-llamacpp.json.
- scripts/34_decision.py with missing audit/soak evidence fails closed with a clear error.
Report what you changed per file and paste the acceptance-command outputs.
