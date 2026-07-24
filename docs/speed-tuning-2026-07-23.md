# Speed tuning session — 2026-07-23

Goal: make the production llama.cpp endpoint (DeepSeek V4 Flash UD-Q2_K_XL on the
DGX Spark GB10, 128 GB unified) meaningfully faster for agent workloads
(~20K-token fixed prefix, interactive TTFT, decode throughput). Everything below
was measured on this host, same weights, same pinned fusion binary
(`llama.cpp-fusion` @ `0dc74e33`, PR #25585) unless stated.

## Results

| Metric | Before (prod flags + `-ub 256`) | After | Change |
|---|---|---|---|
| Prefill, 19K prompt | ~208 tok/s | **434 tok/s** | 2.1× |
| TTFT, 19K cold prompt | ~97-100 s | **~59 s** | ~40% |
| TTFT, cached/repeat turn | ~100 s (agent payloads missed cache) | **2-4 s** capability, byte-stable prefix only | see §4 note |
| Decode, prose | 14-15 tok/s (agent-observed) / 18.3 clean | **18.3 tok/s** | — |
| Decode, code echoing context | — | **19.7 tok/s** | +11% vs baseline 18.3 |
| Decode, repetitive JSON/tool output | — | **27.6 tok/s** | +50% |
| Cold model load | 6-7 min | **~92 s** | ~4× |
| MemAvailable, loaded | ~20 GiB | 18.4 GiB | watchdog margin intact |

Serving config (manually started; systemd unit not yet updated):

```
DSV4_SERVER_BINARY=$HOME/llamacpp-project/src/llama.cpp-fusion/build/bin/llama-server \
DSV4_BUILD_MANIFEST=configs/build-manifests/llamacpp-fusion.json \
DSV4_NO_MMAP=1 DSV4_UBATCH_LARGE=1 DSV4_UBATCH=2048 DSV4_BATCH=2048 \
DSV4_SPEC_TYPE=ngram-map-k4v \
scripts/21_serve_llamacpp.sh start
```

New env-gated launcher knobs (defaults preserve prior production behavior
exactly): `DSV4_NO_MMAP`, `DSV4_LOG_VERBOSITY`, `DSV4_SLOT_SAVE_PATH`,
`DSV4_SPEC_TYPE` (whitelisted), `DSV4_KV_QUANT` (f16|q8_0),
`DSV4_UBATCH_LARGE` (permits `-ub` up to 2048; membudget charges +2 GiB
overhead for ub>512).

## What each change did (and how it was verified)

1. **`--no-mmap`** — GB10 mmap page-fault handling is pathologically slow
   (NVIDIA forum: 8m44s vs 1m30s for a comparable load; ggerganov's canonical
   Spark configs all disable mmap). Measured here: 6-7 min → 92-105 s.
   A "kernel 6.17.1 alone fixes it" claim was adversarially refuted — the flag
   is what matters.
2. **`-ub 2048`** (was launched at 256, frozen cap was 512) — prefill 208 → 434
   tok/s on an 18.7K-token prompt. The old 512 cap guarded a memory peak that
   does not exist on the fusion build: measured CUDA compute buffer is 267 MiB
   at ub=512 (the historical "35 GiB peak" was the pre-fusion build). ub=2048
   costs ~1 GiB.
3. **`--spec-type ngram-map-k4v`** (n-gram speculative decoding, no draft
   model) — engages only when output echoes context/history: prose 18.3
   tok/s (no regression observed in sampled runs), code-echo 19.7 (+11%,
   61-70% draft acceptance), repetitive JSON 27.6 (+50%, 86% acceptance).
   Well-suited to agent/tool-call traffic. Scope note (sol review): memory
   cost and prose-latency neutrality are observed-negligible in these
   samples, not proven universally.
4. **Prompt caching (server side) verified working** — identical 18.7K-token
   repeat request: 4 tokens prefilled, TTFT 2.3 s; same-prefix/new-question:
   517 tokens prefilled, TTFT 4.2 s. `--cache-ram 0` does NOT disable in-slot
   prefix reuse (a web claim to the contrary was refuted 0-3 and disproven
   locally). Honest scope (sol review): this session did NOT change caching —
   the 2-4 s number is what the server always could do with a byte-stable
   prefix; the ~100 s the agent experiences per turn persists until the
   Hermes payload-instability is fixed client-side. The table row is a
   capability bound, not a realized production improvement.

## Rejected / dead ends (all verified, don't re-litigate without new evidence)

- **MTP (`draft-mtp`) with current weights: impossible.** Parsed all three GGUF
  shard headers: the Unsloth UD-Q2_K_XL export contains **no NextN/MTP
  tensors** (blocks 0..42, no `nextn`/`eh_proj`/`mtp` names). Not a flag or
  build issue — the tensors were stripped at quantization.
- **q8_0 KV cache**: the DSV4 quantized-KV bug is fixed (PR #25202 is an
  ancestor of the fusion pin; output verified coherent) — but decode measured
  *slightly slower* at 19K ctx (16.3-17.0 vs 17.1-17.3 fp16). This arch's
  compressed KV is MB-scale; there is no bandwidth to save. Keep fp16.
- **Slot save/restore**: `--slot-save-path` save (164 ms) and restore (38 ms,
  n_restored=18748) both report success, but the next identical request gets
  `cache_n=0` and re-prefills fully — restored state is not LCP-matchable.
  Suspected fork bug in slot token-list restore. Open issue.
- **Flash attention**: already active (`resolve_fused_ops: Flash Attention
  enabled`); no additional lever there.
- **Request-body capture in llama-server**: impossible at any verbosity — the
  logging hooks are commented out upstream. At `-lv 5`, `launching slot` debug
  lines DO include full prompt text (usable for payload diffing; privacy
  caveat: prompts land in the 700-mode server log).

## Why agent TTFT was ~100 s every turn (root cause, external)

The server cache works; the Hermes agent's payload is unstable between
requests, so the prefix never matches. Known upstream issues, no config
toggle: non-deterministic tool/MCP schema ordering
(NousResearch/hermes-agent#27339) and a minute-precision timestamp in the
system prompt (#15866). DSV4 cannot KV-shift (`get_can_shift() == false` in
`llama-kv-cache-dsv4.cpp`), so `--cache-reuse` cannot soften this — the prefix
must be byte-stable. Mitigations: disable unused toolsets/MCP servers in
`~/.hermes/config.yaml`; durable fix is a two-line Hermes patch (sort tools
deterministically; date-only timestamp).

## The decode ceiling and the paths through it

Decode ~18 tok/s prose is near the bandwidth bound: ~90 GiB quant on
~273 GB/s ⇒ low-20s tok/s ceiling without speculation. Speculative decoding is
**lossless at temperature 0** (draft proposes, target verifies; rejected
tokens are recomputed exactly), so these paths trade memory/disk/accuracy of
the *weights*, never output correctness of accepted tokens:

1. **MTP-retaining GGUF + `--spec-type draft-mtp`** (this build has the full
   MTP driver, `common_speculative_impl_draft_mtp`). Candidate:
   [teamblobfish/DeepSeek-V4-Flash-GGUF](https://huggingface.co/teamblobfish/DeepSeek-V4-Flash-GGUF)
   -XL variants retain NextN heads at Q8_0. Sizes: Q2_K-XL ~100 GiB (too big
   for our envelope), **IQ2_XS-XL ~81 GiB / IQ2_XXS-XL ~73 GiB (fit)**.
   Expected: cross-model Spark data shows ~2.4-2.6× decode at ~72% acceptance
   (PR #22673); smaller weights also decode faster per-token (up to +20% from
   73 vs 90 GiB alone). Plausible outcome: 30-40 tok/s prose.
   Tradeoffs: (a) ~73-81 GiB download (267 GB free on disk — fits, ~90 GiB
   headroom after); (b) lower bpw than UD-Q2_K_XL ⇒ accuracy re-qualification
   required per protocol (golden + holdout suites) before production; (c)
   README targets a fork (`cchuter/llama.cpp feat/v4-port-cuda`) — verify
   header/tensor-name compatibility with the upstream-based fusion build from
   the first downloaded shard before pulling the rest; (d) llama.cpp's
   `draft-mtp` driver on DSV4 specifically is unproven (drivers exist for
   gemma4/step35/qwen35 layouts — DSV4's NextN may or may not map cleanly).
2. **ds4 (DSpark) with its native speculative drafter** — already built,
   benchmarked, and reproducible in this repo (`vendor/ds4-on-spark`). The
   single-GB10 community recipe reaches
   [27-34 tok/s decode](https://forums.developer.nvidia.com/t/deepseek-v4-flash-iq2xxs-on-a-single-gb10/368970)
   and there is a dedicated
   [single-GB10 DSpark speculative-decoding optimization thread](https://forums.developer.nvidia.com/t/optimizing-deepseek-v4-flash-on-a-single-nvidia-gb10-gx10-with-dspark-speculative-decoding/376830).
   Zero download. Tradeoffs: (a) hard ≤~28K prompt-token envelope on this host
   (results/envelope-exception-ds4.json) — tight with a 20K agent prefix, rules
   out long chats; (b) the drafter had a known arming footgun
   (`DS4_CONT_DSPARK`, see docs/research-fable-2026-07-16.md) and its memory
   behavior under the watchdog is unqualified; (c) product override
   (results/DECISION-OVERRIDE.md) chose llamacpp for the 1M-context roadmap —
   ds4 would be a second, capped endpoint, not a replacement.
3. **Draft-model speculation (`draft-simple`)** — needs a small
   vocab-compatible draft GGUF. No published DSV4-Flash draft model was found
   (2026-07-23 search); the community single-GB10 numbers attributed to
   "draft" setups turned out to be DSpark (path 2), not llama.cpp. Parked
   unless a draft model appears.

Recommended order: verify-then-download IQ2_XXS-XL (path 1) for the big prose
decode win with dev-split qualification; keep path 2 as the zero-cost
short-context alternative.

## Reproduction

- Prefix-cache verification: three-request A/B/C pattern (cold / identical /
  shared-prefix) against `127.0.0.1:8011/v1/chat/completions`, read
  `timings.cache_n` / `timings.prompt_n`.
- Decode workloads: 256-token generations at temp 0 — prose essay, from-scratch
  code, code-echo (reproduce a supplied file with a docstring change),
  repetitive JSON tool-calls; read `timings.predicted_per_second`,
  `timings.draft_n`, `timings.draft_n_accepted`.
- GGUF MTP check: parse shard headers (magic/KV skip/tensor-info walk), look
  for `nextn`/`eh_proj` tensor names. 20-line python, no gguf lib needed.
