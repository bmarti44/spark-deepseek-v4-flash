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

- Path 1 (MTP): blocked — no loadable NextN weights were found in any source
  checked here (two quantizers' full inventories + the one local MTP file).
  Re-check when a quantizer publishes V4-Flash GGUFs with verified `nextn`
  tensors (verify with a header parse BEFORE downloading 70+ GiB).
- Path 2 (ds4/DSpark): real wins only for cold-prompt TTFT and echo-heavy
  generation, and only with ~3 GiB more free RAM than a desktop-loaded host
  provides; loses on prose decode, per-turn prefix reuse, context ceiling,
  and stability.

The 73 GiB IQ2_XXS-XL weights were deleted 2026-07-24 (disk pressure — see
Appendix housekeeping note; re-download command preserved there).

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
Adoption trigger: rope fix lands + a V4-Flash DFlash drafter GGUF appears —
NECESSARY conditions, not sufficient (sol re-review): the PR discussion also
records unresolved quantized-target greedy divergence and draft-cache/state
cleanup concerns, so DSV4 correctness and stability under this path are
undemonstrated until measured here.

### Track C: EAGLE-3 head — exists but proof-of-concept grade

[ManiacLabs/DeepSeek-V4-Flash-EAGLE3.1](https://huggingface.co/ManiacLabs/DeepSeek-V4-Flash-EAGLE3.1)
(2026-06-07) is the first public EAGLE-3 head for this model, but: trained on
a 71K-example corpus (65K general + 6K agentic, 4 epochs — examples, not
tokens; corrected per sol re-review), ~11% draft acceptance, mean accepted
length 1.33, served only via a custom vLLM overlay (stock serving lacks the
V4 auxiliary-state capture it needs), explicitly "No SGLang / llama.cpp
support." The card reports 2.63x throughput on 4x B200 despite the 1.33 mean
acceptance — we have NOT built a single-Spark cost model, so the local gain
is unknown rather than provably break-even. Not pursued. Adoption trigger: a
head with mean acceptance length >=2.5 (or an official release). Caveat: our
build's `--spec-type draft-eagle3` flag existing does not establish that
DSV4 auxiliary-state extraction, tensor mapping, or rope handling work for
this architecture — adoption would need a conversion AND an integration
proof, not just a flag.

### Track A: REAP expert pruning — tested, blocked by a kernel crash

[REAP](https://github.com/CerebrasResearch/reap) (Cerebras Research)
one-shot-prunes MoE experts by router-weighted activation. Community prunes
of V4 Flash exist with standard `deepseek4` GGUF headers (verified by
range-fetching headers before download — 512 KB instead of 72 GiB).
Candidate under test: `xik94/DSV4-Flash-162B-REAP-Q3_K_M.gguf` (72.3 GiB,
144 of the original experts, ~3.8 bpw vs production's ~2.7): more bits per
RETAINED weight and ~18 GiB more headroom — whether that nets out to higher
quality than the unpruned Q2 is an open question the holdout suite must
answer (pruning 75% of experts is itself a fidelity cost). Note the physics before expecting decode
miracles: expert_used_count is unchanged (6+1 shared), so ACTIVE bytes per
token at Q3 exceed production Q2 — raw decode should be modestly SLOWER; the
prize is accuracy-per-byte, memory headroom (context, speculation, no
memory-gate friction), and the community-reported 200K-context single-Spark
deployment (~24 tok/s with 2-token speculation).

**Measured result (2026-07-24): crashes on request 2 — root cause identified
and a fix ported (see below).** The 72.3 GiB GGUF loads (`deepseek4`, 144
experts), leaves 37.7 GiB free, and the FIRST request decodes coherent prose
at 21.4-21.7 tok/s (single data point; exact request: 256-token completion,
temp 0, 18-token prompt, `-ub 2048 --no-mmap`, ngram spec loaded but idle —
raw probe transcripts in this doc's appendix). Every SECOND request in the
same process aborts with `CUDA error: an illegal memory access`.

Isolation matrix (all two-request probes, `cache_prompt: false`):

| Variant | Result |
|---|---|
| fusion build (0dc74e33) | crash on request 2 |
| pre-fusion pin (32e789fdf) | crash on request 2 — NOT a fusion regression |
| fusion + `GGML_CUDA_DISABLE_GRAPHS=1` | crash — not CUDA-graph reuse |
| fusion + `GGML_CUDA_FORCE_CUBLAS=1` | crash — not MMQ-specific |
| fusion + `CUDA_LAUNCH_BLOCKING=1` | names the kernel: `ggml_cuda_mul_mat_q` (mmq.cu:221) |

Root cause (confirmed by the quantizer's own model card, which we found
after the isolation): **REAP remaps several routing slots to the same
physical expert, and `mm_ids_helper` (ggml/src/ggml-cuda/mmid.cu) races when
more than one warp thread matches the same expert for a token** —
`warp_reduce_any` + a single store slot corrupts the compact index stream
that downstream expert matmuls consume. The quantizer ships a patch
(prefix-sum ranks instead of any-reduce); their `.patch` file is truncated
and targets an older base, so the fix was ported semantically to our tree
(both the generic and neu_padded-optimized paths) in a dev worktree
(`llama.cpp-reapfix`, production checkout untouched). Earlier phrasing here
attributed the crash to "context re-use with the pruned non-power-of-two
expert count" — that causal guess was wrong in the mechanism (it is a
duplicate-ID warp race that request 2's state happens to expose) and is
superseded by this section.

Accuracy was NOT evaluated. The 21.7 tok/s figure is a single prompt/config
data point, not a benchmark; "higher bpw per retained weight" describes the
quantization arithmetic only — whether REAP-75% pruning at Q3 beats the
unpruned Q2 on quality is an open empirical question for the holdout suite.

## Appendix: raw REAP probe data (auditability)

Probe: llama-server with the REAP GGUF, loopback :8021, flags
`-c 32768 -np 1 -ngl 999 --no-warmup --no-mmap --cache-ram 0` (+ per-variant
env), three sequential /v1/chat/completions requests, `cache_prompt: false`,
`max_tokens: 64`, `temperature: 0`.

Throughput observations (fusion build, `-ub 2048 -b 2048`, ngram spec loaded):

```
short-ctx prose r1: prompt_n=18 gen_n=256 decode_tps=21.44 prefill_tps=51.5  (run 1)
short-ctx prose r1: decode=21.7 t/s                                          (run 2)
```

Crash matrix raw results:

```
oldpin          : r1=200 r2=000 r3=000 CRASHES-ON-REUSE   (32e789fdf build)
fusion-blocking : r1=200 r2=000 r3=000 CRASHES-ON-REUSE   (CUDA_LAUNCH_BLOCKING=1)
  -> E CUDA error: an illegal memory access was encountered
  -> E   in function ggml_cuda_mul_mat_q at .../ggml-cuda/mmq.cu:221
fusion-nographs : r1=200 r2=000 r3=000 CRASHES-ON-REUSE   (GGML_CUDA_DISABLE_GRAPHS=1; 0 'CUDA Graph' log lines)
fusion-cublas   : r1=200 r2=000 r3=000 CRASHES-ON-REUSE   (GGML_CUDA_FORCE_CUBLAS=1)
```

The dev fix lives in the dsv4-owned worktree `llama.cpp-reapfix`
(`git diff` = mmid.cu only, 36 insertions / 8 deletions); the ported change
mirrors xik94's published fix (prefix-sum ranks for duplicate expert IDs in
`mm_ids_helper`, both code paths).

Housekeeping: `weights/teamblobfish-iq2_xxs_xl/` (73 GiB) was DELETED
2026-07-24 after its purpose (MTP tensor inventory: negative) was served —
the root filesystem was at 97% and only ~21 GiB above the unit's 100 GiB
startup floor with both experimental weight sets retained (sol re-review).
Re-download if ever needed:
`hf download teamblobfish/DeepSeek-V4-Flash-GGUF IQ2_XXS-XL/... --local-dir weights/teamblobfish-iq2_xxs_xl`.
`weights/xik94-reap162b/` (73 GiB) is retained while the mmid fix is under
test; delete it too if the REAP line is abandoned.

## Bug-resolution session (2026-07-24, late)

### Bug B (REAP second-request crash): FIXED in a dev build — two-layer root cause

Layer 1 — duplicate-expert-ID warp race in `mm_ids_helper`
(ggml/src/ggml-cuda/mmid.cu): REAP remaps several routing slots to one
physical expert; `warp_reduce_any` + a single store slot drop/corrupt compact
entries when >1 warp thread matches. Community fix by the quantizer (xik94)
ported semantically to our base (their `.patch` is truncated and targets an
older tree); both the generic and neu_padded-optimized paths.

Layer 2 — NOVEL, found here: the shared-memory `store` is sized
`n_tokens * sizeof(entry)`, assuming ≤1 entry per token per expert. With
duplicates an expert can receive up to n_expert_used entries per token, so
large prefill batches overrun shared memory even WITH the community fix
(reproduced: short requests pass, 19K prefill faults in `ggml_cuda_mul_mat_q`
at the post-`mm_ids_helper` check under CUDA_LAUNCH_BLOCKING). Fix: size the
store `n_tokens * n_expert_used * sizeof(entry)` (48 KB at ub=2048/6 experts,
within Blackwell's opt-in limit; the existing smpbo assert now fails loudly
instead of corrupting). xik94's own build is exposed to this on large
batches — worth reporting back to them and upstream.

Verified after both fixes (dev worktree `llama.cpp-reapfix`, patch preserved
at docs/patches/mmid-duplicate-expert-ids.patch, probe at
docs/patches/reap-two-request-probe.sh): full bench suite passes on
REAP-162B Q3_K_M — prose 21.4 tok/s, code 21.5, 19K prefill 463 tok/s,
19K-depth decode 19.2-20.0, math spot-check correct. That is +15-17% decode
over production at every point measured. Production adoption still requires
accuracy qualification (holdout suites) and a manifested build per protocol.

### Bug A (slot restore no-op): root-caused — fix requires fork surgery

Instrumented restore handler proves the restored token container is
byte-perfect (`0 24694 223 1320 ...` = file = fresh tokenization). The
failure is a three-way interaction:
1. Slot save files persist tokens + KV cells but NOT the fork's context
   checkpoints (`slot.prompt.checkpoints`).
2. The DSV4 compressed cache cannot partial-remove
   (`common_conte: the context does not support partial sequence removal`).
3. llama-server's must-evaluate-≥1-token rule decrements n_past even on an
   exact match, which always demands removing ≥1 tail position.
Native in-slot reuse survives (observed cache_n values are CHECKPOINT
positions, e.g. 1614/18726, not raw LCP) because live checkpoints exist;
restored slots have none, so any repeat degenerates to full re-prefill.
Even a boundary-exact save (prompt-only request, n_saved == request tokens)
fails on rule 3. No client-side workaround exists. Recommended fork patch:
serialize the newest context checkpoint into the slot save file and
reinstate it on restore (this is precisely the gap the bigctx plan's M1
"verify checkpoints work with --cache-ram 0" milestone anticipated).
