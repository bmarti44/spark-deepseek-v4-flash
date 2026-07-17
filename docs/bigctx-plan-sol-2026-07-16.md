# Phase-2 plan: maximum-context DSV4 serving

This plan is based on read-only inspection of the pinned repository/source, existing benchmark artifacts, host capacity, and upstream research. I changed nothing, started/stopped nothing, and sent no requests to ports 8011 or 8012.

## A. Executive summary

The practical recommendation is:

1. Ship the first production version at **256K context, `-ub 512`, `-np 1`, f16 K cache, `--cache-ram 0`**.
2. Promote **512K** only if a full-context load, cold state restore, and 30-minute near-full soak all retain at least **16 GiB MemAvailable**. The forecast straddles that limit.
3. Treat **1M as experimental**. With the current 90.18 GiB weights and f16 DSV4 cache, predicted headroom is only about **10.5–12 GiB**, before worst-case checkpoint/page-cache pressure. That overlaps the 12 GiB watchdog kill line.
4. Keep one engine slot and put a queueing, token-aware router on port 8013:
   `Tailnet → Caddy:8010 → auth:8014 → router:8013 → llama.cpp:8011`.
5. Use exact-prefix caching and saved slot states for conversations and canonical corpus prefixes. Use SQLite FTS5/BM25 skim mode only for uncached requests whose predicted prefill exceeds ten seconds.
6. Persist token transcripts every turn, but initially persist full DSV4 snapshots only at ingest, idle boundaries, explicit pins, and periodic high-water marks. Existing llama.cpp whole-state serialization makes a 1M snapshot approximately **6.7 GiB**, so “rewrite the full state every turn” is not viable.
7. Budget roughly **4–6 engineer-weeks** for a hardened phase-2 implementation. True incremental every-turn KV persistence is another **3–6 weeks** of engine work.

The major correction to the original premise is that this model’s current f16 compressed cache is not about 4 GiB at 1M. The source-derived value is about **6.76 GiB**, because CSA, HCA, and the lightning-indexer cache all contribute.

The official model declares a 1,048,576-token context and supplies a dedicated encoder package, so 1M is architecturally intended—but not necessarily safe with this particular quant, batch geometry, and 119 GiB UMA envelope. [DeepSeek-V4-Flash model card](https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash)

---

## B. Context ladder

### Memory basis

Observed local facts:

- Physical/unified memory: approximately **119.67 GiB**.
- Weight shards: **96,832,507,552 bytes = 90.18 GiB**, from the pinned manifest at [unsloth-ud-q2_k_xl.json](/home/bmarti44/spark-deepseek-v4-flash/configs/pins/unsloth-ud-q2_k_xl.json:5).
- Current 32K/`-ub 512` soak:
  - baseline MemAvailable: **20.971 GiB**
  - minimum: **20.903 GiB**
  - 96 requests, zero errors  
  [soak-llamacpp.json](/home/bmarti44/spark-deepseek-v4-flash/results/soak-llamacpp.json:31)
- Production launch gate: 16 GiB projected free.
- Watchdog termination line: 12 GiB.  
  [launcher](/home/bmarti44/spark-deepseek-v4-flash/scripts/21_serve_llamacpp.sh:409)

The current launcher’s `4096` KV bytes/token estimate is too low for DSV4 and should be replaced in phase 2. [Current estimate](/home/bmarti44/spark-deepseek-v4-flash/scripts/21_serve_llamacpp.sh:414)

### Exact persistent DSV4 cache scaling

For the current architecture and f16 K cache:

- Raw 128-token SWA, all 43 layers:

  `43 × 512 × 2 × PAD(min(n_ctx, 128 + n_ubatch), 256)`

- CSA, 21 layers, compression ratio 4:

  `21 × 512 × 2 × n_ctx/4 = 5,376 bytes/token`

- HCA, 20 layers, compression ratio 128:

  `20 × 512 × 2 × n_ctx/128 = 160 bytes/token`

- Lightning indexer, 21 layers, 128 dimensions, ratio 4:

  `21 × 128 × 2 × n_ctx/4 = 1,344 bytes/token`

Total long-context slope:

`5,376 + 160 + 1,344 = 6,880 bytes/token`

The compressor rings add approximately 11.64 MiB per slot. Raw SWA padding comes from [llama-kv-cache-iswa.cpp](/home/bmarti44/spark-deepseek-v4-flash/vendor/llama.cpp/src/llama-kv-cache-iswa.cpp:69).

### Predicted memory ladder

