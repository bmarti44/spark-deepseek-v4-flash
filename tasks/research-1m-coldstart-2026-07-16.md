# Deep research: 1M-token cold-start prefill in SECONDS on (near-)single-box hardware

You are a research agent. READ-ONLY on this machine: modify nothing, start/stop nothing,
and NEVER send requests to 127.0.0.1:8011 or :8012 — a benchmark is running. Local file
reading + web/academic research only.

## Context (measured facts)
- Host: one DGX Spark GB10 (sm_121, aarch64, 119 GiB unified, 140W, 273 GB/s-class bandwidth).
- Model: DeepSeek-V4-Flash 284B MoE (13B active), CSA+HCA hybrid sparse attention +
  Lightning Indexer, MTP head, 1M ctx architecturally. Served 2-bit on llama.cpp
  (UD-Q2_K_XL) and the entrpi/ds4 engine (DSpark speculative).
- Measured prefill: ~280 tok/s (llama.cpp) to ~750 tok/s (ds4) at 16K. Naive 1M cold
  prefill = 22 min to 1 hour. Goal: SECONDS. That's a 100-1000x gap — incremental flag
  tuning will not close it; we need structural ideas.
- KV is nearly free for this model: compressed K-only cache ~128 MiB per 32K tokens
  (~4 GiB at 1M). Prefill COMPUTE is the wall, not memory.
- We already know about: prompt/prefix caching, llama.cpp --slot-save-path (prefill once,
  persist, reload), -ub batch widening, the 0dc74e3 fusion rebuild, chunked prefill.

## Questions — think structurally, cite the latest research (2025-2026)
1. **Precomputation & state reuse beyond exact-prefix**: research on composable/cached KV
   for RAG-style corpora — CacheBlend, PromptCache/prompt-cache-modularity, CacheGen
   (compressed KV streaming/loading), RAGCache, position-independent caching / KV cache
   splicing, approximate-prefix reuse. Which apply to a compressed-latent-attention model
   (cache is NOT per-token K/V matrices in the usual sense)? What breaks?
2. **Sparse/selective prefill**: can the Lightning Indexer or similar (quest-style token
   selection, lazy/deferred prefill, "prefill on demand") let the model prefill only the
   tokens a query actually attends to? Research on lazy prefill, chunked attention with
   early exit, speculative prefill (SpecPrefill), prefill pruning/token dropping (LazyLLM,
   SnapKV-at-prefill lineage, GemFilter), and their fidelity cost.
3. **Hardware-scale answers**: multi-Spark prefill (the ConnectX/NVLink-C2C 2-Spark
   configs), sequence-parallel prefill across boxes, prefill-decode disaggregation
   (prefill on a rented big GPU or cloud, ship the ~4 GiB compressed cache to the Spark,
   decode locally — CacheGen-style transfer math at ~1-10 Gbps: is this seconds?). Any
   published DeepSeek MLA/CSA cache portability results (is the cache deterministic across
   builds/hardware? quantization of the latent cache for transfer?).
4. **Radical latency hiding**: streaming ingestion (prefill the corpus as it's written,
   long before query time), background/incremental index maintenance, hierarchical
   summarize+retrieve hybrids that fake 1M with 32K live windows (and their fidelity
   trade-offs vs true attention over 1M).
5. **What are we not thinking of?** Anything in 2025-2026 systems/ML literature (MLSys,
   OSDI, SOSP, NeurIPS/ICLR/ICML, arXiv) that changes this picture: linear-attention
   distillation for prefill, cross-request KV prediction, learned cache compression like
   TurboQuant applied to latent caches, hybrid SSM sidecars, etc. Rank by plausibility
   on THIS stack.

## Output format
Markdown. Per idea: [expected latency at 1M] [fidelity risk] [engineering effort]
[what exists today vs research-only] — mechanism, why it fits/breaks on V4-Flash's
compressed sparse-attention cache, citations (URLs), and the first concrete experiment we
could run on this repo's stack. End with a ranked top-5 "path to seconds" and a clear
statement of the best achievable cold-start number you believe is real on (a) one Spark,
(b) two Sparks, (c) Spark + cloud prefill.
