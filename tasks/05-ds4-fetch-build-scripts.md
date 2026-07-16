# T1.2 — Write scripts/10_fetch_ds4.sh and scripts/11_build_ds4.sh

The ONLY files you may create or modify are `scripts/10_fetch_ds4.sh` and `scripts/11_build_ds4.sh`. Never delete or edit anything else. No git commands, no sudo, no network. Follow the reimplementation spec in `docs/ds4-security-review.md` §E13 (read it) — key points repeated below with orchestrator decisions applied.

Both scripts will be RUN AS the unprivileged user `dsv4` (invoked via `sudo -u dsv4`). They must work with `HOME=/home/dsv4`, honor `DS4_HOME` (default `$HOME/ds4-project`) and derive: `SRC_DIR=$DS4_HOME/src/ds4`, `GGUF_DIR=$DS4_HOME/gguf`. All pins are read at runtime from the repo's `configs/pins/ds4-weights.json` (resolve the repo root from the script's own path; the repo is readable by dsv4 via ACL). `umask 077` in both.

## scripts/10_fetch_ds4.sh
1. Engine source: clone `https://github.com/Entrpi/ds4.git` into `$SRC_DIR` if absent (full clone, not shallow); `git -C $SRC_DIR fetch origin`; `git -C $SRC_DIR checkout --detach <git_pins.engine.commit from pin file>`. HARD GATE: `git -C $SRC_DIR rev-parse HEAD` must equal the pinned commit string; anything else = exit 1. Tag names are never trusted as identity.
2. Weights: for each entry in `files[]` of the pin file (roles base, mtp, dspark_drafter): download `https://huggingface.co/<repo>/resolve/<revision-of-that-repo-from-sources>/<path>` to `$GGUF_DIR/<basename>.partial` with `curl -L --fail --retry 5 --retry-delay 10 --continue-at -`, then verify byte size AND sha256 against the pin file, then atomic `mv` and `chmod 444`. Skip files already present with correct size (full sha check in --verify-only). Delete-and-fail on any mismatch, naming the file.
3. Disk pre-check: ≥120 GiB free on $GGUF_DIR's filesystem before downloading.
4. `--verify-only` mode: no downloads, full size+sha256 verification of engine HEAD and all weight files.
5. On success write `$GGUF_DIR/manifest.json` (repos, revisions, files with bytes+sha256, engine commit, verified_at) and print summary JSON to stdout: `{"ok":bool,"engine_commit":str,"files_present":n}`.

## scripts/11_build_ds4.sh
1. Preconditions (each fatal): `uname -m` == aarch64; `$SRC_DIR` HEAD == pinned engine commit (re-verify); `nvcc` available after `export PATH=/usr/local/cuda/bin:$PATH` (REQUIRED — dsv4's default PATH lacks it); nvcc release must start with `13.`.
2. Build: `make -C $SRC_DIR -j"$(nproc)" cuda-spark` (audited official GB10 target: forces sm_121 + Spark HBM-cache define; builds ds4, ds4-server, ds4-bench, ds4-eval, ds4-agent). Never fetch anything during build.
3. Post-build verification: binaries `ds4`, `ds4-server`, `ds4-bench` exist and are executable in $SRC_DIR; `cuobjdump --list-elf $SRC_DIR/ds4-server 2>/dev/null | head` (cuobjdump lives in /usr/local/cuda/bin) output must mention `sm_121`; `$SRC_DIR/ds4 --help` exits 0.
4. Write `$DS4_HOME/build-manifest.json`: engine commit, build command, nvcc version string, gcc version string, sha256 of the three verified binaries, built_at UTC. Print `{"ok":bool}` to stdout.
5. NOTE in a comment: ds4-agent and ds4_weight_server are built by the target but must NEVER be executed in service; serving uses only ds4-server.

## Shared requirements
bash strict mode; `--help`; clear stderr progress; python3 for JSON (no jq); exit 0 success / 1 verification-or-build failure / 2 usage-or-environment failure.

## Definition of done
`bash -n` clean on both; `--help` works on both; `scripts/10_fetch_ds4.sh --verify-only` fails cleanly (exit 1) when $DS4_HOME is absent. Do NOT clone, download, or build anything yourself — the orchestrator executes for real as dsv4.

Final message: files created + deviations (should be none).
