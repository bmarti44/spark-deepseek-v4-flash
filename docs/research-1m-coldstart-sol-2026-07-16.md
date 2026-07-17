# Executive conclusion

A true, exact, raw-token 1M cold prefill in single-digit seconds is not credible on one or two DGX Sparks. At 13B active parameters, even the optimistic `2 × 13B × 1M ≈ 26 PFLOP` lower bound is 26 seconds at the Spark’s advertised 1-PFLOP sparse-FP4 peak—with perfect utilization and zero attention, indexing, routing, communication, or quantization overhead. The current stack achieves roughly 750 tok/s, making 1M about 1,333 seconds.

“Seconds” becomes realistic only in one of three ways:

1. The exact cache was computed before the query.
2. The online model receives only 4K–32K retrieved/selected tokens.
3. A remote accelerator has already produced a compatible cache and it reaches the Spark over at least 10 Gbps.

I will distinguish:

- **Strict cold:** no cache exists; every token must be processed after query arrival.
- **State cold:** cache exists on disk or remotely but is not resident.
- **Semantic shortcut:** the model sees summaries or selected tokens rather than true 1M attention.

The local baseline is supported by the saved [DS4 measurements](/home/bmarti44/spark-deepseek-v4-flash/results/speed-ds4-dspark.json:156) and [llama.cpp measurements](/home/bmarti44/spark-deepseek-v4-flash/results/speed-llamacpp.json:155). One caveat: the recorded DS4 run hit a graph-allocation failure at 28,672 tokens, so 1M is currently an extrapolation, not a demonstrated engine result.

## Why V4-Flash’s cache changes the answer

