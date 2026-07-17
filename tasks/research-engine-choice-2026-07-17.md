# Deep research: is llama.cpp the right engine for THIS product on THIS box?

You are a research agent. READ-ONLY on this machine: modify nothing, start/stop nothing,
NEVER send requests to 127.0.0.1:8011/8012/8010. Local file/source reading + web research.

## The product (decided, not up for debate)
One DGX Spark GB10 (sm_121, aarch64, 119 GiB unified memory, OOM = hard system freeze,
~273 GB/s memory bandwidth, driver 580.159.03, CUDA 13) serving DeepSeek-V4-Flash
(284B MoE, 13B active, CSA/HCA sparse attention + Lightning Indexer, 1M ctx
architecturally) as an authenticated OpenAI-compatible endpoint with:
- the LARGEST safe context we can gate (target 1M; the model's compressed K-only cache
  is ~6.9 KiB/token ≈ 6.7 GiB at 1M — memory is NOT the wall, prefill compute is),
- aggressive caching: every turn cached, cross-request AND cross-restart persistence of
  KV/cache state to disk with restore-in-seconds (this is load-bearing for the design),
- a cost-based router (full prefill if cached/short, retrieval skim above ~10 s prefill),
- background corpus ingest producing saved states.
Current plan uses upstream llama.cpp (pin 32e789fd, UD-Q2_K_XL 2-bit GGUF ~90.2 GiB,
measured 13.9 tok/s decode @4K, ~280 tok/s prefill, slot save/restore code exists for
the DSV4 cache type). Sources on disk: /home/dsv4/llamacpp-project/src/llama.cpp.

## The question
Brian asks: is llama.cpp actually the best engine for this? What about vLLM? What is
best ON THE SPARK specifically? Evaluate at least: llama.cpp (status quo), vLLM,
SGLang, TensorRT-LLM, ktransformers, and anything 2025-2026 that's Spark-relevant
(NVIDIA's own DGX Spark serving stacks, TRT-LLM on GB10, MLC, ollama is just llama.cpp).
For EACH engine answer concretely:
1. Does it run DeepSeek-V4-Flash AT ALL on GB10/sm_121/aarch64 today? (V4's CSA/HCA +
   Lightning Indexer needs explicit model support — check repos/issues/PRs, not vibes.)
2. Can it fit 284B in 119 GiB? What quantization formats does it support for this model
   at ~2-3 bit (GGUF Q2_K support? AWQ/GPTQ at 2-bit? anything else)? vLLM's GGUF
   support status and MoE/GGUF interaction specifically.
3. Unified-memory behavior: does it respect UMA/allocate safely on GB10 (freeze-on-OOM
   box), or does it assume discrete VRAM + host RAM split?
4. Context: max ctx it supports for THIS model; KV/cache memory model for MLA-style
   compressed caches; prefix caching; **state persistence to disk + restore** (vLLM
   sleep/wake? SGLang HiCache/RadixAttention hierarchical? LMCache integration? compare
   honestly to llama.cpp --slot-save-path).
5. Measured/reported performance on GB10 or closest aarch64 UMA hardware (prefill and
   decode) — cite sources; NVIDIA marketing numbers flagged as such.
6. Operational fit: OpenAI-compatible server, auth story, systemd friendliness, build
   effort on aarch64+CUDA13+sm_121.
Then the verdict: (a) best engine for THIS product today; (b) whether any engine beats
llama.cpp enough to justify re-benchmarking (our protocol makes that a full re-run);
(c) hybrid options (e.g. vLLM for prefill elsewhere, llama.cpp local) only if practical.

## Output format
Markdown: comparison table first (engine × the 6 criteria), then per-engine detail with
citations (URLs), then a clear ranked recommendation with the single decisive reason per
rejected engine. Flag every claim you could NOT verify. Be specific to this box — a
datacenter H100 result does not transfer to 273 GB/s UMA.
