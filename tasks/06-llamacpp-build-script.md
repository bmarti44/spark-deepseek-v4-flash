# T2.2 — Write scripts/13_build_llamacpp.sh

The ONLY file you may create or modify is `scripts/13_build_llamacpp.sh`. No git commands against THIS repo, no sudo, no network in this task (the script you write performs its own clone at runtime).

The script will be RUN AS unprivileged user `dsv4` (`sudo -u dsv4`), with `HOME=/home/dsv4`. It must honor `LLAMACPP_HOME` (default `$HOME/llamacpp-project`), deriving `SRC_DIR=$LLAMACPP_HOME/src/llama.cpp` and `BUILD_DIR=$SRC_DIR/build`. `umask 077`. Read the pinned commit at runtime from the repo's `configs/versions.lock` (`pins."llama.cpp".commit` and `.repo`) — resolve repo root from the script's own path, same pattern as `scripts/11_build_ds4.sh` (read that file for conventions).

## Behavior
1. Clone `pins."llama.cpp".repo` into `$SRC_DIR` if absent (full clone); fetch; `git checkout --detach <pinned commit>`; HARD GATE: `rev-parse HEAD` equals the pin or exit 1.
2. Preconditions: aarch64; `export PATH=/usr/local/cuda/bin:$PATH`; nvcc present and release 13.x; cmake present (fatal if missing — report clearly, orchestrator will install if needed).
3. Configure + build:
   `cmake -S $SRC_DIR -B $BUILD_DIR -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=121 -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF`
   `cmake --build $BUILD_DIR --config Release -j"$(nproc)" --target llama-server llama-cli llama-bench`
   (`-DLLAMA_CURL=OFF` keeps the build network-free and drops the libcurl dependency.)
4. Post-build gates: the three binaries exist+executable under `$BUILD_DIR/bin/`; `cuobjdump --list-elf $BUILD_DIR/bin/llama-server | head` mentions `sm_121`; `$BUILD_DIR/bin/llama-server --version` exits 0 (it prints to stderr; tolerate that).
5. Write `$LLAMACPP_HOME/build-manifest.json`: commit, cmake configure+build commands, nvcc/gcc/cmake version strings, sha256 of the three binaries, built_at UTC. Print `{"ok":true}` on success.
6. Exit codes: 0 ok / 1 build-or-verification failure / 2 usage-or-environment failure. bash strict mode, `--help`.

## Definition of done
`bash -n` clean; `--help` works. Do NOT clone or build anything yourself — the orchestrator executes as dsv4.

Final message: file created + deviations (should be none).