Values in the cache column are tensor plus compressor-ring memory. Add up to roughly 35 MiB of cell metadata at 1M. Graph values are only the identifiable `n_ctx × n_ubatch` lower bound; the headroom forecast includes a larger scheduler-buffer allowance calibrated from current measurements and upstream DSV4 logs.

| Context | DSV4 f16 cache GiB, `ub512 / ub2048` | Context-dependent graph floor GiB, `ub512 / ub2048` | Predicted MemAvailable GiB, `ub512 / ub2048` | Recommendation |
|---:|---:|---:|---:|---|
| 64K | 0.463 / 0.526 | 0.094 / 0.330 | 20.3–20.7 / 18.0–19.5 | Both viable; qualify `ub512` first |
| 128K | 0.883 / 0.946 | 0.188 / 0.660 | 19.7–20.1 / 17.0–18.5 | Production candidate |
| 256K | 1.723 / 1.786 | 0.377 / 1.320 | 18.3–18.9 / 14.5–16.5 | Recommended production rung at `ub512`; `ub2048` experimental |
| 512K | 3.402 / 3.465 | 0.754 / 2.641 | 15.5–16.6 / 10.0–12.5 | Conditional at `ub512`; reject `ub2048` |
| 1,048,576 | 6.762 / 6.825 | 1.508 / 5.281 | 10.5–12.0 / 1–4 | Not production-safe as configured |

