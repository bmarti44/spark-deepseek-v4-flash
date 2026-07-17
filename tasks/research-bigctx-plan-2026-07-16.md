# Deep research + implementation plan: max-context serving with smart caching/routing on this Spark

You are a research agent. READ-ONLY on this machine: modify nothing, start/stop nothing,
NEVER send requests to 127.0.0.1:8011 or :8012 (benchmark in flight). Local file/source
reading + web research. Output = a concrete, buildable PLAN, not just findings.

## The product Brian wants (his spec, verbatim intent)
On this single DGX Spark (GB10, 119 GiB unified, freeze-on-OOM), serving DeepSeek-V4-Flash
2-bit on llama.cpp (upstream, V4 support; sources at /home/dsv4/llamacpp-project/src/llama.cpp):
1. The LARGEST safe context window — target 1M (V4's compressed K-only cache is ~4 GiB at
   1M; the unknown is scratch/compute-buffer scaling and the 12 GiB watchdog floor).
2. AGGRESSIVE caching: every turn's tokens cached; conversations and re-seen documents
   never re-prefill. Cross-request and cross-restart persistence where possible.
3. SMART ROUTING: full-fidelity prefill for anything cached or short; retrieval-augmented
   "skim mode" ONLY for uncached queries whose prefill would exceed ~10 seconds; responses
   tagged when skim mode was used.
4. INGEST PIPELINE: registered corpora (repos, doc sets) pre-read in the background at
   write time; saved states restored in seconds at query time.

## Research + plan questions
1. **Context ladder feasibility (local source work)**: read the dsv4 cache + context
   allocation code (src/llama-kv-cache-dsv4.cpp, llama-context, server slot allocation).
   How do compute/scratch buffers, logits buffers, indexer state, and checkpoint memory
   scale with n_ctx for THIS architecture? Predict memory at 64K/128K/256K/512K/1M with
   -ub 512 vs 2048. Where does the 119 GiB box actually top out with ~90 GiB weights?
   What's the recommended rung ladder + per-rung gate set (memory headroom, needle/RULER-
   style fidelity, TTFT, soak)? Any hard n_ctx limits in the V4 implementation (position
   encoding, indexer top-k, u32 offsets)?
2. **Caching mechanics (local + web)**: exact semantics of cache_prompt, --cache-ram,
   slot save/restore (--slot-save-path, /slots API), context shift + checkpoints for V4's
   compressed cache (issue #25452 lineage — is slot save/restore even SUPPORTED for the
   dsv4 cache type? verify in source: state_write/state_read paths). Cross-restart
   persistence: what exists vs needs building. Multi-user: how many slots can coexist at
   big ctx, and does -np partition n_ctx?
3. **Router design (web + local)**: how to estimate "uncached prefill cost" per request
   BEFORE sending it — llama.cpp server cache introspection (/slots, /props, prompt
   matching behavior), client-side tokenization against the official encoder (we have
   one in the repo), longest-cached-prefix estimation. Where should the router sit in our
   chain (Caddy -> auth helper -> engine; scripts/40_auth_helper.py, configs/caddy/)?
   Concrete threshold math for "10 seconds" at measured prefill rates.
4. **Retrieval skim mode (web)**: lightest-weight retrieval stack that runs ON the Spark
   beside a ~100 GiB resident model (embedding model choice small enough to coexist, or
   BM25/lexical-only to spend zero GPU?), chunking for code vs prose, how to compose the
   retrieved window (fits our official-encoder rendering), and honest fidelity expectations
   vs full attention. Existing open-source routers/gateways that already do cost-based
   routing (vLLM router, llm gateway projects) worth borrowing from vs writing ~500 lines.
5. **Ingest pipeline (plan)**: storage layout for saved states (per-corpus files, ~4 GiB
   each at 1M — disk budget on this box: check df), invalidation on corpus change
   (content-hash manifests like our existing pins), background scheduling (systemd,
   nice/ionice so ingest never competes with live serving — SAME GPU though: how to
   time-slice safely under the watchdog?), and the restore-latency numbers to expect
   (NVMe read of 4 GiB ≈ 1-2 s + engine load path).
6. **What breaks / what are we missing**: multi-tenancy vs one giant slot, cache eviction
   policy, security (saved states contain the corpus — permissions), interaction with the
   frozen benchmark protocol (this is all post-decision phase-2, new protocol version),
   and any 2025-2026 published work on exactly this pattern (KV-cache-as-index,
   "prefill-once serve-many", context-database systems like LMCache, vLLM production
   stack, SGLang RadixAttention hierarchical caching — what's portable to llama.cpp+V4?).

## Output format
A PLAN document: (a) executive summary; (b) the context ladder with predicted memory per
rung and per-rung gates; (c) component designs (router, cache layer, ingest pipeline) each
with: what exists today / what we build / effort estimate / risks; (d) a build order as
numbered milestones with acceptance tests runnable on this repo's harness style;
(e) open questions needing experiments, each with the exact cheap experiment;
(f) citations for all web claims. Be specific to THIS stack — no generic advice.
