# T2.3a — Write scripts/12_fetch_gguf.sh (pinned, checksum-verified GGUF downloader)

The ONLY file you may create or modify is `scripts/12_fetch_gguf.sh`. No network access needed (the pins below were captured by the orchestrator from the HF API on 2026-07-16). No git commands, no sudo.

## What it does
Download the Unsloth UD-Q2_K_XL quantization of DeepSeek-V4-Flash at a PINNED revision with per-shard SHA256 verification, into `weights/unsloth-ud-q2_k_xl/` under the repo root.

## Pinned constants
All pins (repo, revision commit, per-shard byte sizes and sha256 values) live in `configs/pins/unsloth-ud-q2_k_xl.json`, captured by the orchestrator from the HF API on 2026-07-16. The script must READ that file — never embed hash values in code (the secret scanner's checksum exemption is scoped to `configs/pins/`).
- Download URL template: `https://huggingface.co/<REPO>/resolve/<REVISION>/<FILEPATH>` (revision pinned in the URL — never `main`).

<!-- Orchestrator note (post-execution): the original brief embedded the pins directly; the
     pre-commit secret scanner correctly flagged 64-hex values in scripts/ and tasks/, so the
     orchestrator refactored pins into configs/pins/ (single source of truth) and updated the
     script accordingly. -->

## Requirements
1. bash strict mode; `--help`; repo root resolved from the script's own location (`cd "$(dirname "$0")/.."`).
2. Pre-check: ≥150 GiB free on the destination filesystem (`df -B1`), else exit 2 with message.
3. Per file: if final file exists with correct byte size, skip download (report "present"); else `curl -L --fail --retry 5 --retry-delay 10 --continue-at -` to `<name>.partial`, then verify byte size AND sha256, then atomic `mv` into place. Any mismatch: delete the bad file, exit 1 naming the file.
4. `--verify-only`: no downloads; verify size+sha256 of all final files; exit 0 only if all present and correct.
5. After success (both modes): write `weights/unsloth-ud-q2_k_xl/manifest.json` — JSON with `repo`, `revision`, `files` (name, bytes, sha256), `verified_at` UTC timestamp.
6. Progress to stderr (one line per file state change); machine-readable summary JSON to stdout at the end: `{"ok": bool, "files_present": n, "bytes_total": n}`.
7. sha256 via `sha256sum`; JSON via `python3` (no jq dependency).

## Definition of done
`bash -n` clean; `--help` works; `--verify-only` on an empty weights dir exits nonzero with a clear message (do NOT download anything yourself — the orchestrator runs the real download).

Final message: confirm file created + any deviations (should be none).
