# Max-context serving with aggressive caching + smart routing on this Spark — implementation plan

Date: 2026-07-16. Read-only research pass (no server touched; benchmark on :8011 untouched).
Grounded in: `/home/dsv4/llamacpp-project/src/llama.cpp/src/llama-kv-cache-dsv4.{h,cpp}`,
`src/llama-context.cpp`, `tools/server/server-context.cpp` (pin `32e789fd`, configs/versions.lock),
the GGUF header of `weights/unsloth-ud-q2_k_xl/`, `scripts/21_serve_llamacpp.sh`,
`scripts/40_auth_helper.py`, `configs/caddy/Caddyfile`, `results/speed-llamacpp.json`,
`docs/research-1m-coldstart-{fable,sol}-2026-07-16.md`, and web research (citations §7).

---

## (a) Executive summary

**The architecture cooperates; the engine's rollback semantics and the memory floor are the two
real constraints.** Verified in source: the DSV4 cache is four stores (raw SWA-128 ISWA + CSA 4:1 +
HCA 128:1 + Lightning-Indexer keys, plus three tiny compressor ring states), it has **complete,
versioned `state_write`/`state_read`** including per-sequence FULL and PARTIAL modes
(`llama-kv-cache-dsv4.cpp:1317-1378`), and the built server (verified via `--help` on the pinned
binary) exposes `--slot-save-path`, `POST /slots/{id}?action=save|restore|erase`,
`--ctx-checkpoints`/`--checkpoint-min-step`, and `--cache-ram`. So **disk slot save/restore for
this cache type exists today** — the substrate for "never re-prefill" is already in the pin.

Three hard facts shape everything:

1. **No partial rollback, no KV shift.** `get_can_shift()` returns `false` (line 1198-1202) and
   `seq_rm` refuses any truncation with `p0 <= seq_pos_max` (line 1209-1237). Consequences:
   `--cache-reuse` is silently ignored; a request that *diverges* from a slot's cached prefix can
   only be served by restoring an in-RAM context checkpoint or re-prefilling from zero. Exact
   extension (conversation continuation, corpus append) works natively.
2. **Memory ceiling.** Weights are 90.2 GiB of 119.2 GiB. Analytic cache cost is ~6.7 KiB/token
   (§b — note: `21_serve_llamacpp.sh` budgets 4 KiB/token, likely undersized), plus a compute-buffer
   term that grows with `n_ctx` (LID scores every CSA row per ubatch). Prediction: **512K fits
   comfortably; 1M straddles the 12 GiB watchdog** and is only viable at `-ub 512` with the 16 GiB
   budget floor renegotiated to ~13 GiB (new protocol version — this is post-decision phase-2 work).
3. **Prefill is 275–290 tok/s** at the current `-ub 512` config (results/speed-llamacpp.json,
   flat 4K→28K). The 10-second router threshold is therefore **~2,800 uncached tokens** today;
   ingesting a 1M corpus costs ~60 min of background compute. `-ub 2048` should raise prefill
   substantially (community GB10 data scales pp with ubatch) at the price of ~4× compute buffer.

The externally researched systems (LMCache, SGLang HiCache, vLLM production-stack router,
Mooncake) are all **engine-coupled and not portable as software**; what we borrow are their designs:
a radix-style prefix index over saved states, heat-based eviction, and explicit cache objects with
TTL. CacheGen/CacheBlend are ruled out for this stack (cache is already a learned compression;
llama.cpp has no partial-prefill hook). Total build: **~2,000 lines of Python in this repo's
script style + config changes, zero engine patches** for the core; one optional engine-side item
(sparse state files) flagged as stretch.

---

## (b) Context ladder: predicted memory per rung + gates

### Model facts (GGUF header, read directly)

- `deepseek4`, 43 layers, `context_length = 1,048,576` (YaRN ×16 over 64K native — **1M is the
  architectural hard cap**; no u32/position hazards below it: kv_size, idxs, pos are all
  u32/int32-safe at 1M; largest per-layer cache tensor at 1M is 256 MiB ≪ 2³¹).
