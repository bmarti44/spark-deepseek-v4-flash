# T0.1 — Scaffold repository

You are implementing one task inside an existing empty git repo at the current working directory (`~/spark-deepseek-v4-flash`). This repo will become PUBLIC on GitHub, so hygiene rules below are mandatory.

## Objective
Create the repository skeleton for a project that benchmarks two DeepSeek-V4-Flash inference stacks on an NVIDIA DGX Spark and serves the winner as a secured endpoint.

## Steps (exactly these; no network access needed or permitted)
1. Create directories, each containing a `.gitkeep`: `scripts/`, `verification/`, `tasks/` (exists), `configs/`, `results/`, `docs/`, `bin/`.
2. `.gitignore` at repo root covering at minimum: `bin/` (vendored binaries), `weights/`, `models/`, `*.gguf`, `*.safetensors`, `hf-cache/`, `logs/`, `*.log`, `.env`, `*api-key*`, `__pycache__/`, `*.pyc`, `.venv/`, `.cache/`. Do NOT ignore `results/` or `configs/`.
3. `README.md` stub: project title "DeepSeek-V4-Flash on a single DGX Spark", one-paragraph description (benchmark `entrpi/ds4-on-spark` vs upstream llama.cpp on GB10, serve winner via Tailscale with API-key auth), a "Status: work in progress" line, and a section skeleton (Results / Reproducing / Security model / Runbook) with TODO markers.
4. `LICENSE`: MIT, copyright 2026 Brian Martin.
5. `docs/citations.md`: create with heading "Sources" and a note "populated as the project proceeds".
6. `configs/versions.lock`: JSON skeleton with keys `host` (fill: hostname spark-aba1, gpu GB10 sm_121, os "Ubuntu 24.04.4", kernel "6.17.0-1026-nvidia", driver "580.159.03", cuda "13.0", dgx_os_updated "2026-07-16"), `pins` (empty object — will hold git commits), `artifacts` (empty object — will hold SHA256s). Values you cannot verify: leave as given here.
7. Secret scanning hooks: create `.githooks/pre-commit` and `.githooks/pre-push`, both executable, both invoking `scripts/lint_secrets.sh`. Write `scripts/lint_secrets.sh` (executable): scans staged files (pre-commit) or the diff range being pushed (pre-push) using `gitleaks protect --staged` / `gitleaks detect` IF a `gitleaks` binary is on PATH or at `bin/gitleaks`, and ALWAYS additionally greps staged/pushed content for: 64-hex-char strings (`[0-9a-f]{64}`), `Bearer [A-Za-z0-9._-]{20,}`, `BEGIN( RSA| OPENSSH)? PRIVATE KEY`, `hf_[A-Za-z0-9]{30,}`, `sk-[A-Za-z0-9]{20,}`, `tskey-[A-Za-z0-9-]{20,}`. Any hit = exit 1 with the offending file:line printed (redact the matched value itself to its first 6 chars). Run `git config core.hooksPath .githooks`.
8. Commit everything as a single commit with message: `T0.1: scaffold repository`. Configure nothing else in git.

## Constraints
- Do NOT create, read, or reference any real secret or key.
- Do NOT write anything into `verification/`, `results/`, or `tasks/` beyond the `.gitkeep` files.
- Do NOT install packages or fetch anything from the network.
- Do NOT create `verification/MANIFEST.sha256` (reserved for the orchestrator).

## Done criteria
`git log --oneline` shows exactly one commit; `git status` clean; hooks path configured; `bash scripts/lint_secrets.sh --self-test` exits 0 (implement a `--self-test` mode that feeds itself a fake 64-hex string via stdin and confirms it WOULD be caught, without touching the index).

Your final message: a list of created files and any deviations (deviations should be none).

<!-- Orchestrator note (post-execution): Codex deleted this brief during T0.1, interpreting the
     tasks/ constraint as "must contain only .gitkeep"; restored by the orchestrator. Future briefs
     say explicitly: never delete existing files. Codex also could not commit ('.git' is read-only
     in its sandbox) — git steps performed by the orchestrator after gate G0.1 passed. -->
