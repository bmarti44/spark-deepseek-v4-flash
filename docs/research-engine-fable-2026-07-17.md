# Engine choice for DeepSeek-V4-Flash on one DGX Spark — deep research report

Date: 2026-07-16 (brief dated 2026-07-17). Read-only pass; no server touched, no requests to :8010/:8011/:8012.

**Scope note on local sources:** `/home/dsv4/llamacpp-project/src/llama.cpp` is not readable by this user
(permission denied on `/home/dsv4`). Equivalent verification was done against the repo's own vendored checkout
`/home/bmarti44/spark-deepseek-v4-flash/vendor/llama.cpp`, confirmed to be at the exact pin
`32e789fdfd598e9a1872da55ac941e4d94f030bd` (git log, 2026-07-16). Everything marked [src] below was verified in
that tree; [local] means this repo's own docs/results; [web] means cited URL.

---

## 1. Comparison table

| Criterion | llama.cpp (pin 32e789fd) | vLLM | SGLang | TensorRT-LLM | ktransformers | MLC-LLM | ollama |
|---|---|---|---|---|---|---|---|
| **1. Runs DSV4-Flash on GB10/sm_121/aarch64 today** | **Yes — proven on this exact box.** DSV4 arch + `GGML_OP_LIGHTNING_INDEXER` + DSV4 KV cache in the pin [src]; benchmark suites passed here [local] | Upstream V4 support exists (PR #40760, day-0 2026-04-24) but the CSA/DSA path needs DeepGEMM/FlashMLA kernels that have **no SM12x build**; no verified single-Spark V4 run exists. Working GB10 recipes are community forks on **2× Sparks** | Day-0 V4 support (LMSYS 2026-04-25) but sparse path hard-blocked on SM120/121 (DeepGEMM `get_paged_mqa_logits_metadata` has no SM12x impl, issue #23657); no verified V4 run on sm_121 | GB10 support "beta" (rel. 1.2, official Spark playbook). "DSv4 sparse MLA" landed v1.3.0rc21 (~yesterday); **V4-Flash CSA/HCA specifically unconfirmed**; no Spark V4 report | V4-Flash supported (May 2026) but recipe is x86 AVX512 + discrete GPU; aarch64 build fails (issue #1690); zero sm_121 evidence | No — newest DeepSeek work is V3 (PR #3192); no CSA/HCA/indexer code | Wraps llama.cpp but does **not** expose slot save/restore; V4-Flash library entry is primarily `:cloud` |
| **2. Fits 284B in 119 GiB (2–3-bit format)** | **Yes**: UD-Q2_K_XL GGUF 90.2 GiB, running here [local] | **No**: FP8 ≈ 285 GB, NVFP4 checkpoint ~149 GB; GGUF support deprecated to an early-stage out-of-tree plugin with no V4/deepseek support; no 2-bit AWQ/GPTQ for DeepSeek MoE | **No**: native ckpt ~158 GB; W2/W3 schemes "lack real kernels"; GGUF deepseek arch unsupported (#4756) | **No**: ModelOpt floor is 4-bit (NVFP4 ~150–160 GiB); **cannot load GGUF at all** | Uses MXFP4/AMXINT4 from safetensors, ~4-bit GPU experts + CPU DDR — assumes a second memory pool that doesn't exist on UMA | No 2-bit MoE path found | Same GGUF as llama.cpp (if the arch is in its vendored llama.cpp) |
| **3. UMA-safe on freeze-on-OOM box** | Known-good: explicit `-c`/batch, membudget watchdog in this repo's scripts [local] | `gpu_memory_utilization` = fraction of the unified 128 GB pool; NVIDIA's own troubleshooting warns UMA "may encounter memory issues even within capacity"; Spark freeze-instead-of-OOM threads exist | Runs on a dev branch/community wheels; ubehera/sglang-spark documents **three UMA deadlock signatures** + a "wedge-watcher" | `free_gpu_memory_fraction` presumes discrete VRAM; NVIDIA advises dropping page caches before load; Spark zombie-hang threads | Architecturally moot on UMA (no CPU/GPU split to exploit) | Unknown | Inherits llama.cpp behavior |
| **4. Max ctx / MLA cache / prefix cache / disk persistence + restore** | 1M architectural cap in GGUF header; 4-store DSV4 cache with versioned `state_write/state_read` [src: llama-kv-cache-dsv4.cpp]; `--slot-save-path` + `POST /slots/{id}?action=save\|restore` + `--ctx-checkpoints` [src]; restore ≈ seconds (state ~6.7 GiB@1M, less compressed) [local plans] | 1M in dual-Spark recipes; prefix caching default; **sleep mode discards KV, nothing survives restart**; LMCache adds disk tiers + cross-restart persistence and announced V4 support (MP mode), but V4 IndexCache still an open issue (#45350) and unproven on Spark | RadixAttention prefix cache; HiCache L3 disk tier exists but local-file backend is "for demonstration purposes", sparse/hybrid-model HiCache is WIP (#12826), no documented restart-restore latency | KV reuse + host-RAM offload only; **no disk tier, cache dies with process**; Dynamo KVBM disk mode "[Experimental]", restart survival unstated | No KV persistence documented | n/a | **No** save/restore exposed; upstream auto-persist request closed "not planned" (#17107) |
| **5. Measured perf on GB10 (this model)** | **Measured on this box**: 13.9 tok/s decode @4K, 275–290 tok/s prefill, 28K envelope valid [local]; community IQ2_XXS single-GB10 ~12–15 tok/s; ds4 343.8 pp / 13.75 tg @7K — everyone is at the ~273 GB/s roofline | Single-Spark V4-Flash: **zero numbers exist** (doesn't fit). 2× Spark FP8 forks: 30–45 tok/s (Aiden), ~67 tok/s (MiaAI NVFP4, unreconciled spread), prefill 1.2–1.9K tok/s | No V4 numbers on GB10; gpt-oss-120b ~50 tok/s (LMSYS, dev branch, best-case) | No DeepSeek-on-Spark numbers at all; CUTLASS MoE pathologically slow on sm_121 (4.6 tok/s until Triton env workaround; issue closed "not planned") | None on Spark | None | ~= llama.cpp minus features |
| **6. Ops: OpenAI server / auth / build on aarch64+CUDA13+sm_121** | OpenAI-compat server, `--api-key`, systemd-friendly single binary, **already built and gated behind Caddy+auth here** [local] | OpenAI server + `--api-key`; but no stable cu130 aarch64 wheels (nightlies vanish, #28669); practical path = containers/forks | `--api-key`; needs `lmsysorg/sglang:spark` container or custom sm_121a wheels + patched NCCL; "severely lacking" per NVIDIA forum users | `trtllm-serve` OpenAI-compat, **no real API-key enforcement** (reverse proxy needed); NGC containers; rc-quality on GB10 | OpenAI endpoint, `--max-running-requests 2` cap | n/a | Easy but feature-poor |

---

## 2. Per-engine detail

### 2.1 llama.cpp (status quo) — pin 32e789fd

**Model support [verified in source, vendor/llama.cpp @ pin]:**
- `LLM_ARCH_DEEPSEEK4` (src/llama-arch.{h,cpp}); `GGML_OP_LIGHTNING_INDEXER` (ggml/include/ggml.h:573);
  Hadamard rotation tensors for the indexer (src/llama-kv-cache.cpp:325-327).
- Dedicated `src/llama-kv-cache-dsv4.cpp` implementing the 4-store cache (raw SWA-128 ISWA, CSA 4:1,
  HCA 128:1, indexer keys) **with complete state write/read plans** (`dsv4_state_write_k_cache` /
  `dsv4_state_read_k_cache`, per-sequence FULL/PARTIAL modes) — i.e., disk slot save/restore for this exact
  cache type is upstream, not a promise.
- `--slot-save-path` wired in common/arg.cpp:3288; server exposes `POST /slots/{id}?action=save|restore|erase`
  and `--ctx-checkpoints`/`--checkpoint-min-step` (verified via built binary per docs/bigctx-plan-fable).
- Upstream history: V4 merged 2026-06-29 (PR #24162), plus indexer op (PR #24231), quantized-KV fix (PR #25202),
  FA fixes (PR #25370), graph-split reduction (PR #25702) — all in the pin (docs/llamacpp-pin-choice.md).

**Fit / quant:** UD-Q2_K_XL GGUF = 90.2 GiB of 119.2 GiB; the only ≤3-bit ecosystem for this architecture is
GGUF (Unsloth UD, antirez asymmetric Q2, JANGTQ2 79.6 GB) — all llama.cpp-family formats.

**Context/persistence:** GGUF header says `context_length = 1,048,576` (YaRN ×16; hard cap). Compressed K-only
cache ≈ 6.7 KiB/token analytic → ~6.7 GiB at 1M; slot state file at 1M ≈ 4–6.7 GiB → restore in ~2–6 s at NVMe
rates (docs/research-1m-coldstart-fable). Known limits verified in source: `get_can_shift() == false` and
`seq_rm` refuses truncation → **no partial rollback / `--cache-reuse` is a no-op**; divergence = in-RAM
checkpoint restore or full re-prefill (docs/bigctx-plan-fable, llama-kv-cache-dsv4.cpp:1198-1237).

**Measured here [results/speed-llamacpp.json, results/DECISION.md]:** decode 13.7–13.9 tok/s flat 0→28K;
prefill 275–290 tok/s at `-ub 512` (TTFT 14.3 s @4K, 57.8 s @16K, 104.5 s @28K); GSM8K 97%, MMLU-Pro 74.1%,
HumanEval 73.8% at Q2. Community corroboration: single-GB10 V4-Flash IQ2_XXS ~12–15 tok/s
(https://forums.developer.nvidia.com/t/deepseek-v4-flash-iq2xxs-on-a-single-gb10/368970); ds4 README 343.8 pp /
13.75 tg @7K (https://github.com/antirez/ds4) — decode is at the ~273 GB/s bandwidth roofline
(13B active ≈ few GB/token), so **no engine can materially beat 13.9 tok/s single-stream at 2-bit on this box**.
Headroom is in prefill (`-ub` sweep; ds4 data shows wider chunks lift pp ~25%) and speculative decode
(DFlash/MTP infra is in the pin, draft-model availability unverified).

**Ops:** single binary, OpenAI-compatible, already productionized here (Caddy → auth helper → :8011),
NVIDIA even ships an official llama.cpp Spark playbook
(https://github.com/NVIDIA/dgx-spark-playbooks/tree/main/nvidia/llama-cpp).

**Risks to carry forward:** (i) PR #24162 comment threads report `--cache-type-k q8_0` garbage (fixed by
PR #25202, but repo runs fp16 K anyway) and **multi-turn amnesia after checkpoint restore** — the phase-2 plan's
restore-fidelity gate (prefill→save→erase→restore→compare) is mandatory before trusting persistence; (ii)
Q2 quality on a QAT-FP4-experts model may degrade more than V3.x-era intuition suggests
(https://arxiv.org/pdf/2505.02390 measured -14.66% avg for Q2_K_L on DeepSeek; Unsloth-V4-specific numbers
unverified) — this repo's own accuracy suite partially covers this (HumanEval 73.8% vs ds4's 89.6% at a
different quant is a hint the quant, not the engine, is the quality lever).

### 2.2 vLLM — REJECTED (decisive: no ≤3-bit format ⇒ cannot fit one Spark)

1. **Model support:** day-0 V4 (PR #40760; blog https://vllm-project.github.io/2026/04/24/deepseek-v4.html)
   covering CSA c4a/c128a + Lightning Indexer via DeepGEMM/FlashMLA — but those kernels target
   Hopper/datacenter Blackwell. SM120 fallback issue #40928 closed with unclear resolution; #40851 (sm_80)
   open; **no evidence the V4 kernel path runs on sm_121 at all**. vLLM's own DGX Spark blog
   (https://vllm-project.github.io/2026/06/01/vllm-dgx-spark.html) never mentions DeepSeek.
2. **Quant:** official recipe is FP8 (~285 GB); NVFP4 ckpt ~149 GB (https://huggingface.co/OsaurusAI/DeepSeek-V4-Flash-JANGTQ2)
   — **4-bit already misses 119 GiB**. GGUF was deprecated out-of-tree to `vllm-project/vllm-gguf-plugin`
   (v0.0.4, ~20 stars, "highly experimental"); no deepseek-V4 GGUF path exists and one would have to
   reimplement the entire sparse-attention stack. No 2-bit AWQ/GPTQ for DeepSeek MoE anywhere.
3. **UMA:** `--gpu-memory-utilization` is a fraction of the unified pool; NVIDIA warns of "memory issues even
   within capacity" (https://build.nvidia.com/spark/vllm/troubleshooting); acceptable but not comforting on a
   freeze-on-OOM box.
4. **Persistence:** sleep mode explicitly discards KV (https://docs.vllm.ai/en/latest/features/sleep_mode/).
   LMCache is the real answer — disk tiers, survives restarts, MLA-aware, **announced V4 support in MP mode**
   (https://x.com/lmcache/status/2055044595822776767) — genuinely more powerful than `--slot-save-path`
   (automatic chunk-level, cross-instance), but V4 Lightning-Indexer cache reuse is still an open issue
   (vllm #45350) and nothing is proven on Spark.
5. **Perf:** single-Spark V4-Flash: zero data (doesn't fit). Dual-Spark community forks: Aiden recipe FP8 TP=2,
   prefill 1,188–1,942 tok/s, decode 30–45 tok/s single-stream, 1M ctx operational
   (https://forums.developer.nvidia.com/t/deepseek-v4-flash-aiden-recipe-from-reddit-1m-token-session-operational-cuda-12-1-tailored-for-dgx-spark-gb10/372268);
   MiaAI-Lab NVFP4 recipe ~67 tok/s (https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark).
   The 45-vs-67 spread is unreconciled; both are forks, not upstream.
6. **Ops:** `vllm serve --api-key` is fine; but no stable cu130 aarch64 wheels (nightlies get deleted,
   vllm #28669/#43435); practical deployment = NGC container or fork images.

### 2.3 SGLang — REJECTED (decisive: V4 sparse path has no SM12x kernel — hard block, plus no ≤3-bit format)

1. Day-0 V4 support on datacenter GPUs (https://www.lmsys.org/blog/2026-04-25-deepseek-v4/), DSA precedent from
   V3.2. **Issue #23657**: V4's compressed attention calls DeepGEMM `get_paged_mqa_logits_metadata`, which has
   no SM120/SM121 implementation and no fallback; `SGLANG_DISABLE_DEEP_GEMM=1` doesn't help. Closed without a
   documented fix; roadmap (#23602) lists SM121 as a "community target" only.
2. Native ckpt ~158 GB; W2A16/W3A16 "lack real kernels" per its own quant docs; GGUF deepseek arch unsupported
   (#4756, #3973); a July 2026 report found 9 bugs serving a Q4_K_M MoE GGUF (#30122).
3. GB10 support lives on an unmerged dev branch (#11658) + community wheels (ubehera/sglang-spark), which
   document three UMA deadlock signatures on this hardware.
4. HiCache's L3 disk tier is fleet-oriented; local-file backend is "for demonstration purposes"
   (backend_factory.py); hierarchical caching for sparse/hybrid caches (exactly DSV4's) is WIP (#12826); no
   published restart-restore latency anywhere. Not a substitute for explicit slot save/restore.
5. Best Spark number is gpt-oss-120b ~50 tok/s (LMSYS, marketing-adjacent, dev branch). No V4-on-GB10 data.

### 2.4 TensorRT-LLM / NVIDIA stacks — REJECTED (decisive: cannot load GGUF and has no ≤3-bit format; V4-Flash support unconfirmed)

1. Official Spark playbook exists (containers 1.3.0rc13; https://github.com/NVIDIA/dgx-spark-playbooks/tree/main/nvidia/trt-llm),
   but sm_121 is rough: `sm_121a` ptxas failures (#8474), CUTLASS MoE 7× slower than the undocumented
   `TRTLLM_MOE_BACKEND=TRITON` workaround (#12706, closed "not planned").
2. "DSv4 sparse MLA" landed in v1.3.0rc21 (~2026-07-15) — lineage suggests V4/V4-Pro; **no evidence it covers
   V4-Flash's CSA/HCA hybrid**; no supported-models entry, no Spark recipe, request #13431 unanswered.
3. ModelOpt floor is 4-bit (NVFP4 ≈ 150–160 GiB for 284B — doesn't fit); **no GGUF ingestion at all**.
4. KV cache: reuse + host-RAM offload only; cache dies with the process. Dynamo KVBM adds a disk tier
   ([Experimental]) but restart survival is unstated and LMCache's persistence claim is documented for vLLM,
   not TRT-LLM. Nothing equivalent to `--slot-save-path`.
5. No DeepSeek-on-Spark numbers exist; one forum thread reports TRT-LLM NVFP4 slower than LM Studio GGUF on
   Spark (https://forums.developer.nvidia.com/t/trt-llm-for-inference-with-nvfp4-safetensors-slower-than-lm-studio-gguf-on-the-spark/348636).
6. `trtllm-serve` has no real API-key enforcement (reverse proxy required — same as llama.cpp, so no ops win).
   NIM on Spark: prepackaged models only; nobody ships a 2-bit 284B NIM.

### 2.5 ktransformers — REJECTED (decisive: architecturally pointless on UMA; x86-only in practice)

Supports V4-Flash (May 2026, doc/en/DeepSeek-V4-Flash.md) but the whole design is heterogeneous placement —
experts in x86 DDR (AVX512/AMX kernels), attention in discrete-GPU VRAM. GB10 has one memory pool; there is
nothing to offload to. aarch64 builds fail on NEON intrinsics (#1690); SM_120 validated only after an
all-zero-tokens Lightning-Indexer bug (#2001); sm_121 appears nowhere. `--max-running-requests 2`. No KV
persistence documented. (Rejection is partly inferential — nobody has tried it on Spark; flagged below.)

### 2.6 MLC-LLM — REJECTED (decisive: no deepseek_v4 model support at all)

Latest DeepSeek work is V3 (PR #3192); no CSA/HCA/Lightning-Indexer code, no sm_121/CUDA-13 evidence, no 2-bit
MoE story. Negative result (absence of evidence), flagged below.

### 2.7 ollama — REJECTED (decisive: strict subset of llama-server that removes the load-bearing feature)

Wraps llama.cpp but exposes neither `--slot-save-path` nor `/slots/{id}` save/restore; the auto-persist feature
request upstream was closed "not planned" (llama.cpp #17107). Local V4-Flash support gated on llama.cpp anyway;
library entry is primarily `:cloud`. Nothing ollama adds (model mgmt, easy pull) matters for a pinned,
manifest-verified production endpoint.

### 2.8 Also considered (Spark-relevant 2025–2026)

- **antirez/ds4 ("DwarfStar")** — already benchmarked in this repo (Candidate A, composite winner 86.03 vs
  81.62, 18.7 tok/s decode @4K). Native disk-KV design (`--kv-disk-dir`, SHA1-indexed checkpoints) is exactly
  the product's caching philosophy, and it ships a `make cuda-spark` GB10 target. **Rejected for production by
  Brian's 2026-07-17 override on measured grounds: warm >28K prompt fails (HTTP 500), envelope ≤~28K
  (results/envelope-exception-ds4.json) — cannot meet the 1M-target requirement.** Also: beta-labeled, no auth,
  single mutable KV session, supply-chain caveats (docs/ds4-security-review.md: mutable HF `main` URLs, no
  SHA-256). Remains the fallback for fast small-context serving. If ds4 later fixes its large-ctx session-graph
  allocation, it becomes the strongest challenger — its checkpointed-KV UX is better than slot files.
- **croll83/llama.cpp-dgx fork** (TurboQuant KV, NVFP4, DFlash-MTP for sm_121): non-auditable fork, conflicts
  with pin discipline. Watch, don't adopt.
- **DeepSeek-V4-Flash-DSpark variant** (official MTP block-drafter, ~1.5–1.8× decode claim, SGLang PR first;
  https://forums.developer.nvidia.com/t/new-deepseek-v4-flash-dspark/374739): the single most promising future
  decode lever *for llama.cpp too* (the pin already has MTP/DFlash spec-decode infra). Unverified availability
  in GGUF.
- **exllamav3/TabbyAPI**: no aarch64 wheels, no deepseek_v4 support found. Reject (negative result).

---

## 3. Verdict

### (a) Best engine for THIS product today: **llama.cpp (the current pin) — keep it.**

It is the only engine that satisfies all four hard constraints simultaneously:
1. runs V4-Flash's CSA/HCA + Lightning Indexer on sm_121 (verified in the pinned source and measured on this box);
2. fits 284B in 119 GiB (GGUF is the only ≤3-bit ecosystem for this architecture, and llama.cpp is the only
   engine that loads it);
3. has working, source-verified disk KV save/restore for the DSV4 cache type (`--slot-save-path` +
   `/slots` API + versioned state I/O in llama-kv-cache-dsv4.cpp) — the load-bearing product feature;
4. is already built, benchmarked, gated, and productionized on this exact host.

Every alternative fails on at least one *fatal* axis, and most fail on two independent ones (no sm_121 sparse
kernels AND no sub-4-bit format). This is not a close call: on a 119 GiB box, the quantization-format question
alone eliminates vLLM, SGLang, TRT-LLM, ktransformers, and MLC before performance is even discussed.

Single decisive reason per rejection:
- **vLLM**: no ≤3-bit format → the model cannot fit in 119 GiB (GGUF path deprecated/experimental, no V4 support).
- **SGLang**: V4's compressed attention has no SM121 kernel (DeepGEMM, no fallback) — cannot forward-pass here.
- **TensorRT-LLM**: cannot load GGUF and has no sub-4-bit format; V4-Flash (CSA/HCA) support unconfirmed.
- **ktransformers**: its GPU+CPU split is meaningless on unified memory; x86/AVX512-only in practice.
- **MLC-LLM**: no deepseek_v4 support exists.
- **ollama**: same engine minus the slot save/restore the product depends on.
- **ds4**: measured ≤28K context envelope on this host vs a 1M product target (Brian's standing override).

### (b) Does anything justify a full re-benchmark? **No engine swap does. Two llama.cpp-internal items might.**

Decode is bandwidth-bound (~273 GB/s / ~13B-active working set); 13.9 tok/s is at the roofline and every
credible single-GB10 V4-Flash datapoint (this repo, IQ2_XXS forum thread, ds4's own README) lands at 12–15 tok/s.
No competing engine has demonstrated a single-Spark V4-Flash run at all, so there is no number that could beat
the status quo. What *is* worth protocol-versioned re-runs (already on the phase-2 track, not engine swaps):
`-ub 1024/2048` prefill sweep (targets the real weakness: TTFT 57.8 s @16K), and MTP/DFlash speculative decode
if a DSpark-format draft materializes (only >20% decode lever). Re-open the engine question only if one of
these tripwires fires: (i) SGLang/vLLM land SM12x sparse-attention fallback kernels AND a ≤3-bit V4 format,
(ii) ds4 fixes >28K sessions, (iii) TRT-LLM ships a V4-Flash Spark recipe with a documented restart-surviving
KV disk tier.

### (c) Hybrid options: **none practical today; one honest future path.**

- "vLLM for prefill elsewhere, llama.cpp local" is not practical: KV states are not portable across engines
  (different cache layouts — vLLM paged FP8/FP4 MLA vs llama.cpp's 4-store DSV4 GGUF-quantized cache); there is
  no serialization bridge, and building one is a research project, not an integration.
- The only real hybrid is **a second DGX Spark running the community vLLM FP8 TP=2 recipe** (30–67 tok/s decode,
  ~1.2–1.9K tok/s prefill, 1M ctx demonstrated) — 2–5× decode, ~5–7× prefill, full-precision-class quality,
  plus LMCache for persistence. That is a hardware purchase + fork-image trust decision, not an engine choice
  on this box. If prefill throughput becomes the product bottleneck, this is the upgrade path to price.
- Keeping ds4 warm as the ≤28K fast lane behind the router is technically feasible (it's already built and
  benchmarked) but doubles ops surface and RAM pressure for a modest UX win; recommend against unless routing
  telemetry shows most traffic is short-context and TTFT-sensitive.

---

## 4. Claims that could NOT be verified (aggregated, all flagged inline above)

Local:
1. `/home/dsv4/llamacpp-project/src/llama.cpp` itself unreadable (permission denied); verification used the
   repo's vendored checkout confirmed at the same pin SHA.

llama.cpp:
2. Restore-fidelity of slot save/restore on THIS build (PR #24162 threads report multi-turn amnesia after
   checkpoint restore) — must be gated by the phase-2 acceptance test before production reliance.
3. DFlash/DSpark draft-model availability in GGUF; Unsloth UD-Q2_K_XL quality vs the FP4-QAT baseline.

vLLM:
4. Whether upstream V4 DeepGEMM/FlashMLA kernels run on sm_121 at all; why issue #40928 closed; any V4/deepseek
   support in vllm-gguf-plugin; LMCache restore latency for V4 (indexer-cache persistence semantics, #45350
   open); the "CUDA 12.1" claim in the Aiden dual-Spark recipe (contradicts CUDA-13-only GB10); the
   45-vs-67 tok/s spread between the two dual-Spark recipes.

SGLang:
5. Any fix behind closed issue #23657; nvidia NVFP4 repack size; any HiCache restart-restore latency number
   (none published); "V4 merged in v0.5.12" (third-party blog only).

TRT-LLM:
6. Whether v1.3.0rc21 "DSv4" covers V4-Flash CSA/HCA; whether KVBM's disk cache survives restart; whether
   KVBM/Dynamo runs on Spark at all; build.nvidia.com playbook pages (timed out; corroborated via GitHub mirror);
   exact rc release dates.

Others:
7. ktransformers-on-Spark (no positive or negative evidence anywhere — rejection inferred from x86/AVX512
   requirements and UMA architecture mismatch); MLC and exllamav3 rejections are absence-of-evidence negatives;
   ollama local `q4_k_m` V4 pull (one uncorroborated blog); ds4 save/restore latency on GB10 (design documented,
   no measurements); single-source community benchmarks (Dendro Logic, X posts) treated as anecdotal.

Marketing flags: NVIDIA playbook perf language ("significantly higher throughput") carries no numbers; LMSYS
gpt-oss Spark numbers were produced on an unmerged dev branch (best-case); PyTorch/LMSYS GB300 "5×" posts are
datacenter-HBM results, irrelevant at 273 GB/s UMA.

## 5. Key sources

Local (verified): `vendor/llama.cpp` @ 32e789fd (src/llama-arch.*, ggml/include/ggml.h,
src/llama-kv-cache-dsv4.cpp, common/arg.cpp); `results/{speed-llamacpp.json,DECISION.md,DECISION-OVERRIDE.md,
envelope-exception-ds4.json}`; `docs/{llamacpp-pin-choice.md,bigctx-plan-fable-2026-07-16.md,
research-1m-coldstart-fable-2026-07-16.md,research-fable-2026-07-16.md,ds4-security-review.md}`.

Web (primary): vLLM V4 blog https://vllm-project.github.io/2026/04/24/deepseek-v4.html · vLLM Spark blog
https://vllm-project.github.io/2026/06/01/vllm-dgx-spark.html · vllm issues #40928/#40851/#45350/#36821/#28669 ·
vllm-gguf-plugin https://github.com/vllm-project/vllm-gguf-plugin · LMCache https://github.com/LMCache/LMCache ·
LMSYS V4 day-0 https://www.lmsys.org/blog/2026-04-25-deepseek-v4/ · sglang issues #23657/#23602/#11658/#12826/
#4756/#30122 · HiCache design https://docs.sglang.io/advanced_features/hicache_design.html · TRT-LLM releases
https://github.com/NVIDIA/TensorRT-LLM/releases · TRT-LLM issues #12706/#8474/#13431 · KV docs
https://nvidia.github.io/TensorRT-LLM/latest/features/kvcache.html · Dynamo KVBM
https://docs.nvidia.com/dynamo/latest/user-guides/kv-cache-offloading · DGX Spark playbooks
https://github.com/NVIDIA/dgx-spark-playbooks · ktransformers doc/en/DeepSeek-V4-Flash.md + issues #1690/#2001 ·
mlc-llm PR #3192 · llama.cpp PR #24162, issue #17107, discussion #16578 · antirez/ds4
https://github.com/antirez/ds4 · single-GB10 V4 thread
https://forums.developer.nvidia.com/t/deepseek-v4-flash-iq2xxs-on-a-single-gb10/368970 · dual-Spark recipes
(Aiden forum thread; https://github.com/MiaAI-Lab/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark) · Spark freeze threads
https://forums.developer.nvidia.com/t/dgx-spark-becomes-unresponsive-zombie-instead-of-throwing-cuda-oom/353752 ·
Q2 quality caution https://arxiv.org/pdf/2505.02390.
