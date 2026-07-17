# Fix batch (round-3 review, overall 77.3): close all remaining high findings

Fix the round-3 findings below. Do NOT touch any results/ file. Do not run servers or
send requests to 127.0.0.1:8010/8011/8012. Bash style must match existing scripts
(set -Eeuo pipefail, die(), safe_log). After editing any MANIFEST-listed file, refresh
its line in verification/MANIFEST.sha256 (keep sorted by path) and verify
`sha256sum -c` passes.

IMPORTANT CONSEQUENCE you must document but NOT execute: scripts/31 changes below alter
its manifest line, which the committed audit artifacts bind (harness_manifest_line).
The operator (not you — your sandbox has no docker) will regenerate
results/audit-{ds4,llamacpp}.json with scripts/36 and re-run scripts/34 to refresh
results/decision.json after your batch lands. Add this sequence to the PROTOCOL v7
entry (see §D1) and do not fail your acceptance on the stale committed audits.

## A. memory-safety

A1. scripts/01_memwatch.sh — on_term (TERM/INT/HUP) currently sets expected_exit=true
and exits without touching the engine. Required: if the watchdog is ARMED (target file
published and identity-verified), any TERM/INT/HUP must SIGKILL the engine group FIRST
(same verified-identity kill path as breach), then exit nonzero loudly. Add an explicit
disarm handshake for graceful stops: the serve scripts' stop path must stop the engine
first, then remove/retract the target file (disarm), then TERM the watchdog; the
watchdog treats TERM-with-no-armed-target as a clean stop. Verify and fix the stop
sequencing in scripts/20_serve_ds4.sh + scripts/21_serve_llamacpp.sh accordingly.

A2. scripts/20 + 21 — unarmed startup window: before launching the engine, publish a
PROVISIONAL target (the serve script's own process group, which contains the engine
child, with start-ticks) so a breach during startup kills the whole start group; after
engine PID discovery, atomically replace with the final engine target as today.
scripts/01_memwatch.sh: while holding a provisional target, a breach kills that group
(verified identity) instead of merely logging.

A3. scripts/20 + 21 cleanup_failed_start — kill the ENGINE group first, then the
watchdog, then release lock/files (reverse of current order), so no unsupervised
interval exists during failed-start cleanup.

## B. verifier boundary (PROTOCOL v7, non-voiding decision-layer hardening)

B1. scripts/34_decision.py — cross-check the audit artifact against the accuracy files
it claims to bind: for every suite, require the audit's `correct_recount` and
`summary_correct` to be present, equal to each other, and equal to the `correct` read
from the corresponding acc-*.json. Any mismatch = evidence failure.