- `attention.key_length = 512`, `head_count_kv = 1` (K-only latent rows, fp16 ⇒ 1 KiB/row/layer),
  `sliding_window = 128`, `indexer.key_length = 128`, `indexer.top_k = 512`,
  `compress_ratios = [0,0,4,128,4,128,…]` ⇒ ~21 CSA layers, ~20 HCA layers, LID on CSA layers.

### Cache cost model (from `llama_kv_cache_dsv4` ctor, lines 970-1088)

| Store | rows | bytes/token | at 1M |
|---|---|---|---|
| CSA (21 layers) | n_ctx/4 | 21×1024/4 = 5,376 B | 5.25 GiB |
| LID (21 layers) | n_ctx/4 | 21×256/4 = 1,344 B | 1.31 GiB |
| HCA (20 layers) | n_ctx/128 | 20×1024/128 = 160 B | 0.16 GiB |
| raw ISWA (SWA half) | ~n_swa+n_ubatch+pad | — (constant) | ~0.04 GiB |
| compressor states ×3 | constant (8–128 rows, F32) | — | ~MiBs |
| **total** | | **~6.9 KiB/token** | **~6.7 GiB** |

This disagrees with the 4,096 B/token used by `02_membudget.py` invocation in
`21_serve_llamacpp.sh` and the "~128 MiB/32K" figure in the earlier cold-start doc (which measured
the ds4 stack). **Gate 0 of every rung is reading the engine's own numbers**: the ctor logs exact
MiB per store (`LLAMA_LOG_INFO … "DSV4 %s state buffer size"`, `"compressed KV cache, size = %u
cells"`, and `memory_breakdown()`); the current server log at `/home/dsv4/logs/llamacpp-server.log`
was started at too low a verbosity to contain them, so this resolves at first rung start.

### Compute/scratch scaling (from `llama-context.cpp`)

Worst-case graph is reserved with `n_tokens = min(n_ctx, n_ubatch)` (line 556, 787): weight-side
compute is **∝ ubatch, not n_ctx**. The n_ctx-dependent terms are attention-width tensors:
LID scoring is dense over all CSA rows (top-k=512 selection happens *after* scoring), so per-graph
tensors of shape `ub × n_ctx/4` (scores, masks, `n_visible`) dominate: at `-ub 512`, ~512 MiB per
live f32 tensor at 1M; the allocator reuses across layers, so expect **+1–3 GiB at 1M / ub 512**
and **+4–12 GiB at ub 2048** on top of the 3–5 GiB measured at 32K (comment in serve script).
Logits/output buffer: `n_batch × n_vocab × 4 B` = 2048×129,280×4 ≈ 1.06 GiB, ctx-independent.

### The ladder

Assumptions: baseline MemAvailable ≈ 114 GiB (119.2 − ~4–5 OS/caddy/helper; engine currently
resident shows used ≈ 98 at 32K ⇒ engine ≈ 94 ⇒ consistent). Weights 90.2 GiB. Watchdog kills at
MemAvailable < 12 GiB; budget gate currently demands projected ≥ 16 GiB.

| Rung | cache (6.9 KiB/t) | non-weight overhead (ub 512) | total footprint | predicted MemAvailable | verdict |
|---|---|---|---|---|---|
| 64K | 0.42 GiB | 4.0–5.0 GiB | ~95 GiB | **18–19** | pass (floor 16) |
| 128K | 0.84 | 4.1–5.3 | ~96 | **17–18** | pass |
| 256K | 1.68 | 4.3–6.0 | ~97 | **16–17** | pass, at floor |
| 512K | 3.37 | 4.8–7.0 | ~99 | **14–16** | needs floor→14 (watchdog margin ok) |
| 1M | 6.74 | 5.5–9.0 | ~103–106 | **9–13** | only if measured overhead lands low AND floor→13; `-ub 512` only |

