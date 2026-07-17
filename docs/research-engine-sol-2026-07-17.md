| Engine | 1. DeepSeek‑V4‑Flash on one GB10 | 2. Fits 119 GiB / quantization | 3. GB10 UMA safety | 4. Context, caching, persistence | 5. Relevant performance | 6. Operational fit |
|---|---|---|---|---|---|---|
| **llama.cpp, pinned `32e789fd`** | **Yes—verified locally.** Explicit CSA/HCA, Lightning Indexer, and compressor-state implementation. | **Yes.** UD‑Q2_K_XL GGUF is 90.18 GiB. | **Verified on this box.** Still needs conservative memory admission because OOM freezes the machine. | Architectural 1M; recommend 256K production gate, 512K only after qualification. Complete DSV4 slot serialization and restart restore. No automatic hierarchical disk cache. | **Local:** 290.8 prefill / 13.88 decode tok/s at 4K; 274.8 / 13.15 at 28K. | OpenAI-compatible, native API key, systemd-friendly, known CUDA 13/sm_121 build. |
| **DwarfStar / ds4** | **Yes—older candidate verified locally.** Current upstream is **UNVERIFIED locally**. | **Yes.** Approximately 80.76 GiB base 2-bit model; about 90.8 GiB with optional MTP/drafter. | **Not robust enough yet.** Tested build failed graph allocation at 28K; eager mode crossed the watchdog threshold. | Current upstream has exact V4 disk sessions across restarts, but one mutable in-memory cache and serialized inference. Recommends roughly 100–300K on 128 GB. | Valid local 4K runs reached 779 prefill / 18.7 decode, but produced invalid early stops; all 28K runs failed. Current upstream’s public single run reports 344 / 13.75. | OpenAI/Anthropic APIs, but no native authentication found; beta and changing quickly. |
| **vLLM** | **No verified single-Spark path.** V4 ran on **two** Sparks using an SM12x patch. | **No today.** Official/NVFP4 checkpoints are about 160–168 GB. V4 GGUF/Q2 support is **UNVERIFIED and apparently missing from the current GGUF mappings**. | Designed around separate VRAM/host pools. CPU offload does not add capacity on UMA. | V4 1M and prefix caching exist on supported datacenter GPUs. Multi-tier V4 KV offload exists; durable cross-restart discovery/restore is **UNVERIFIED**. Sleep mode discards KV. | Two-Spark report: approximately 4.5–5 decode tok/s; no comparable single-Spark prefill result. | Excellent API server and API keys, but currently needs patching/build work for SM121. |
| **SGLang** | **No verified upstream SM121 path.** V4 exists, but the roadmap still leaves SM121 open. | **No documented 2-bit V4 checkpoint/loader capable of fitting one Spark.** | **UNVERIFIED.** Its GPU/host hierarchy assumes physically distinct tiers. | RadixAttention/HiCache are attractive, but current V4 hierarchical-cache issues remain; restart-safe exact V4 state is **UNVERIFIED**. | No V4-on-Spark benchmark found. | OpenAI-compatible and supports API keys, but the required kernel/quantization path is absent. |
| **TensorRT‑LLM** | V4 support and DGX Spark beta support exist separately; **their intersection is not validated**. | **No.** Current V4 FP4/NVFP4 packages exceed 119 GiB; no supported approximately 2-bit route. | Has UVM and host/disk cache controls, but V4-on-GB10 behavior is **UNVERIFIED**. | V4-specific compressed/indexer cache manager exists. Disk KV is still prototype-level; cross-restart V4 restore on Spark is **UNVERIFIED**. | No V4 GB10 result found. | Strong packaged server; V4 Spark profile and built-in auth story are **UNVERIFIED**. |
| **KTransformers** | **No.** V4 recipe is validated on x86/AVX‑512 plus RTX 5090, not aarch64 GB10. | **No.** Its published recipe needs at least 256 GB system RAM for the official weights. | CPU/GPU offload gains no extra physical pool on Spark. | Published example is 16K and disables radix caching; no persistent exact V4 cache workflow found. | Maintainer reports “20+ tok/s” on RTX 5090—**not transferable to Spark**. | Large porting effort; inherits SGLang serving constraints. |
| **MLC‑LLM** | **No explicit V4 architecture implementation found.** This is an **UNVERIFIED negative** based on current repository/docs search. | No documented V4 2-bit compiled package or GGUF route. | **UNVERIFIED.** | No verified CSA/HCA/indexer cache or disk-state support. | None found. | REST server exists, but this would be a model/kernel port rather than deployment. |
| **NVIDIA NIM / Dynamo** | V4 NIMs exist generally, but no certified single-Spark V4 profile was found. | Does not solve the underlying 160–168 GB checkpoint problem. | NVIDIA documents Spark support generally, but NIM also lists unhealthy-after-OOM behavior. | No verified restartable V4 cache solution for this exact profile. | No V4 single-Spark result found; generic Spark marketing figures are not relevant. | Operationally polished when a supported profile exists; this one does not. |
| **Ollama** | Exact V4 support in its current vendored llama.cpp is **UNVERIFIED**. | Could inherit GGUF fit only if its backend contains the required V4 code. | Inherits llama.cpp behavior. | Does not expose llama.cpp’s slot save/restore interface needed by this product. | No relevant result. | Easy packaging, but no native auth and it obscures the load-bearing cache controls. |

