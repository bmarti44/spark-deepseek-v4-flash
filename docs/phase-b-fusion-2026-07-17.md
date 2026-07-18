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

## Deployment status (2026-07-18) — DEPLOYED PROVISIONALLY; qualification incomplete

The fusion build was deployed as the production engine (systemd env override to the
`llama.cpp-fusion` worktree). A subsequent sol/max review (docs review + this note)
found the deployment was **not yet fully qualified**; the honest state:

**Landed in the repo, offline-validated (commits f74487c, and the follow-up batch);
NOTE all systemd-unit/serve changes below apply only on the NEXT install+restart —
they are repo-landed, live-deployment unconfirmed:**
- Integrity: serve now REQUIRES a non-empty `shared_libraries` map and hashes every
  entry (incl. `libggml-cuda.so`); baseline + fusion manifests both carry them and the
  builder (`13_build_llamacpp.sh`) now emits them, so generated manifests are covered
  too. Validated offline (both manifests verify against their libs; a tampered CUDA lib
  is caught).
- Restart circuit breaker: `scripts/03_guard.sh` latches after 3 CONSECUTIVE unhealthy
  checks (count-based, so slow ~600 s failing restarts cannot evade it); engine-unit
  `StartLimit` is a secondary fast-burst guard only. (The earlier claim that StartLimit
  alone "closed" the hammer-restart path was wrong — it can be evaded by slow failures.)
- `-ub 256` startup-peak mitigation is in the repo unit.

Also corrected for accuracy: the "correct" claim above is a golden/smoke-gate + needle
result, NOT an accuracy qualification (see open items). The +11-19% prefill / +14%
decode figures were measured at `-ub 512`; the deployed `-ub 256` production config's
throughput is UNMEASURED (expected slightly lower prefill, unchanged decode).

**STILL OPEN — requires GPU/model time (deferred while the host GPU is in other use):**
- **Memory safety is unproven.** A startup NVRM/UMA OOM occurred on deploy and recovered.
  The `-ub 256` mitigation and its assumed root cause (fusion graph-capture buffers) are
  NOT validated — the review notes `--no-warmup` disables startup decode and fusion
  *reduces* graph nodes, so the true cause may be scheduler reservation / CUDA context /
  VMM fragmentation. Neither the membudget gate nor the 1 Hz `MemAvailable` watchdog can
  observe a GPU-side NVRM failure. **Qualify with attended cold starts** (guard/StartLimit
  make auto-retry safe now), recording llama.cpp compute-buffer sizes, high-frequency
  `MemAvailable`, and NVRM errors, at `-ub` 512 vs 256. Then set the budget KV slope to the
  derived ~6880 B/tok plus measured fusion overhead.
- **Accuracy is not a controlled comparison.** The fusion GSM8K 97/100 run did NOT disable
  thinking the way the frozen baseline did, its transcripts are under `/tmp` (untracked),
  and the per-item pass sequence differs despite the equal total. Re-run identically
  (thinking off, tracked transcripts) and add MMLU-Pro + HumanEval before treating fusion
  as accuracy-qualified.

**Canonical baseline vs production:** the frozen A-vs-B benchmark and `configs/versions.lock`
remain `32e789fd` (unchanged record). Fusion (`0dc74e3`) is a production **deployment
override**, reversible by removing the two fusion `Environment=` lines from the engine unit.
Until the memory + accuracy items above are closed, treat the fusion deployment as
provisional.

## Lesson
A correctness gate that reports "empty" without distinguishing "reasoning budget
exhausted" from "no output" will wrongly fail a reasoning model. Fix the harness to read
`reasoning_content` and/or give reasoning tests an adequate budget before trusting a
pass/fail as a correctness signal.
