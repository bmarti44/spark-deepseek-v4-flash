# Task: write REPRODUCING.md + docs/runbook.md

RULES (binding):
- CREATE exactly two files: REPRODUCING.md (repo root) and docs/runbook.md. Modify nothing else.
- Never delete files. No git state commands. Do not start/stop servers, do not send requests
  to 127.0.0.1:8011/8012 (a benchmark is running against 8012 RIGHT NOW).
- You may read everything in the repo and run read-only commands to verify claims
  (e.g. --help output, ls, cat). Every command you document must exist with the exact flags
  you show — verify against the actual scripts, do not guess.

## REPRODUCING.md — a stranger with their own DGX Spark reproduces everything
Audience: a competent engineer who cloned github.com/bmarti44/spark-deepseek-v4-flash onto
a stock DGX Spark (GB10, 128 GB, DGX OS). Cover, in order, with exact commands:

1. Hardware/OS prerequisites + the UMA hard-freeze warning (why the memory-safety layer is
   non-negotiable). State measured facts from configs/versions.lock.
2. One-time host setup as root: setup/01..04 in order, what each does, which are needed for
   benchmarking (01–03) vs production (04). Note 03 activates the repo git hooks and creates
   the dsv4 user + sudoers delegation + ACL expectations (dsv4 must be able to read the repo:
   show the setfacl commands the repo relies on — find them by reading setup/ and PROTOCOL/docs;
   if they are not in a script, say so explicitly and give the commands inline).
3. Harness environment: python venv (.venv-harness, requirements-harness.txt), docker
   presence for HumanEval sandbox, codex CLI NOT required to reproduce (it was the
   implementation agent, not a runtime dependency).
4. Fetch + verify: weights (scripts/12 for the GGUF; scripts/10 for ds4 + its weights),
   encoder (14), evalsets (16) — all pinned via configs/pins/ + evalsets/pins.json; explain
   the SHA-256 verify-on-fetch model and where manifests land.
5. Build: scripts/11 (ds4) and 13 (llama.cpp) as dsv4; clean-worktree enforcement; where
   build manifests are written; how configs/build-manifests/*.json (committed copies) are
   used as --config-evidence.
6. Serve: scripts/20 (ds4) / 21 (llama.cpp) start|stop|status as dsv4; single-residency
   flock; watchdog-first design; state files under /run/dsv4; readiness ~5–7 min cold.
7. Run every gate exactly as this repo did (list the real commands with real flags):
   golden (32), token parity (33), speed (30), accuracy dev+holdout with --config-evidence
   (31; note the once-only holdout ledger semantics and PROTOCOL.md versioning),
   soak (35, frozen 30-min), audit (36), decision (34 with --soak-evidence + --audit-evidence).
   State that verification/MANIFEST.sha256 freezes all of these: `sha256sum -c` to verify.
8. Production install (after a winner exists): setup/04, apt install caddy, 41_install_service.sh
   <winner>; what its built-in verification checks; key rotation + out-of-band delivery;
   tailscale serve command and the funnel-off warning.
9. What you should expect to see: reference the committed results/ files as the canonical
   record (do NOT restate numbers that might change — link to files).
10. Threat model + protocol pointers (docs/threat-model.md, PROTOCOL.md,
    docs/adversarial-review-2026-07-16.md, docs/research-*-2026-07-16.md).

## docs/runbook.md — day-2 operations for the served endpoint
Sections: start/stop/status (systemd units + serve scripts), health checks (local curl via
auth-header file, tailnet URL), key rotation (41 default vs --keep-key; delivering the new
key), guard timer behavior (auto-restart semantics; how to silence during maintenance:
systemctl stop dsv4-guard.timer), watchdog logs location + what BREACH/FAIL_CLOSED entries
mean, memory-pressure triage (what to check before restarting), upgrading an engine safely
(PROTOCOL versioning: any engine/flag change = new candidate config = full gate rerun),
known limits (A's warm >28K envelope if ds4 wins; B TTFT profile if llama wins — phrase both
conditionally since the decision is pending), incident: server unresponsive (guard restarts;
manual: serve script stop as dsv4, check memwatch log, restart), incident: host froze
(hard reboot; RuntimeDirectory is tmpfs so state clears; residency lock is safe).

## Style
Plain prose, exact commands in fenced blocks, no invented flags, no marketing. Link files
with relative repo paths. Where a step requires root vs bmarti44 vs dsv4, say which.

## Acceptance
- Every fenced command verified against the real script/flag (you ran --help or read source).
- No references to files that don't exist.
Report: list of commands you verified and how.