`-ub 2048` column: add ~1–2 GiB at ≤128K, ~3–5 GiB at 256–512K, ~10+ GiB at 1M — so **ub 2048 is a
≤256K tool** (use it for ingest throughput at low rungs; never at 1M).

`-np` note: `n_ctx_seq = n_ctx / n_seq_max` (llama-context.cpp:266) and the DSV4 cache is **forced
non-unified** (header FIXME "only supports non-unified mode"), so slots statically partition
context and memory scales with the total. `-np 2 -c 1048576` = two 512K users at the 1M footprint.
Keep `-np 1` at ≥512K; `-np 2` is a 256K-rung option. Checkpoints and prompt cache are slot-local.

### Per-rung gate set (each rung is a new `CTX=` run of `21_serve_llamacpp.sh`, off-benchmark window)

1. **Memory gate**: parse the startup DSV4 buffer log lines + `memory_breakdown`; recompute
   `02_membudget.py` with the *measured* bytes/token; MemAvailable after full 100%-fill prefill
   must exceed watchdog+2 GiB. (Fill via fixture: extend `fixtures/gen_fixtures.py` to emit
   rung-sized text.)
2. **Fidelity gate (RULER-lite)**: multi-key NIAH + variable tracking + one QA task *at the rung
   length*, ~30 samples each, run through the official encoder against `/v1/completions` (the
   three most discriminating RULER categories; full RULER unnecessary per rung). Pass = no
   cliff vs previous rung (≤10 pt drop). Watch 64K→128K especially: that's where YaRN engages.
3. **TTFT/prefill gate**: `30_bench_speed.py`-style cells at 25/50/100% of rung; record prefill
   tok/s decay with depth (DSA should keep it near-flat; a superlinear fall means the LID dense
   scoring is becoming the bottleneck — feeds router constants).
4. **Soak gate**: `35_soak.py` at the rung with rotation prompts sized to rung/2, ≥30 min,
   existing thresholds.
