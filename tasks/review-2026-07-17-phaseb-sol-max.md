# Technical review: recent runtime fixes + Phase B fusion evaluation

You are reviewing the repository at /home/bmarti44/spark-deepseek-v4-flash READ-ONLY.
This is a TECHNICAL CORRECTNESS + METHODOLOGY review — NOT a security audit and NOT a
scored/graded review. Judge whether the recent work is correct and the Phase B
conclusion is sound. Be adversarial and concrete, but focus on "is this right", not
on threat models.

## CRITICAL OUTPUT RULES (previous codex runs on this repo were killed by an output filter — obey exactly)
1. NEVER write a full 64-char hex digest anywhere in reasoning or report; use the first 6 chars + ellipsis.
2. NEVER cat/print digest-bearing files (verification/MANIFEST.sha256, results/*.json, configs/build-manifests/*, configs/pins/*) wholesale; compare programmatically and print only MATCH/MISMATCH + field name.
3. Do NOT paste diffs/patches/file-contents from any integrity experiment; describe each in one neutral sentence.

## DO NOT
- Do not modify/create/delete any tracked file (scratch under /tmp only).
- Do not send any HTTP request to 127.0.0.1:8010/8011/8012/8013/8014 (a model server may be resident; a wrong request can OOM-freeze the host). Read code only.
- Do not start any server or run any build.

## Scope: commit range `02e119c..HEAD` (6 commits)
- 49e58b4 — serve scripts 20/21: fixed a `[[ … != … ]]` split across a newline that broke bash parsing of start/stop.
- 619840a — `discover_server_pid` (20/21): was latching the start-gate `sleep` child instead of the engine; now waits until the launcher execs into `flock` (comm==flock) and requires readable start-ticks before selecting the child.
- f47e8e5 + 3b043d0 — Caddyfile: site matcher `http://127.0.0.1:8010` → bare `:8010` + `bind 127.0.0.1`; scripts/42_verify_exposure.sh: Funnel check now reads AllowFunnel from `tailscale serve status --json`, plus a new forwarded-Host 401 probe.
- d5a5fed — Phase B: rejected the fused-hyper-connection rebuild (llama.cpp 0dc74e3) after golden gates showed empty output at ≥16K ctx; added serve env overrides DSV4_SERVER_BINARY / DSV4_BUILD_MANIFEST / DSV4_MEM_FLOOR_GIB (defaults preserve production); added configs/build-manifests/llamacpp-fusion.json + docs/phase-b-fusion-2026-07-17.md + docs/phase-b-golden-fusion-2026-07-17.json.
- a293a03 — engine systemd unit: Environment=DSV4_MEM_FLOOR_GIB=15 (was hard 16).

## Review these, each with file:line + a concrete failure scenario, tagged [critical]/[high]/[medium]/[low]:
1. **discover_server_pid race fix (scripts/21 + 20).** Is it actually race-free now? Consider: flock present (comm==flock) but the engine child not yet forked; the sh→exec transition of the engine command; PID reuse; the case where flock's first child is not the engine. Does the surrounding DISARM/provisional-target/identity logic still hold with the change? Are start/stop/status all correct and parseable?
2. **The bash syntax fix (49e58b4).** Confirm the corrected conditional is semantically what was intended (engine start-ticks changed check) and that no similar multi-line `[[ ]]` construct remains broken elsewhere in 20/21/01_memwatch.
3. **Caddy `:8010` + `bind 127.0.0.1`.** Confirm this yields a loopback-only listener that also matches every Host (so Tailscale-forwarded requests reach the auth proxy) — and that nothing now routes around the auth proxy or binds beyond loopback. Any regression vs the prior config for the local readiness path?
4. **Exposure verifier changes (42).** Is reading AllowFunnel from `tailscale serve status --json` a correct proof that Funnel is off (vs the old text grep)? Does the forwarded-Host probe correctly catch the host-matcher class of bug? Any false-negative where 42 passes while exposure is actually wrong?
5. **Serve env overrides + mem floor.** DSV4_SERVER_BINARY/DSV4_BUILD_MANIFEST/DSV4_MEM_FLOOR_GIB default to the production values, so the systemd path is unchanged — verify that. Is floor 15 GiB safe given the 12 GiB watchdog kill line and the 90 GiB model on a 119 GiB host (consider KV growth at 32K and the documented 4KiB/tok→~6.9KiB/tok KV undercount)? Note the integrity check hashes only the thin `llama-server` binary, not the shared libs where the real code lives — is that a meaningful gap for the benchmark's build-manifest?
6. **Phase B methodology + conclusion.** Read docs/phase-b-fusion-2026-07-17.md and docs/phase-b-golden-fusion-2026-07-17.json. Was rejecting the fusion binary the correct call? Is the evidence (golden needle_16k + sustained_ctx failures; empty completion at 16K; op source unchanged from 0dc74e3 through origin/master; #25822 test-only) sufficient and correctly reasoned? Is there a plausible SALVAGE path I missed — a cparams/runtime flag to enable/disable the fused op, a build option, a different commit, or a config that would make the op correct? Could the empty output have a cause OTHER than the fused op (so a good binary was wrongly rejected)? Was skipping the speed measurement justified?

## Output
For each of the 6 areas: `## <area> — <one-line verdict>` then tagged bullets (file:line + concrete failure scenario), or an explicit justification if clean. End with `## Summary`: top issues ranked by severity (if any), whether the fusion-rejection conclusion is correct, and a one-line overall judgement on whether the recent work is technically sound. If your sandbox blocks something, say so and reason from the code.
