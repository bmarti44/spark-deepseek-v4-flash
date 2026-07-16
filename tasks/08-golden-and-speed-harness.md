# T3.1a — Write scripts/14_fetch_encoder.sh, scripts/32_golden_tests.py, scripts/30_bench_speed.py, and fixtures

ONLY these files may be created/modified:
`scripts/14_fetch_encoder.sh`, `scripts/32_golden_tests.py`, `scripts/30_bench_speed.py`, `fixtures/` (new directory, its contents), `requirements-harness.txt`.
No git, no sudo, no network (scripts you write fetch at runtime). These will be reviewed line-by-line and FROZEN by hash — they are the verification layer, so: no cleverness, no silent fallbacks, every check either passes or fails loudly. python3.12, stdlib only unless listed in requirements-harness.txt (allowed: `tokenizers` — nothing else).

Common client contract (both python tools): args `--base-url http://127.0.0.1:PORT`, `--api-key-file PATH` (optional; send `Authorization: Bearer <key>` when given), `--out PATH` (results JSON), `--stack-label NAME` (recorded in output). Use urllib from stdlib (no requests). Timeouts generous (300 s per request). All sampling: `temperature 0`, fixed `seed 42` where the API accepts it.

## 1. scripts/14_fetch_encoder.sh
Fetch the official encoder+tokenizer pinned in `configs/pins/official-encoding.json` into `vendor/official-encoding/` (relative to repo root):
- For each file entry: download `https://huggingface.co/<repo>/resolve/<revision>/<path>` with curl (retry 5); verify `git hash-object <file>` equals `git_oid_sha1` (git is available); place under `vendor/official-encoding/<path>`; any mismatch = delete + exit 1 naming the file.
- Idempotent; `--verify-only` mode; summary JSON to stdout. bash strict mode; umask 022 here (files must be world-readable — dsv4 reads them via ACL).

## 2. scripts/32_golden_tests.py — correctness gate for a RUNNING server
Checks (each -> {name, pass, detail}); overall pass = all pass; exit 0/1. IMPORTANT: never mark a check pass on exception — exceptions = fail with the message.
1. `health`: GET /health (llama.cpp) or /v1/models (ds4) returns 200 — pick via `--health-path` arg (default /health).
2. `models_endpoint`: GET /v1/models lists exactly one model.
3. `basic_fact`: chat "What is the capital of France? Answer with just the city name." → completion contains "Paris" (case-insensitive).
4. `arithmetic`: chat "Compute 17 * 23. Reply with just the number." → contains "391".
5. `determinism`: same prompt ("List the first 5 prime numbers.") twice at temp 0 → identical completion text (V4 sparse attention should be deterministic single-stream at temp 0; if this fails persistently record the two outputs in detail — do NOT weaken to prefix-match silently).
6. `needle_16k`: build a 16000-token haystack from fixtures (see below) with the sentence "The secret code word is BLUEBERRY-7421." inserted at 40% depth; ask "What is the secret code word? Reply with just the code word." → contains "BLUEBERRY-7421". Skip-with-fail if server ctx < 17k (report, don't crash).
7. `multiturn_cache_consistency`: 3-turn conversation asked twice — once as one request with full history, once incrementally (two requests, second carries history) → final answers must match exactly at temp 0.
8. `streaming_sse`: chat with `"stream": true` → receives >1 SSE `data:` chunks, terminating `[DONE]`, concatenated deltas equal a non-empty string, and a `usage` object arrives (with `stream_options: {"include_usage": true}` if needed).
9. `error_schema`: POST /v1/chat/completions with invalid JSON body → 4xx (not 5xx, not hang); POST with unknown model name → 4xx or success-with-served-model (record which; pass either way, this check is about not-crashing).
10. `auth_enforced` (only when --api-key-file given): inference without key → 401/403.
11. `sustained_ctx`: one request with ~30000 tokens of fixture context (or 0.9 × server ctx if smaller, via --ctx arg) asking for a 64-token summary → completes without error in 600 s; record TTFT.
Prompt-token counts for haystack construction: approximate 1 token ≈ 4 chars is NOT acceptable — use the pinned tokenizer (`tokenizers` lib, load `vendor/official-encoding/tokenizer.json`) to measure and trim.

## 3. scripts/30_bench_speed.py — reproducible speed suite for a RUNNING server
- Fixtures: `fixtures/gen_fixtures.py` (also write this; run at build time by you) deterministically generates `fixtures/ctx-32k.txt` (~35k tokens of varied deterministic pseudo-prose from seed 42, sentence-structured, no repetition cycles shorter than 1000 tokens — build from a seeded word list; measure with the pinned tokenizer). COMMIT the generator; generate the .txt during this task and commit it too (it is a few MB of text; that is fine).
- Contexts: 0, 4096, 16384, 32768-minus-margin tokens (prefix slices of the fixture, token-measured, minus 512 for the question+generation). For each context level and each rep: prompt = unique 32-token seeded preamble (rep-specific — defeats prefix caching) + fixture slice + "Continue this text naturally." 
- Generation: `max_tokens 256`, `temperature 0`, and `ignore_eos: true` if `--ignore-eos-supported` flag passed (llama.cpp supports it; ds4 unknown — orchestrator decides per stack). Record actual completion_tokens; a rep is INVALID if completion_tokens < 200 (early stop) — report invalid reps, they don't count toward medians, and >2 invalid reps per cell = suite failure.
- Measurement: streaming request; TTFT = first content chunk wall time; decode tok/s = (completion_tokens − 1) / (t_last_chunk − t_first_chunk); prefill tok/s = prompt_tokens / TTFT (label it "incl. queue+setup"). Cross-check client-counted streamed tokens vs server usage.completion_tokens within ±2% else rep invalid. 
- Reps: `--reps N` (default 5) per context level, sequential. Between reps: 2 s idle. No warmup rep excluded by default; `--warmup 1` runs+discards N warmup reps first (orchestrator will use 1).
- Output JSON: per cell {ctx_tokens, reps: [{ttft_s, decode_tok_s, prefill_tok_s, completion_tokens, valid}], median_decode, iqr_decode, median_ttft}; plus metadata {stack_label, base_url, started_at, finished_at}. Also capture `nvidia-smi --query-gpu=clocks.sm,temperature.gpu --format=csv,noheader` before/after each cell into the JSON (subprocess; tolerate failure by recording null — GB10 may not report all fields).
- No pass/fail thresholds in this script — it MEASURES; gates interpret.

## 4. requirements-harness.txt
Exactly: `tokenizers` (one line, with a pinned version available for aarch64 py3.12 — use `tokenizers==0.22.1` unless you know it unavailable; the orchestrator will pip-install into a venv).

## Definition of done
- `bash -n` on the shell script; `python3 -m py_compile` on all python files.
- `fixtures/ctx-32k.txt` generated and present; `fixtures/gen_fixtures.py --check` re-generates and byte-compares (idempotence proof) — implement that flag.
- `scripts/32_golden_tests.py --help` and `scripts/30_bench_speed.py --help` work.
- Do NOT run against any server and do NOT download anything in this task (tokenizer fetch happens at runtime via 14_fetch_encoder.sh; for fixture generation use a seeded wordlist embedded in gen_fixtures.py — you can't token-measure without the tokenizer, so define the fixture as ~140k chars and let the harness token-trim at runtime; document this).

Final message: files created + deviations.