5. **Churn gate (new, targets issue #25452 lineage)**: alternate two divergent long prompts on one
   slot ×50; assert no "Context size exceeded" / stall / SWA-cell exhaustion. The pin (2026-07-16
   master) postdates PR #25402 but #25452 is open with a fix branch — this gate tells us whether
   we carry the bug.

Climb 64K → 128K → 256K → 512K → 1M; stop at the last rung passing all five. Predicted stop:
**512K under current floors; 1M possible after floor renegotiation if gate 1 lands ≤6 GiB overhead.**

---

## (c) Component designs

### C1. Cache layer ("every turn cached; never re-prefill")

**Exists today (verified in source/pin):**
- In-slot prefix reuse: `cache_prompt` default-on; slot selection by longest-common-prefix
  (`--slot-prompt-similarity`, server-context.cpp:1538-1575). Exact-extension requests reuse the
  whole cache (final `seq_rm(p0=end)` succeeds because p0 > seq_pos_max).
- Rollback for divergent turns: **context checkpoints** with `LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY`
  (server-context.cpp:2289-2334, 3280-3320) — PARTIAL writes only raw-SWA + compressor ring states
  (llama-kv-cache-dsv4.cpp:1330), i.e. MiB-scale snapshots; on divergence the server restores the
  newest usable checkpoint and replays from there; with none it re-prefills from zero (the logged
  "forcing full prompt re-processing" path). Currently **disabled implicitly**: serve script does
  not pass `-ctxcp` but default is 32 — however `--cache-ram 0` is set, and checkpoints live in
  slot state (not the RAM cache), so they work; verify in M1.
- Disk persistence: `/slots/{id}?action=save|restore` → `llama_state_seq_save_file/load_file` →
  `llama_kv_cache_dsv4::state_write/state_read` FULL mode. **Caveat found in source**: the
  compressed-cache dump writes the *entire allocated storage* per stream
  (`dsv4_state_write_k_cache` writes all `kv_size` rows, lines 292-360), so a slot file at the 1M
  rung is ~6.7 GiB **regardless of how many tokens the corpus actually has**, and restore hard-fails
  unless `kv_size` matches ("DSV4 K-cache state size mismatch") — **state files are rung-specific**.
  Mitigation: the ctor zero-fills compressed buffers, so unused rows are zeros → **zstd the files**
  (level 3): effective on-disk size ∝ used tokens; decompress-on-restore adds <1 s at NVMe rates.

**Build:**
- `scripts/54_statestore.py` — state-store manager. Layout
  `/var/lib/dsv4/states/ctx-<kv_size>/<corpus_id>/state.bin.zst` + `manifest.json` per corpus:
  content hash (same style as `configs/pins/*.json`), token count, token-ID list file (needed to
  compute prefix matches without the server), encoder revision, llama.cpp commit, kv_size, ub,
  created/last-hit timestamps. LRU eviction against a disk budget (default 250 GiB; box has
  **499 GiB free** on `/`, 87% used — budget must be co-owned with the weights/results usage).
  A saved-state is invalid if llama.cpp commit changes (no upstream format stability guarantee) —
  manifest check forces re-ingest on pin bumps.
- Serve-script config delta (one flag): `--slot-save-path /var/lib/dsv4/states/live` (+ keep
  `--cache-ram 0` at ≥512K — the RAM prompt cache copies FULL state per entry, 0.9 GiB at 128K,
  6.7 GiB at 1M; it is only sane at ≤128K rungs, where enabling `-cram 16384` gives cross-slot-
  switch reuse for free). Add explicit `-ctxcp 32 --checkpoint-min-step 2048` so multi-turn
  divergence replays ≤2K tokens (~7 s) instead of the 8K default (~29 s).

**Effort:** 3–4 days. **Risks:** (i) #25452 churn bug (gate 5); (ii) save blocks the single slot
for seconds — saves must be scheduled by the router when idle; (iii) format fragility across pin
bumps (manifest-enforced re-ingest); (iv) restore also blocks — a 1M restore is ~3–5 s of
serving pause (NVMe 6.7 GiB read ~1.5–2.5 s + UMA copy).

### C2. Router (smart full-vs-skim dispatch)

**Placement.** Chain today: Tailscale → Caddy :8010 (`forward_auth` → helper :8014, strips
Authorization) → `reverse_proxy 127.0.0.1:{$DSV4_UPSTREAM_PORT}` (Caddyfile). The router becomes
the upstream: run it on **127.0.0.1:8013** and set `DSV4_UPSTREAM_PORT=8013` in the Caddy service
env — **zero Caddyfile edits**, auth and rate limiting stay in front, engine stays credential-free
behind. Router must enforce the same loopback-only bind and never log request bodies (match
`40_auth_helper.py` conventions).

**Exists today:** the official encoder + tokenizer are vendored and pinned
(`vendor/official-encoding`, `configs/pins/official-encoding.json`) and `33_token_parity.py`
already proves client-side token IDs match the server — so **client-side longest-cached-prefix
computation is trustworthy**. `/slots` (default-enabled) returns per-slot token state for
verification. Measured prefill rate exists per rung from gate 3.

**Build:** `scripts/55_router.py` (asyncio, stdlib + vendored encoder; ~700 lines) + unit tests.
Decision procedure per request:
1. Render/tokenize with the official encoder (completions-style, as the harness already does).
2. Compute cached-prefix estimate = max(LCP vs its own mirror of the live slot's token stream,
   LCP vs state-store token-ID files via a radix/trie index — the HiCache/vLLM-router idea, done
   client-side because llama.cpp has no cache-introspection API beyond `/slots`).
3. `est_prefill_s = (n_tokens − n_cached_prefix) / rate_ema`, where `rate_ema` is updated from
   the `timings` block llama-server returns on every response (self-calibrating; init from gate-3).
4. Route: **(a)** prefix hit on live slot, or total ≤ threshold → forward as-is. **(b)** prefix hit
   on a saved state → `POST /slots/0?action=restore` (decompress first), then forward.
   **(c)** `est_prefill_s > 10` and no state hit → **skim mode** (C3), tag response with
   `x-dsv4-skim: true` header AND a `"dsv4_skim": true` field injected into the JSON body.
5. Idle hooks: when no request for N s, trigger deferred state saves and ingest steps (C4).

Threshold math, concrete: at today's measured 275–290 tok/s (`-ub 512`), 10 s ⇒ **~2,800 tokens**;
if `-ub 2048` at ≤256K rungs lands at the community-reported 2–3× (GB10 pp scales strongly with
ubatch; DSpark fork reports 795 tok/s), threshold becomes ~5,500–8,000. The router recomputes it
continuously from `rate_ema`, so the "10 seconds" contract holds as rates change.

**Effort:** 4–6 days incl. tests. **Risks:** (i) tokenization drift between encoder and any
chat-template path — mitigate by keeping the completions-style contract and reusing the parity
gate as a router unit test; (ii) mirror desync with the engine slot — resync from `/slots` on
every response; (iii) single slot means a restore-then-serve pipeline head-of-line blocks other
users (~3–5 s worst case) — acceptable at this box's concurrency, documented.

### C3. Retrieval skim mode

**Design: lexical-only first (zero GPU, zero resident RAM beyond SQLite).** BM25 via **SQLite
FTS5** (stdlib `sqlite3`; no new deps, fits the repo's no-heavy-deps style). Chunking: code by
function/class boundary (tree-sitter optional; regex-based fallback) capped ~300 lines; prose by
heading/paragraph, 512–1,024 tokens, 15% overlap. Compose: top-k chunks with file-path headers,
rendered through the official encoder, newest-first ordering, sized to the *current* threshold
budget × a skim multiplier (default 4× ⇒ ~11K tokens ⇒ ~40 s worst-case prefill today — honest:
skim beats the 60-minute cold path by 100×, but is NOT sub-10 s at ub 512; the 10 s figure governs
*routing*, and skim responses are latency-tiered and tagged). Embedding rerank (bge-small on CPU,
~0.5 GiB) is a later optional layer — do not spend UMA on it until BM25 recall measurably fails.

**Fidelity expectations (state them in the response tag):** good for point-lookup/QA-shaped
questions; wrong for global aggregation, counting, and multi-hop across unretrieved chunks —
exactly RULER's category split. Gate: run the rung fidelity set in skim mode vs full attention and
publish the gap in `results/skim-fidelity.json`; REFRAG-style tricks and CacheBlend splicing are
explicitly out of scope (no llama.cpp partial-prefill hook; latent cache breaks their premises).

**Exists today:** nothing (evalsets/fixtures reusable). **Effort:** 3–4 days. **Risks:** recall
misses on vocabulary mismatch (BM25 weakness) — mitigated by query expansion with the
conversation's recent turns; skim outputs contaminating conversation caches — skim runs on the
scratch slot region and is never state-saved.

### C4. Ingest pipeline

**Build:** `scripts/53_ingest.py` + `dsv4-ingest.service`/`.timer` (repo already has
`configs/systemd` + `41_install_service.sh` install pattern; `nice -n 19 ionice -c3` for the CPU
parts). Corpora registered in `configs/corpora.json` (path globs + per-file content hashes, same
shape as existing pins). Loop: detect hash drift → re-render corpus through the official encoder →
chunk into ≤(rung − 8K reserve) token documents → submit prefill requests **through the router's
ingest lane** (router admits ingest only after N idle seconds and cancels/defers when live traffic
arrives — this is the GPU time-slicing answer: same GPU, but memory is statically budgeted so the
watchdog is indifferent, and the single-slot queue means an in-flight ingest chunk delays a live
request by ≤ one ubatch batch, ~seconds; the router additionally caps ingest requests to
`n_batch`-sized continuation steps so preemption latency is bounded) → periodic
`/slots?action=save` every ~64K tokens (resumability: a killed ingest restarts from the last
saved state, which restores exactly because the compressor ring state is serialized) → final save,
zstd, manifest write, BM25 index update.

**Numbers to expect:** 1M-token corpus ≈ 60 min at 280 tok/s (today) or ~20–30 min if ub-2048
ingest at ≤256K rungs pans out; restore at query time 3–5 s at 1M rung, ~1 s at 128K rung.
Disk: 250 GiB budget ⇒ ~35 full-1M corpora uncompressed-equivalent; zstd on zero-filled regions
stretches this several-fold for smaller corpora.

**Security:** saved states are the corpus (plus conversation content if turn-saving is enabled) —
`/var/lib/dsv4/states` owned `dsv4:dsv4` mode 0700, umask 077 (already repo convention), listed in
`docs/security-model.md`; never expose `/slots` beyond loopback (Caddy already fronts everything;
`--slot-save-path` restricts restore to that directory, path-traversal safe upstream).

**Effort:** 4–5 days. **Risks:** ingest/serve contention mis-tuning (mitigate: idle-gate +
bounded chunks); invalidation storms on big repo rebases (mitigate: chunk-level hashing so only
changed suffixes re-ingest — but NOTE: a change at token k invalidates all state after k; prefix
structure means corpora should be ordered stable-files-first).

---

## (d) Build order — numbered milestones with acceptance tests

Protocol note first: all of this is phase-2, post-decision. Per PROTOCOL.md's standing rule, add a
new protocol version entry before any gate runs; none of the frozen v2–v4 results are touched.

**M0 — Instrumented rung-0 restart (½ day).** Restart llama.cpp serving at CTX=32768 with default
log verbosity, `-ctxcp 32 --checkpoint-min-step 2048`, `--slot-save-path`.
*Accept:* `results/ctxladder-32k.json` records the DSV4 ctor buffer lines; measured bytes/token
computed and written; `02_membudget.py` invocation in the serve script updated to the measured
value; golden tests (`32_golden_tests.py`) pass unchanged.

**M1 — Cache mechanics verification (1 day).** New `scripts/52_state_roundtrip.py`:
(1) prefill a 16K fixture, greedy-decode 128 tokens; (2) `/slots` save → erase → restore →
greedy-decode again; assert **token-identical**; (3) kill server, restart, restore from file,
assert token-identical (cross-restart); (4) divergent-prefix turn: assert checkpoint restore
happens (log grep) and output is correct; (5) churn gate: 50 alternating divergent prompts, no
stall/ctx-exceeded (issue #25452 probe). *Accept:* `results/state-roundtrip.json` pass=true with
recomputed evidence, harness-style.

**M2 — Context ladder climb (2–3 days, off-benchmark windows).** `scripts/50_ctx_ladder.sh` +
`scripts/51_gate_ctx.py` implementing the five gates of §b; fixtures extended to rung sizes;
RULER-lite tasks generated locally (needle/VT/QA templates through the official encoder — no new
datasets needed, synthetic). Climb 64K→1M, stop at first failure.
*Accept:* `results/ctxladder-<rung>.json` per rung, all five gates recomputed from raw arrays
(35_soak-style honesty); DECISION-style summary naming the production rung; if 512K < rung < 1M
is blocked only by the 16 GiB floor, an explicit floor-change entry in PROTOCOL.md.

**M3 — State store + ingest (1 week).** `54_statestore.py`, `53_ingest.py`, corpora config,
systemd units, zstd, manifests, BM25 index build.
*Accept:* register this repo (~a few M tokens of code/docs) as corpus-0; ingest completes in the
predicted window with serving loop responsive (probe RTT < 2× baseline during ingest, measured);
restore-latency table in `results/ingest-restore.json` (target: ≤5 s at top rung, ≤1.5 s at 128K);
kill -9 mid-ingest resumes losing ≤64K tokens of work; hash-drift of one file triggers re-ingest
of only suffix states.

**M4 — Router (1 week).** `55_router.py` + `DSV4_UPSTREAM_PORT=8013` cutover + unit tests reusing
the parity-gate probes.
*Accept:* `results/router-golden.json`: (a) cached-conversation turn TTFT ≤ 2 s at 100K-deep
context (checkpoint path); (b) registered-corpus cold query TTFT ≤ 8 s at top rung (restore path);
(c) unregistered 50K-token prompt routes to skim, responds < 60 s, response carries both skim tags;
(d) short uncached prompts route full-fidelity; (e) `34_decision.py`-style recomputation of the
routing log proves every decision matched the threshold formula; (f) auth chain intact (engine
never sees Authorization — reuse the existing Caddy check).

**M5 — Skim quality + fidelity ledger (3–4 days).** Skim composer tuning; skim-vs-full gap
measured on the rung fidelity set + a repo-QA probe set.
*Accept:* `results/skim-fidelity.json` published with the honest gap; skim never triggers for
prompts with ≥90% cached prefix; tag present in 100% of skim responses (soak-verified).

**M6 — Soak + runbook + protocol closeout (2–3 days).** 24 h mixed-workload soak (conversations +
corpus queries + background ingest) at the production rung under the watchdog.
*Accept:* `35_soak.py`-extended run pass; MemAvailable never < watchdog+1 GiB; runbook.md updated
(new ports, state-store ops, eviction, pin-bump re-ingest procedure); threat-model addendum for
state files.

Critical path: M0→M1→M2 (everything else depends on the rung and on save/restore actually
round-tripping). M3/M4 parallelizable after M1.

---

## (e) Open questions → exact cheap experiments

1. **Real bytes/token and compute-buffer growth** (decides the 1M verdict). *Experiment:* M0/M2
   startup-log reads at 32K and 256K; 15 min each; compare ctor MiB lines vs §b model. No load
   needed — allocation is static at init.
2. **Does slot restore round-trip bit-exact for DSV4 on our pin, incl. across restart?** Source
   says yes (versioned FULL dump incl. ring states); #25402/#25452 history says "recent fixes".
   *Experiment:* M1 steps 1–3 at 16K; ~1 h.
3. **Do we carry the #25452 SWA-churn exhaustion bug?** *Experiment:* M1 step 5 (50 alternating
   divergent prompts); ~30 min. If it reproduces: cherry-pick the `dsv4-swa-churn-fix` lineage
   into a new pin (protocol-versioned) before M3.
4. **Prefill rate at `-ub 2048` and its compute-buffer price on GB10.** *Experiment:* one
   `30_bench_speed.py` cell run at CTX=131072 `-ub 2048` vs `-ub 512`; 30 min; sets ingest config
   and the router threshold's upper bound.
5. **Does restore require matching `-ub` (raw ISWA cache is sized by n_ubatch)?** *Experiment:*
   save at ub 512, restart with ub 2048, restore; 15 min. If it fails, ingest and serve must share
   ub (recorded in manifest either way).
6. **Fidelity across YaRN rungs** (64K native → 1M is ×16 interpolation on a 2-bit quant —
   nobody has published RULER numbers for this combination). *Experiment:* gate 2 of M2 per rung;
   the 128K rung result after one afternoon tells us whether the 1M ambition is even worth the
   memory fight.
7. **Skim-vs-full quality gap on our actual workloads.** *Experiment:* M5 probe set (30 repo
   questions answered both ways at 256K); half a day; bounds how aggressively the router should
   prefer skim.
8. **Checkpoint spacing vs turn latency trade.** *Experiment:* multi-turn replay at min-step
   {512, 2048, 8192} measuring per-turn TTFT and RAM held by 32 checkpoints; 1 h.

---

## (f) Citations

Local/source (all verified this pass):
- `src/llama-kv-cache-dsv4.cpp`: ratios 4/128 (l.18-19), state magic/version + FULL/PARTIAL
  (l.21-26, 1317-1378), full-storage K dumps + kv_size match requirement (l.292-360),
  `get_can_shift`=false (l.1198), seq_rm no-truncation (l.1209), zero-fill of compressed buffers
  (l.1083-1088), per-store ctor sizes + log lines (l.970-1088).
- `src/llama-context.cpp`: n_ctx_seq partitioning (l.261-275), worst-case graph reserve ∝ ubatch
  (l.556, 787), output buffer (l.347).
- `tools/server/server-context.cpp`: LCP slot selection (l.1538+), cache-reuse disabled when
  !can_shift (l.1215-1228, 3158-3165), PARTIAL checkpoints (l.2289-2334), checkpoint-restore-else-
  full-reprocess (l.3280-3320), `/slots` save/restore via `llama_state_seq_save_file` (l.2508-2582,
  4485-4512).
- Pinned binary `--help`: `--slot-save-path`, `-ctxcp`, `-cram`, `-sps`, `--cache-reuse`, `-kvu`.
- GGUF header of `DeepSeek-V4-Flash-UD-Q2_K_XL` (dims, ratios, YaRN, 1M cap);
  `results/speed-llamacpp.json` (275–290 tok/s prefill, 13.2–13.9 tok/s decode, ttft table);
  `configs/versions.lock` + `docs/llamacpp-pin-choice.md` (pin 32e789fd, 2026-07-16 master);
  `df -h` (499 GiB free); `scripts/21_serve_llamacpp.sh` (flags, watchdog 12 GiB, floor 16 GiB,
  4096 B/token assumption); `docs/research-1m-coldstart-{fable,sol}-2026-07-16.md`.

Web (from this pass's research agents):
- llama.cpp: server README (slots API, cache_prompt) github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md;
  host-memory prompt cache PR #16391; slot-persistence discussions #20572, #13606, #20574;
  restore≈7× writeup ai-muninn.com/en/blog/kv-cache-disk-restore-7x; DSV4 merge PR #24162;
  checkpoint-save lineage PR #25402; churn bug issue #25452; SWA cache-reuse limits #21468, #21831;
  slot-local checkpoints #22942; Unsloth V4 guide unsloth.ai/docs/models/deepseek-v4.
- DGX Spark performance: discussion #16578 (gpt-oss-120B ~570 t/s pp2048; ub scaling);
  jetsonhacks.com Spark bench (pp4096@ub4096 ≈ 2047 t/s); NVIDIA forum DSpark thread (DSV4-Flash
  ~795 t/s prefill, 18-20 t/s decode, forum id 376884); GB10 compute forums.developer.nvidia.com
  /t/351993.
- Systems (design-only borrow, none portable): LMCache arxiv.org/abs/2510.09665 + docs.lmcache.ai;
  SGLang HiCache lmsys.org/blog/2025-09-10-sglang-hicache + docs.sglang.io hicache_design; vLLM
  production-stack prefix/KV-aware routing docs.vllm.ai/projects/production-stack; Mooncake
  arxiv.org/abs/2407.00079; MemServe arxiv.org/abs/2406.17565.
- Ruled-out techniques: CacheGen arxiv.org/abs/2310.07240 (premises mooted by latent cache);
  CacheBlend arxiv.org/abs/2405.16444 (no partial-prefill hook in llama.cpp; V-discrepancy signal
  absent for latent rows).
- Evaluation: RULER arxiv.org/abs/2404.06654 + github.com/NVIDIA/RULER (OpenAI-compatible client);
  lm-evaluation-harness local-completions backend github.com/EleutherAI/lm-evaluation-harness;
  cache semantics to copy: ai.google.dev/gemini-api/docs/caching (explicit cache objects + TTL),
  Anthropic cache_control breakpoint model.
