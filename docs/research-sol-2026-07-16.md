# Research result

As of 2026-07-16, the clearest near-term win is the new post-pin llama.cpp hyper-connection fusion. The current quantization is already the safest fidelity/capacity point: the actual UD-Q2_K_XL payload is about **90.18 GiB**, not 78 GiB. Q3_K_XL cannot fit, while IQ3_XXS is technically loadable but leaves dangerously little OOM margin.

I did not touch either server or send localhost requests.

## Ranked findings

### 1. Upgrade llama.cpp for the new DeepSeek-V4 hyper-connection fusion

[impact high] [effort medium] [confidence medium] — Commit [`0dc74e3`](https://github.com/ggml-org/llama.cpp/commit/0dc74e332edee2616e4d8d9ab3b68dfc340fc14a), merged after your `32e789fd` pin, fuses DeepSeek-V4 hyper-connection operations. [PR #25585](https://github.com/ggml-org/llama.cpp/pull/25585) reports graph-node reduction from roughly 29K to 8K and substantial decode/prefill gains on AMD hardware.

The reported AMD +60.9% decode number should not be projected onto GB10. The graph reduction is nevertheless directly applicable: current V4 execution spends considerable work in Sinkhorn/hyper-connection operations, and fewer graph nodes should reduce launch and scheduling overhead on NVIDIA too. This was the only material V4-specific change I found between your pin and current upstream [master history](https://github.com/ggml-org/llama.cpp/commits/master/).

Concrete next step: build an otherwise identical binary with only the pin changed to `0dc74e332edee2616e4d8d9ab3b68dfc340fc14a`; compare 4K decode plus 16K/28K TTFT and prefill.

**[FROZEN RERUN REQUIRED]** Engine code and floating-point operation ordering change.

---

### 2. Try to route 28K ds4 requests through the persistent bounded context

[impact high] [effort low] [confidence medium] — The ds4 failure appears to be a routing/capacity interaction, not an inherent 32K model limit. The failing request is sent to a serial lazy session whose full graph cannot be allocated:

> `lazy session graph alloc failed (ctx=32768 prefill_cap=4096)`

The continuous path already supports chunked prefill. Source inspection suggests its persistent context allocates banks based partly on `DS4_SERVER_COALESCE_MAX`; reducing that value to `2` may raise the logged per-sequence `seq_cap` enough for a 28,672-token request while retaining the continuous path. Do not set it to `1`: that disables the persistent multi-request context and returns execution to the failing serial path.

Concrete next step after the holdout finishes:

1. Record the boot line containing `persistent batch ctx ready (... seq_cap=...)`.
2. Test `DS4_SERVER_COALESCE_MAX=2`.
3. Confirm that `seq_cap >= 28672` and rerun the 28K envelope prompt under the memory watchdog.

Keep `DS4_CONT_PREFILL_CHUNK=4096`. The source comment says 8192 was only about 2% faster while costing approximately 5.2 GiB extra—unacceptable with a hard-freeze OOM failure mode. `DS4_SESSION_LAZY_GRAPH=0` is also ruled out by your observed watchdog breach. `DS4_SERVER_SERIAL_MAX_TOKENS=28672` can provide clean rejection but does not fix execution.

I found no newer post-pin lazy-graph fix beyond the local `baa88902`/v0.2.2 branch state; monitor the [batched-serving branch](https://github.com/Entrpi/ds4/tree/batched-serving) and its [commit history](https://github.com/Entrpi/ds4/commits/batched-serving/).

**[FROZEN RERUN REQUIRED]** Server allocation/routing changes.

---

### 3. Increase llama.cpp physical ubatch for long-prompt prefill

[impact high for TTFT, low for decode] [effort low] [confidence medium] — Your llama.cpp command uses the default `-b 2048 -ub 512`. The very large gap between ds4 and llama.cpp at 16K—21.8s versus 57.8s TTFT—makes physical batch size the most promising flag-level prefill lever.

Test, in order:

```text
-b 2048 -ub 1024
-b 2048 -ub 2048
```

Keep the logical batch at 2048 initially. Larger `-b` values can produce very large V4 graphs and allocation spikes. The official llama.cpp DGX Spark benchmarking thread commonly uses `-fa 1 -ub 2048`, though on other models, so 2048 is a plausible Spark target rather than a guarantee for V4 ([DGX Spark benchmark discussion](https://github.com/ggml-org/llama.cpp/discussions/16578)). The current flag definitions are documented in the [server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md).

Do this after applying the hyper-connection fusion because the smaller graph may make larger ubatches safer.

**[FROZEN RERUN REQUIRED]** Benchmark TTFT, decode, peak unified memory, and watchdog floor separately.

---

### 4. Measure ds4 proposal acceptance before changing speculative depth

[impact medium-high] [effort low-medium] [confidence high] — DSpark combines the quantized target, its MTP head, and a separate drafter. Drafted tokens are verified by the target. At temperature zero, an accepted token must agree with the target argmax; the drafter therefore controls speed, not target-model fidelity. At sampling temperatures, ds4’s rejection/delta-proposal path is intended to preserve the target distribution, assuming implementation correctness.

Useful controls found in source:

```text
DS4_DSPARK_VERIFY_DEPTH=1..4
DS4_DSPARK_ADAPT_DEPTH=1
DS4_DSPARK_TRACE=1
DS4_DSPARK_PROFILE=1
DS4_DSPARK_QUENCH=1
DS4_DSPARK_MAX_KV=65536
```

Keep verify depth `4` as the initial production setting for one or two live sequences. Enable tracing first and collect accepted tokens per target verification, quench frequency, and time by depth. Only then try adaptive depth. Quench should remain enabled because it falls back toward plain target decode when acceptance is poor.

I found no user-facing “acceptance probability threshold” that should be tuned: target verification determines acceptance algorithmically. Weak drafter quality lowers acceptance and throughput; it should not substitute drafter logits into final output.

**[FROZEN RERUN REQUIRED]** Depth/adaptation changes performance and may expose numerical bugs; run deterministic output equality plus the speed suite.

---

### 5. Exploit stable prompt prefixes outside the frozen cold/unique protocol

[impact high when prefixes repeat] [effort low] [confidence high] — With one slot, a stable system/tool prefix and `cache_prompt: true` can avoid re-evaluating the common prefix. Cross-slot or evicted-prefix caching requires `--cache-ram`; your current `--cache-ram 0` deliberately disables it.

On unified memory, host prompt cache is not “free CPU RAM”—it consumes the same 119 GiB pool. If the serving workload has repeated long system/tool definitions, test a bounded cache such as:

```text
--cache-ram 1024
```

Use byte-identical prompt serialization and keep static system/tool content at the beginning. `--keep` is not a general prompt-cache control; it governs which initial tokens survive context shifting. `--slot-save-path` helps persistence across restarts but adds storage I/O and is not a decode-speed feature. See the [server flags](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md) and [prompt-caching guide](https://github.com/ggml-org/llama.cpp/discussions/13606).

An application-level exact-response cache is even faster for byte-identical temperature-zero requests. Its key must include the model revision, chat template, tools, sampler settings, stop rules, and prompt.

**[SEPARATE WORKLOAD BENCHMARK]** Do not let cache hits enter the frozen engine benchmark unless that protocol explicitly measures warm-prefix reuse.

---

### 6. llama.cpp cannot currently use V4-Flash’s MTP head or ds4 drafter

[impact high potential, unavailable now] [effort high] [confidence high] — llama.cpp has generic `--spec-type draft-mtp` support from [PR #22673](https://github.com/ggml-org/llama.cpp/pull/22673), but the current DeepSeek converter explicitly skips `mtp.*` tensors in [deepseek.py](/home/bmarti44/spark-deepseek-v4-flash/vendor/llama.cpp/conversion/deepseek.py:499). The installed Unsloth GGUF contains zero MTP/NextN tensors, and the DeepSeek-V4 support PR still lists MTP as unfinished ([PR #24162](https://github.com/ggml-org/llama.cpp/pull/24162)).

The newer DFlash speculative framework also does not yet provide a production V4 path; its current implementations target other model families, with V4 described as future integration work ([PR #22105](https://github.com/ggml-org/llama.cpp/pull/22105)). The ds4 drafter should not be assumed compatible with llama.cpp’s ordinary `--model-draft` interface.

Concrete next step: do not invest time trying to pass the ds4 drafter or MTP GGUF to current llama.cpp. Track converter plus runtime support for `deepseek4` MTP.

Target-only n-gram speculation is available now. A low-risk experiment is:

```text
--spec-type ngram-simple
```

Its defaults and alternatives are listed in [the local server README](/home/bmarti44/spark-deepseek-v4-flash/vendor/llama.cpp/tools/server/README.md:255). Expect the best gains on repetitive code or structured output, not general reasoning.

**[FROZEN RERUN REQUIRED]** N-gram speculation is intended to be lossless but changes execution.

---

### 7. Keep F16 cache; V4’s cache structure makes KV quantization unattractive

[impact low for speed/capacity] [effort low] [confidence high] — DeepSeek-V4’s llama.cpp cache is effectively **K-only** for raw/SWA, CSA, HCA, and Lightning Indexer state. The implementation explicitly removes V storage in [llama-kv-cache-dsv4.cpp](/home/bmarti44/spark-deepseek-v4-flash/vendor/llama.cpp/src/llama-kv-cache-dsv4.cpp:685). Therefore:

- `--cache-type-v` is effectively irrelevant for this model.
- Only `--cache-type-k` materially applies.
- Compressed recurrent/state tensors remain F32 and are not reduced by `-ctk`.

At 32K context and `-np 1`, the potential F16→Q8 saving is only on the order of hundreds of MiB, not tens of GiB. Extra dequantization can make speed neutral or worse, while quantization may alter close logits at temperature zero.

Recommendation:

```text
-ctk f16
```

If a later configuration needs the last fraction of a GiB, test `-ctk q8_0`. Do not start with q4. There are no published V4-specific long-context or accuracy results for quantized cache.

**[FROZEN RERUN REQUIRED]** Any `-ctk` change needs long-context, multi-turn, GSM8K/MMLU-Pro/HumanEval, and deterministic-output testing.

---

### 8. UD-Q2_K_XL is currently the best demonstrated fidelity/safety point

[impact high for fidelity and system safety] [effort low] [confidence high] — The local three-shard payload totals approximately 96.83 GB decimal, or **90.18 GiB**. Its GGUF metadata records an imatrix dataset with 768 entries and 214 chunks, so this is already an imatrix-informed dynamic quant; there is no missing “plain versus imatrix” upgrade to apply.

Published [Unsloth V4-Flash file sizes](https://huggingface.co/unsloth/DeepSeek-V4-Flash-GGUF) are:

| Quant | Decimal size | Approx. GiB | Fit assessment |
|---|---:|---:|---|
| UD-IQ2_M | 90.9 GB | 84.7 GiB | Safe capacity; likely some fidelity loss |
| UD-Q2_K_XL | 96.8 GB | 90.2 GiB | Best current balance |
| UD-IQ3_XXS | 103 GB | 95.9 GiB | Razor-thin OOM margin |
| UD-Q3_K_M / XL | 129 GB | 120.1 GiB | Cannot fit weights alone |

IQ3_XXS would leave about 23 GiB before runtime and OS allocations. Assuming roughly 6 GiB engine overhead and your mandatory 16 GiB free floor, only about 1 GiB of safety remains. With OOM meaning a hard freeze, this is not a production-safe configuration.

UD-IQ2_M saves about 5.5 GiB and might improve decode if entirely bandwidth-bound, but kernel throughput can offset the smaller payload. General—not V4-specific—Unsloth Dynamic 2.0 results show Q2_K_XL tending to retain quality better than IQ2_M on other architectures ([Dynamic 2.0 benchmarks](https://unsloth.ai/docs/basics/unsloth-dynamic-2.0-ggufs)). I found no apples-to-apples V4 MMLU/GSM8K/HumanEval quant comparison; available V4 reports are anecdotal, such as the [IQ3_XXS discussion](https://huggingface.co/unsloth/DeepSeek-V4-Flash-GGUF/discussions/7).

Concrete next step: retain UD-Q2_K_XL. Consider IQ2_M only as a speed/capacity experiment with the complete accuracy suite. Do not attempt Q3_K_XL on this host.

**[FROZEN RERUN REQUIRED]** Any weight quant change requires the full protocol.

---

### 9. Add a multi-turn/churn fidelity gate for llama.cpp

[impact high for real serving fidelity] [effort medium] [confidence high] — Early V4 llama.cpp builds could restore compressed attention states incorrectly during prompt-cache checkpointing, producing gibberish, stalls, or crashes ([issue #25452](https://github.com/ggml-org/llama.cpp/issues/25452)). Your pin already includes the relevant sequence-removal/checkpoint fix from [PR #25588](https://github.com/ggml-org/llama.cpp/pull/25588), so upgrading solely for that fix is unnecessary.

However, the current launch still uses the default 32 context checkpoints. The Unsloth model discussion recommends `--ctx-checkpoints 0` for affected builds and reports a major multi-turn/tool-use improvement after engine and template fixes ([discussion #2](https://huggingface.co/unsloth/DeepSeek-V4-Flash-GGUF/discussions/2)).

Concrete next step: create a regression that repeatedly extends, truncates, and reuses one slot across 15–30 turns, including tool-call templates. Keep checkpoints enabled if the pinned fix passes. Use:

```text
--ctx-checkpoints 0
```

only as a correctness fallback, because disabling checkpoints can force more prefix reprocessing and hurt latency. Also pin the exact revised chat template; changing it can materially change accuracy.

**[ACCURACY RERUN REQUIRED]** The existing single-turn v2 scores do not validate slot churn or template state restoration.

---

### 10. Flash attention is probably already active; make it explicit, not a headline optimization

[impact low unless auto-selection failed] [effort low] [confidence high] — llama.cpp defaults `-fa` to `auto`; your command omits the flag. On a supported CUDA backend it should already select fused attention. Explicit:

```text
-fa on
```

is useful to prevent silent fallback and make logs reproducible, but produces no speed gain if `auto` already selected it. Verify the startup log shows Flash Attention/fused operation placement before doing an A/B. The exact flag semantics are in the [server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md).

Do not use `-fa off` except as a diagnostic. V4’s hybrid sparse attention means not every operation maps to conventional FA, so the expected improvement is smaller than for a dense transformer.

**[FROZEN RERUN REQUIRED]** If startup logs show a behavioral change from auto to on.

---

### 11. Keep full GPU offload and one slot

[impact medium if misconfigured, no change currently] [effort low] [confidence high] — Current `-ngl 999 -np 1` is correct. Modern syntax can express the same intent as:

```text
-ngl all -np 1
```

Unified memory does not make CPU offload advantageous: it shares physical capacity, but CPU-offloaded layers lose CUDA kernel throughput and introduce synchronization. It does not create a second independent RAM pool. Likewise, increasing `-np` partitions attention/cache resources and trades single-request latency for aggregate concurrent throughput.

Avoid `--mlock` for a roughly 90 GiB model; pinning that much memory can starve the OS. Keep mmap enabled unless diagnosing load-time page behavior. Neither mmap setting should materially improve warmed steady-state decode.

Concrete next step: leave these settings unchanged. Test `-np 2` only if the workload changes from one client to concurrent requests.

---

### 12. Native `sm_121` is correct; `121a-real` is a low-priority build experiment

[impact low currently] [effort medium] [confidence medium-high] — `CMAKE_CUDA_ARCHITECTURES=121` is a valid native GB10 build target. CUDA 13 also exposes architecture-specific `sm_121a`/`sm_121a-real` targets that permit family-specific Tensor Core features ([NVCC 13 documentation](https://docs.nvidia.com/cuda/archive/13.0.0/cuda-compiler-driver-nvcc/index.html), [compute-capability documentation](https://docs.nvidia.com/cuda/archive/13.2.1/cuda-programming-guide/05-appendices/compute-capabilities.html)).

I did not find current ggml CUDA kernels explicitly using the relevant architecture-specific instructions, so rebuilding with:

```text
-DCMAKE_CUDA_ARCHITECTURES=121a-real
```

is unlikely to rival the hyper-connection or ubatch wins. `native` is another reproducible option when building directly on the Spark.

Do not blindly force `GGML_CUDA_FORCE_MMQ`; automatic selection can prefer different kernels for decode and prefill, while forcing MMQ may improve one and hurt the other.

**[FROZEN RERUN REQUIRED]** Build flag/kernel selection changes.

---

### 13. No DGX Spark system switch is likely to produce an engine-scale gain

[impact low-medium] [effort low] [confidence high] — Driver `580.159.03` matches NVIDIA’s current DGX Spark software release line ([release notes](https://docs.nvidia.com/dgx/dgx-spark/release-notes.html)). The hardware has a 140W SoC and ships with a 240W adapter ([hardware guide](https://docs.nvidia.com/dgx/dgx-spark/hardware.html)); use that adapter and monitor clocks, P-state, temperature, and throttling throughout benchmarks.

Keep the display reservation at the current 2 GiB default rather than raising it to 4 GiB. MIG is intended to partition GPU resources; it cannot improve a single model that needs essentially the whole GPU and memory budget ([supported MIG profiles](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/supported-mig-profiles.html)). There is no useful second memory pool to unlock with pinning.

Concrete next step: record thermal/clock telemetry alongside each run. Investigate system settings only if clocks fall materially during the 16K/28K tests.

---

### 14. HTTP/2 and streaming aggregation are negligible compared with model time

[impact low] [effort low] [confidence high] — At 13–19 tokens/s, each output token costs roughly 53–77 ms. HTTP framing and local SSE chunk emission are a small fraction of that. HTTP/2 may improve connection multiplexing, but with one client and one slot it cannot accelerate model execution.

Client-side aggregation of several token deltas can reduce downstream parser/UI overhead but increases visible streaming latency. Continuous batching likewise helps aggregate throughput only when requests overlap.

Concrete next step: retain streaming for responsiveness. Profile HTTP only if engine-side timing and client-observed timing diverge by several percent.

---

### 15. No third engine is presently competitive on one GB10

[impact low now] [effort avoided high] [confidence high] — vLLM has DeepSeek-V4 and MTP code, but a real DGX Spark report uses **two** GB10 systems with TP2, achieves roughly 5 tokens/s, and reports CUDA-graph trouble ([vLLM issue #40969](https://github.com/vllm-project/vllm/issues/40969); [V4 MTP API](https://docs.vllm.ai/en/latest/api/vllm/models/deepseek_v4/nvidia/mtp/)). It also lacks a demonstrated route for this 2-bit GGUF on one Spark.

SGLang’s V4 support is validated on multi-GPU datacenter configurations rather than one GB10 ([release notes](https://github.com/sgl-project/sglang/releases), [V4 tracker](https://github.com/sgl-project/sglang/issues/23743)). TensorRT-LLM has emerging V4 support, but no single-GB10 recipe consuming the required sub-4-bit GGUF format ([TensorRT-LLM releases](https://github.com/NVIDIA/TensorRT-LLM/releases)).

Concrete next step: stay with ds4 and llama.cpp. Revisit alternate engines only when one publishes a single-GB10, sub-100-GiB V4 configuration.

## Top 5 actions for speed

1. **Rebuild llama.cpp at `0dc74e3` for fused V4 hyper-connections.** Highest-probability decode plus prefill engine improvement. **[FROZEN RERUN]**
2. **Sweep `-ub 1024`, then `-ub 2048`, after the fusion.** Target the 16K/28K TTFT deficit while watching peak memory. **[FROZEN RERUN]**
3. **Test ds4 with `DS4_SERVER_COALESCE_MAX=2` and verify `seq_cap >= 28672`.** Potentially fixes the long-context failure without eager-graph OOM. **[FROZEN RERUN]**
4. **Profile DSpark acceptance at verify depth 4, then test adaptive depth.** Keep quench enabled and compare deterministic outputs. **[FROZEN RERUN]**
5. **Use stable-prefix caching for repeated system/tool prompts.** Start with one slot and `cache_prompt:true`; only add a bounded `--cache-ram` if cross-session reuse justifies unified-memory cost. **[SEPARATE WORKLOAD BENCHMARK]**

## Top 3 actions for fidelity

1. **Keep UD-Q2_K_XL with `-ctk f16`.** It is already imatrix-informed, fits with a defensible safety margin, and has strong measured v2 accuracy.
2. **Add a multi-turn/slot-churn/template regression.** Keep context checkpoints if the pinned fix passes; use `--ctx-checkpoints 0` only if corruption persists. **[ACCURACY RERUN]**
3. **Require deterministic equivalence for every speculative change.** Compare ds4 plain target, DSpark depths, and llama n-gram speculation on exact prompts before accepting throughput gains. **[FROZEN + ACCURACY RERUN]**