# Research: raising DeepSeek-V4-Flash speed AND fidelity on the single DGX Spark
Agent: fable max · Date: 2026-07-16 · Brief: tasks/research-perf-fidelity-2026-07-16.md
Constraints honored: read-only; no requests to 127.0.0.1:8011/8012; sources read locally + web.

Legend: [impact][effort][confidence]. "RE-RUN" = would invalidate the frozen benchmark
protocol (PROTOCOL.md v2) and require re-running the pre-registered suites.

---

## 0. Corrections to the brief's stated facts (verified locally)

- The llama.cpp pin `32e789fd` is dated **2026-07-16 21:06 +0800** (verified via
  `git log` in /home/dsv4/llamacpp-project/src/llama.cpp), not 2026-06-29. It already
  contains the DSV4 quantized-KV fix `024c46ae4` (PR #25202, 2026-07-07) — confirmed with
  `git merge-base --is-ancestor`. The comment in scripts/21_serve_llamacpp.sh ("upstream
  quantized-K bugs make -ctk/-ctv inappropriate") is **stale** for this pin.
- Local UD-Q2_K_XL shards total ~93 GB (~87 GiB), not ~78 GiB
  (ls of weights/unsloth-ud-q2_k_xl/). HF lists the quant at 96.8 GB (decimal).

---

## 1. llama.cpp upstream movement since the pin (Candidate B)

### F1. Fused hyper-connection ops — PR #25585 / commit 0dc74e3 [HIGH][low-med][high] — RE-RUN
**Corroborated** (coordinator lead was real): "DeepseekV4: Add fused hyper-connection ops",
author am17an, **merged 2026-07-16**, merge commit `0dc74e3` — i.e. hours *after* the
current pin `32e789fd`; `git log --grep=25585` confirms it is NOT in the pin. Adds three
fused ops (hc_comb / hc_pre / hc_post) with CUDA kernels fusing Sinkhorn normalization
into the HC block; **reduces graph nodes 29k → 8k** with "big increases in TG + PP";
a reviewer measured **+60.9% decode / +7.4% prefill on MI250X**. The graph-node collapse
disproportionately helps small GPUs like GB10 where per-node launch overhead dominates
bandwidth-bound decode. This is the single largest known speed lever for Candidate B.
- Next step: bump the pin to ≥0dc74e3, rebuild per configs/build-manifests/llamacpp.json,
  re-run parity/golden/speed/accuracy suites. Note RPC protocol + GGML_OP_COUNT changed
  (98→101), so mixed-version RPC is not a concern here (single box).
- URLs: https://github.com/ggml-org/llama.cpp/pull/25585 ,
  https://github.com/ggml-org/llama.cpp/commit/0dc74e3

### F2. Quantized-KV fix already in the pin — PR #25202 [LOW][none][high]
Issue #25382: `--cache-type-k q8_0` produced garbage on DSV4 because Hadamard rotation
(non-null self_k_rot) diverted layers off the sparse CSA/HCA/lightning-indexer paths to
build_raw_attention. Fixed 2026-07-07 (commit 024c46ae4), **already an ancestor of the
pin**. KV-quant is therefore *functionally* available — but with MLA-style compression the
KV pool at 32K ctx is only ~128 MiB (4096 B/token per the membudget call), so KV-quant
buys almost nothing here. Recommendation: keep fp16 KV (fidelity-free choice), but update
the stale script comment. Only revisit if ctx is raised far beyond 32K.
- URLs: https://github.com/ggml-org/llama.cpp/pull/25202 ,
  https://github.com/ggml-org/llama.cpp/issues/25382

### F3. Speculative decoding for V4-Flash in llama.cpp: not usable today, coming [MED-now/HIGH-later][med][high]
- The pinned build already has the full spec framework: `--spec-type` with
  draft-simple / eagle3 / **draft-dflash** / **draft-mtp** / ngram (verified in
  common/arg.cpp + speculative.cpp; MTP framework = PR #22673, DFlash = PR #22105).
- **But**: the Unsloth UD-Q2_K_XL GGUF contains **no NEXTN/MTP tensors** (verified by
  scanning all three shard headers with `strings` — zero `nextn`/`.mtp` matches), so
  `--spec-type draft-mtp` has nothing to load; Unsloth's HF discussion confirms an MTP /
  draft GGUF for V4-Flash is only "planned".
- **PR #25173** ("spec: add DSpark speculative decoding", wjinxu) is open, approved by
  several reviewers, awaiting final maintainer review; currently targets Qwen3, with
  **DeepSeek-V4 support planned as a follow-up**. DSpark upstream reports 1.88x decode on
  Qwen3-8B. deepseek-ai also published DeepSeek-V4-Flash-DSpark (integrated block drafter,
  block size 5, confidence threshold) which SGLang already runs (1.48–1.81x single-stream).
- Next step: subscribe to #25173 and to Unsloth's V4-Flash MTP-GGUF plans. When either
  lands, Candidate B's 13.9 tok/s could plausibly reach ~1.5–1.9x, erasing much of A's lead.
- URLs: https://github.com/ggml-org/llama.cpp/pull/25173 ,
  https://github.com/ggml-org/llama.cpp/pull/22673 ,
  https://github.com/ggml-org/llama.cpp/pull/22105 ,
  https://huggingface.co/unsloth/DeepSeek-V4-Flash-GGUF/discussions/6 ,
  https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash-DSpark ,
  https://forums.developer.nvidia.com/t/new-deepseek-v4-flash-dspark/374739

### F4. Flash attention on DSV4: verify it actually engages [MED][low][med]
Community reports (loFT LLC dual-Blackwell writeup) say FA support for DSV4's custom
attention graph was incomplete in early branches (30–40% GPU util). The serve script does
not pass `-fa` (default "auto"). The DGX Spark llama.cpp playbook recommends `-fa on` as
"a strict superset with no downside," gains mostly in prefill — exactly B's weak spot.
- Next step (read-only): grep a *historical* server log for the printed flash_attn state,
  or run `llama-bench -fa 0/1` offline on a scratch port after the holdout completes.
  If FA never engages on the sparse paths, the -ub lever (F5) matters even more.
- URLs: https://loftllc.dev/en/docs/tech/llm-research/deepseek-v4-flash-llama-cpp-blackwell-local-inference/ ,
  https://vlaicu.io/posts/dgx-llamacpp-playbook/

---

## 2. llama.cpp serve/build flags not yet tuned (Candidate B)

Current flags (scripts/21_serve_llamacpp.sh): `-c 32768 -np 1 -ngl 999 -b 2048 -ub 512
--no-warmup --cache-ram 0`, fp16 KV, mmap default(!), no -fa flag, no slot-save.
Build: `-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=121 -DCMAKE_BUILD_TYPE=Release`.

### F5. Raise -ub (micro-batch) 512 → 1024/2048 for prefill [HIGH for TTFT][low][med] — RE-RUN
B's TTFT at 16K is 57.8 s vs A's 21.8 s — prefill is B's biggest deficit, and prefill is
compute-bound (playbook confirms). `-ub 512` limits per-forward token width and MoE
rows/expert; the DGX playbook ships `-b 2048 -ub 2048` on GB10. Cost: larger compute
buffers (the script's own comment says compute buffers at b=2048/ub=512 measure 3–5 GiB;
ub=2048 grows this by several GiB — re-run 02_membudget.py; overhead-gib 6 may need raising).
ds4's own tuning found chunk width 2048→4096 lifted prefill 248→304 tok/s on this exact
box (ds4_server.c S6 comment) — same physics applies to B.
- Next step: offline llama-bench sweep -ub {512,1024,2048} × -b {2048,4096} at 4K/16K
  prompts; adopt best that passes the memory gate. Changes serve flags ⇒ RE-RUN.

### F6. Add --no-mmap [MED][low][med] — RE-RUN
The GB10 playbook marks `--no-mmap` "mandatory on unified memory systems" (page-cache
backed mmap weights vs pinned/UM allocation). The serve script does not pass it, so B runs
with mmap default-on. On 119 GiB UMA with a 87 GiB model, mmap paging pressure can degrade
decode and interacts badly with the MemAvailable-based watchdog (mmap pages count as
reclaimable, inflating MemAvailable while the working set is hot).
- Next step: A/B llama-bench with/without --no-mmap; watch the 16 GiB floor — --no-mmap
  makes the footprint *explicit* which may trip the budget gate even though the true
  working set is unchanged.
- URL: https://vlaicu.io/posts/dgx-llamacpp-playbook/

### F7. Build-flag deltas: 121a + FA_ALL_QUANTS [LOW][low][high]
Playbook builds with `-DCMAKE_CUDA_ARCHITECTURES=121a` (enables newest tensor-core MMA +
native FP4 paths; neutral for Q2_K weights) and `-DGGML_CUDA_FA_ALL_QUANTS=ON` (only
matters for FA over quantized KV). Neither should move Q2_K_XL + fp16-KV numbers much.
Do it opportunistically at the F1 rebuild. RE-RUN (same rebuild event as F1).

### F8. Prompt caching / slots [LOW for evals, MED for production][low][high]
`--cache-ram 0` disables the RAM prompt cache deliberately (script hard-requires the flag
exist). llama-server still does per-slot KV prefix reuse by default — with -np 1 and a
constant system prompt, repeated-prefix requests skip re-prefill (the observed
"graphs reused = 252799" log line shows heavy reuse). For production serving with repeated
long system prompts, `--slot-save-path` + slot restore is the bigger win; for temp-0 evals
it's a benchmark-validity hazard (cached prefixes change timing) — leave off during suites.
`-np 1` is correct for the single-client protocol; raising -np splits ctx per slot and
would REQUIRE protocol changes — don't.

---

## 3. entrpi/ds4 upstream + engine internals (Candidate A)

### F9. Upstream fork movement after baa88902: v0.2.3 exists, no 28K fix [MED][low][high]
GitHub API compare baa88902...v0.2.3 (tag 7807a870, 2026-07-16 20:34Z): exactly 4 commits —
teb-gate safety-warning ratchet (73edb828, 7b3ff9aa), **"Server: launch defaults —
ds4-server -c N boots the full stack"** (8b262209), changelog (7807a870).
- Nothing addresses the lazy-session-graph >28K failure.
- 8b262209 fixes a real footgun: at baa88902, `DS4_CONT_DSPARK=0` **still armed the
  drafter** (presence-based check). The repo's serve script is safe (it uses `env -u` then
  sets `=1` explicitly), but any ad-hoc invocation with `=0` was silently speculative.
- The install wrapper repo (Entrpi/ds4-on-spark) is still pinned to v0.2.2.
- URLs: https://github.com/Entrpi/ds4 (branches/tags via API),
  https://github.com/Entrpi/ds4-on-spark

### F10. How the DSpark pipeline works + why it cannot hurt fidelity [info][—][high]
From /home/dsv4/ds4-project/src/ds4/ds4.c (continuous-batch decode loop, ~L33560-33790):
- Per step, each live bank packs `[committed, draft0..D-1]` = (1+D) rows into ONE verify
  forward of the *base* model. Acceptance keeps the **genuine base-argmax prefix** of the
  drafts; rejected rows' compressor state rolls back via snapshot/restore (M2). The code
  comments state the invariant twice: "the verify forward is the sole source of committed
  tokens, so a different draft only shifts the accept rate, never correctness (gate proves
  accept-stream == mode-0 regardless of drafts)". At temperature 0 this is exact
  greedy-equivalence, not probabilistic rejection sampling — **drafter quality bounds speed
  only, never output distribution**. Fidelity of A is bounded by its 2-bit base quant, not
  by DSpark.
- Draft source: DSpark block drafter (default depth D = DS4_DSPARK_BLOCK-1 = 4 verifiable
  drafts/step; deepseek-ai's DSpark uses block size 5) + on-device Markov refine; MTP head
  optional since 9308fa5 ("MTP-droppable").

### F11. DSpark/serving tunables worth sweeping (all env vars, no rebuild) [MED][low-med][med] — RE-RUN if adopted
Verified read-sites in ds4.c/ds4_server.c:
- `DS4_DSPARK_VERIFY_DEPTH` (1..4; default 4): "diagnostic/perf dial for finding the
  speed/acceptance optimum on **small-width hardware**" — GB10 is exactly that; verify
  rows/step = MS×(1+D). Sweep 2/3/4.
- `DS4_DSPARK_ADAPT_DEPTH` (opt-in): auto depth adaptation; mutually exclusive with a
  forced VERIFY_DEPTH.
- `DS4_DSPARK_MAX_KV` (default 65536) / `DS4_DSPARK_ADAPT_GATE` (opt-in measure-and-switch
  controller, solo-stream only — matches the NLIVE=1 production regime): irrelevant below
  32K ctx (gate never binds at 65536), but ADAPT_GATE is the right setting if ctx is ever
  raised; upstream's own probes show spec goes *below* 1.0x at ~64K+ prose.
- `DS4_SERVER_COALESCE_MAX` (default **16**), `DS4_SERVER_COALESCE_WAIT_MS` (default 0),
  `DS4_SERVER_COALESCE_MAX_TOKENS` (default 4096 since the S6 flip): group *concurrent*
  requests only. **Refutes the coordinator's second lead**: with the protocol's single
  sequential client, coalescing never engages, so `DS4_SERVER_COALESCE_MAX=2` is a no-op
  for benchmark numbers (and under real concurrency it would *reduce* batching vs the
  default 16). Not a speed lever for this setup.
- `DS4_CONT_PREFILL_CHUNK` / `_LIVE`: admission-chunked prefill already defaults on
  (chunks clamp to prefill_cap; 4096 was picked on GB10 data). Leave unless re-probing.
- `DS4_CONT_MTP_BATCH_DRAFT=1`: batched cross-bank draft chain, "pure perf", off by
  default — single-live-bank benefit small but free to A/B.

### F12. The >28K lazy-graph failure: root cause + the one real mitigation lead [HIGH][med][med] — RE-RUN + quality A/B
Mechanics (ds4.c ~L36760-36830 + envelope-exception-ds4.json): session graphs allocate
lazily; `metal_graph_session_fit_ok` refuses the multi-GiB raw-cap alloc when headroom is
insufficient (on UMA the alternative is the kernel OOM-killer — observed killing both
ds4-server and ds4_weight_server at -c 69632). Eager alloc (DS4_SESSION_LAZY_GRAPH=0) was
tested 2026-07-16 and breaches the 12 GiB watchdog. Upstream has no fix (F9). Escape
hatches that exist but are unsafe: `DS4_SESSION_GRAPH_FIT=0` (disables the gate — do NOT,
OOM = hard freeze), `DS4_SESSION_GRAPH_HEADROOM_MB` (only *raises* safety).
The real lead: **`DS4_CUDA_FP8_KV` (+`DS4_CUDA_FP8_KV_PREDECODE`, `DS4_CUDA_FP4_INDEX`)**
— compressed-KV options shipped in v0.2 ("FP8/FP4 compressed-KV options" per release
notes; dedicated `opp-c-fp8-kv-decode` branch upstream). Halving KV/compressor footprint
directly shrinks what the fit gate must accommodate, plausibly moving the serve envelope
from ~28K to full 32K, and may also speed bandwidth-bound decode. FP8 KV is a *lossy*
representation ⇒ mandatory golden/parity + accuracy dev-set A/B before adoption.
- Next step: offline (ds4-bench, scratch port, after holdout): boot dspark profile with
  DS4_CUDA_FP8_KV=1, replay the 28672-token speed cell + golden tests + token parity.

---

## 4. Quantization fidelity (Candidate B weights)

### F13. Quant landscape for the ~100 GiB budget [MED][med][med] — RE-RUN if changed
Unsloth V4-Flash GGUF sizes (HF repo): UD-IQ1_S 82.5 / UD-IQ1_M 86.9 / UD-IQ2_XXS 90.9 /
UD-IQ2_M 90.9 / **UD-Q2_K_XL 96.8 (current)** / **UD-IQ3_XXS 103** / UD-IQ3_S 117 /
UD-Q3_K_M and UD-Q3_K_XL 129 / UD-Q4_K_XL 155 / UD-Q8_K_XL 162 GB.
- **UD-Q3_K_XL confirmed too big** (129 GB > 119 GiB total RAM). Verified.
- **UD-IQ3_XXS (103 GB ≈ 96 GiB)** is Unsloth's explicit recommendation "for best
  results" at ~110 GB RAM. On this box: 96 GiB weights + 6 GiB overhead + ~0.13 GiB KV
  vs ~119 GiB total minus OS ⇒ **borderline; almost certainly fails the current
  16 GiB-floor membudget gate at 32K ctx**. It could only be considered with a reduced
  overhead estimate or a documented floor change — given OOM = hard freeze, treat as
  "attractive but likely out of envelope"; verify with 02_membudget.py arithmetic only
  (no boot) before spending any further time.
- **UD-IQ2_M (90.9 GB)** is ~6 GB *smaller* than Q2_K_XL with imatrix-tuned IQ2 mixes that
  often match or beat K-quants per GiB at this tier. If headroom is needed (e.g., for -ub
  2048 compute buffers or FP8-KV experiments), it is the best candidate swap — but no
  published per-quant accuracy exists to prove it matches Q2_K_XL.
- **No published MMLU/GSM8K per-quant data for V4-Flash.** Unsloth's docs publish only
  PPL/KLD for the Q4/Q8 tiers (e.g. UD-Q4_K_XL: PPL 4.5335 vs 4.5319 official, KLD 0.0102,
  top-token 96.28%); nothing for the 2–3-bit tiers. Any quant change must be validated
  with the repo's own dev-set suite (31_bench_accuracy.py) — that is the only trustworthy
  fidelity signal at this tier.
- URLs: https://huggingface.co/unsloth/DeepSeek-V4-Flash-GGUF ,
  https://unsloth.ai/docs/models/deepseek-v4

### F14. KV-cache quant × fidelity [LOW][low][high]
Now functionally safe post-#25202 (in pin), but the MLA-compressed cache is so small at
32K that quantizing it frees ~64 MiB — pure fidelity risk for no gain. Keep fp16. (Same
conclusion as the script comment, but for the correct, updated reason.)

---

## 5. GB10 / DGX Spark platform notes

### F15. Platform tuning [LOW-MED][low][med]
- GB10: sm_121, ~273 GB/s LPDDR5x — decode is bandwidth-bound; MoE-with-small-active is
  the best-case shape (13B active), which is why both engines already sit near roofline
  (18.7 tok/s ≈ 273/13ish GB working set). Don't expect miracles from flags on decode;
  the graph-overhead cut (F1) and speculation (F3/F10) are the only >20% decode levers.
- nvidia-smi on this box reports power.limit N/A (no settable cap) and SM clock 2444 MHz —
  nothing to gain from power/clock tuning; MIG does not exist on GB10.
- NVIDIA forum reports for the 2×Spark vLLM V4-Flash recipe see 49–54 tok/s single-stream —
  that's with FP8 weights, MTP spec decode, and 2 boxes; not comparable to 1 box at 2-bit.
- URLs: https://vlaicu.io/posts/dgx-llamacpp-playbook/ ,
  https://forums.developer.nvidia.com/t/guide-deepseek-v4-flash-on-2x-dgx-spark-gb10-reproducible-vllm-serving-recipe-up-to-1m-token-context/374742

### F16. Third-engine viability check: not viable single-box today [closes Q6][—][high]
- **vLLM**: SM121 support is still being worked (issue #31128; native DSV4-on-SM12x fix
  pending in PR #41834); the working GB10 recipe requires **2× Sparks (TP=2+EP)** because
  it serves the FP8 checkpoint (~149 GiB) — no sub-4-bit path for this arch in vLLM. Not
  viable on one 119 GiB box.
- **SGLang**: has DSpark speculative support (--speculative-algorithm DSPARK) and Day-0 V4
  recipes, but same weight-format problem on a single GB10.
- **TensorRT-LLM**: no evidence of V4-Flash + GB10 single-node support found. Skip.
- Community fork croll83/llama.cpp-dgx (TurboQuant KV, NVFP4, DFlash-MTP for GB10) exists
  but is a non-auditable fork — mention-only, conflicts with this repo's pin discipline.
- URLs: https://github.com/vllm-project/vllm/issues/31128 ,
  https://vllm.ai/blog/2026-06-01-vllm-dgx-spark ,
  https://github.com/hazyumps/deepseek-v4-flash-gb10 ,
  https://github.com/croll83/llama.cpp-dgx

---

## Top-5 speed actions (ranked, expected value ÷ effort)

1. **Rebuild llama.cpp at ≥ 0dc74e3 (PR #25585 fused HC ops)** — merged today, hours after
   the pin; 29k→8k graph nodes, reported +60.9% decode on comparable hardware. Could move
   B from 13.9 to ~18-22 tok/s and shrink the A-vs-B gap or flip it. [RE-RUN: all suites]
2. **B prefill: sweep -ub 1024/2048 (with -b up to 4096) + --no-mmap + explicit -fa on** —
   targets B's worst number (TTFT 57.8 s @16K); ds4's own GB10 data shows wider prefill
   chunks lift prefill ~25%; membudget gate must be re-checked. [RE-RUN: speed suite]
3. **A: DS4_CUDA_FP8_KV(+PREDECODE) experiment** — plausibly fixes the >28K envelope
   (smaller session-graph/KV footprint passes the fit gate) AND speeds bandwidth-bound
   decode; lossy ⇒ golden/parity + accuracy A/B mandatory. [RE-RUN: all suites for A]
4. **A: DSpark depth sweep (DS4_DSPARK_VERIFY_DEPTH 2/3/4 or DS4_DSPARK_ADAPT_DEPTH)** —
   upstream explicitly flags depth as the dial for small-width hardware like GB10; zero
   fidelity risk (F10 invariant). [RE-RUN: speed suite if adopted]
5. **Watch/adopt llama.cpp speculative decoding for V4-Flash** (PR #25173 DSpark follow-up,
   or Unsloth MTP-GGUF release; framework + flags already in the pinned binary) — the only
   B-side >1.5x decode lever on the horizon; check weekly. [RE-RUN when adopted]

Refuted lead: `DS4_SERVER_COALESCE_MAX=2` is **not** a speed lever — default is already 16
and coalescing only groups *concurrent* requests; the protocol's single sequential client
never triggers it (ds4_server.c worker_main, L12514-12525).

## Top-3 fidelity actions

1. **Run the full accuracy suite on Candidate A (dev sets)** — A currently has no
   GSM8K/MMLU/HumanEval numbers at all; its fidelity is bounded by the 2-bit
   IQ2XXS/Q2K base mix, and DSpark provably cannot degrade it (F10). This is the largest
   open fidelity unknown in the A-vs-B decision.
2. **Do the UD-IQ3_XXS arithmetic before dreaming about it**: Unsloth's recommended
   "best results" quant (103 GB) is borderline-infeasible under the 16 GiB floor +
   6 GiB overhead at 32K ctx; run 02_membudget.py on paper. If (and only if) it passes,
   an accuracy dev-set A/B vs Q2_K_XL is the highest-value fidelity experiment for B.
   If headroom is ever needed instead, UD-IQ2_M (90.9 GB) is the candidate swap — but
   demands the same dev-set validation since no per-quant benchmarks exist at this tier.
3. **Keep fp16 KV cache** on B (fix #25202 makes q8_0 functional, but the MLA cache is
   ~128 MiB — quantizing it is pure fidelity risk for no memory/speed gain), and update
   the stale comment in scripts/21_serve_llamacpp.sh so a future tuner doesn't
   re-litigate it for the wrong reason.

## Things requiring frozen-protocol re-runs (summary)
Any of: llama.cpp pin bump (F1/F7), serve-flag changes (-ub/-b/--no-mmap/-fa, F5/F6),
ds4 env-var changes adopted into 20_serve_ds4.sh (F11/F12), weight quant swap (F13),
ds4 version bump to v0.2.3 (F9). Pure documentation updates (stale comments, envelope
docs) do not.

## Key source files read (local)
- /home/bmarti44/spark-deepseek-v4-flash/scripts/21_serve_llamacpp.sh (flags, budget gate)
- /home/bmarti44/spark-deepseek-v4-flash/scripts/20_serve_ds4.sh (profiles, lazy-graph note)
- /home/bmarti44/spark-deepseek-v4-flash/configs/build-manifests/{llamacpp,ds4,ds4-weights}.json
- /home/bmarti44/spark-deepseek-v4-flash/results/envelope-exception-ds4.json
- /home/dsv4/ds4-project/src/ds4/ds4.c (DSpark loop ~L33560+, lazy graph ~L36760+, S6/P1 notes)
- /home/dsv4/ds4-project/src/ds4/ds4_server.c (coalesce worker ~L12480+, deep-serial guard ~L12436)
- /home/dsv4/llamacpp-project/src/llama.cpp (git history; common/arg.cpp, speculative.{h,cpp}, llama-arch.h, llama-model.cpp)
