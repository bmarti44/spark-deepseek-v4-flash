# Task fixB: ops + security hardening (sol-high review remediation)

RULES (binding):
- Modify ONLY: scripts/20_serve_ds4.sh, scripts/21_serve_llamacpp.sh, scripts/01_memwatch.sh,
  scripts/40_auth_helper.py, scripts/41_install_service.sh, scripts/lint_secrets.sh,
  configs/systemd/*.service (may ADD new unit/timer files here), configs/caddy/Caddyfile,
  scripts/10_fetch_ds4.sh, scripts/11_build_ds4.sh, scripts/13_build_llamacpp.sh,
  setup/03-dsv4-user.sh.
- Do NOT touch scripts/30–36, results/, tasks/, verification/, evalsets/, weights/, fixtures/.
- Never delete or create files outside the allowed set. No git state changes (no add/commit).
- Bash: set -Eeuo pipefail style must be preserved; bash -n must pass on every touched script.
- A llama.cpp server (port 8011) IS RUNNING under user dsv4 with live state in /run/dsv4 —
  nothing you do may signal, restart, or reconfigure it. File edits only.

## Watchdog ordering + supervision (scripts/20, 21, 01)
1. Start the memory watchdog BEFORE launching the engine in both serve scripts (currently the
   engine starts first). The watchdog initially watches only MemAvailable (it may receive the
   engine PID/PGID via a file or fifo once the engine spawns — keep it simple: pass the engine
   process-group id to the watchdog through a state/pid file it polls until present).
2. scripts/01_memwatch.sh: fail closed. On ANY internal error (procfs read failure, log write
   failure, unexpected exit path) it must SIGTERM (then SIGKILL after 10s) the engine process
   group before exiting, and log why. A watchdog that dies silently while the engine keeps
   running is the failure mode to eliminate.
3. Stop paths in 20/21: before signalling memwatch_pid and flock_pid, verify identity the same
   way server_pid is verified (start-ticks + boot-id captured in the state file at spawn).
   Store memwatch_start_ticks and flock_start_ticks in the state JSON at start. When stopping
   with a state file that lacks those fields (legacy), fall back to: verify the PID's command
   line matches the expected script/flock signature before killing; never kill unverified PIDs.

## systemd (configs/systemd/)
4. Engine units: remove the `|| true` from the preflight ExecStartPre — preflight failure must
   block ExecStart (fail closed). Keep the advisory comment but rewrite it to say failure blocks.
5. Add dsv4-guard.service + dsv4-guard.timer (both installed but only enabled by the installer):
   every 60s run the active stack's serve script `status`; on failure, `systemctl restart` the
   engine unit. The guard must read which stack is active from /etc/deepseek-v4-flash/env
   (installer already writes it — extend the env file with STACK=<ds4|llamacpp> in task 8).
   Guard runs as root, calls status via `sudo -u dsv4` or runuser. Journal-log every action.

## Auth helper (scripts/40_auth_helper.py)
6. Bound resources: cap concurrent in-flight auth checks at 64 (semaphore; over-limit returns
   503 immediately) and add a global token-bucket rate limit: 120 requests/minute sustained,
   burst 240; over-limit returns 429. Constants in code, not flags. Keep: exactly-one
   Authorization header, hmac.compare_digest, no key logging, 204/401 semantics.

## Installer (scripts/41_install_service.sh)
7. Never place the key in any argv. Create /etc/deepseek-v4-flash/auth-header
   (root:dsv4auth 0640) containing `Authorization: Bearer <key>` whenever the key is
   (re)generated, and change the printed verification commands to use `curl -H @/etc/deepseek-v4-flash/auth-header`.
8. Append STACK=<stack> to /etc/deepseek-v4-flash/env (used by the guard).
9. Post-install verification (script performs it, not just prints): wait up to 600s for
   readiness, then (a) curl without auth -> expect 401; (b) curl with the auth-header file ->
   expect 200 on /v1/models; (c) `ss -tlnp` shows 8010–8014 bound only to 127.0.0.1;
   (d) `tailscale serve status` output, if it mentions 8011 or 8012 directly, ABORT with a
   loud error (a pre-existing serve config would bypass auth). Install must exit nonzero if
   any check fails.
10. Enable dsv4-guard.timer for the installed stack.

## Secret lint (scripts/lint_secrets.sh)
11. Fix: results/DECISION.md is routed to scan_digest_json and always fails as invalid JSON.
    Route *.md exempted files to the NOHEX tier only (plain-text scan without the 64-hex rule
    is NOT acceptable — instead scan them with the full pattern but allow 64-hex only when a
    line is a markdown table/inline-code digest of <=12 hex chars... simplest correct rule:
    DECISION.md must never contain a full 64-hex string; scan it with the FULL pattern, i.e.
    REMOVE results/DECISION.md from the exemption list entirely. 34_decision.py now truncates
    digests to 12 chars, so full-pattern scanning is correct.)
12. Pre-push: scan every commit in the push range (git rev-list remote..local), not just the
    endpoint diff — a secret added then removed within the range must still be caught. Keep the
    NUL-safe file listing and the digest-tier split per commit. Repo is small; performance is fine.

## Build reproducibility (scripts/10, 11, 13)
13. After checkout of the pinned commit and before building, require a clean worktree:
    `git status --porcelain` must be empty and `git describe --always --dirty` must not end in
    -dirty; abort otherwise. Record that string into the build manifest each script writes.

## Hooks activation (setup/03-dsv4-user.sh)
14. Append a step that runs `git -C <repo> config core.hooksPath .githooks` (idempotent) so a
    fresh clone activates the pre-commit/pre-push scanners; print what it did.

## Acceptance (run yourself; I re-run everything)
- bash -n on every touched shell script; python3 -m py_compile scripts/40_auth_helper.py.
- scripts/lint_secrets.sh --self-test passes.
- `bash scripts/41_install_service.sh` with no args prints usage, exit 2 (no root needed for that path).
- Do NOT run the serve scripts or installer for real.
Report per-file changes + acceptance outputs.
