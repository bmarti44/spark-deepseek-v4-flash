# Decode-ceiling paths: measured results — 2026-07-24

Follow-up to docs/speed-tuning-2026-07-23.md. Two paths past the ~18 tok/s
prose decode ceiling were pursued to completion on this host. Baseline for all
comparisons: tuned llama.cpp fusion serving UD-Q2_K_XL
(`-ub 2048 --no-mmap --spec-type ngram-map-k4v`, fp16 KV): 434 tok/s prefill
@19K, decode 18.3 prose / 19.7 code-echo / 27.6 repetitive-JSON tok/s.

## Path 2: ds4 (DSpark profile) with its native speculative drafter

The repo's `ds4` candidate IS the community single-GB10 recipe: IQ2XXS-class
base + separate MTP GGUF + `DSpark-drafter-Q2K-Q8.gguf`, drafter armed by the
`dspark` profile (`DS4_CONT_DSPARK=1`, `DS4_CONT_MTP_MODE=2`).

Measured (CTX=24576, floor 13 via new `DS4_MEM_FLOOR_GIB` override; wall-clock
based — ds4 returns no timing fields; ~1.5 s fixed per-request overhead not
subtracted):

| Workload | ds4 dspark | tuned llamacpp | verdict |
|---|---|---|---|
| prose decode (short ctx) | ~13-14 tok/s (drafter self-quenches on prose) | 18.3 | llamacpp |
| code gen (short ctx) | ~19 tok/s (68.4% acceptance, 2.68 tok/step) | 18.4 | tie |
| code echo-edit | **25.8 tok/s** (97.1% acceptance, 4.71 tok/step) | 19.7 | ds4 |
| repetitive JSON | **crashed** (watchdog kill, twice) | 27.6 stable | llamacpp |
| 19K prefill + 256 gen, cold | 42.8 s wall (~870-1100 tok/s prefill implied) | ~73 s (434 tok/s) | ds4 |
| 19K repeat request | ~37 s (appears to re-prefill; no cross-request prefix cache observed) | 2-4 s (prefix cache) | llamacpp |
| cold load | 60-76 s | ~92 s | tie |

Stability finding (the headline): **the dspark profile cannot survive
speculation-heavy bursts on this host at current memory slack.** Two
reproducible watchdog kills (MemAvailable 11.71 and 11.97 GiB vs the 12.0 GiB
kill line) during the repetitive-JSON workload — the same workload where its
drafter performs best (97% acceptance). Post-load slack was 15.6 GiB (CTX
32768) / 18.4 GiB (CTX 24576) with ~3 GiB held by desktop browsers; the spec
burst transiently allocates ~4-6 GiB. `DS4_DSPARK_MAX_KV` / `DS4_DSPARK_MAX_NLIVE`
gate when speculation engages, not the burst size — no memory-budget knob
exists for it.

Verdict: not a general win over the tuned llama.cpp endpoint for the agent
workload. Where it clearly wins: cold-prompt TTFT (2-2.5x prefill) and
context-echoing generation — IF ~3 GiB more slack is freed (close browsers) or
the burst is qualified. Where it loses: prose decode (slower than tuned
llamacpp), no observed cross-request prefix reuse (every agent turn re-pays
prefill: ~40 s vs llamacpp's 2-4 s), ≤~28K context envelope, and the
demonstrated fragility. The 2026-07-17 DECISION-era 26 tok/s soak decode was
measured at 4K ctx on a lighter host; it does not transfer to the 20K-prefix
agent regime.

Launcher change: `scripts/20_serve_ds4.sh` gained env-gated
`DS4_MEM_FLOOR_GIB` (default 16 = production behavior), mirroring the llamacpp
launcher's benchmark override.

## Path 1: MTP-retaining IQ2_XXS-XL GGUF + llama.cpp draft-mtp

Weights: [teamblobfish/DeepSeek-V4-Flash-GGUF](https://huggingface.co/teamblobfish/DeepSeek-V4-Flash-GGUF)
IQ2_XXS-XL (2 shards, ~73 GiB total; NextN heads pinned Q8_0 per the -XL
recipe). Compatibility pre-check on shard 1 (46.4 GiB, blocks 0-27): tensor
naming (`output_hc_base/fn/scale`, `blk.N.*`) matches the fusion build's DSV4
schema exactly — the README's "requires cchuter fork" note predates the
upstream V4 merge (2026-06-29) and appears stale.

### Verdict: draft-mtp is a dead end today — three independent confirmations

1. **The teamblobfish -XL GGUF does not contain NextN/MTP tensors.** Full
   tensor inventory of both shards (846 + 482 tensors, blocks 0-42, every
   unique name pattern enumerated): the schema matches the fusion build's DSV4
   layout exactly (attn compressors, hyper-connections, indexer, sinks) but
   there is no NextN head under any naming. The README's "-XL pins NextN heads
   at Q8_0" line is recipe boilerplate the conversion did not honor.
2. Same result previously verified for Unsloth UD-Q2_K_XL (all 43 blocks, no
   MTP tensors). Two independent quantizers, zero NextN exports — consistent
   with the converter path never emitting V4-Flash NextN tensors.
3. **ds4's standalone MTP GGUF cannot bridge the gap**: loading it via
   `--spec-type draft-mtp -md .../DeepSeek-V4-Flash-MTP-Q4K-Q8_0-F32.gguf`
   fails with `unknown model architecture: 'deepseek4_mtp_support'` — a
   ds4-private arch string. llama.cpp exits cleanly at load.

Until someone publishes a V4-Flash GGUF with real NextN tensors (or upstream's
converter gains that mapping), llama.cpp MTP for this model is not a matter of
flags or effort — the weights do not exist in loadable form.

### Consolation data: IQ2_XXS-XL plain (73 GiB vs 90 GiB), same server flags

| Workload | IQ2_XXS-XL | UD-Q2_K_XL (prod) |
|---|---|---|
| prose decode | 19.6 tok/s | 18.3 |
| code decode | 19.4 | 18.4 |
| 19K prefill | 453 tok/s | 434 |
| 19K-depth decode | 17.6-18.6 | 16.7-17.3 |
| echo-edit (ngram) | 24.3 (88% acc) | 19.7 |
| repetitive JSON (ngram) | 26.0 (75% acc) | 27.6 |

Only +5-7% on prose despite 19% smaller weights: decode reads the routed
active-expert subset per token, and the size savings concentrate in experts
that are mostly idle per step. Without MTP the smaller quant does not justify
its bpw drop (2.21 vs UD-Q2_K_XL's class) — accuracy re-qualification would
almost certainly show regression for a marginal speed gain.

## Bottom line

**The tuned llama.cpp endpoint on UD-Q2_K_XL remains the production
configuration.** Neither path dethrones it today:

- Path 1 (MTP): blocked on the ecosystem — no loadable NextN weights exist.
  Re-check when a quantizer publishes V4-Flash GGUFs with verified `nextn`
  tensors (verify with a header parse BEFORE downloading 70+ GiB).
- Path 2 (ds4/DSpark): real wins only for cold-prompt TTFT and echo-heavy
  generation, and only with ~3 GiB more free RAM than a desktop-loaded host
  provides; loses on prose decode, per-turn prefix reuse, context ceiling,
  and stability.

The 73 GiB IQ2_XXS-XL weights are kept at
`weights/teamblobfish-iq2_xxs_xl/` (disk now ~190 GB free) as the fallback
candidate if MTP-bearing conversions appear for this scheme first; delete the
directory to reclaim the space.