B2. scripts/34_decision.py — hash the CURRENT scripts/31_bench_accuracy.py and require
it to equal the sha256 in its verification/MANIFEST.sha256 line (which the audits
bind). Additionally verify the manifest itself: run the equivalent of `sha256sum -c`
in-process over ALL manifest entries before deciding; any failure = abort. (Keep it
stdlib; stream files, don't slurp.)

B3. scripts/34_decision.py read_speed — bind speed-artifact identity: require the
stack label to match the candidate, and require model, max_tokens/generation controls,
tokenizer/fixture identity (whatever fields scripts/32 actually records — read
scripts/32 first and bind every identity field it emits), and warmup count to match
per-stack expected constants derived from the committed artifacts. Fabricated or
foreign speed JSON must fail.

B4. scripts/34_decision.py soak validation — validate raw arrays: all timestamps
finite, nonnegative, strictly monotonic per array, bounded by [start, start+elapsed];
health-probe and memory-sample spacing consistent with scripts/35's frozen intervals
(tolerance ±50%); no duplicate timestamps. Also bind soak identity: require
config_hash, model, max_tokens, and extra_body fields recorded by scripts/35 (read 35
to get exact field names) to be present and to match the engine/stack under decision;
mismatch = evidence failure. MUST still pass on the committed results/soak-*.json —
verify by running the real decision command dry (it will fail later on stale audit
bindings; assert the failure is ONLY the stale-audit binding, nothing from your new
speed/soak checks — or better, add a --validate-evidence-only mode that runs every
evidence check and stops before verdict, and use it for acceptance).

B5. scripts/31_bench_accuracy.py + scripts/36_audit_accuracy.py — enforce the Docker
image digest: before any sandbox execution, resolve the local image's RepoDigest
(`docker inspect python:3.12-slim`) and require it to equal
configs/pins/humaneval-runtime.json; fail closed on mismatch or inspect error; record
the resolved digest in the output artifact (31: summary provenance; 36: audit
document). Do NOT change any prompt, rendering, scoring, extraction, or generation
logic in 31 — this is a preflight + provenance field only.

## C. security

C1. scripts/40_auth_helper.py — authenticate BEFORE consuming a rate token (auth is a
constant-time compare; keep it constant-time). Failed-auth requests must not drain the
authenticated clients' bucket. Add a separate, smaller unauthenticated-failure bucket
(e.g. 30 burst / 1 per 2 s refill) that 429s abusive unauthenticated traffic without
affecting keyed clients. Update scripts/tests/test_auth_helper.py: wrong-key burst no
longer exhausts the main bucket (keyed requests still succeed after unauth flood), and
the unauth bucket itself 429s.

C2. scripts/40_auth_helper.py — bound pre-handler resource use: set a socket/header
timeout (e.g. handler timeout attribute + server socket timeout ~10 s) and cap total
concurrent connections (connection-level semaphore around handler dispatch, larger
than the 64 response cap, e.g. 128, returning 503 or closing when exceeded) so
slow-loris style partial requests cannot grow threads unboundedly. Stdlib only.

C3. New scripts/42_verify_exposure.sh — standalone re-verification of the exposure
chain, runnable any time: tailscale serve status parses clean; funnel OFF; no route to
8011/8012/8013/8014; any serve route targets 127.0.0.1:8010 only; 8010 → 401 without
key, 200 with key (read key as the service user only if run as root, else skip the
authed probe with a loud note). Factor the existing checks out of
scripts/41_install_service.sh so both use the same functions (source a shared lib or
have 41 call 42). Docs (REPRODUCING.md, docs/runbook.md): run 42 after ANY tailscale
config change, and the serve command section must be immediately followed by it.

## D. reproducibility + process-integrity

D1. PROTOCOL.md — fix the stale headline: the intro still says "Protocol v2 is the
binding version". Rewrite: v6 is binding today (v7 after this entry); numbers used by
the decision come from the version columns recorded per suite (v2 speed/golden, v4
generation + v5 grading for HumanEval, v6+ verifier). Add the v7 entry table covering
every change in this batch (all non-voiding: verifier/ops/security hardening; docker
digest preflight; audit regeneration sequence required because 31's manifest line is
audit-bound).

D2. PROTOCOL.md + scripts/36_audit_accuracy.py — the llamacpp GSM8K holdout ledger
entry predates the started-entry rule and 36 grandfathers it by filename. Make this an
explicit recorded exception: PROTOCOL v7 entry documents WHY (entry was created under
v2 code before the started-record existed, evidence witnessed by git history at commit
<find the actual commit that added results/holdout-ledger.json and cite it>), and 36's
grandfather clause must cite the PROTOCOL entry in a comment + restrict itself to the
exact ledger entry content hash (not just the filename), so a future edit of that
entry breaks the grandfather.

D3. verification/MANIFEST.sha256 — add configs/pins/ds4-weights.json and
configs/pins/unsloth-ud-q2_k_xl.json (keep sorted).

D4. scripts/31_bench_accuracy.py — clean-room ledger namespacing: support env
DSV4_LEDGER_NAMESPACE (default empty = ours); when set, it is folded into the ledger
identity (recorded as a field in entries and part of the once-only identity), so a
bit-identical clean-room build can rerun holdouts under its own namespace without
touching our committed entries. Editing/deleting committed entries still voids the
witness — keep that documented. Update REPRODUCING.md clean-room section.

D5. REPRODUCING.md — host-setup honesty: setup/02's apt full-upgrade is unpinned;
document this as a known reproducibility limitation with the mitigation: capture
`dpkg -l` + nvidia-smi/kernel versions after setup, cross-check against
configs/versions.lock, and record any divergence in the reproducer's notes; preflight
rejection on version mismatch is EXPECTED for future hosts and the reproducer should
record their own versions.lock rather than bypass checks silently.

D6. REPRODUCING.md — gitleaks: add install step with the pinned release
(v8.24.3 linux_arm64, tarball sha256
5f2edbe1f49f (full sha pinned in configs/pins/gitleaks.json), place binary at
bin/gitleaks) so the evidence-commit workflow works on a fresh host.

## Acceptance (run all; report results)

- bash -n every touched shell script; py_compile every touched python file.
- .venv-harness/bin/python -m unittest scripts/tests/test_auth_helper.py -v (loopback
  may be blocked in your sandbox — if so say so; the operator reruns it).
- sha256sum -c verification/MANIFEST.sha256 → all OK (after refreshing lines).
- scripts/34_decision.py --validate-evidence-only (or your equivalent) passes on
  committed speed/soak evidence and fails ONLY on the stale audit binding (expected
  until the operator regenerates audits).
- scripts/lint_secrets.sh --self-test passes.
- grep proves PROTOCOL.md no longer claims v2 is binding.
- git diff --check clean.
Report: files changed, acceptance output, anything not done and why.
