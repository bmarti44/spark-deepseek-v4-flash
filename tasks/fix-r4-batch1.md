# Fix batch (round-4 review, overall 84.5): close the 7 highs + named mediums

Fix the findings below. Do NOT touch any results/ file. Do not run servers or send
requests to 127.0.0.1:8010/8011/8012. Match existing style. After editing any
MANIFEST-listed file, refresh its line in verification/MANIFEST.sha256 (sorted) and
verify sha256sum -c. The operator will regenerate audits/decision after your batch
(your sandbox lacks docker) — record the sequence in the PROTOCOL v8 entry.

## A. memory-safety (87)

A1 [high] Silent disarm via target-file removal. Change the disarm handshake: the
serve scripts' stop path must no longer REMOVE the target file to disarm; instead it
overwrites it with an authenticated disarm record: "DISARM <pid> <pgid> <start_ticks>"
matching the armed identity. scripts/01_memwatch.sh: while armed, target file MISSING
or unreadable or identity-mismatched => FAIL CLOSED (SIGKILL verified engine group if
identity still verifiable, exit nonzero loudly); a valid DISARM record matching the
armed identity => clean disarm (log, exit 0). Serve-script status command (both 20 and
21) must verify the watchdog is genuinely armed: watchdog PID alive AND ready file
says ARMED AND target file present with verified identity; report DEGRADED otherwise.
Update the guard-timer check the same way if it only checks PID liveness.

A2 [medium] Before every kill, re-read /proc/<pid>/stat field 5 (pgid) and require it
to equal the published PGID in addition to start-ticks; mismatch => fail closed loudly
(and still kill the recorded PID itself if its start-ticks match).

## B. benchmark-validity (86)

B1 [high] Bind live bytes to evidence. scripts/21_serve_llamacpp.sh at start: verify
every GGUF shard's SIZE against weights/unsloth-ud-q2_k_xl/manifest.json always, and
verify full per-shard sha256 when DSV4_VERIFY_WEIGHTS=full (document both; default
size-only with a logged notice). Verify the server binary sha256 against the
COMMITTED configs/build-manifests/ entry (MANIFEST-frozen), not the mutable live
build manifest; refuse to start on mismatch. Do the equivalent for
scripts/20_serve_ds4.sh (binary hash vs committed build manifest; weights manifest
size check).

B2 [medium] scripts/34_decision.py: reapply script 30's per-rep validity predicates
from raw rep fields (read scripts/30_bench_speed.py for the exact predicates:
completion-token count, tokenizer errors, timing sanity) instead of trusting `valid`,
and recompute the TTFT median from raw reps; mismatch with reported values => evidence
failure.

## C. soak-and-audit (83)

C1 [high] Endpoint coverage: in 34's soak validation require (a) first health probe
and first memory sample within 2x their frozen interval of t=0, (b) last within 2x
interval of elapsed end, (c) health probe count >= floor(elapsed/interval) * 0.8 (not
the fixed 30 minimum alone). Must still pass on committed results/soak-*.json (they
span their full runs) — prove with --validate-evidence-only.

C2 [medium] 34 soak validation: additionally require request indices strictly
increasing, per-request completion token counts positive and <= max_tokens, TTFT
present/positive/less than total duration per request, and prompt-rotation evidence
(read scripts/35_soak.py for what it records per request — bind whatever rotation
field exists; if only a prompt index, require it to cycle, not repeat one value).

C3 [medium] 34: validate the audit artifact's humaneval_runtime provenance: present,
image == python:3.12-slim, repo_digest equal to configs/pins/humaneval-runtime.json,
pin_sha256 equal to the current pin file hash. Missing/mismatched => evidence failure.

## D. reproducibility (74)

D1 [high] Portable identities in 34: SPEED/SOAK expected metadata must not hard-code
/home/bmarti44 paths. Where a model path is bound, require the path to END WITH the
repo-relative suffix (e.g. weights/unsloth-ud-q2_k_xl/<file>.gguf) rather than equal
an absolute path; keep every other identity field exact.

D2 [high] REPRODUCING.md: every accuracy/speed command a reproducer runs must use
THEIR generated build manifest paths (parameterize: BUILD_MANIFEST=$PWD/build/... as
produced by the build scripts they just ran), with an explicit callout box: committed
configs/build-manifests/ are OUR frozen evidence, used only by the offline audit
(scripts/36) to verify OUR verdict; passing them to a fresh benchmark run is wrong.
Audit every documented command for this.

D3 [high] REPRODUCING.md production-install section: add Tailscale prerequisites
BEFORE the installer/serve steps: install (official apt repo instructions for Ubuntu
arm64), `tailscale up` login, minimum version note, confirm `tailscale status` works,
note that Serve requires HTTPS certificates enabled on the tailnet and that the
installer fails closed without a working authenticated CLI. Mention scripts/42 rerun
after any tailscale change (already documented — keep coherent).

D4 [medium] Add requirements-harness.lock (pip freeze of .venv-harness, operator will
regenerate if you cannot run the venv) referenced from REPRODUCING.md as the exact
known-good resolution; document docker install as the DGX OS docs link plus the
version used (read `docker --version` if available, else leave a TODO-OPERATOR
marker). Note: do not modify .venv-harness itself.

## E. process-integrity (84)

E1 [high] scripts/36_audit_accuracy.py: for every holdout suite result, require
matching ledger discipline: a `started` entry AND a `completed` entry with the same
(ledger_namespace, stack_label, suite, config_digest) as the result file, started
timestamp <= completed timestamp, and the result's config_digest equal to the ledger
pair's. Sole exception: the grandfathered entry (content-hash pinned) may lack the
started record. Any holdout result without its pair => audit FAIL.

E2 [medium] MANIFEST: add .gitleaks.toml and weights/unsloth-ud-q2_k_xl/manifest.json
and weights/ds4 manifest if one exists (check). Refresh all touched lines.

E3 [medium] scripts/41_install_service.sh: stack argument other than llamacpp
requires an explicit `--acknowledge-decision-override` flag; without it, print the
DECISION-OVERRIDE.md summary (llamacpp is the production engine) and abort. With
llamacpp, no change.

## F. PROTOCOL v8 entry

Document every change as non-voiding (verifier/ops/reproducibility hardening; no
scorer, prompt, dataset, generation, or soak-measurement change), plus the operator
sequence: regenerate audits (36) then decision (34) because 36's ledger-pair rule and
34's new checks must consume regenerated artifacts.

## Acceptance (run all; report)
- bash -n / py_compile all touched files.
- sha256sum -c verification/MANIFEST.sha256 all OK.
- 34 --validate-evidence-only on committed evidence: every NEW check passes (audits
  will fail only if your 36 changes alter audit content — say so; operator regenerates).
- unittest test_auth_helper if sockets allowed (else note).
- scripts/lint_secrets.sh --self-test passes; no full 64-hex digests added to prose or
  python (put enforcement digests in configs/pins/* and read them).
- git diff --check clean; results/ untouched.
Report: files changed, acceptance output, anything not done and why.
