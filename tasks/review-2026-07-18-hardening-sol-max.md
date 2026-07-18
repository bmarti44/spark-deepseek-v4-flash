# Technical review: post-deploy hardening batch (.so integrity, backoff, bounds, honesty docs)

Reviewing /home/bmarti44/spark-deepseek-v4-flash READ-ONLY. TECHNICAL CORRECTNESS +
SAFETY review, NOT a security audit, NOT scored. This is a follow-up: a prior sol/max
review found the fusion deployment not memory-safe and under-verified; this batch fixes
the GPU-free subset. Check the fixes are correct and don't introduce new failure modes.

## CRITICAL OUTPUT RULES (prior codex runs here were killed by an output filter — obey)
1. Never write a full 64-char hex digest; use first 6 chars + ellipsis.
2. Never cat/print digest-bearing files (MANIFEST.sha256, results/*.json, configs/build-manifests/*, configs/pins/*) wholesale; compare programmatically, print MATCH/MISMATCH + field.
3. Never paste diffs/patches/file-contents from integrity experiments; one neutral sentence each.

## DO NOT
- Do not modify/create/delete tracked files (scratch under /tmp only).
- Do not contact 127.0.0.1:8010-8014; do not start any server/build/model. The model server may be resident; a wrong request can OOM-freeze the host. Read code only.

## Scope: commits `c2a34fc..HEAD` (f74487c hardening, 3efe711 docs)
- f74487c: (a) serve `verify_live_artifacts` now hashes every `shared_libraries` entry in the build manifest (the CUDA lib etc.), not just the thin `llama-server`; baseline manifest `configs/build-manifests/llamacpp.json` gained `shared_libraries`. (b) engine unit gains `StartLimitIntervalSec=900/StartLimitBurst=3`. (c) `00_preflight.sh` validates `DSV4_MIN_ROOT_FREE_GIB` positive-int; `21_serve_llamacpp.sh` caps `DSV4_BATCH/UBATCH` at 2048/512 and requires ub<=b<=CTX.
- 3efe711: docs/phase-b-fusion-2026-07-17.md deployment-status section (provisional; open qualification items).

## Review, each with file:line + concrete failure scenario, tagged [critical]/[high]/[medium]/[low]:
1. **`.so` integrity check (scripts/21_serve_llamacpp.sh, verify_live_artifacts).** Is the added shared-library hashing correct and safe? Consider: symlink handling (`libggml-cuda.so` -> `.so.0`); the `os.path.basename(lib_name)==lib_name` guard vs path traversal; whether hashing follows or should reject symlinks (the model-shard check REJECTS symlinks — is treating libs differently justified?); whether it could FALSE-POSITIVE and block a legitimate start (e.g., a lib present as only a versioned name); startup-time cost; and whether `shared_libraries` being optional leaves any build unverified. Does the baseline manifest's new `shared_libraries` correctly match the baseline build on disk (reason about it; do not read /home/dsv4)?
2. **StartLimit backoff (engine unit).** Does `StartLimitIntervalSec=900/Burst=3` on a `Type=oneshot RemainAfterExit=yes` unit actually rate-limit guard-driven `systemctl restart`? Any interaction with the guard timer (dsv4-guard.service does `systemctl restart`) that defeats it, or that could wedge the engine permanently? Is the documented `reset-failed` recovery correct? Does a successful start reset the counter?
3. **Input bounds (00_preflight, serve).** Is the positive-int guard on `DSV4_MIN_ROOT_FREE_GIB` correct and placed before use in arithmetic (no `set -u`/arithmetic-eval injection)? Are the `DSV4_BATCH/UBATCH` bounds (ub<=b<=CTX, <=2048/512) correct, and do they still allow the intended `-ub 256`? Any off-by-one or type issue?
4. **Manifest coverage / consistency.** Did every changed MANIFEST-tracked file get its hash refreshed (verify programmatically)? Is adding `shared_libraries` to the baseline build manifest safe for other consumers of that JSON (decision/speed scripts that read `commit`/`binaries`)?
5. **Docs honesty (3efe711).** Does the deployment-status section accurately and completely capture the open risks (memory qualification unproven, accuracy not controlled), or does it overstate what was resolved? Anything still misleading?
6. **Anything the prior review flagged that this batch should have covered but didn't** (GPU-free only — exclude items that legitimately need the model/GPU).

## Output
Per area: `## <area> — <verdict>` then tagged bullets (file:line + scenario) or explicit justification if clean. End with `## Summary`: any new/remaining GPU-free issues ranked, plus a one-line judgement on whether the hardening batch is correct and safe to keep. Note sandbox limits and reason from code where blocked.
