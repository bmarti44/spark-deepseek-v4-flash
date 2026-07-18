# Phase B (B1): fused hyper-connection rebuild — CORRECT + ~14% FASTER (deploy candidate)

**Objective:** Rebuild llama.cpp at commit `0dc74e332` ("DeepseekV4: Add fused
hyper-connection ops", PR #25585) — the plan's top speed lever — validate correctness
and speed, deploy if better.

## VERDICT (corrected 2026-07-18): the fusion binary is correct and meaningfully faster. It is a deploy candidate.

> **Correction notice.** An earlier version of this doc (2026-07-17) REJECTED the
> fusion binary, concluding the fused op produced empty/NaN output at long context.
> That conclusion was WRONG. A max-effort independent review (codex sol) flagged it,
> and re-testing confirmed the error. The details are below so the mistake is on record.

## What was built and verified present
- Isolated `git worktree` at `0dc74e332` (production worktree untouched).
- Built `-j20` with production flags (`-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=121 -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF`).
- Fusion op genuinely compiled in: `libggml-cuda.so` differs from production and exports
  `ggml_cuda_op_dsv4_hc_pre/comb/post`, absent in the production lib.
- Build manifest: `configs/build-manifests/llamacpp-fusion.json`.

## Why the first pass wrongly rejected it
DeepSeek-V4-Flash is a **reasoning** model. The golden gates `needle_16k` /
`sustained_ctx` run with `max_tokens=64` and the harness reads only `message.content`,
ignoring `message.reasoning_content`. At long context the model spends the whole 64-token
budget *thinking* and emits no final answer — recorded as "empty content". My direct
repro compounded the error by using `max_tokens=20`. None of this indicated a broken op.

**Re-test (needle at ~9k prompt tokens):**
| max_tokens | content | finish_reason | needle in reasoning/content |
|---|---|---|---|
| 64 | `''` | length | **found in reasoning_content** (ran out of budget) |
| 512 | `BLUEBERRY-7421` | stop | **correct final answer** |

The other 8 golden gates (health, models, basic_fact, arithmetic, determinism,
multiturn_cache, streaming, error_schema) passed on the fusion binary.

## Speed (5 reps/cell, same protocol as the frozen production run; evidence: docs/phase-b-speed-fusion-2026-07-18.json)
| ctx | decode prod→fusion | prefill prod→fusion |
|---|---|---|
| 0 | 13.71 → 15.99 (+16.6%) | 94 → 112 (+19.2%) |
| 4096 | 13.88 → 15.75 (+13.5%) | 291 → 327 (+12.3%) |
| 16384 | 13.51 → 15.44 (+14.2%) | 284 → 317 (+11.5%) |
| 28672 | 13.15 → 14.94 (+13.6%) | 275 → 305 (+11.0%) |

~14% faster decode, ~11-19% faster prefill across the envelope.

## Before deploying to production (open items)
1. **Accuracy validation.** The fused op changes numerics; golden gates are smoke tests,
   not accuracy. A GSM8K/MMLU comparison vs the frozen production numbers (GSM8K ~97-98/100)
   should be run before the fusion binary becomes the served production build.
2. **Integrity coverage.** The serve integrity check hashes only the thin `llama-server`
   binary (identical across builds); the fused code lives in `libggml-cuda.so`. A real
   deployment should hash the MANIFEST-recorded shared libraries too (the fusion build
   manifest already records them).
3. **Protocol + config.** New build manifest + PROTOCOL entry for the binary change;
   systemd/serve pointed at the fusion binary+libs; production restart (needs root).

## Lesson
A correctness gate that reports "empty" without distinguishing "reasoning budget
exhausted" from "no output" will wrongly fail a reasoning model. Fix the harness to read
`reasoning_content` and/or give reasoning tests an adequate budget before trusting a
pass/fail as a correctness signal.
