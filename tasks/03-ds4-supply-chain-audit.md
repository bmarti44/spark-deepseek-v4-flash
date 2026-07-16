# T1.1 — Supply-chain audit of the ds4 stack (READ-ONLY analysis, one output file)

The ONLY file you may create or modify is `docs/ds4-security-review.md`. Touch nothing else. No network access — everything you need is already cloned locally:

- `vendor/ds4-on-spark/` — installer/recipes repo (github.com/entrpi/ds4-on-spark), HEAD = 039e047 (2026-07-16, "Pin bump: fork release v0.2.2 — always-on fast-path artifacts")
- `vendor/ds4/` — the engine (github.com/Entrpi/ds4, fork of antirez/ds4). Audit tag **v0.2.2** = commit baa889025b16a7060f5f854226cb0d14e260eb52 (`git -C vendor/ds4 checkout` is FORBIDDEN — inspect via `git -C vendor/ds4 show v0.2.2:<path>` and `git -C vendor/ds4 diff <ref1> <ref2>` so the working tree stays untouched).

Context: this machine will build and run this code as an unprivileged user to serve a private LLM endpoint. We will NOT run install.sh; we will reimplement its audited steps in our own scripts. Your audit is the basis for that reimplementation and for the go/no-go decision.

## Audit questions (answer ALL, with file:line citations)

### A. install.sh behavior (vendor/ds4-on-spark/install.sh)
1. Every action it performs: clones (which repo/ref), builds (exact make/cmake invocations, CUDA arch flags), downloads (exact URLs/HF repos/filenames), files/dirs written (with paths), services or cron installed, sudo usage, PATH/rc modifications, smoke tests.
2. How weight downloads are verified (length? sha256? nothing?) — cite lines.
3. What environment variables change behavior (DS4_REF, DS4_REPO, HF_REPO, DSPARK_HF_REPO, CUDA_ARCH, etc.) and their defaults.

### B. The v0.2.2 "always-on fast-path artifacts" (CRITICAL)
4. What exactly are these artifacts? Prebuilt binaries/kernels downloaded at build or run time, or source-built? If downloaded: from where, fetched by what code, verified how? Diff v0.2.1 → v0.2.2 in vendor/ds4 (`git -C vendor/ds4 diff v0.2.1 v0.2.2 --stat` then read the relevant hunks) and quote the mechanism.
5. If artifacts are fetched from a third-party host or a personal bucket rather than the pinned git repo / official HF: flag as HIGH RISK and say whether a source-only build path exists (env var / make target to disable).

### C. Engine code (vendor/ds4 at v0.2.2)
6. Network surface: enumerate every place the engine or its scripts initiate outbound connections (grep for curl/wget/http/socket connect in .c/.cu/.sh/Makefile). Telemetry/analytics/update checks?
7. `ds4_server.c` / `ds4_web.c`: default bind address, port, any auth mechanism (API key? none?), endpoints exposed (OpenAI-compatible paths? admin endpoints? /shutdown?). Does it honor a bind-address flag?
8. File writes at runtime (cache dirs, logs, kv store paths — ds4_kvstore.c, ds4_ssd.c: does anything write outside its working directory?).
9. Anything that reads credentials, dotfiles, or SSH material (grep for getenv of suspicious vars, ~/.ssh, /etc paths).
10. Build system: does `make` fetch anything from the network? Submodules?

### D. Weights
11. Exact HF repos + filenames the default path downloads (main GGUF from antirez/deepseek-v4-gguf; DSpark drafter from bleysg/DeepSeek-V4-Flash-DSpark-drafter-GGUF), total sizes if determinable from the scripts/docs, and target directory layout the engine expects.

### E. Verdict + reimplementation spec
12. Findings list, each labeled HIGH/MEDIUM/LOW with file:line evidence.
13. A precise step list our `scripts/10_fetch_ds4.sh` + `11_build_ds4.sh` + `20_serve_ds4.sh` must implement: exact git SHAs to pin, build commands for CUDA sm_121 (aarch64), artifact handling decision (source-build vs verified download), weight files + expected verification method, server launch flags for loopback-only serving, env vars for the DSpark drafter path.
14. Anything in the engine we must patch or config to make serving safe (e.g., disable an unauthenticated admin endpoint).

## Output format
`docs/ds4-security-review.md`: executive summary (≤10 lines, verdict: SAFE-TO-PROCEED / PROCEED-WITH-MITIGATIONS / DO-NOT-USE), then sections A–E. Dense, citation-heavy. No speculation — if you cannot determine something from the local clones, say so explicitly in an "Unresolved" list.

Final message: the executive summary verbatim + list of unresolved items.
