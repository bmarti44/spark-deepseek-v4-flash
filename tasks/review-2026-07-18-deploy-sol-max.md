# Technical review: fusion deployment + memory-safety ops changes

You are reviewing the repository at /home/bmarti44/spark-deepseek-v4-flash READ-ONLY.
This is a TECHNICAL CORRECTNESS + SAFETY review — NOT a security audit, NOT a scored
review. The central concern is MEMORY SAFETY: a near-OOM occurred and was mitigated,
and I need you to check the reasoning is sound.

## CRITICAL OUTPUT RULES (previous codex runs on this repo were killed by an output filter — obey exactly)
1. NEVER write a full 64-char hex digest anywhere; use the first 6 chars + ellipsis.
2. NEVER cat/print digest-bearing files (verification/MANIFEST.sha256, results/*.json, configs/build-manifests/*, configs/pins/*) wholesale; compare programmatically, print only MATCH/MISMATCH + field name.
3. Do NOT paste diffs/patches/file-contents from any integrity experiment; describe each in one neutral sentence.

## DO NOT
- Do not modify/create/delete any tracked file (scratch under /tmp only).
- Do not send any HTTP request to 127.0.0.1:8010/8011/8012/8013/8014 (a model server is RESIDENT; a wrong request can OOM-freeze the host). Read code only.
- Do not start any server or run any build or load any model.

## Background (what happened)
The fused-hyper-connection llama.cpp build (0dc74e3) was validated (GSM8K dev 97/100 =
production; needle correct at adequate budget; decode +13.5-16.6%, prefill +11-19%) and
DEPLOYED as the production engine via systemd env overrides. On deploy the CUDA
graph-capture phase hit transient NVRM NV_ERR_NO_MEMORY (GPU/UMA OOM) and recovered; the
engine reached health 200 and is stable at ~21 GiB free. Root cause hypothesis: the fused
op's extra graph-capture buffers raise the STARTUP memory peak above production's on this
tight host (90 GiB model / 119 GiB UMA). Mitigation: -ub lowered 512->256 (env-config) to
~halve the prefill compute buffer that dominates the peak.

## Scope: commits `a293a03..HEAD`
- 8e73d29 — corrected Phase B conclusion (fusion correct + faster); evidence docs.
- fefd98d — deploy: systemd unit sets DSV4_SERVER_BINARY/DSV4_BUILD_MANIFEST to the fusion build.
- 5cb5559 — 00_preflight.sh: root-disk floor env-configurable (DSV4_MIN_ROOT_FREE_GIB, default 350); unit sets 100.
- c2a34fc — 21_serve_llamacpp.sh: -b/-ub env-configurable (DSV4_BATCH/DSV4_UBATCH, defaults 2048/512); unit sets DSV4_UBATCH=256.

## Review these, each with file:line + concrete failure scenario, tagged [critical]/[high]/[medium]/[low]:
1. **Memory-safety of the deployment.** Is the near-OOM root-cause reasoning correct (fused-op graph-capture buffers raise the startup peak)? Is -ub 256 an adequate, correct mitigation — does lowering -ub actually reduce the graph-capture/compute-buffer peak in llama.cpp, and by roughly the claimed amount? Are there OTHER startup allocations (CUDA context, KV pool, MoE expert buffers) that -ub does NOT reduce and could still OOM on a restart? Is there a residual risk that a guard-timer restart or reboot re-hits the peak and hard-freezes? Consider whether the membudget gate (02_membudget, floor 15) and the 12 GiB external watchdog can even SEE a GPU-side UMA allocation failure (NVRM) vs a system MemAvailable dip.
2. **The env-override deployment mechanism.** DSV4_SERVER_BINARY/DSV4_BUILD_MANIFEST point systemd at the fusion build (llama.cpp-fusion worktree). Is anything fragile: the worktree being outside the committed tree, the integrity check hashing only the thin llama-server binary (not the fused libggml-cuda.so), the manifest path via @DSV4_REPO@ expansion, reversibility? Could a stale/rebuilt worktree serve unverified code while the manifest check passes?
3. **Preflight disk-floor change (5cb5559).** Is defaulting to 350 but setting 100 in the unit sound? Any case where 100 GiB free is too low for the running engine (log growth, future Phase C slot-save/checkpoints)? Message/units correct?
4. **-b/-ub env plumbing (c2a34fc).** Validation correct (positive-int guard)? Do defaults exactly preserve prior behavior (2048/512)? Does -ub 256 have any correctness or throughput cliff worth flagging? Any interaction with -b that should also be lowered?
5. **Consistency + reversibility.** Are the three new env knobs (binary/manifest, disk floor, batch/ubatch) plus the earlier mem-floor coherent and documented in the unit? Is the whole deployment cleanly reversible to the 32e789fd build? Did any MANIFEST-tracked file change without its hash refreshed?
6. **Phase B conclusion soundness (8e73d29).** Given the corrected docs, is the fusion-is-correct-and-faster conclusion now well-supported, or is any evidence still thin (accuracy only on GSM8K dev, not MMLU/HumanEval; speed methodology)? Anything that would make deploying fusion premature EVEN aside from the memory issue?

## Output
For each area: `## <area> — <one-line verdict>` then tagged bullets (file:line + failure scenario) or an explicit justification if clean. End with `## Summary`: the top memory-safety risks ranked, whether -ub 256 is a sufficient mitigation or something more is needed, and a one-line overall judgement. If your sandbox blocks something, say so and reason from code.