`UNVERIFIED` means I found no primary-source or exact-box demonstration—not that the feature is theoretically impossible. Status is as of 2026‑07‑16.

## Bottom line

**Keep upstream llama.cpp.** It is the only candidate demonstrated on this exact single Spark with all three non-negotiables:

1. a 284B V4 checkpoint that fits safely enough to run,
2. correct CSA/HCA/Lightning Indexer execution and cache-state semantics, and
3. complete disk-serializable V4 state across process restarts.

No competing engine currently justifies your full benchmark rerun. DwarfStar is the only serious challenger, but its local long-context failure disqualifies it before performance matters.

## llama.cpp

**Model support and fit.** The pinned source has a dedicated DeepSeek‑V4 model implementation, Lightning Indexer execution, and a V4-specific cache implementation. The serializer includes sliding-window state, CSA K, HCA K, indexer K, and all three compressor states: [deepseek4.cpp](/home/bmarti44/spark-deepseek-v4-flash/vendor/llama.cpp/src/models/deepseek4.cpp:565), [llama-kv-cache-dsv4.cpp](/home/bmarti44/spark-deepseek-v4-flash/vendor/llama.cpp/src/llama-kv-cache-dsv4.cpp:1317). This support arrived through upstream [PR #24162](https://github.com/ggml-org/llama.cpp/pull/24162).

The local UD‑Q2_K_XL shards total 96.83 GB decimal, or **90.18 GiB**, consistent with the published [Unsloth V4 GGUF collection](https://huggingface.co/unsloth/DeepSeek-V4-Flash-GGUF). The build is pinned and recorded for aarch64, CUDA 13, and architecture 121 in [llamacpp.json](/home/bmarti44/spark-deepseek-v4-flash/configs/build-manifests/llamacpp.json).

**UMA.** It has already exercised the actual allocation path on this Spark. That evidence is more valuable than nominal SM121 support elsewhere. NVIDIA confirms that Spark’s CPU and GPU share a dynamic 128 GB pool rather than separate VRAM and host RAM; `cudaMemGetInfo` may also understate reclaimable memory ([Spark porting guide](https://docs.nvidia.com/dgx/dgx-spark-porting-guide/overview.html), [optimization guidance](https://docs.nvidia.com/dgx/dgx-spark-porting-guide/optimization.html)). Consequently, “CPU offload” is not extra capacity here.

**Context and persistence.** The model declares 1,048,576 positions in its [official configuration](https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash/blob/main/config.json). Locally measured cache growth is approximately 6,880 bytes/token, so a 1M cache is roughly 6.7 GiB. Nevertheless, the current full-memory projection leaves only about 10.5–12 GiB available at 1M—below the project’s 16 GiB production floor once weights, graphs, scratch space, filesystem cache, and transient allocations are counted. See the [long-context plan](/home/bmarti44/spark-deepseek-v4-flash/docs/bigctx-plan-sol-2026-07-16.md).

Therefore:

- Ship with a **256K hard production gate**.
- Treat **512K as conditional**, enabled only after full prefill, save/restore, and concurrency/soak qualification.
- Keep **1M as an architectural/retrieval target**, not an accepted request size today.

The server exposes `--slot-save-path` and `/slots/{id}?action=save|restore`, documented in the [llama.cpp server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md). This is a correct whole-state persistence primitive, not an automatic content-addressed disk hierarchy.

Two important limitations:

- **Restore-in-seconds at a full 1M cache is UNVERIFIED end-to-end.** The serializer exists, but the SLA still needs measurement on the actual NVMe filesystem.
- Saving a roughly 6.7 GiB whole-state file after every 1M-context turn would cause substantial latency and write amplification. Keep every turn in the live slot/transcript, but checkpoint disk state at controlled boundaries—ingest completion, idle transition, high-water mark, or explicitly pinned conversations—unless incremental state writing is added.

Treat saved files as tied to the exact model/build. Cross-version slot-file compatibility is **UNVERIFIED**.

**Performance.** Exact local medians are in [speed-llamacpp.json](/home/bmarti44/spark-deepseek-v4-flash/results/speed-llamacpp.json):

- 4K: **290.8 prefill / 13.88 decode tok/s**
- 16K: **284.4 / 13.51**
- 28K: **274.8 / 13.15**

At short-context speed, 1M prefill would already take about an hour. The measured/modelled long-context slowdown makes **3–5 hours** a more realistic planning range, so the cost router is essential even though KV memory is compressed.

**Operations.** The native OpenAI-compatible server supports API keys and fits systemd cleanly. Retaining Caddy in front remains sensible for TLS, centralized authentication, request limits, and protection of non-OpenAI administrative endpoints.

## DwarfStar / ds4

DwarfStar is the only alternative specifically optimized around DeepSeek‑V4 rather than retrofitting it. Its current [repository](https://github.com/antirez/ds4) advertises a Spark build, approximately 81 GB 2-bit base weights, exact V4 disk sessions, OpenAI/Anthropic endpoints, and persistence across session switching and restart.

The exact local candidate performed impressively on valid short runs:

- 4K: **778.6 prefill / 18.74 decode tok/s**
- 16K: **785.7 / 16.18**

But some 4K/16K runs ended early, and **all five 28K runs failed** because lazy graph allocation could not be satisfied; eager allocation breached the watchdog. Evidence: [speed-ds4-dspark.json](/home/bmarti44/spark-deepseek-v4-flash/results/speed-ds4-dspark.json), [envelope-exception-ds4.json](/home/bmarti44/spark-deepseek-v4-flash/results/envelope-exception-ds4.json).

Current upstream has evolved substantially from the tested commit. Its public Spark example reports approximately **343.8 prefill / 13.75 decode tok/s** for a 7K prompt—only about 18% above local llama.cpp prefill and slightly below llama.cpp decode. That is a maintainer-provided single run, not your protocol.

Current ds4’s session design is operationally attractive, but it still has one live mutable cache, serialized inference, no native authentication found, and describes itself as beta. It also estimates approximately 26 GB for a full 1M cache—much larger than llama.cpp’s representation—and recommends roughly 100–300K on 128 GB.

**Decision:** keep it on the watchlist, but do not spend a full rerun until upstream demonstrates a fixed long-context allocation path, valid responses at ≥256K, and restart restore under a controlled Spark memory ceiling.

## vLLM

vLLM now has explicit DeepSeek‑V4 support and 1M-context work, but its own [V4 announcement](https://vllm-project.github.io/2026/04/24/deepseek-v4.html) uses four B200/B300 GPUs for Flash. That is a different memory and bandwidth regime.

The closest Spark evidence is [issue #40969](https://github.com/vllm-project/vllm/issues/40969): V4 ran across **two** DGX Sparks with a local SM12x/Marlin patch. Reported decode was approximately 4.5–5 tok/s, and one compilation mode hung after repeated requests. It does not establish a single-Spark path.

Fit is decisive:

- Official DeepSeek weights are around 160 GB ([model repository](https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash/tree/553034d7dd9e06c2eeaee68cf85a17d6d4754cf0)).
- NVIDIA’s NVFP4 package is about 168 GB ([NVFP4 repository](https://huggingface.co/nvidia/DeepSeek-V4-Flash-NVFP4/tree/main)).
- No verified V4 2-bit AWQ/GPTQ package and compatible kernel were found.
- vLLM describes GGUF as highly experimental and underoptimized ([GGUF documentation](https://docs.vllm.ai/en/latest/features/quantization/gguf/)); it is moving into an [out-of-tree plugin](https://github.com/vllm-project/vllm-gguf-plugin).
- The current [GGUF loader](https://github.com/vllm-project/vllm/blob/main/vllm/model_executor/model_loader/gguf_loader.py) contains architecture-specific MoE mappings for DeepSeek V2/V3 but no V4 mapping. Therefore V4 GGUF/Q2 loading is **UNVERIFIED and source inspection indicates incomplete support**.

vLLM has added multi-tier KV offload, including DSV4 work ([PR #41735](https://github.com/vllm-project/vllm/pull/41735), [PR #43142](https://github.com/vllm-project/vllm/pull/43142)). Those demonstrations were on H100-class systems. Durable cache discovery and exact restart restoration are **UNVERIFIED**. Its [sleep mode](https://docs.vllm.ai/en/latest/features/sleep_mode/) frees or discards KV rather than persisting it.

Operationally, vLLM has a mature OpenAI server and API keys, although its [security documentation](https://docs.vllm.ai/en/stable/usage/security/) recommends additional protection because the API key does not cover every sensitive endpoint.

**Decisive rejection:** there is no verified single-Spark V4 weight format that fits.

## SGLang

SGLang has native V4 work, RadixAttention, and HiCache. On datacenter GPUs, that combination is conceptually closer to your desired automatic cross-request hierarchy than llama’s manual slots.

On Spark, however, the current [hardware roadmap](https://github.com/sgl-project/sglang/issues/23602) lists community SM120 work while leaving SM121 unresolved. No upstream V4-on-GB10 demonstration was found. There is also no documented V4 approximately 2-bit checkpoint/loader path that fits 119 GiB.

HiCache provides L1 GPU, L2 host, and external storage tiers, but the host tier is not additional physical memory on Spark. Current V4 hierarchical-cache problems are visible in [issue #26690](https://github.com/sgl-project/sglang/issues/26690); long-context downstream SM120 instability is also reported in [issue #26427](https://github.com/sgl-project/sglang/issues/26427). Exact cross-restart restoration of V4 compressor/indexer state is **UNVERIFIED**.

The server does support API keys and cache sizing controls ([server arguments](https://github.com/sgl-project/sglang/blob/main/docs/advanced_features/server_arguments.md)).

**Decisive rejection:** no verified SM121 V4 execution and fitting quantization path.

## TensorRT‑LLM

TensorRT‑LLM’s [supported-model table](https://nvidia.github.io/TensorRT-LLM/latest/models/supported-models.html) now includes DeepSeek V4 on Blackwell. Its [V4 example](https://github.com/NVIDIA/TensorRT-LLM/tree/main/examples/models/core/deepseek_v4) contains dedicated compressed, indexer, and compressor cache management rather than treating V4 as ordinary attention.

But NVIDIA’s Spark support is beta, and its [release notes](https://nvidia.github.io/TensorRT-LLM/release-notes.html) do not list V4 among validated single-Spark configurations. The current V4 example begins with an eight-B200, 4K-context bring-up. No V4 GB10 result was found.

The official FP4/NVFP4 checkpoints exceed 119 GiB, and TensorRT‑LLM has no supported GGUF Q2_K or comparable V4 2-bit route. That alone prevents deployment.

TensorRT‑LLM exposes UVM, host-cache, and prototype disk-cache controls in its [LLM API](https://nvidia.github.io/TensorRT-LLM/latest/llm-api/reference.html). Exact V4 disk restoration across a Spark process restart is **UNVERIFIED**. `trtllm-serve` provides OpenAI-compatible endpoints ([server documentation](https://nvidia.github.io/TensorRT-LLM/commands/trtllm-serve/trtllm-serve.html)); built-in authentication for this deployment is **UNVERIFIED**, so assume a reverse proxy.

**Decisive rejection:** no V4 checkpoint small enough for one Spark.

## KTransformers

KTransformers added V4 in [v0.6.2](https://github.com/kvcache-ai/ktransformers/releases). Its [V4 tutorial](https://github.com/kvcache-ai/ktransformers/blob/main/doc/en/DeepSeek-V4-Flash.md) targets an x86 AVX‑512 host with at least 256 GB RAM and an RTX 5090. The example uses 16K context, disables radix caching, and reports “20+ tok/s.”

None of that transfers to an aarch64 GB10 with a single 119 GiB UMA pool. Offloading experts to “CPU memory” still consumes the same physical pool, and GB10 lacks the x86 kernels used in the demonstrated configuration.

**Decisive rejection:** its validated architecture and memory requirement do not match this machine.

## MLC‑LLM

I found no DeepSeek‑V4 architecture, CSA/HCA, or Lightning Indexer implementation in the current [MLC‑LLM repository](https://github.com/mlc-ai/mlc-llm). This is an **UNVERIFIED negative** because repository state can change, but there is no documented V4 package or issue/PR establishing support.

MLC’s model process requires explicit architecture lowering and compilation ([compilation documentation](https://llm.mlc.ai/docs/compilation/compile_models.html)); its quantizations are compiled MLC formats, not a route for loading the existing V4 GGUF. Its [REST server](https://llm.mlc.ai/docs/deploy/rest.html) does not compensate for the missing model and cache implementation.

**Decisive rejection:** V4 would first require a new backend/model port.

## NVIDIA NIM, Dynamo, and Spark playbooks

NVIDIA’s [DGX Spark playbooks](https://github.com/NVIDIA/dgx-spark-playbooks) package llama.cpp, vLLM, SGLang, TensorRT‑LLM, and NIM workflows; they are not an additional inference engine.

NIM’s [release notes](https://docs.nvidia.com/nim/large-language-models/1.15.0/release-notes.html) mention V4 models and expanded Spark support, but the [Spark deployment matrix](https://docs.nvidia.com/nim/large-language-models/latest/deploy-on-dgx-spark.html) does not establish a certified single-Spark V4 profile. NIM also documents an unhealthy-after-OOM condition, particularly relevant on this freeze-on-OOM box.

Dynamo’s V4 hybrid-cache/router integration remains active work; for example, [issue #8667](https://github.com/ai-dynamo/dynamo/issues/8667) tracks V4 hybrid-cache routing. It is orchestration around an underlying engine, not a fitting 2-bit single-box implementation.

**Decisive rejection:** no supported V4 single-Spark profile exists underneath the packaging.

## Ollama

[Ollama](https://github.com/ollama/ollama) uses llama.cpp as a backend. It cannot improve the underlying kernel, fit, or cache representation. Exact V4 support depends on which llama.cpp revision Ollama vendors and is **UNVERIFIED**.

More importantly, Ollama does not expose the `/slots` save/restore control needed for exact background-ingest states and cross-restart restoration. It also assumes an external security boundary rather than providing this product’s authenticated service model.

**Decisive rejection:** it hides the specific llama.cpp state-management primitive the product requires.

## Ranked recommendation

1. **Pinned upstream llama.cpp — deploy.**  
   Decisive advantage: only implementation proven to fit and preserve every V4-specific cache component on this exact box.

2. **DwarfStar — watch, no full rerun yet.**  
   Decisive rejection: failed the local 28K allocation envelope and emitted invalid shorter runs.

3. **vLLM — reconsider only with additional hardware or a proven V4 2-bit loader.**  
   Decisive rejection: no fitting single-Spark checkpoint path.

4. **TensorRT‑LLM — reconsider if NVIDIA ships a certified GB10 V4 profile and smaller quantization.**  
   Decisive rejection: supported weights exceed physical memory.

5. **SGLang — reconsider after upstream SM121 plus V4 HiCache stabilization.**  
   Decisive rejection: missing verified GB10 execution path.

6. **KTransformers.**  
   Decisive rejection: x86/256 GB architecture mismatch.

7. **MLC‑LLM.**  
   Decisive rejection: no explicit V4 backend.

8. **NIM/Dynamo.**  
   Decisive rejection: packaging does not solve the unsupported engine/weight combination.

9. **Ollama.**  
   Decisive rejection: removes required cache-state controls without adding capability.

## Practical hybrid options

A vLLM/SGLang remote prefill followed by local llama.cpp decode is **not practical today**. No supported converter exists between their paged/hierarchical V4 caches and llama.cpp’s serialized DSV4 state. Their quantizations, block layouts, compressor histories, and Lightning Indexer state are also engine-specific. A text/token handoff would force llama.cpp to prefill again, eliminating the benefit. Whether a custom converter is theoretically possible is **UNVERIFIED**.

The practical hybrids are:

- Run semantic/retrieval skim remotely, then give selected text to local llama.cpp.
- Route an entire request—including decode—to a remote engine when latency/cost permits.
- Perform background ingest using the **same pinned llama.cpp build and model**, then save its slot state for later local restoration.

So the recommended architecture is: **llama.cpp as the sole cache-owning engine; retrieval as the long-context escape hatch; 256K production admission initially; controlled disk checkpoints; and no full alternative-engine rerun at present.**