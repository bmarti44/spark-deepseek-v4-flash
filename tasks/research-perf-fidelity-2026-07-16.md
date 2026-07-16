# Deep research: raise DeepSeek-V4-Flash speed AND fidelity on a single DGX Spark

You are a research agent. READ-ONLY on this machine: do not modify files, do not start/stop
any server, and DO NOT send requests to 127.0.0.1:8011 or :8012 — a benchmark holdout run is
in flight and any extra load contaminates it. Local inspection (reading code, configs,
results, logs) plus web research only.

## Current state (facts, all in this repo)
- Host: DGX Spark GB10, sm_121, aarch64, 119 GiB unified memory (OOM = hard freeze),
  driver 580.159.03, CUDA 13.0.
- Model: DeepSeek-V4-Flash 284B MoE, 13B active, hybrid CSA+HCA sparse attention +
  Lightning Indexer, MTP head. Official weights ~149 GiB -> must quantize below ~4 bit.
- Candidate A: entrpi/ds4 engine @ baa88902, "DSpark" speculative profile (2-bit base +
  MTP + separate drafter GGUF). Sources at /home/dsv4/ds4-project/src. decode ~18.7 tok/s
  @4K ctx, 16.2 @16K; prefill far better than B (TTFT 16K = 21.8s vs B 57.8s); warm server
  FAILS >28K-token prompts (lazy session graph; eager mode breached memory watchdog).
- Candidate B: upstream llama.cpp @ 32e789fd (V4-Flash support merged 2026-06-29),
  Unsloth UD-Q2_K_XL (~78 GiB, 3 shards). Sources at /home/dsv4/llamacpp-project/src/llama.cpp.
  Build manifest configs/build-manifests/llamacpp.json. Serve flags in scripts/21_serve_llamacpp.sh.
  decode 13.9 @4K, 13.1 @28K (no context limit issue). Accuracy (v2): GSM8K 97%,
  MMLU-Pro dev 77.9%, HumanEval 81.1%.
- Both serve with ctx 32768, single client, temperature 0 evals, enable_thinking=false.

## Research questions (rank findings by expected impact / effort)
1. llama.cpp speed levers for THIS model class on THIS hardware: flash-attention flags,
   -ub/-b micro/batch sizing, --cache-type-k/v (q8_0/q4) KV quantization (speed AND
   fidelity cost), -np parallel slots, --n-gpu-layers/offload policy on unified memory,
   speculative decoding support for V4-Flash in llama.cpp (draft model support for MoE+MTP?),
   MTP head usage in llama.cpp (is the merged V4 support using MTP? PRs since 2026-06-29?),
   prompt-cache / slot-save features, sm_121-specific CUDA build flags (we build with
   CMAKE_CUDA_ARCHITECTURES=121).
2. Upstream movement: llama.cpp commits/PRs/issues since 32e789fd (2026-06-29) touching
   deepseek, V4, MLA/CSA/HCA attention, MTP, GB10/sm_121, unified memory. NVIDIA DGX Spark
   forums + llama.cpp discussions for GB10 tuning (memory pinning, MIG?, power/thermal caps,
   nvidia-smi settings, kernel params). entrpi/ds4 commits since baa88902 (fixes for the
   >28K lazy-graph bug? new profiles? quality fixes?).
3. Quantization fidelity: is UD-Q2_K_XL the best fidelity/GiB point that fits ~100 GiB
   budget? Compare Unsloth UD-IQ2_M / UD-Q2_K_XL / UD-Q3_K_XL sizes for V4-Flash (Q3 likely
   too big with ctx: verify), imatrix variants, KV-quant interactions. Any published
   V4-Flash quant benchmarks (MMLU/GSM8K deltas per quant level)?
4. ds4 DSpark specifics: how the drafter+MTP speculative pipeline works (read
   /home/dsv4/ds4-project/src), tunables (draft length, acceptance threshold, env vars),
   whether drafter quality bounds output fidelity (it should not — verify rejection
   sampling preserves target distribution), the lazy session graph issue and whether a
   bounded-graph or chunked-prefill setting exists.
5. Serving-layer wins that don't change engines: continuous batching settings, response
   caching, --keep/prompt-prefix reuse for repeated system prompts, HTTP/2, streaming
   chunking overhead.
6. Anything else material we're missing (e.g., a third viable engine for this model on
   aarch64+sm_121: vLLM/SGLang/TensorRT-LLM state for V4-Flash on GB10 — likely not ready,
   verify quickly, don't rabbit-hole).

## Output format
Markdown. For each finding: [impact high/med/low] [effort low/med/high] [confidence] —
what, why it applies to THIS setup, exact flags/commits/links, and a concrete next step.
End with a top-5 ranked action list for speed and a top-3 for fidelity. Cite URLs for all
web claims. Flag anything that would require re-running the frozen benchmark protocol.
