# Phase B (B1) result: fused hyper-connection rebuild — REJECTED (upstream correctness bug)

**Date:** 2026-07-17
**Objective:** Rebuild llama.cpp at commit `0dc74e332` ("DeepseekV4: Add fused
hyper-connection ops", PR #25585) — the plan's top speed lever for the production
binary — re-run correctness/speed gates, and deploy if it is faster and correct.

**Verdict: DO NOT DEPLOY.** The fused hyper-connection op produces empty / NaN
output at long context. The production binary stays at `32e789fd`.

## What was built and verified present
- Isolated `git worktree` at `0dc74e332` (current production worktree untouched).
- Configured + built `-j20` with the production flags
  (`-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=121 -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF`).
- Confirmed the fusion op is genuinely compiled in: `libggml-cuda.so` differs from
  production and exports `ggml_cuda_op_dsv4_hc_pre/comb/post`, which are absent in the
  production lib. So the benchmark exercised the real fused path.
- Build manifest: `configs/build-manifests/llamacpp-fusion.json`.

## Correctness result (golden gates, fusion server on :8011, ctx 32768)
Production (`32e789fd`) passes every golden gate. Fusion (`0dc74e332`) fails the two
long-context gates and passes the rest:

| gate | production 32e789fd | fusion 0dc74e3 |
|---|---|---|
| health, models, basic_fact, arithmetic, determinism, multiturn_cache, streaming, error_schema | PASS | PASS |
| **needle_16k** | PASS | **FAIL** — completion empty ("secret code not found in completion: ''") |
| **sustained_ctx** | PASS | **FAIL** — "sustained stream final content is empty" |

Direct reproduction: a 16,023-token prompt returns an empty completion
(`completion_tokens: 20`, all empty — the signature of NaN logits from the fused op).
Short prompts (≤ a few hundred tokens) answer correctly, so the op is broken only
above some context threshold that is well inside our 32K production window.

## Why a newer commit would not help
No commit between `0dc74e332` and `origin/master` (`86d86ed4`) touches the op source
files (`ggml-cuda/dsv4-hc.cu`, `dsv4-hc.cuh`, `models/deepseek4.cpp`,
`ggml-cpu/ops.cpp`, `ggml.c`). The only follow-up referencing the feature (#25822) is
test-only (one line in `tests/test-backend-ops.cpp`, initializing sentinel tensors to
avoid NaNs), which corroborates that the op has a NaN problem but does not fix the
runtime path. This is an unfixed upstream bug in a just-merged PR.

## Decision and next steps
- Production remains on `32e789fd` (unchanged, verified correct). No speed gain is
  available from the fusion op today.
- Speed was intentionally not measured: correctness-broken output makes throughput
  numbers meaningless. The op targets prefill, so it remains worth revisiting **iff**
  upstream fixes the NaN behavior — re-run this exact procedure against the fixed commit.
- Recommend reporting the long-context NaN/empty-output regression upstream against
  PR #25585.
- The `-ub` prefill sweep (plan B2) is decoupled from the fusion op and can still be
  run on the production binary as Phase C router-tuning; not done here.
