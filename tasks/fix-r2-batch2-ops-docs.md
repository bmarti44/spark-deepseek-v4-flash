# Fix batch 2 (round-2 review): ops fail-open paths + security + reproducibility docs

Fix these confirmed round-2 findings. Do NOT touch scripts/31, scripts/34, scripts/35,
scripts/36, scripts/37, or any results/ file. Do not run servers or send requests to
127.0.0.1:8010/8011/8012. Bash style must match existing scripts (set -euo pipefail,
die(), safe_log patterns). After editing any MANIFEST-listed file, refresh its line in
verification/MANIFEST.sha256 (keep sorted by path) and verify sha256sum -c passes.

## CONTEXT CHANGE you must incorporate: results/DECISION-OVERRIDE.md
The benchmark verdict picked ds4, but Brian overrode for the product: the PRODUCTION
endpoint is LLAMACPP (1M-context roadmap). Docs must present: benchmark verdict = ds4
(record stands), production engine = llamacpp (override, with the reason), ds4 = parked
alternative. The installer will be run with stack=llamacpp.

## 1. scripts/01_memwatch.sh — breach kill must not depend on logging
On breach: SIGKILL the engine group FIRST, then attempt logging. A safe_log failure
during breach handling must never divert to the graceful path (order the statements;
disable the ERR trap inside the breach handler if needed). Keep fail_closed graceful
handling for genuine internal errors only.

## 2. scripts/20_serve_ds4.sh + scripts/21_serve_llamacpp.sh — cleanup traps
Add an ERR/EXIT trap armed from just before the watchdog starts until successful
completion of start: on failure, kill the started watchdog and engine process group,
remove the published target file, and release the lock. Cover the residency-lock
contention path (discover_server_pid die) so an unarmed watchdog is never left behind.
Also: publish start-ticks alongside PID/PGID in the memwatch target file and make
scripts/01_memwatch.sh verify /proc/<pid>/stat start-ticks before arming AND before
killing (PID-reuse guard); on mismatch fail closed (kill nothing that doesn't match;
exit nonzero loudly).

## 3. scripts/40_auth_helper.py — concurrency must cover inference, not just auth
The current semaphore only spans the token check. Restructure so the helper is a
streaming reverse proxy in front of the engine (stdlib only): Caddy → helper → engine,
holding the concurrency slot for the ENTIRE request/response (including SSE streaming),
64 in-flight cap → 503, keep the existing token bucket. Preserve constant-time key
comparison, Authorization stripping before upstream, duplicate-header rejection. Update
configs/caddy/Caddyfile accordingly (Caddy terminates TLS/tailscale side and proxies to
the helper; engine port never exposed). Add scripts/tests/test_auth_helper.py (stdlib
unittest, spawns the helper against a mock upstream on a random port) covering: 200
happy path incl. streamed chunks, 401 wrong key, 429 burst, 503 when 64 slots held,
slot released after response completes. Update configs/systemd/dsv4-authhelper.service
if env/ports change.

## 4. scripts/41_install_service.sh — verification must fail closed
- tailscale verification: any error running `tailscale serve status` = install FAILURE
  (rollback or explicit abort message), not a warning; explicitly verify: no funnel
  enabled, no route to 8011/8012, and if a serve route exists it targets 8010 only.
- Post-install must also verify the auth-helper proxy chain (from §3) end to end on
  loopback: engine port refuses external, 8010 → 401 without key, 200 with key.

## 5. scripts/lint_secrets.sh — gitleaks required
If gitleaks is absent, FAIL with install instructions instead of skipping the
historical scan.

## 6. Reproducibility docs (REPRODUCING.md, docs/runbook.md, README.md)
- Update to verdict-era reality: DECISION.md verdict (ds4 wins the ≤28K benchmark) +
  DECISION-OVERRIDE.md (llamacpp is the production endpoint; 1M-context roadmap;
  ds4 parked). Remove all "no winner yet"/"evidence incomplete" text.
- Every llamacpp gate command must include the auth flags actually needed
  (--api-key-file where 31/30/32/33/35 support it) so the documented sequence runs
  without 401s. Check each script's actual flag name before writing it.
- Holdout ledger: add a "clean-room reproduction" section: a fresh reproducer's runs
  produce a DIFFERENT config digest identity (their own binary/weights hashes) so the
  once-only ledger does not block them; verifying OUR holdout numbers is done via the
  committed transcripts + scripts/36 audit (offline recount), NOT by re-querying.
  Document explicitly that editing/deleting the committed ledger voids the witness.
- Parameterize the hardcoded bmarti44/repo paths: setup scripts and systemd units get
  a single documented variable (e.g. DSV4_REPO, default the current path) — units may
  use a sed-on-install step in 41_install_service.sh rather than runtime env.
- Pin what can be pinned in docs: record the exact docker image digest used for
  HumanEval (`docker inspect python:3.12-slim --format '{{index .RepoDigests 0}}'` —
  run it and paste the digest), the caddy version to install, and note
  setup/02's full-upgrade caveat with the versions.lock cross-check step.
- docs/threat-model.md: correct the recount claim to match the new v6 audit reality.

## Acceptance (run all)
- bash -n on every touched shell script; py_compile on the helper; the new unittest
  file passes (.venv-harness/bin/python -m unittest scripts/tests/test_auth_helper.py -v).
- sha256sum -c verification/MANIFEST.sha256 → all OK.
- scripts/lint_secrets.sh runs clean on the working tree (gitleaks is installed here).
- grep proves no doc still says "no winner"/"incomplete evidence"; grep proves every
  documented llamacpp benchmark command carries the auth flag.
Report: files changed, acceptance output, anything not done and why.