DeepSeek-V4-Flash does not leave an independently reusable K/V pair for every source token. Its CSA compresses sequence entries at a 4:1 rate; HCA introduces much coarser 128-token entries; Lightning Indexer selects compressed entries for attention; SWA state and incomplete compression tails also remain live. See the [official V4 report](https://arxiv.org/html/2606.19348) and [vLLM’s V4 implementation account](https://vllm-project.github.io/2026/04/24/deepseek-v4.html).

The vLLM implementation consequently treats 256 native tokens as a logical cache boundary and manages several cache/state kinds. This has five implications:

- A token cannot necessarily be extracted or replaced independently; reuse must be aligned to compressed blocks.
- Splicing requires CSA entries, HCA entries, Lightning Indexer keys, SWA state, and compressor tails—not just relocated RoPE keys.
- A document encoded alone has different layer states from the same document following other documents.
- Moving a module changes compression grouping unless lengths and boundaries are carefully padded.
- Small numerical changes can alter Lightning top-k choices near score ties.

This is why ordinary position-independent caching papers are informative but not drop-in solutions.

# 1. Precomputation and reuse beyond exact prefixes

| Idea | Assessment at 1M | Mechanism, V4 fit/break, first experiment |
|---|---|---|
| Exact-prefix trees: RAGCache/Preble | **[~1–8 s hit; ≥1,333 s miss] [none if exact] [low–medium] [exists today]** | [RAGCache](https://arxiv.org/abs/2404.12457) and [Preble](https://arxiv.org/abs/2407.00023) improve storage placement and prefix-hit scheduling, not composability. They fit V4 because stored model-native state remains unchanged. They cannot reuse documents in a different order. **Experiment:** generate a corpus with repeated prefixes of 32K/64K/128K, persist every complete 256-token boundary, then compare hit TTFT and byte count against full prefill using the existing [speed harness](/home/bmarti44/spark-deepseek-v4-flash/scripts/30_bench_speed.py:23). |
| CacheBlend / EPIC / Cache-Craft / FusionRAG | **[roughly 140–600 s if published speedups transferred] [medium] [very high] [research prototype]** | [CacheBlend](https://arxiv.org/abs/2405.16444), [EPIC](https://arxiv.org/abs/2410.15332), [Cache-Craft](https://arxiv.org/abs/2502.15734), and [FusionRAG](https://arxiv.org/abs/2601.12904) combine separately cached chunks and recompute selected boundary or high-impact tokens. Reported gains range from a few times to about 9×; that is still minutes from a 1,333-second baseline. V4 requires block-aligned recomputation with compressor halos and all auxiliary states. Recomputing one token may invalidate its C4 group, C128 group, and later contextualized entries. **Experiment:** cache two 256-aligned documents separately, splice `A+B`, recompute one then progressively larger boundary halos, and compare logits/top-k index selections with a true `A+B` prefill. |
| PromptCache modular schemas | **[load-scale seconds] [medium–high semantic risk] [high] [exists for conventional attention]** | [Prompt Cache](https://proceedings.mlsys.org/paper_files/paper/2024/hash/a66caa1703fe34705a4368c3014c1966-Abstract-Conference.html) reserves positions for reusable modules and controls inter-module attention. It is fast precisely because it changes which modules contextualize each other. That makes it unsuitable when fidelity means equivalence to ordinary 1M causal attention. V4 additionally needs fixed C4/C128 alignment. **Experiment:** compare three prompts—normal concatenation, independently cached modules, and an explicitly masked “modular semantics” baseline—to determine whether the application can tolerate the changed attention graph. |
| MiniPIC/SparseX-style position-independent modules | **[potentially tens of seconds at very high reuse; unproven] [medium] [very high] [research-only for V4]** | [MiniPIC](https://arxiv.org/abs/2606.13126) stores unrotated keys and applies positions at attention time; [SparseX](https://arxiv.org/abs/2606.01751) combines reusable segments with selective query recomputation. Partial-RoPE correction alone is insufficient for V4 because compression grouping, indexer state, residual tails, and learned attention-sink behavior remain position/context dependent. **Experiment:** first test pure relocation without compositional context: encode one 256-token-aligned module at two positions and compare every serialized state component. This isolates position dependence before attempting cross-document reuse. |
| Approximate/fuzzy cache reuse | **[~200 s if 6× scaling held] [high] [high] [research-only]** | [SemShareKV](https://aclanthology.org/2025.findings-ijcnlp.25/) uses semantic matching to substitute approximately similar token states. It reports substantial reuse on short workloads, but a V4 compressed entry represents a group rather than one semantic token. Wrong reuse can affect both memory contents and later Lightning selection. This is unsuitable for exact extraction, counting, legal, or code tasks. **Experiment:** perform nearest-neighbor reuse only for complete 256-token blocks and evaluate adversarial near-duplicate documents differing in one number, negation, or function body. |
| CacheGen-style cache loading | **[3–60 s transfer, plus zero or full prefill depending on cache hit] [low if lossless; medium if quantized] [medium–high] [codec exists, V4 port does not]** | [CacheGen](https://cs.stanford.edu/~keithw/sigcomm2024/sigcomm24-final1571-acmpaginated.pdf) compresses conventional KV streams and reports 3.5–4.3× size reduction, but only about 1.7–1.8× load-delay reduction. It fits V4 conceptually because the native cache is already small; its codec would need retraining for V4’s heterogeneous latent/indexer states. **Experiment:** entropy-profile each serialized state tensor separately and test lossless compression first. Then quantize one state kind at a time while running the [golden cache-consistency test](/home/bmarti44/spark-deepseek-v4-flash/scripts/32_golden_tests.py:479). |
| Editable “notes” and KV cartridges | **[tens to hundreds of seconds] [medium–high] [extreme] [research-only]** | [Models Take Notes at Prefill](https://arxiv.org/abs/2606.17107) treats cached state as editable memory but explicitly identifies DeepSeek-V4-style sequence-dimension compression as an open frontier. [Cartridges at Scale](https://arxiv.org/abs/2606.04557) trains compact document-specific KV memories for million-token corpora, trading several accuracy points for much smaller online prompts. A V4 cartridge would have to synthesize valid CSA/HCA/indexer state and probably require fine-tuning the target Q2 model. **Experiment:** begin on one layer and one 256-token block: train a small adapter to predict its compressed memory state, then measure state error, Lightning top-k agreement, and next-token KL divergence. |

### Practical verdict on composable caching

A V4-native CacheBlend/PIC implementation is plausible, but the unit of composition should be approximately:

```text
256 source tokens
  + CSA/HCA compressed entries
  + indexer keys/metadata
  + SWA state
  + compressor residual/tail
  + a recomputed boundary halo
```

Even then, separately encoded middle documents are not exact. To reach seconds from 1,333 seconds, at least 99% of work must disappear; current PIC systems generally do not demonstrate that combination of hit rate, full causal fidelity, and V4-style compressed state.

# 2. Sparse and selective prefill

The Lightning Indexer solves a different problem from prefill skipping. It reduces the compressed memories each query attends to, but each source token still needs hidden states from earlier layers, MoE computation, compression, and index construction. The indexer cannot know the final query’s useful entries before those entries exist.

| Idea | Assessment at 1M | Mechanism, V4 fit/break, first experiment |
|---|---|---|
| Lightning Indexer / Quest / SnapKV | **[~1,333 s cold prefill unchanged] [low] [already present] [today]** | [Quest](https://arxiv.org/abs/2406.10774) selects KV pages at decode time; [SnapKV](https://arxiv.org/abs/2404.14469) observes attention near the prompt end and retains a smaller decode cache. V4’s Lightning Indexer is already the native analogue. All require the original cache to have been produced. **Experiment:** record the union of entries selected by the user query across layers and compare it with prefill time; this quantifies how much decode attention is sparse while demonstrating that TTFT remains unchanged. |
| SpecPrefill | **[best reported scaling: ~174 s plus selector] [medium–high] [medium] [prototype exists]** | [SpecPrefill](https://arxiv.org/abs/2502.02789) uses a cheaper model to retain only important original-position chunks for the large model. It reports up to 7.66× TTFT improvement with generally small average degradation, but aggregation/counting tasks degrade at aggressive retention. It is compatible with V4 because omitted tokens never enter V4’s cache; it is not equivalent to 1M attention. There is no obvious smaller V4-family speculator. **Experiment:** chunk the corpus into 256-token blocks, select 10%, 25%, and 50% using embeddings or BM25, preserve original positions/order, and feed only those chunks through unmodified DS4. |
| LazyLLM / UniPrefill | **[~7–11 min at reported 2–3×] [medium] [very high] [research-only for V4]** | [LazyLLM](https://arxiv.org/abs/2407.14057) runs early layers on all tokens, prunes tokens for later layers, and may revive them. [UniPrefill](https://arxiv.org/abs/2605.06221) propagates block sparsity through attention and GEMMs, reporting up to about 2.1×. This attacks the expensive later MoE layers, so it is more relevant than SnapKV, but V4’s grouped compressed state makes revival and block bookkeeping harder. **Experiment:** after an ordinary 32K prefill, log per-layer token/block importance and simulate the achievable MoE work reduction before writing sparse kernels. |
| GemFilter | **[~9 min at reported 2.4×] [medium–high] [medium] [research prototype]** | [GemFilter](https://aclanthology.org/2026.findings-acl.677/) scans early layers, selects a small token subset, then reruns the model. It pays for the scan and is therefore not a 100× mechanism. **Experiment:** use Lightning scores from an early V4 layer as the filter, reconstruct a reduced prompt in original order, and compare against a BM25/embedding selector. |
| FlashPrefill / SIFT attention pruning | **[likely minutes, not seconds] [low–medium] [very high] [research-only]** | [FlashPrefill](https://arxiv.org/abs/2603.06199) accelerates sparse full-attention prefill substantially on other MoE models. [SIFT](https://arxiv.org/abs/2606.09441) stores compact offline attention-location hints. V4 already has sequence compression and a learned indexer, so their headline attention gains are not multiplicative; MoE and compressor work remains. SIFT may reduce indexer/scoring overhead but cannot eliminate the all-token forward pass. **Experiment:** profile attention/indexer versus MoE/compression time at 16K and 32K. An attention-only optimization’s absolute ceiling is its measured time fraction. |
| SPEED / SwiftKV / KV prediction | **[~11–17 min for demonstrated shallow-prefill variants; unknown for prediction] [medium–high] [extreme] [model adaptation required]** | [SPEED](https://arxiv.org/abs/2605.06105) skips later prefill layers, with quality declining as more layers are removed. [SwiftKV](https://arxiv.org/abs/2410.03960) transforms early-layer states into later-layer KV. [KV Prediction](https://arxiv.org/abs/2410.08391) trains an auxiliary model to predict another model’s cache. For V4, the predictor must generate compressed memories and indexer state consistently across 43 layers. This changes the model and requires training data/logits from the exact Q2 target. **Experiment:** predict only one later layer’s CSA entries from an earlier layer, then measure indexer top-k agreement before attempting end-to-end generation. |

### Fidelity boundary

Selective prefill works when the task is localized retrieval. It is weakest on exactly the cases that motivate true 1M context:

- exhaustive counting or aggregation;
- finding a subtle contradiction among many similar records;
- dependencies whose relevance becomes apparent only after other evidence;
- code or logs where one changed token matters;
- requests asking the model to reason about the corpus as a whole.

There is no known query-time selector that can guarantee it retained every token the full model would have used without effectively doing the original computation.

# 3. Hardware-scale answers

## Two Sparks

**[~16.6 min demonstrated at 980K] [none for exact parallelism] [very high] [partial support today]**

The inter-box connection is not NVLink-C2C. NVLink-C2C connects the CPU and GPU inside each GB10; two Sparks communicate over ConnectX-7/RoCE, nominally 200 Gbps. See NVIDIA’s [Spark specification](https://www.nvidia.com/en-us/products/workstations/dgx-spark/), [cluster instructions](https://docs.nvidia.com/dgx/dgx-spark/spark-clustering.html), and [GB10 announcement](https://nvidianews.nvidia.com/news/nvidia-announces-dgx-spark-and-dgx-station-personal-ai-computers).

A community V4 TP2 result reports 980K prefill at about 986 tok/s, or 16.6 minutes, on two Sparks. It also shows throughput declining with context length. That is the closest direct evidence available, though it is not peer-reviewed: [NVIDIA forum benchmark](https://forums.developer.nvidia.com/t/deepseek-v4-flash-aiden-recipe-from-reddit-1m-token-session-operational-cuda-12-1-tailored-for-dgx-spark-gb10/372268).

Lossless context/sequence parallelism is real: [Context Parallelism for Scalable Million-Token Inference](https://arxiv.org/abs/2411.01783) reports 77 seconds for Llama-3 405B at 1M—but uses 128 H100s across 16 nodes. Two Sparks cannot turn that mechanism into 100× speedup. Ideal 2× scaling from the local DS4 rate would be 11.1 minutes; communication and V4 compressor-boundary exchanges make 11–15 minutes an aggressive custom-engine target.

**First experiment:** at 32K then 128K, shard native-token ranges while exchanging C4/C128 boundary state; compare against TP-only. Record compute/communication overlap and exact logits.

## Prefill/decode disaggregation

**[strict cold: probably 60–180 s today; cache hit: 4–10 s at 10 Gbps] [low only with identical model/cache ABI] [extreme on current stack] [supported within vLLM, not across vLLM↔DS4]**

The official [vLLM V4 recipe](https://recipes.vllm.ai/deepseek-ai/DeepSeek-V4-Flash) demonstrates V4 prefill/decode disaggregation using Mooncake/NIXL within one engine family. It does not demonstrate exporting an official FP8 V4 cache into a Q2 llama.cpp/DS4 process.

This is the central blocker:

> A cache computed from official FP8 weights is not the cache of the local UD-Q2 model.

Quantization changes every layer’s hidden states. Exact cache handoff therefore requires:

- identical tokenizer and rendered prompt;
- identical Q2 weights;
- identical RoPE and context settings;
- compatible cache precision/layout;
- all compressor/indexer/SWA tail state;
- compatible engine/build semantics.

Hardware/build differences can alter reductions and Lightning top-k decisions. The official emphasis on deterministic kernels is not evidence of bitwise cache portability across vLLM, llama.cpp, DS4, GB10, and B200. I found no published V4/MLA/CSA cross-engine cache-portability result.

**First experiment:** before renting anything large, export a 32K cache from one process, restore it in a second same-build process, and compare full next-token logits, indexer selections, and generated tokens. Then repeat across builds and only then across hardware. The existing [token-parity script](/home/bmarti44/spark-deepseek-v4-flash/scripts/33_token_parity.py) is the natural starting point.

## Transfer math for the measured 4 GiB cache

| Link | Ideal raw wire time | Hypothetical 4× coded size | Realistic interpretation |
|---|---:|---:|---|
| 1 Gbps | 34.4 s | 8.6 s | Not raw single-digit; likely 10–20 s with codec, protocol, and restore |
| 10 Gbps | 3.44 s | 0.86 s | Approximately 5–10 s end-to-end is credible |
| 200 Gbps | 0.172 s | 0.043 s | Network negligible; serialization and cache admission dominate |

CacheGen’s measured end-to-end improvement is materially smaller than its size reduction, so the 4× column is a wire-size illustration, not a latency forecast.

The July 2026 [Lynx](https://arxiv.org/abs/2607.01831) paper streams high-significance cache bits first and begins speculative decode while residual precision arrives. It improves TTFT by up to 1.43× over ordinary 8-bit transfer. This is useful latency hiding, not a replacement for cloud prefill, and would need a V4-aware progressive format.

## Cloud compute estimate

There is no published V4 single-request 1M prefill number on an 8×H200/B200 box. The 128-H100 context-parallel result proves that exact 1M in roughly a minute is possible at datacenter scale, not on a typical rented single GPU.

My budgeting estimate is:

- Purpose-built same-Q2 many-GPU service today: **60–180 seconds compute**.
- Highly optimized V4-native 16–32 B200 pool: **20–60 seconds is a plausible research target**, not a demonstrated result.
- Add about **5–10 seconds** for a 4 GiB handoff at 10 Gbps.
- If the cache already exists, compute disappears and the handoff itself can meet the seconds goal.

Layer-wise overlap, as explored by [Prefill-as-a-Service](https://arxiv.org/abs/2604.15039), can hide part of the transfer behind remaining prefill.

# 4. Radical latency hiding

| Idea | Assessment at 1M | Mechanism, limitations, first experiment |
|---|---|---|
| Streaming append-only ingestion | **[~1–8 s query-time restore] [none] [low–medium] [possible today]** | Prefill documents as they arrive and periodically persist complete-block state. At 750 tok/s, any ingestion stream slower than that can remain caught up. Appending the eventual query then costs only query-tail prefill and cache restore. A middle edit invalidates all downstream contextualized state. **Experiment:** append the corpus in 4K increments, snapshot every 32K, restore the final snapshot, and compare it with a single uninterrupted prefill. |
| Background RAG-cache maintenance | **[seconds for cached canonical order; 22+ min for a new ordering] [none on hits] [medium] [possible today]** | Maintain canonical corpus orders, tenant/system prefixes, and common document bundles before requests arrive. It works best when the corpus is stable and query-independent. It is storage/index engineering rather than a new attention algorithm. **Experiment:** replay real query traces offline and measure the longest-prefix hit distribution under a fixed cache-storage budget. |
| Hierarchical retrieve + live window | **[~5.3 s at 4K; 10.7 s at 8K; 21.3 s at 16K; 42.7 s at 32K, plus retrieval] [medium–high] [low–medium] [today]** | Retrieve chunks, summaries, citations, and possibly neighboring context into a live window. This is the most realistic single-Spark path to seconds. It fakes 1M rather than attending over 1M. Use query decomposition and multiple retrieval passes for coverage. **Experiment:** construct localized, multi-hop, contradiction, and global-counting tasks over the same corpus; sweep 4K/8K/16K/32K and compare against the slow full-context reference. |
| Hierarchical summaries with exact fallback | **[5–20 s normal path; ≥22 min fallback] [medium] [medium] [today]** | Store per-chunk facts and hierarchical summaries, answer from the hierarchy, then escalate low-confidence or aggregation requests to exact prefill. This gives practical tail control while preserving an exact path. **Experiment:** require every answer to cite source chunk IDs; trigger fallback when retrieval coverage or answer agreement across two retrieval passes is low. |

For production, streaming exact state and hierarchical retrieval are complementary: snapshots handle stable common prefixes, while retrieval handles query-specific selection.

# 5. Other research directions

| Idea | Assessment at 1M | V4 judgment |
|---|---|---|
| TurboQuant / learned cache quantization | **[prefill remains ≥1,333 s; transfer may shrink 1.5–3×] [medium] [high] [research port]** | [TurboQuant](https://arxiv.org/abs/2504.19874) is promising for conventional K/V storage. V4 already uses mixed low-precision/cache compression, so gains will be smaller. Quantizing indexer keys can change top-k ordering. Test each cache component separately. |
| HYPIC and linear-attention segment operators | **[potentially seconds on compatible models] [high/model-changing] [extreme] [research-only]** | [HYPIC](https://arxiv.org/abs/2607.01299) composes cached transition operators for hybrid linear-attention models. CSA/HCA is sparse compressed softmax attention, not an associative recurrent transition. Applying this requires distilling or replacing the architecture. |
| Linear-attention/SSM distillation | **[could make 1M ingestion near-linear and state-small] [very high] [extreme] [model replacement]** | A recurrent sidecar could ingest the corpus quickly and supply summaries/memory to V4. It cannot reproduce true V4 attention without extensive distillation. Treat it as a different model with a V4 decoder, not an optimization. |
| Cross-request KV prediction | **[unknown; aspirational 2–10×] [high] [extreme] [research-only]** | Predicting compressed V4 state is more plausible than reconstructing normal per-token KVs because the target state is small, but Lightning top-k sensitivity and contextual dependence make errors consequential. Start with one layer and complete 256-token blocks. |
| FlashMemory-DSV4 / on-demand reconstruction | **[cold prefill unchanged] [low] [medium] [research prototype]** | [FlashMemory-DSV4](https://arxiv.org/abs/2606.09079) is directly relevant to V4 memory/indexing and can reduce cache traffic, but it assumes the long-context memory already exists. It improves decode/memory behavior rather than raw cold prefill. |
| Self-indexing compressed keys | **[prefill largely unchanged] [medium] [high] [research-only]** | [Self-Indexing KVCache](https://arxiv.org/abs/2603.14224) unifies compressed keys and sparse lookup. V4 already has a learned FP4-oriented Lightning Indexer, so this is more likely an indexer simplification than a 100× prefill win. |

# Ranked top-five path to seconds

1. **Exact streaming/background snapshots of the canonical corpus.**  
   The only high-plausibility, full-fidelity, single-Spark route to query-time seconds. It is not strict cold start; it moves all expensive work earlier.

2. **Hierarchical retrieval with a 4K–8K live V4 window.**  
   Roughly 5–15 seconds on the measured DS4 rate. Best immediate operational answer, with explicit fidelity loss and an exact slow fallback.

3. **Same-Q2 cloud prefill plus native DS4 cache handoff.**  
   The 4 GiB transfer is compatible with seconds at 10 Gbps. The real project is cache ABI and numerical compatibility, not networking. Validate at 32K before building a large cloud service.

4. **V4-native, 256-token-aligned PIC/CacheBlend.**  
   Cache complete CSA/HCA/indexer/SWA modules, recompute boundary halos, and quantify how much downstream state must be repaired. This could produce tens of seconds at extremely high reuse, but no existing paper solves V4’s sequence-compressed state.

5. **SpecPrefill-style query-driven chunk selection.**  
   The fastest approximate experiment requiring no V4 kernel surgery. Published gains suggest minutes rather than seconds alone, but it composes naturally with retrieval, cloud prefill, or cached corpora.

Two Sparks do not make the top five because they reduce minutes to fewer minutes, not seconds.

# Best achievable numbers I believe are real

| Configuration | Strict raw 1M cold prefill | If exact state already exists |
|---|---:|---:|
| One Spark | **~22–30 minutes**; point estimate **25 min** | **~1–8 s** local restore, to be measured |
| Two Sparks | **~15–17 minutes today**; custom Q2 sequence parallel might reach **11–15 min** | Low-single-digit restore/replication |
| Spark + cloud prefill | **~60–180 s** with a purpose-built same-Q2 many-GPU service; **20–60 s** is an aggressive future target | **~5–10 s at 10 Gbps**, **~40–60 s at 1 Gbps** without an effective codec |

So the clear answer is:

- **Exact, truly cold, single-digit seconds:** not plausible on one or two Sparks.
- **Exact query-time seconds:** plausible through prior streaming/prefix computation.
- **Approximate query-time seconds:** plausible now with a 4K–8K retrieved live window.
- **Cloud-assisted strict cold:** likely tens of seconds to a few minutes, but not currently supported across the official FP8/cloud and local Q2/DS4 cache formats.