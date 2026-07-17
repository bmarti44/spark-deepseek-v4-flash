# 1M-token cold-start prefill in seconds on DGX Spark — structural research findings

Date: 2026-07-16. Read-only research pass. Grounded in
`/home/dsv4/llamacpp-project/src/llama.cpp/src/llama-kv-cache-dsv4.{h,cpp}` and 2025–2026 literature.

---

## 0. Grounding: what the DSV4 cache actually is (and the physics floor)

### 0.1 Cache layout (from `llama-kv-cache-dsv4.cpp/h`)

- Four stores per sequence: a **raw ISWA per-token cache** (only the SWA half is used; window ≈ 128
  tokens per the SGLang V4 day-0 writeup), plus three **compressed K-only block caches**:
  **CSA at ratio 4** (`DSV4_CSA_RATIO = 4`, top-k selected), **HCA at ratio 128**
  (`DSV4_HCA_RATIO = 128`, dense), and **LID** (Lightning-Indexer keys), each with a per-row
  `score` tensor.
- Compressed rows are **graph outputs from a stateful ring compressor** (`llama_dsv4_comp_state`,
  `comp_plan`): `state_persist_src/dst_idxs` maintain a per-sequence ring state; **overlapped
  compression** reads `[previous block | current block]` (`state_read_idxs` "two contiguous
  halves"), so a compressed row depends on its own block plus **exactly one previous block** of
  per-token K states — a *bounded, local* dependency horizon. This matters enormously for splicing
  (idea 2).
- RoPE is applied at commit time via `state_write_pos`, and the context exposes
  `build_input_k_rot` / `set_input_k_rot` — i.e., the machinery to **re-rotate cached K rows to new
  absolute positions already exists** (used for shifts). Position re-basing of a chunk cache is
  mechanically supported, not hypothetical.
- Full serialization exists and is versioned: `state_write/state_read` with `DSV4_STATE_MAGIC`,
  `DSV4_STATE_VERSION`, and FULL vs PARTIAL modes, covering raw K cache, all three compressed
  caches, scores, and the compressor ring states. So **slot save/restore round-trips the entire
  attention state** — the substrate for every precompute/ship idea below.
- Size: ~128 MiB / 32K tokens ⇒ **~4 GiB at 1M** (compressed caches dominate; raw SWA cache is
  window-bounded and tiny). KV memory is a non-issue; only compute is.

### 0.2 The compute floor (why "seconds" on one Spark cannot mean "full prefill")

13B active params × 2 FLOPs/param/token × 1e6 tokens ≈ **26 PFLOPs** of FFN/MoE work alone
(attention is already subquadratic here — that's the point of CSA/HCA). GB10 peaks at
~1 PFLOP sparse FP4 (~500 TF dense NVFP4, ~208 TF FP8 measured, ~100 TF BF16 measured —
[NVIDIA forums](https://forums.developer.nvidia.com/t/detailed-compute-performance-metrics-for-dgx-spark/351993),
[IntuitionLabs review](https://intuitionlabs.ai/articles/nvidia-dgx-spark-review)). Even at an
unrealistic 250 TF sustained, full 1M prefill ≥ **~105 s**; at a realistic 50–100 TF effective for
2-bit MoE kernels, **~4–9 min is the hard floor**. Measured today: 22–60 min.

**Conclusion that frames everything below:** on one Spark, "1M cold start in seconds" is only
achievable by *not doing the prefill at query time* — restore it, splice it, ship it, or skip most
of it. The ideas are ranked accordingly.

---

## 1. Precomputation & state reuse beyond exact-prefix

### Idea 1 — Corpus-time streaming ingestion + slot persistence ("prefill before the question exists")
**[Latency at 1M: 2–6 s] [Fidelity: none — bit-identical] [Effort: low] [Exists today]**

Mechanism: prefill the corpus at write/ingest time (append-only, chunked prefill in the
background), persist per-corpus slots via `--slot-save-path` (which serializes the full DSV4 state,
§0.1). At query time: restore slot (~4–5 GiB; local NVMe at 2–4 GB/s ⇒ **~1.5–3 s**), then prefill
only the suffix (query + template, hundreds of tokens ⇒ <1 s at 750 tok/s). Appends to a document
reuse the persisted state exactly (the ring compressor state is saved, so continuation is exact).
This is "we already know" territory *individually*, but the structural reframing — **treat prefill
as an index-build that happens at ingest, never at query** — is the only path that reaches
low-single-digit seconds on one Spark with zero fidelity loss. Kimi's Mooncake formalizes exactly
this economics: KV cache as a persistent, disaggregated store
([Mooncake, FAST'25 best paper](https://madsys.cs.tsinghua.edu.cn/publication/mooncake-a-kvcache-centric-disaggregated-architecture-for-llm-serving/ToS2025-Qin.pdf),
[repo](https://github.com/kvcache-ai/Mooncake)); SGLang's V4 day-0 work adds **ShadowRadix**,
native prefix caching for exactly this hybrid attention
([LMSYS blog](https://www.lmsys.org/blog/2026-04-25-deepseek-v4/)).

Why it fits V4-Flash: perfectly — the versioned state I/O already exists; 4 GiB/1M is 30–60×
smaller than a dense-KV model's state, which is what makes restore seconds-fast at all.
Breaks: only for *genuinely never-seen* text (see ideas 4–6) and for cross-document composition
(see idea 2).

First experiment: prefill 1M synthetic tokens once (off-hours), save slot, drop caches
(`echo 3 > drop_caches` — on a non-benchmark box), time restore + 100-token query on ds4/llama.cpp.
Measure restore wall-clock vs file size; verify token-identical output vs live prefill.

### Idea 2 — Position-independent chunk-cache store + splice (EPIC/CacheBlend/KVLink, adapted)
**[Latency at 1M: ~5–20 s] [Fidelity: moderate, task-dependent] [Effort: high] [Research + engineering]**

Mechanism: precompute per-chunk DSV4 states for corpus chunks *independently* (position-zero-based),
store them; at query time compose an arbitrary ordered subset into one context: re-rotate each
chunk's K rows to its new absolute position, then repair the seams. Literature:
[CacheBlend (EuroSys'25 best paper)](https://dl.acm.org/doi/10.1145/3689031.3696098) recomputes
~15% of tokens (the high-cross-attention ones) and gets 2.2–3.3× TTFT with ~no quality loss;
[EPIC](https://arxiv.org/pdf/2410.15332) shows only the **chunk-boundary attention-sink tokens**
need fixing (O(k·N) not O(N²), "LegoLink");
[PromptCache](https://arxiv.org/abs/2311.04934)-style modular schemas;
[KVLink](https://arxiv.org/abs/2502.16002) (trainable link tokens, needs finetuning);
[Star Attention (NVIDIA)](https://arxiv.org/abs/2411.17116) shows anchor-block-prefixed local
encoding preserves 97–100% accuracy.

Why V4-Flash is *unusually well suited* — three code-grounded reasons:
1. **Raw attention is SWA-128 only.** Dense cross-chunk dependence — the thing CacheBlend fights —
   exists only inside a 128-token window. A seam repair needs to recompute at most the last SWA
   window + one overlapped compressor block (128 tokens for HCA) per seam. Dependency horizon is
   bounded *by architecture*, not by heuristic.
2. **Re-positioning is native.** `k_rot` inputs + `state_write_pos` mean chunk re-basing is a batch
   RoPE rotation of cached rows (the shift path), not a recompute.
3. Cross-chunk influence flows only through CSA top-k selection and HCA 128:1 rows — i.e. the model
   is *trained* to consume context as selected compressed blocks, which is much closer to "chunks
   encoded semi-independently" than a dense-attention model is. Star-Attention-style anchor blocks
   should transfer better here, not worse.

What breaks: (a) hidden states of chunk tokens never saw other chunks, so compressed rows differ
from true sequential prefill — the CacheBlend approximation, unvalidated on sparse-trained models;
(b) the **Lightning Indexer scores** were computed against chunk-local queries — selection quality
after splicing is the novel open risk (nobody has published KV-splicing results for a
DSA/lightning-indexer model as of mid-2026); (c) the ring compressor state at each seam must be
rebuilt (cheap: one block).

First experiment: 2-chunk splice at 32K. Prefill A then B sequentially (ground truth); separately
prefill A and B independently, splice B's state after A with k_rot re-basing + recompute of B's
first 256 tokens; compare answer quality on needle/QA probes and compare LID top-k selections
(Jaccard of selected block sets) — the selection overlap is the cheapest fidelity oracle this
stack uniquely has.

### Idea 3 — CacheGen-style entropy coding of the latent cache (storage/transfer multiplier)
**[Latency: multiplier on ideas 1/5, ~2–4× smaller] [Fidelity: low-moderate] [Effort: medium] [Research on this cache]**

[CacheGen (SIGCOMM'24)](https://dl.acm.org/doi/10.1145/3651890.3672274) gets 3.5–4.3× KV shrink via
delta-coding across adjacent tokens + layerwise quantization + arithmetic coding, with adaptive
quality/bandwidth tradeoff. Caveat for V4-Flash: its gains come from *redundancy in dense per-token
K/V*, and DSV4 rows are already 4:1 / 128:1 learned compressions — residual redundancy is smaller
and CSA rows are top-k-selected (less smooth across neighbors). Expect the low end (~2×) not 4×.
Quantizing latent rows to 4–8 bit is the safer axis
([TurboQuant, ICLR'26](https://arxiv.org/abs/2504.19874): near-optimal 3-bit K / 2-bit V via random
rotation + Lloyd-Max — directly applicable to latent rows since it's distribution-agnostic;
inner-product-unbiasedness is exactly what the indexer's score reuse needs). 4 GiB → ~1–1.5 GiB
makes NVMe restore <1 s and network shipping 1–12 s at 1–10 Gbps.
First experiment: dump one saved slot, offline-quantize compressed K rows to 8/6/4-bit per-row
scale, reload, measure perplexity + needle accuracy vs bit-width. (Pure offline, no server needed.)

### Idea 4 — RAGCache / hierarchical retrieve-then-attend, incl. REFRAG
**[Latency at 1M-equivalent: 1–5 s] [Fidelity: moderate-high risk, task-dependent] [Effort: medium] [Exists today (RAG) / research (REFRAG)]**

Fake the 1M window: keep the corpus in a retrieval index + per-chunk KV caches
([RAGCache](https://arxiv.org/abs/2404.12457): knowledge-tree of chunk KVs, order-aware reuse), live
window 32–128K. [REFRAG (Meta, 2025)](https://arxiv.org/pdf/2509.01092) is the aggressive version:
feed *chunk embeddings* (16:1) directly as decoder inputs, expanding only policy-selected chunks to
tokens — 30.75× TTFT, no perplexity loss on RAG tasks. Conceptually delicious here because HCA
*already is* a trained 128:1 chunk-embedding pathway — "REFRAG for free" would mean prefilling only
the HCA rows via a cheap encoder and skipping full-token prefill for cold chunks; that's a training
project (new distilled encoder that predicts HCA rows from raw text), not a deployment. Fidelity:
fine for QA/RAG-shaped tasks; breaks on global aggregation/multi-hop over the full 1M.
First experiment: baseline harness task at 1M vs retrieval-top-64K live window; quantify the
fidelity gap on this repo's evalsets before investing anywhere else — it bounds how much "true 1M"
is even worth.

---

## 2. Sparse / selective prefill (compute-skipping)

### Idea 5 — Token-dropped prefill: SpecPrefill / GemFilter / LazyLLM lineage, with the MTP head as the oracle
**[Latency at 1M: ~2–6 min on one Spark (from 22–60)] [Fidelity: moderate] [Effort: medium-high] [Research, adaptable]**

The wall is MoE FFN FLOPs per token, so the only compute-side lever is running *fewer tokens*
through the trunk. [SpecPrefill (ICML'25)](https://arxiv.org/abs/2502.02789): a small draft model
scores token importance, main model prefills only the keepers (with original positions) — 7.66×
TTFT on Llama-405B, quality preserved on LongBench/RULER at ~10–20% keep rates.
[GemFilter](https://arxiv.org/abs/2409.17422) uses the model's own early layers to select (2.4×
speedup, needs all tokens through early layers — less useful here);
[LazyLLM](https://arxiv.org/abs/2407.14057) defers pruned tokens' KV to on-demand revival — the
revival idea maps nicely onto "prefill on demand" for CSA blocks.

V4-Flash-specific twist this stack uniquely enables: **the MTP head is a single SWA-only decoder
layer** ([LMSYS](https://www.lmsys.org/blog/2026-04-25-deepseek-v4/)) — an in-model, ultra-cheap
(~1/60th cost) forward pass that could play SpecPrefill's draft role with perfect tokenizer/embedding
alignment; alternatively run *only the Lightning Indexer path* over the full text to score
query-conditioned relevance, then full-prefill only top-scoring regions (+ SWA halos). What breaks:
dropped tokens never get CSA/HCA/LID rows, so they are invisible to *future* queries — fine for
single-shot, wrong for persistent slots; and the compressor's overlapped block structure forces
keeping contiguous block-aligned runs (ratio-128 granularity for HCA), not scattered tokens — a
constraint no published token-dropper handles yet (novel work, publishable).
Ceiling check: 10% keep ⇒ 2.6 PFLOPs ⇒ ~30–60 s ideal, 2–6 min realistic. **Gets to minutes, not
seconds, on one Spark** — its real role is the cold path of a tiered system (idea 1 hot path).
First experiment: offline, no serving — compute LID scores for a 1M doc + query, prefill only
top-10% blocks (block-aligned) via context-shift tricks, compare QA accuracy vs full prefill.

### Idea 6 — NVFP4 prefill fast path (raise the floor)
**[Latency at 1M: ~4–10 min] [Fidelity: low risk] [Effort: high (kernels)] [Engineering, partially exists (TRT-LLM)]**

The 750 tok/s ds4 number is far below GB10's paper compute; Q2_K decode kernels don't use FP4
tensor cores for the big prefill GEMMs. An NVFP4-weights prefill path (dequant Q2→NVFP4 once, or a
native NVFP4 GGUF for prefill only) targeting the ~500 TF dense FP4 pipe could plausibly reach
3–5K tok/s prefill ⇒ 1M in ~3.5–6 min. Combines multiplicatively with idea 5 (→ ~30–90 s hybrid,
the best "true compute, one box" number I believe). Not seconds alone; listed because every other
idea's cold path sits on top of this rate.
First experiment: profile one prefill ubatch (nsys) to get actual MFU; if <15%, kernel headroom is
real before any algorithmic work.

---

## 3. Hardware-scale answers

### Idea 7 — Cloud prefill + compressed-cache shipping (prefill-decode disaggregation across the WAN)
**[Latency at 1M: ~25–40 s pipelined] [Fidelity: low-moderate] [Effort: high] [Components exist; the converter is the research]**

Math, grounded: DeepSeek-V3.2 prefill measures **~7,360 tok/s/GPU on GB300 (FP4)**
([vLLM blog](https://vllm.ai/blog/2026-02-13-gb300-deepseek)) — an 8-GPU rented node ⇒ 1M prefill
in **~20–25 s** (V4-Flash's sparse attention keeps this near-flat with length; 8×H200 is ~5.7K
tok/s total ⇒ ~3 min, so it must be Blackwell). Cache ship: ~4 GiB → ~2 GiB quantized (idea 3):
**~2 s at 10 Gbps, ~16–30 s at 1 Gbps** — and CacheGen-style *streaming* of finished blocks while
prefill continues (Mooncake/LMCache transfer engines do exactly this,
[LMCache report](https://lmcache.ai/tech_report.pdf)) pipelines transfer under compute ⇒ end-to-end
≈ max(prefill, transfer) + tail ≈ **~25 s at 10 Gbps**. This is the only *genuinely cold* path to
sub-minute.

Portability, grounded in the code: bit-determinism across hardware is **not required** — decode
consumes cache values approximately, and the DSV4 state format is a versioned dump of tensors +
ring states, so a cloud producer only needs to emit the same layout/dtype. What breaks: (a) no
published engine emits llama.cpp-DSV4-format state — you'd run the *same llama.cpp fork* on a cloud
Blackwell box (easiest; CUDA aarch64→x86 is a rebuild) or write an SGLang→DSV4 state converter
(hard: SGLang's ShadowRadix pools vs DSV4's ring-state semantics must be reconciled, incl. the
overlapped-compression previous-block half); (b) quantization mismatch — a cloud FP8/FP4 model's K
rows fed to a Q2 trunk is *cross-precision cache reuse*, untested for DSV4 but analogous to
CacheGen's lossy reuse (their result: tolerable); the LID score tensors must also ship or selection
breaks. No published MLA/CSA cache-portability study exists as of 2026-07 — this is an open,
publishable gap.
First experiment: same llama.cpp fork on any rented Blackwell GPU, prefill 128K, `state_write`,
scp to Spark, `state_read`, compare outputs token-by-token vs local prefill. One afternoon,
answers the whole cross-hardware question at small scale.

### Idea 8 — Two-Spark sequence-parallel prefill (Star-Attention-shaped, not Ring)
**[Latency at 1M: ~11–30 min true; ~halves ingest time for idea 1] [Fidelity: none-to-low] [Effort: medium-high] [Partially exists (llama.cpp RPC ≠ this)]**

Ring/striped attention ([LoongServe, SOSP'24](https://dl.acm.org/doi/10.1145/3694715.3695948),
[Medha](https://arxiv.org/abs/2409.17264), Meta context-parallelism) shard the *sequence*; llama.cpp
RPC only shards *layers/tensors* (pipeline), which does not cut sequential prefill latency. But
V4-Flash's architecture makes **Star-Attention-style block-parallel prefill**
([NVIDIA](https://arxiv.org/abs/2411.17116)) nearly exact rather than approximate: raw attention is
SWA-128, so two Sparks can prefill halves with only a 128-token halo + anchor block, exchanging
compressed rows (≈ MiBs) over the 200 GbE ConnectX-7 link
([2-node Spark clusters are routine](https://github.com/ArgentAIOS/dgx-spark-cluster),
[dev.classmethod.jp](https://dev.classmethod.jp/en/articles/dgx-spark-two-node-clustering/)).
The approximation is confined to CSA top-k selection seeing only local blocks during encode —
same open question as idea 2, same experiment validates both. Verdict: 2× on a 22–60 min baseline
is still minutes; the second Spark's best use is **doubling ingest throughput and hosting the
chunk-cache store** (ideas 1–2), or halving the floor of ideas 5+6 to ~15–45 s in the maximal
hybrid.

---

## 4–5. Radical latency hiding & things not on the brief's list

### Idea 9 — Tiered "KV-native corpus filesystem" (the synthesis)
**[Query-time at 1M: ~2–5 s warm, ~25 s cloud-cold, minutes true-cold] [Fidelity: exact→moderate by tier] [Effort: staged] [Buildable now]**

Not one technique — an architecture: every document ingested into the corpus is prefilled in the
background (idea 1, both Sparks, idea 6 rate), stored as position-zero chunk states (idea 2 format,
idea 3 compression, on NVMe — at 4 GiB/1M-tokens, 1 TB stores a 250M-token corpus). Query time:
exact-prefix hit → slot restore (2–3 s); composed/multi-doc → splice + seam repair (5–20 s);
truly cold + urgent → cloud burst (idea 7, ~25 s); truly cold + local-only → token-dropped prefill
(idea 5, minutes) while a background full prefill repairs the cache for next time. This is
Mooncake's KVCache-centric thesis scaled down to two desk boxes, and it is the only coherent way
"seconds at 1M" is real.

### Idea 10 — Linear-attention distillation / SSM sidecar: ranked LOW here
**[Effort: very high] [Research-only]** — [LoLCATs](https://arxiv.org/abs/2410.10254),
[Mamba-in-the-Llama](https://arxiv.org/abs/2408.15237), [LAWCAT](https://arxiv.org/html/2509.18467)
convert attention to linear forms. Deliberately deprioritized: V4-Flash's attention is *already*
subquadratic (that's CSA/HCA), the prefill wall is MoE FFN FLOPs, which linearizing attention does
not touch. The only variant that attacks the wall is distilling a small SSM *sidecar that predicts
compressed cache rows directly from text* (skipping the 284B trunk for cold chunks) — effectively
learned KV prediction / "REFRAG for HCA rows" (idea 4) — genuinely novel, a training project.
Similarly, cross-request KV prediction has no 2025-26 result strong enough to bet on.

---

## Ranked top-5 path to seconds

1. **Ingest-time prefill + slot persistence + fast restore** (idea 1 + 3) — exists today, exact,
   2–6 s at query time. Do this first; everything else is a fallback tier.
2. **Position-independent chunk store + splice with bounded seam repair** (idea 2) — turns tier 1
   from "exact prefix only" into "any composition of known chunks", 5–20 s. Highest research value;
   V4-Flash's SWA-128 + block-local compressor makes it more tractable than for dense models.
3. **Cloud-burst prefill + streamed compressed-cache shipping** (idea 7) — the only genuinely-cold
   sub-minute path: ~25 s pipelined on a rented 8×Blackwell node at 10 Gbps.
4. **Token-dropped prefill with MTP/LID as the importance oracle** (idea 5) — local cold path,
   minutes not seconds; uniquely synergistic with this architecture.
5. **NVFP4 prefill kernel path** (idea 6) — multiplies 4 and 8; raises every cold number ~4–7×.

## Best achievable cold-start numbers I believe are real (1M tokens)

| Config | Genuinely cold (text never seen) | "Cold process, warm corpus" (precomputed state) |
|---|---|---|
| **(a) One Spark** | ~22–60 min today; **~30–90 s** ceiling with NVFP4 path + 10% token-drop (research, fidelity risk); hard physics floor ~105 s for *full* prefill — true full-prefill seconds is impossible | **~2–5 s** (slot restore, exists today); ~5–20 s for spliced multi-doc compositions (research) |
| **(b) Two Sparks** | ~half of (a): ~11–30 min today, **~15–45 s** maximal-hybrid ceiling | **~2–5 s** (restore is NVMe-bound, not helped); 2× ingest throughput is the real win |
| **(c) Spark + cloud** | **~25 s** pipelined (8×GB300-class prefill ~20–25 s ∥ streamed ~2 GiB quantized cache at 10 Gbps); ~40–60 s at 1 Gbps | ~2–5 s local, cloud irrelevant |

Bottom line: "seconds" is achieved by re-architecting *when* prefill happens (tiers 1–2), not by
making prefill itself fast; the only honest cold-compute seconds figure is the cloud-burst ~25 s.

## Key citations
- CacheBlend (EuroSys'25): https://dl.acm.org/doi/10.1145/3689031.3696098
- EPIC position-independent caching: https://arxiv.org/pdf/2410.15332
- CacheGen (SIGCOMM'24): https://dl.acm.org/doi/10.1145/3651890.3672274
- SpecPrefill (ICML'25): https://arxiv.org/abs/2502.02789
- Star Attention (NVIDIA): https://arxiv.org/abs/2411.17116
- Mooncake (FAST'25): https://madsys.cs.tsinghua.edu.cn/publication/mooncake-a-kvcache-centric-disaggregated-architecture-for-llm-serving/ToS2025-Qin.pdf
- LMCache tech report: https://lmcache.ai/tech_report.pdf
- REFRAG (Meta): https://arxiv.org/pdf/2509.01092
- TurboQuant (ICLR'26): https://arxiv.org/abs/2504.19874
- DeepSeek-V3.2 DSA: https://www.marktechpost.com/2025/09/30/deepseek-v3-2-exp-cuts-long-context-costs-with-deepseek-sparse-attention-dsa-while-maintaining-benchmark-parity/
- SGLang DeepSeek-V4 day-0 (HSA, MTP, ShadowRadix, HiSparse): https://www.lmsys.org/blog/2026-04-25-deepseek-v4/
- vLLM DeepSeek-V3.2 on GB300 (7360 tok/s/GPU prefill): https://vllm.ai/blog/2026-02-13-gb300-deepseek
- LoongServe (SOSP'24): https://dl.acm.org/doi/10.1145/3694715.3695948
- Medha multi-million context: https://arxiv.org/abs/2409.17264
- GemFilter: https://arxiv.org/abs/2409.17422 ; LazyLLM: https://arxiv.org/abs/2407.14057
- LoLCATs: https://arxiv.org/abs/2410.10254 ; Mamba-in-the-Llama: https://arxiv.org/abs/2408.15237
- RAGCache: https://arxiv.org/abs/2404.12457 ; KVLink: https://arxiv.org/abs/2502.16002
- 2-Spark clustering: https://github.com/ArgentAIOS/dgx-spark-cluster ;
  https://dev.classmethod.jp/en/articles/dgx-spark-two-node-clustering/
- GB10 compute: https://forums.developer.nvidia.com/t/detailed-compute-performance-metrics-for-dgx-spark/351993
