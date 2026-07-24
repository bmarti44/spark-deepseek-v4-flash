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
| 19K prefill + 256 gen, cold | 42.8 s wall (prefill NOT separable: ds4 exposes no split timings; implied ~580-1100 tok/s across the plausible 10-26 tok/s decode range) | ~73 s (434 tok/s measured) | ds4, margin unquantified |
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
workload. Where it wins: cold-prompt TTFT (42.8 s vs ~73 s wall on the same
19K+256 job — a solid 1.7x on wall clock; the per-phase prefill multiple is
not separable from ds4's opaque timings) and context-echoing generation — IF
~3 GiB more slack is freed (close browsers) or the burst is qualified. Where it loses: prose decode (slower than tuned
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

Scope of this conclusion (sol review): what is PROVEN is that neither tested
quantizer's GGUF contains NextN tensors and the one standalone MTP file on
this host is format-incompatible. The converter-never-emits-NextN explanation
is an inference consistent with both data points, not a survey of every
published conversion. Practical rule stands either way: header-verify
`nextn` tensors (512 KB range fetch) before committing to any download.

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
its bpw drop (2.21 vs UD-Q2_K_XL's class) for a +5-7% speed gain — a
regression risk we chose not to spend qualification cycles on (untested
inference, not a measured accuracy result).

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

## Academic-track follow-ups (investigated 2026-07-23/24)

### Track B: DSpark upstreaming into llama.cpp — watch, not testable yet

[llama.cpp PR #25173](https://github.com/ggml-org/llama.cpp/pull/25173)
(DSpark = DFlash + semi-autoregressive Markov head, confidence-scheduled
verification; design in
[issue #25096](https://github.com/ggml-org/llama.cpp/issues/25096)) is open
and active, but scoped Qwen3-first by the author. DeepSeek-V4 is blocked in
the branch by a rope-type bug (hardcoded NEOX vs V4's NORM; acceptance falls
~5.5 -> ~2.0 tokens) and by the absence of any published DFlash-format
V4-Flash drafter (needs `markov_w1`/`markov_w2` tensors; ds4's
`DSpark-drafter-Q2K-Q8.gguf` is ds4-private format and does not convert).
Adoption trigger: rope fix lands + a V4-Flash DFlash drafter GGUF appears.
If both happen, this brings ds4-class speculation into llama.cpp while
keeping prefix caching, 32K+ context, and the stability ds4 lacked.

### Track C: EAGLE-3 head — exists but proof-of-concept grade

[ManiacLabs/DeepSeek-V4-Flash-EAGLE3.1](https://huggingface.co/ManiacLabs/DeepSeek-V4-Flash-EAGLE3.1)
(2026-06-07) is the first public EAGLE-3 head for this model, but: trained on
only 71K tokens, ~11% draft acceptance, mean accepted length 1.33, served
only via a custom vLLM overlay, explicitly "No SGLang / llama.cpp support."
At 1.33 mean acceptance a bandwidth-bound single-stream deployment roughly
breaks even. Not pursued. Adoption trigger: a head with mean acceptance
length >=2.5 (or an official release); our build already carries
`--spec-type draft-eagle3`, so a well-trained head is a GGUF conversion away.

### Track A: REAP expert pruning — tested, blocked by a kernel crash

[REAP](https://github.com/CerebrasResearch/reap) (Cerebras Research)
one-shot-prunes MoE experts by router-weighted activation. Community prunes
of V4 Flash exist with standard `deepseek4` GGUF headers (verified by
range-fetching headers before download — 512 KB instead of 72 GiB).
Candidate under test: `xik94/DSV4-Flash-162B-REAP-Q3_K_M.gguf` (72.3 GiB,
144 of the original experts, ~3.8 bpw vs production's ~2.7): higher fidelity
per byte AND ~18 GiB more headroom. Note the physics before expecting decode
miracles: expert_used_count is unchanged (6+1 shared), so ACTIVE bytes per
token at Q3 exceed production Q2 — raw decode should be modestly SLOWER; the
prize is accuracy-per-byte, memory headroom (context, speculation, no
memory-gate friction), and the community-reported 200K-context single-Spark
deployment (~24 tok/s with 2-token speculation).

**Measured result (2026-07-24): unusable on the fusion build.** The 72.3 GiB
GGUF loads (`deepseek4`, 144 experts), leaves 37.7 GiB free, and the FIRST
request decodes coherent prose at **21.4-21.7 tok/s** (faster than
production's 18.3 despite higher bpw — contrary to the active-bytes
prediction above). But every SECOND request in the same process aborts with
`CUDA error: an illegal memory access` (ggml-cuda.cu:106), with and without
prompt caching (`cache_prompt: false` reproduces it) and with ~37 GiB free —
so it is the context re-use path with the pruned non-power-of-two expert
count (144), not memory pressure and not slot LCP reuse specifically.
One-request-per-process is disqualifying. Action: file upstream with the
backtrace and this repro (load REAP-144-expert GGUF, send any two requests);
re-test on future llama.cpp pins. Weights kept at `weights/xik94-reap162b/`
(~120 GB disk free after both experimental downloads).

Accuracy was NOT evaluated (blocked before a qualification run made sense).
The single-data-point 21.7 tok/s decode suggests the REAP direction is worth
re-testing once the crash is fixed upstream — it beat production's decode at
higher fidelity per active byte, which the naive bandwidth model did not
predict.