Why `-ub 2048` hurts so badly: DSV4 builds attention masks, lightning-indexer scores, and selection intermediates whose size grows with both context and physical batch. Upstream’s initial DSV4 benchmark reported approximately **24.5 GiB CUDA plus 16.9 GiB CUDA-host compute buffers** with a 1M-sized graph and `ub8192`, confirming that scratch—not just compressed K—is the danger. [Upstream DSV4 PR and benchmark](https://github.com/ggml-org/llama.cpp/pull/24162)

Other allocations:

- Logits do not scale materially with context. With one slot, a full vocabulary float vector is only about 0.5 MiB.
- Indexer top-k output scales with `512 × n_ubatch`, not `n_ctx`; the large object is its pre-top-k score/mask.
- Checkpoints do not carry the full compressed K arrays, but they do carry live SWA plus all F32 compressor rings: approximately **17 MiB each**. The compiled defaults are 32 checkpoints and 8,192-token spacing. [common.h](/home/bmarti44/spark-deepseek-v4-flash/vendor/llama.cpp/common/common.h:625)
- Cap production at four checkpoints initially, about 68 MiB per slot, then increase only if the divergence/churn test proves a need.

### Cold-prefill forecast

Current measured rates at `ub512` are 291 tokens/s at 4K, 284 at 16K, and about 274 at 28K. [speed-llamacpp.json](/home/bmarti44/spark-deepseek-v4-flash/results/speed-llamacpp.json:87)

Long-context attention and indexer work make extrapolation nonlinear. Planning ranges:

| Context | Cold TTFT, `ub512` | Cold TTFT, `ub2048` |
|---:|---:|---:|
| 64K | 4–5 minutes | 2–3 minutes |
| 128K | 10–12 minutes | 5–7 minutes |
| 256K | 25–30 minutes | 12–18 minutes |
| 512K | 75–90 minutes | 35–55 minutes, but memory-unsafe |
| 1M | 3–5 hours | 1.5–3 hours, but memory-unsafe |

These are capacity-planning ranges, not acceptance numbers. Upstream measured 103 seconds at 64K, 241 seconds at 128K, 624 seconds at 256K, and 1,861 seconds at 512K using a much larger `ub8192` configuration, while throughput declined substantially with length. [Upstream measurements](https://github.com/ggml-org/llama.cpp/pull/24162)

This confirms that ingest-time prefill and persistent restore are product requirements, not optional optimization.

### Hard implementation limits

No source-level limit below the advertised 1M was found:

- The server caps each slot at the model’s training context. [server-context.cpp](/home/bmarti44/spark-deepseek-v4-flash/vendor/llama.cpp/tools/server/server-context.cpp:1245)
- Positions are signed 32-bit and cache sizes/indices are generally unsigned 32-bit; 1,048,576 is comfortably inside both.
- GGML tensor dimensions and strides use wider types for the large score tensors.
- Indexer top-k is dynamically clamped to `min(visible_rows, configured_top_k)`, so top-k 512 is not a length cap. [deepseek4.cpp](/home/bmarti44/spark-deepseek-v4-flash/vendor/llama.cpp/src/models/deepseek4.cpp:588)
- `1M × ub2048` reaches 2³¹ token/query pairs. No obvious host overflow exists, but the fused CUDA indexer must be tested explicitly at that geometry.
- Do not exceed 1,048,576: the model was configured and trained for that ceiling, and the server caps slot capacity to it.

### Rung promotion gates

Every rung must pass all of the following before moving upward:

1. **Memory**
   - `--cache-ram 0`, four checkpoints.
   - Full graph allocation, 95%-full prompt, decode, save, and cold restore.
   - No MemAvailable sample below 16 GiB.
   - Immediate hard abort below 12 GiB.
   - No swap, memory compression, CUDA allocation failure, or page-fault storm.

2. **Fidelity**
   - 30 literal needles distributed at 5/25/50/75/95% positions: 100%.
   - RULER retrieval, multi-key, multi-hop, and aggregation aggregate score ≥95% of the 64K baseline; no task below 90% of its baseline.
   - NoLiMa score ≥90% of the 64K baseline.
   - NoLiMa is necessary because literal needles can greatly overstate effective context. [NoLiMa, ICML 2025](https://proceedings.mlr.press/v267/modarressi25a.html)
   - RULER explicitly tests multi-hop and aggregation beyond vanilla needle retrieval. [RULER](https://arxiv.org/abs/2404.06654)

3. **TTFT**
   - Record actual compute-buffer sizes and cold prefill curves.
   - Completion within 1.5× the rung forecast.
   - No unexplained zero-progress interval over 60 seconds.
   - Restore p95 must be lower than recomputing at least 4K tokens.

4. **Soak**
   - Restore or prefill to ≥90% of the rung.
   - Run the equivalent of the existing 30-minute/96-request soak with divergent suffixes and periodic state switches.
   - Zero errors, decode degradation ≤25%, and memory floor maintained.

The expected stopping point is 256K. A 512K pass is plausible but not guaranteed. A 1M production pass is unlikely without reclaiming approximately 4–6 GiB through some combination of a smaller weight quant, validated q8 K cache, smaller `ub`, and checkpoint/page-cache reductions.

---

## C. Component designs

## 1. Cache layer

### What exists today

- `cache_prompt=true` performs an exact longest-common-prefix comparison with the selected slot and evaluates only the unseen suffix. llama.cpp deliberately reevaluates one token when the entire prompt matches so it can obtain logits. [Server documentation](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md) and [implementation](/home/bmarti44/spark-deepseek-v4-flash/vendor/llama.cpp/tools/server/server-context.cpp:3337)
- `--cache-ram` is an in-process FIFO prompt-state cache, not restart persistence. Its default is 8 GiB, but this deployment explicitly disables it. [Server cache options](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- Loading a `--cache-ram` entry consumes/removes its backing byte vector; it is effectively a move, not a reusable serve-many copy. [server-task.cpp](/home/bmarti44/spark-deepseek-v4-flash/vendor/llama.cpp/tools/server/server-task.cpp:1737)
- `/slots/{id}?action=save|restore|erase` exists when `--slot-save-path` is configured. [llama.cpp slot API](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- Full DSV4 state save/restore **is supported at this pin**. It serializes raw SWA, CSA K, HCA K, indexer K, and all three compressor-ring states with magic/version checks. [DSV4 state writer/reader](/home/bmarti44/spark-deepseek-v4-flash/vendor/llama.cpp/src/llama-kv-cache-dsv4.cpp:1317)
- Full compressed tensors are serialized at their allocated cache size, not merely the used token count. [K-cache serialization](/home/bmarti44/spark-deepseek-v4-flash/vendor/llama.cpp/src/llama-kv-cache-dsv4.cpp:292)
- Context shifting and arbitrary middle-chunk reuse are disabled because compressed-row positions have not been made shift-safe. [get_can_shift](/home/bmarti44/spark-deepseek-v4-flash/vendor/llama.cpp/src/llama-kv-cache-dsv4.cpp:1198)
- The July churn/rollback defect reported in issue #25452 has a merged fix in the pinned lineage; the fix clears compressed caches after checkpoint restore. [Issue #25452](https://github.com/ggml-org/llama.cpp/issues/25452), [merged PR #25588](https://github.com/ggml-org/llama.cpp/pull/25588)

### What to build

- A router-owned catalog mapping:
  - tenant
  - model/config fingerprint
  - canonical token prefix
  - active slot or snapshot filename
  - token count, bytes, save/restore timings, last hit
- Immutable full snapshots for:
  - ingested corpus prefixes
  - explicitly pinned conversations
  - periodic conversation high-water marks
  - small numbers of common cross-corpus bundles
- A per-turn token/transcript journal.
- Snapshot cadence: ingest completion, idle boundary, explicit pin, every 32K–64K new tokens, and before planned shutdown.
- Later: incremental compressed-cache journaling so only newly sealed CSA/HCA/indexer blocks and compressor-ring state are written.

### Effort and risks

- Catalog/full-snapshot lifecycle: **5–8 days**.
- Incremental every-turn persistence: **3–6 additional weeks**.
- Main risks:
  - state files are tightly coupled to model, context, cache type, encoder, and llama commit;
  - whole-state writes are 6.7 GiB at 1M;
  - arbitrary reordered documents are not reusable;
  - saved states contain recoverable corpus/conversation information.

Keep `--cache-ram 0` at 512K and above. One 1M state plus checkpoints nearly fills the default 8 GiB RAM cache and directly consumes the watchdog reserve.

### Multi-user behavior

With non-unified KV, `-c` is aggregate context and is divided by `-np`; `-c 1M -np 2` gives roughly 512K per slot. [Context partitioning](/home/bmarti44/spark-deepseek-v4-flash/vendor/llama.cpp/src/llama-context.cpp:260)

For DSV4, forcing unified KV does not solve this: the implementation explicitly maintains raw/compressed streams per sequence even when public KV mode says unified. [DSV4 constructor](/home/bmarti44/spark-deepseek-v4-flash/vendor/llama.cpp/src/llama-kv-cache-dsv4.cpp:998)

Therefore:

- Keep `-np 1`.
- Serialize work through the router.
- Switch tenant-owned disk states as needed.
- Never share private prefixes across tenants.
- Allow sharing only for corpora explicitly marked public.

## 2. Smart router

### Placement

Use a new loopback service:

`Caddy:8010 → forward_auth:8014 → router:8013 → llama.cpp:8011`

Do not put routing in `40_auth_helper.py`. The helper currently performs bounded authorization/rate limiting and does not parse request bodies. [auth helper](/home/bmarti44/spark-deepseek-v4-flash/scripts/40_auth_helper.py:57)

Caddy should continue authenticating first and stripping client authorization before upstream forwarding. [Caddyfile](/home/bmarti44/spark-deepseek-v4-flash/configs/caddy/Caddyfile:9)

For multi-key operation, the auth helper should return a trusted tenant identifier that Caddy copies to the router. The router must ignore any client-supplied tenant header.

### Request algorithm

1. Validate body size, endpoint, tenant, and `context_mode=auto|full|skim`.
2. Render with the pinned official DSV4 encoder and tokenize with the pinned tokenizer. The existing parity harness already loads the correct files. [33_token_parity.py](/home/bmarti44/spark-deepseek-v4-flash/scripts/33_token_parity.py:21)
3. Find the longest exact token prefix among:
   - active slot state;
   - compatible saved conversation states;
   - compatible corpus/bundle states.
4. If a disk state wins, wait for slot idle and restore it.
5. Compute `n_miss = total_tokens - cached_prefix_tokens`.
6. Route:
   - explicit `full`: full mode;
   - explicit `skim`: skim mode;
   - catalog cache hit: full mode;
   - uncached and predicted prefill ≤10 seconds: full mode;
   - otherwise: skim mode.
7. Set `id_slot=0`, `cache_prompt=true`, forward, and compare reported `cached_tokens` with the prediction. Repair or invalidate the catalog on disagreement.

`/slots` exposes occupancy, context size, timings, and processing state, but not a safe authoritative token-prefix inventory. [GET `/slots`](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md) The router therefore needs its own token trie/catalog.

Prefer passing canonical token IDs to the native completion endpoint and translating the response to OpenAI form. That removes renderer drift between router and server. Tool calls, multimodal inputs, and unsupported structured-output cases should initially force full mode or return an explicit unsupported error; they must never be silently skimmed.

### Ten-second threshold math

Initial conservative model:

`T_prefill = α + n_miss / r_p10(n_past_bucket, ubatch)`

Where:

- `α ≈ 0.5 s`
- initial conservative rate `r_p10 ≈ 274 token/s`
- exact mathematical cutoff:

  `(10 - 0.5) × 274 ≈ 2,603 tokens`

Use an operational cutoff of **2,450 uncached tokens** until enough shadow traffic exists.

Track two values separately:

- mode decision: `T_prefill`
- user-visible forecast: `Q_queue + R_restore + T_prefill`

Build EWMAs and conservative P10 rates by `n_past` bucket because miss cost at a 512K cached prefix will not match miss cost from position zero.

A one-token/BOS match is not a meaningful cache hit. “Cached” should mean a cataloged conversation/corpus state match, not incidental prompt overlap.

### Response tagging

Every response must include:

- `X-DeepSeek-Context-Mode: full|skim`
- non-stream JSON:

```json
{
  "context_mode": "skim",
  "skim": {
    "corpus_versions": ["repo-a@manifest-sha256"],
    "retrieved_chunk_ids": ["..."],
    "retrieved_tokens": 1832,
    "candidate_tokens": 428117
  }
}
```

For SSE, the header is always present before streaming. An optional first metadata event can be enabled for clients that explicitly request it.

### Effort and risks

- Functional router: **5–8 days**.
- Hardening, SSE, schemas, metrics, fairness: **another 5–8 days**.
- Expected size: roughly 500–800 lines plus tests.
- Risks: encoder drift, restore races, one-slot head-of-line blocking, oversized request DoS, and capability gaps between native completion and OpenAI chat APIs.

Caddy’s current 10 MB body limit can reject large JSON/code contexts; phase 2 should raise it to about 64 MB while the router enforces decompressed-byte and token quotas.

## 3. Retrieval skim mode

### Initial stack

Use **SQLite FTS5/BM25**, CPU-only:

- effectively zero GPU residency;
- easy immutable per-corpus indexes;
- supports BM25 ranking, tokenization extensions, metadata filters, and transactions. [SQLite FTS5](https://www.sqlite.org/fts5.html)

BEIR found BM25 to be a robust zero-shot baseline, while also showing that learned retrieval/reranking can improve some datasets at added cost. [BEIR](https://arxiv.org/abs/2104.08663)

Only add a dense retriever if the lexical recall gate fails. The fallback should be a CPU ONNX deployment of `BAAI/bge-small-en-v1.5`, roughly 33M parameters/133 MB and 384-dimensional embeddings, never placed on CUDA. [BGE model card](https://huggingface.co/BAAI/bge-small-en-v1.5)

### Chunking

| Content | Chunking |
|---|---|
| Code | AST function/class/module chunks where available; 150–400 official tokens; 30–60 overlap; index path, basename, symbols, imports, snake/camel splits and identifier trigrams |
| Prose | Heading/paragraph bounded; 300–600 tokens; 50–100 overlap; preserve title and section hierarchy |
| Generated/config files | Exact line-aware chunks; store source hash and line range; lower default ranking unless explicitly requested |

Retrieve approximately 20 candidates, then fuse:

- BM25 score
- exact identifier/path matches
- adjacent chunks
- recency/version
- deduplication

The final evidence budget should initially be only **1,500–2,000 tokens**, leaving room for instructions and the query under the 2,450-token full-prefill threshold. An 8K or 16K “skim” would still take roughly 30–60 seconds on the current measured engine unless that skim prefix is itself already cached.

### Fidelity contract

Skim mode cannot honestly guarantee:

- exhaustive absence or count questions;
- global invariants over the whole corpus;
- multi-document joins when retrieval misses a bridge;
- paraphrases/synonyms under lexical-only retrieval;
- semantic relationships with little word overlap.

Those cases remain full mode, or are returned with an explicit “retrieval-limited” tag. NoLiMa’s results are particularly relevant: literal overlap makes retrieval look much easier than semantic long-context use. [NoLiMa](https://proceedings.mlr.press/v267/modarressi25a.html)

For large unregistered requests, require an explicit `documents[]` or `corpus_ids[]` structure. Do not guess which part of an arbitrary chat message is the query versus the document collection.

## 4. Ingest pipeline

### Storage layout

```text
/home/dsv4/cache-v2/
  <engine-model-encoder-fingerprint>/
    <tenant>/
      <corpus-id>/
        <manifest-hash>/
          manifest.json
          sources.jsonl
          tokens.u32le
          fts.sqlite
          slot.state.tmp
          slot.state
          READY
```

Fingerprint all of:

- llama binary SHA and commit;
- every GGUF shard SHA;
- official encoder/tokenizer hashes;
- wrapper/schema version;
- context, batch and ubatch;
- K cache type;
- RoPE/YaRN settings;
- DSV4 state-format version.

A state mismatch should be rejected by the router before llama.cpp attempts restore.

### Invalidation and canonicalization

- Repositories: manifest Git commit, path policy, and blob/content hashes.
- Document sets: SHA-256 exact source bytes plus normalized metadata.
- Immutable version directories.
- Write to temporary paths, fsync, rename, then create `READY`.
- Place volatile documents late in canonical order to maximize reusable LCP after edits.
- Never overwrite the only ready state before the replacement is verified.

A corpus snapshot must be an exact prefix of future query prompts. Test this across 100 appended-query variants. If the official renderer changes earlier tokens when a new turn is appended, use a direct-token corpus wrapper designed to be prefix-stable.

### Scheduling

`nice`, `ionice`, `CPUWeight`, and `IOWeight` cannot prioritize GPU kernels. Therefore ingest must not run concurrently with live model work.

Use:

- systemd path/timer to enqueue changed manifests;
- router-issued maintenance lease;
- begin only after 60 seconds idle, queue length zero, and MemAvailable ≥16 GiB;
- append at most 1,024–2,048 tokens per maintenance quantum;
- check for live work between quanta;
- stop ingest promptly when a foreground request arrives.

Existing completion semantics may generate a token even with `max_tokens=0`. If confirmed, add a loopback-only, token-level **prefill-only/append endpoint** to llama-server. It should:

- require the expected prior position and state fingerprint;
- accept raw token IDs;
- evaluate without sampling;
- return new position and timings;
- yield control after each block.

Estimated engine patch and tests: **5–10 days**.

Large cold corpora still require maintenance windows: 1M prefill can take hours.

### Restore latency and disk budget

Disk facts:

- Current free space: approximately **498.3 GiB**.
- Existing preflight requires at least **350 GiB** free. [preflight](/home/bmarti44/spark-deepseek-v4-flash/scripts/00_preflight.sh:6)

Use a **128 GiB cache quota** initially, preserving the existing reserve. That holds roughly 18 full 1M f16 states after indexes and metadata.

A 1M state is about 6.7 GiB, not 4 GiB. Expected restore:

- sequential NVMe read: roughly 2–4 seconds under favorable conditions;
- state validation, host/device/UMA copies, and contention: plan for **3–10 seconds cold p95**;
- measure rather than promising 1–2 seconds.

After save/restore, advise the kernel that the state-file pages are no longer needed so 6.7 GiB of page cache does not evict model pages. Use per-file `posix_fadvise(DONTNEED)`, not global page-cache dropping.

Eviction score should combine value and size, for example:

`saved_prefill_seconds × recent_hits / (bytes × age_penalty)`

Priority:

1. pinned/public corpora;
2. active conversation checkpoints;
3. hot corpus bundles;
4. one-off conversation states.

Per-corpus states cannot be concatenated. For common multi-corpus queries, prebuild a small set of canonical ordered bundle states; otherwise use skim mode.

### Security

- Service-owned directories mode 0700, files 0600.
- Tenant-separated catalogs, states, and retrieval indexes.
- Do not expose `/slots`, `/props`, metrics, or ingest endpoints through Caddy.
- Treat states as equivalent to the underlying corpus/conversation for backup and encryption policy.
- Apply per-tenant storage, token, request-size, queue-time, and snapshot quotas.

---

## D. What existing systems contribute

| System/work | Portable idea | Why its data plane is not drop-in |
|---|---|---|
| SGLang RadixAttention | Router-owned exact token radix tree and LCP-aware eviction | Assumes engine-managed page-addressable KV, unlike whole DSV4 compressed states and rings. [SGLang paper](https://arxiv.org/abs/2312.07104) |
| RAGCache | Knowledge tree, retrieval-aware replacement | vLLM/Faiss implementation, not llama.cpp DSV4. [RAGCache](https://arxiv.org/abs/2404.12457) |
| CacheBlend / EPIC | Potential arbitrary/reordered-document cache reuse | Require position correction and selective per-layer recomputation; current DSV4 has neither shift-safe compressed rows nor chunk injection. [CacheBlend](https://www.microsoft.com/en-us/research/uploads/prod/2024/09/eurosys25-final999.pdf), [EPIC](https://arxiv.org/abs/2410.15332) |
| LMCache | Chunk hashes, async puts, storage quotas, prefetch/control APIs | Current supported engines are vLLM and SGLang; no llama.cpp connector, and DSV4 compressor state is more than ordinary KV pages. [LMCache integration](https://docs.lmcache.ai/developer_guide/integration.html), [local storage](https://docs.lmcache.ai/kv_cache/local_storage.html) |
| SGLang HiCache | GPU/CPU/file hierarchy and tier-aware scheduling | Same engine/page-layout mismatch; borrow policy, not implementation. [HiCache 2025](https://www.lmsys.org/blog/2025-09-10-sglang-hicache/) |
| Strata | Treat restore I/O and fragmentation as scheduler inputs | SGLang production system, not a whole-state llama adapter. [Strata 2025](https://arxiv.org/abs/2508.18572) |
| Mooncake | KV cache as primary storage/communication object | Designed for disaggregated clusters; useful validation of the state-first architecture, not the single-Spark implementation. [FAST ’25 paper](https://www.usenix.org/conference/fast25/presentation/qin) |
| Tutti | Bulk SSD objects and slack-aware I/O scheduling | 2026 vLLM/GDS work; useful evidence that restore I/O must be scheduled, but not portable here. [Tutti 2026](https://arxiv.org/abs/2605.03375) |
| vLLM Router | Prefix-aware worker routing, circuit breakers, metrics | It chooses among vLLM replicas; this product has one llama slot and must choose full/skim plus state files. [vLLM Router](https://github.com/vllm-project/router) |

Conclusion: write the small stack-specific router. Borrow tries, fingerprints, metrics, quotas, and eviction policies; do not adopt a cluster gateway whose cache assumptions do not match DSV4.

---

## E. Build order and acceptance tests

These are proposed phase-2 harness interfaces, not files that currently exist.

1. **Freeze phase 1 and declare phase-2 protocol v1**

   - Add a separate protocol/version and output directory.
   - Do not rewrite current results or manifests.
   - Record all context, cache, retrieval, and router gates before the first qualifying run.
   - This follows the current standing rule in [PROTOCOL.md](/home/bmarti44/spark-deepseek-v4-flash/PROTOCOL.md:40).

2. **Memory model and context launcher**

   Add architecture-aware DSV4 budgeting and log parsing.

   ```bash
   python3 scripts/50_bigctx_ladder.py \
     --ctx 65536 --ubatch 512 \
     --out results/phase2/ladder-64k-u512.json
   ```

   Acceptance: predicted persistent cache within 5% of llama’s logged cache allocation; peak memory within 15% of forecast; ≥16 GiB minimum.

3. **Long-context fidelity harness**

   ```bash
   python3 scripts/51_longctx_fidelity.py \
     --ctx 65536 --ruler --nolima --needle \
     --out results/phase2/fidelity-64k.json
   ```

   Acceptance: all fidelity thresholds above; deterministic manifest, seeds, and official token counts.

4. **DSV4 save/restore and churn qualification**

   Configure slot-save path, four checkpoints, cache-ram zero.

   ```bash
   python3 scripts/52_slot_roundtrip.py \
     --ctx 65536 --turns 20 --restarts 3 \
     --out results/phase2/slot-roundtrip-64k.json

   python3 scripts/53_dsv4_churn.py \
     --ctx 65536 --iterations 1200 \
     --out results/phase2/churn-64k.json
   ```

   Acceptance:

   - 20/20 restored prompts report all but the mandatory final token cached;
   - no state mismatch or context exhaustion;
   - no divergent turn unexpectedly re-prefills the full prompt;
   - state file permissions and fingerprint rejection pass;
   - cold restore p50/p95 recorded.

5. **Router in shadow mode**

   Router computes decisions and LCPs but traffic still uses the existing path.

   ```bash
   python3 scripts/54_router_trace.py \
     --fixtures tests/phase2/router-fixtures.jsonl \
     --prefill-budget-s 10 \
     --out results/phase2/router-shadow.json
   ```

   Acceptance:

   - official encoder parity on every fixture;
   - predicted cached tokens match server-reported tokens within one;
   - 100% correct mode choice from the frozen policy;
   - no request or response mutation in shadow mode.

6. **Skim retrieval**

   ```bash
   python3 scripts/55_skim_eval.py \
     --registry tests/phase2/corpora.json \
     --full-baseline results/phase2/full-baseline.json \
     --out results/phase2/skim-eval.json
   ```

   Acceptance:

   - exact identifier/path queries ≥98% answer accuracy versus full mode;
   - paraphrase queries ≥90%;
   - multi-hop/negative/count cases either meet their frozen threshold or are classified “full required”;
   - all skim responses carry mode and provenance tags;
   - composed prompt ≤2,450 uncached tokens.

7. **Ingest worker and prefill-only endpoint**

   ```bash
   python3 scripts/56_ingest_acceptance.py \
     --corpus tests/phase2/sample-repo \
     --interrupt-after-blocks 10 \
     --out results/phase2/ingest.json
   ```

   Acceptance:

   - foreground work gains the lease within five seconds of a block boundary;
   - no concurrent foreground/ingest decode;
   - immutable READY transition;
   - changed source invalidates the old manifest;
   - unchanged content reuses the prior state;
   - interrupted temporary states are never restored.

8. **Caddy cutover and security**

   Acceptance:

   - router is the only engine-facing upstream;
   - `/slots`, `/props`, ingest, and metrics are externally blocked;
   - spoofed tenant headers fail;
   - cross-tenant state/retrieval hits are impossible;
   - oversized and over-token requests fail before engine allocation;
   - SSE tags and error propagation work.

9. **Rung promotion**

   Execute 64K → 128K → 256K → 512K → 1M, always `ub512` first. Run `ub2048` only after the same rung passes at `ub512`.

   Production selects the largest rung that passes every gate. Do not reinterpret a 12–16 GiB result as “close enough”; it remains experimental.

10. **Optional R&D**

   - q8 K cache qualification;
   - `ub256` at 1M;
   - smaller weight quant;
   - incremental DSV4 state journals;
   - position-independent document cache research.

---

## F. Open questions and exact cheap experiments

| Question | Cheapest decisive experiment |
|---|---|
| Actual scratch per rung | After phase 1, launch each rung with `cache-ram=0`, one slot, four checkpoints; parse CUDA/CUDA-host compute-buffer logs and sample MemAvailable through one 1K request. Abort below 16 GiB. |
| Is `ub2048` worth its memory? | At 64K and 128K, run identical 4K/16K/64K prefills at ub512 and ub2048; compare p50 TTFT, energy/time, and minimum memory. Promote only if speedup is ≥1.5× with ≥16 GiB free. |
| Does `max_tokens=0` truly prefill only? | At 64K, submit a 1K-token request with zero output requested; inspect generated-token count and slot length. Any sampled token triggers the dedicated endpoint work. |
| Full-state size depends on used length? | Under the same 256K context, save once after 1K and once after 200K. Compare `n_written`. Source predicts nearly equal compressed-state size. |
| Cold restore latency | For one 256K and one 512K state, call per-file `posix_fadvise(DONTNEED)`, then perform ten restores; record p50/p95 bytes/s, MemAvailable, and major faults. |
| Checkpoint requirement | At 64K, repeat 40 divergent turns with checkpoint caps 0/4/8/32; compare correctness, refilled tokens, context-exhaustion errors, and memory. |
| Router LCP accuracy | Generate 100 variants covering append, divergence, shorter prompt, Unicode and tool markers; compare trie prediction to reported cached tokens. |
| Ten-second model accuracy | Measure misses of 512/1K/2K/4K tokens at cached positions 0/64K/256K/512K; fit P10 rates per bucket and require ≤10% underprediction at p95. |
| Prefix-stable corpus rendering | Render one corpus plus 100 distinct appended queries; require the entire stored token vector to remain an exact prefix. Otherwise switch to the direct-token wrapper. |
| Lexical retrieval sufficiency | Evaluate 100 code and 100 prose questions split among exact, paraphrase, multihop, absence and count. Add BGE only if paraphrase recall misses the frozen target. |
| q8 K correctness | At 64K, compare f16 versus q8 K on token parity, needles, RULER and 1,200-turn churn; then repeat at 256K. Any unexplained mismatch rejects q8 for production. |
| 1M feasibility | Attempt only after 512K passes. Allocate/start, run a 1K request, then a staged 64K→256K→512K→95%-full prefill. Hard abort below 12 GiB; production requires ≥16 GiB throughout. |
| Slot partition semantics | At 64K only, run `-np 2` with and without unified mode and inspect per-slot context plus allocation logs. Do not use forced unified mode at larger rungs until memory multiplication is proven safe. |
| State compatibility guard | Restore once under an identical fingerprint, then alter one catalog fingerprint field at a time; router must reject every mismatch before invoking the engine. |

## Bottom line

The buildable product is a **single 256K–512K DSV4 slot backed by exact-prefix disk states, a token-aware router, and CPU lexical retrieval**. It can make registered corpora and long conversations feel fast after ingest while accurately labeling retrieval-limited responses.

The literal strongest form of the spec—arbitrary re-seen documents in any order, full-state persistence after every turn, never any re-prefill—does not exist in current llama.cpp. It requires incremental, chunk-addressable DSV4 state serialization and eventually position-independent cache fusion. Phase 2 should deliver the useful exact-prefix version first, with those limitations explicit.