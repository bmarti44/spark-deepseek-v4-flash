#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

usage() {
    cat <<'EOF'
Usage: 13_build_llamacpp.sh [--help]

Clone and build the pinned llama.cpp revision with CUDA support for sm_121,
verify the resulting binaries, and write a build manifest.
EOF
}

die_build() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

die_env() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}

if (( $# > 1 )); then
    usage >&2
    exit 2
fi
case "${1:-}" in
    '') ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

[[ -n "${HOME:-}" ]] || die_env 'HOME is not set'
LLAMACPP_HOME="${LLAMACPP_HOME:-$HOME/llamacpp-project}"
SRC_DIR="$LLAMACPP_HOME/src/llama.cpp"
BUILD_DIR="$SRC_DIR/build"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" \
    || die_env 'cannot resolve script directory'
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)" \
    || die_env 'cannot resolve repository root'
PIN_FILE="$REPO_ROOT/configs/versions.lock"

for command_name in python3 git mkdir nproc sha256sum gcc uname date head; do
    command -v "$command_name" >/dev/null 2>&1 \
        || die_env "required command not found: $command_name"
done
[[ -r "$PIN_FILE" ]] || die_env "version lock is not readable: $PIN_FILE"

pin_values="$(python3 - "$PIN_FILE" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        pin = json.load(stream)["pins"]["llama.cpp"]
    repo = pin["repo"]
    commit = pin["commit"]
    if not isinstance(repo, str) or not repo or "\n" in repo:
        raise ValueError("llama.cpp repo must be a non-empty, single-line string")
    if not isinstance(commit, str):
        raise ValueError("llama.cpp commit must be a string")
    print(repo)
    print(commit)
except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
    print(f"invalid version lock: {error}", file=sys.stderr)
    sys.exit(2)
PY
)" || die_env "failed to parse version lock: $PIN_FILE"
llamacpp_repo="${pin_values%%$'\n'*}"
llamacpp_commit="${pin_values#*$'\n'}"
[[ "$llamacpp_commit" =~ ^[0-9a-f]{40}$ ]] \
    || die_env 'invalid llama.cpp commit pin'

mkdir -p -- "$LLAMACPP_HOME/src" \
    || die_build "cannot create source parent directory: $LLAMACPP_HOME/src"
if [[ ! -e "$SRC_DIR" ]]; then
    printf 'Cloning pinned llama.cpp repository...\n' >&2
    git clone -- "$llamacpp_repo" "$SRC_DIR" >&2 \
        || die_build "failed to clone llama.cpp into $SRC_DIR"
fi
[[ -d "$SRC_DIR" ]] || die_build "source path is not a directory: $SRC_DIR"

printf 'Fetching llama.cpp revisions...\n' >&2
git -C "$SRC_DIR" fetch --all --tags --prune >&2 \
    || die_build "failed to fetch llama.cpp repository: $SRC_DIR"
git -C "$SRC_DIR" checkout --detach "$llamacpp_commit" >&2 \
    || die_build "failed to check out pinned llama.cpp commit: $llamacpp_commit"
actual_commit="$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null)" \
    || die_build "cannot read llama.cpp HEAD: $SRC_DIR"
[[ "$actual_commit" == "$llamacpp_commit" ]] \
    || die_build "llama.cpp HEAD mismatch: expected $llamacpp_commit, got $actual_commit"

[[ "$(uname -m)" == aarch64 ]] \
    || die_env 'this build requires uname -m to report aarch64'
export PATH="/usr/local/cuda/bin:$PATH"
command -v nvcc >/dev/null 2>&1 \
    || die_env 'nvcc not found after adding /usr/local/cuda/bin to PATH'
command -v cuobjdump >/dev/null 2>&1 \
    || die_env 'cuobjdump not found after adding /usr/local/cuda/bin to PATH'
command -v cmake >/dev/null 2>&1 \
    || die_env 'cmake is required to build llama.cpp but was not found in PATH'

nvcc_version="$(nvcc --version)" || die_env 'nvcc --version failed'
[[ "$nvcc_version" =~ release[[:space:]]13\. ]] \
    || die_env 'nvcc release must start with 13.'
gcc_version="$(gcc --version)" || die_env 'gcc --version failed'
gcc_version=${gcc_version%%$'\n'*}
cmake_version="$(cmake --version)" || die_env 'cmake --version failed'
cmake_version=${cmake_version%%$'\n'*}
parallelism="$(nproc)" || die_env 'nproc failed'

configure_args=(
    cmake -S "$SRC_DIR" -B "$BUILD_DIR"
    -DGGML_CUDA=ON
    -DCMAKE_CUDA_ARCHITECTURES=121
    -DCMAKE_BUILD_TYPE=Release
    -DLLAMA_CURL=OFF
)
build_args=(
    cmake --build "$BUILD_DIR" --config Release -j"$parallelism"
    --target llama-server llama-cli llama-bench
)

printf 'Configuring pinned llama.cpp build...\n' >&2
"${configure_args[@]}" >&2 || die_build 'llama.cpp CMake configure failed'
printf 'Building pinned llama.cpp targets...\n' >&2
"${build_args[@]}" >&2 || die_build 'llama.cpp build failed'

binaries=(llama-server llama-cli llama-bench)
for binary in "${binaries[@]}"; do
    [[ -f "$BUILD_DIR/bin/$binary" && -x "$BUILD_DIR/bin/$binary" ]] \
        || die_build "required executable is missing: $BUILD_DIR/bin/$binary"
done

# CUDA fatbinaries live in the shared libggml-cuda.so, not the executable
# (llama.cpp default builds ggml as shared libraries).
set +o pipefail
elf_head="$(cuobjdump --list-elf "$BUILD_DIR/bin/libggml-cuda.so" 2>/dev/null | head)"
elf_status=$?
set -o pipefail
(( elf_status == 0 )) || die_build 'cuobjdump inspection of libggml-cuda.so failed'
[[ "$elf_head" == *sm_121* ]] \
    || die_build 'libggml-cuda.so CUDA objects do not report sm_121'
"$BUILD_DIR/bin/llama-server" --version >/dev/null 2>&1 \
    || die_build 'llama-server --version smoke test failed'

hashes=()
for binary in "${binaries[@]}"; do
    digest="$(sha256sum -- "$BUILD_DIR/bin/$binary")" \
        || die_build "cannot hash binary: $binary"
    hashes+=("${digest%% *}")
done

built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    || die_env 'cannot obtain current UTC time'
manifest="$LLAMACPP_HOME/build-manifest.json"
manifest_tmp="$manifest.partial"
python3 - "$manifest_tmp" "$manifest" "$llamacpp_commit" \
    "$SRC_DIR" "$BUILD_DIR" "$parallelism" "$nvcc_version" \
    "$gcc_version" "$cmake_version" "$built_at" \
    "${hashes[0]}" "${hashes[1]}" "${hashes[2]}" <<'PY' \
    || die_build 'failed to write build manifest'
import json
import os
import shlex
import sys

(temporary, output, commit, source, build, parallelism, nvcc, gcc, cmake,
 built_at, server_hash, cli_hash, bench_hash) = sys.argv[1:]
configure = [
    "cmake", "-S", source, "-B", build, "-DGGML_CUDA=ON",
    "-DCMAKE_CUDA_ARCHITECTURES=121", "-DCMAKE_BUILD_TYPE=Release",
    "-DLLAMA_CURL=OFF",
]
build_command = [
    "cmake", "--build", build, "--config", "Release", f"-j{parallelism}",
    "--target", "llama-server", "llama-cli", "llama-bench",
]
manifest = {
    "commit": commit,
    "cmake_configure_command": shlex.join(configure),
    "cmake_build_command": shlex.join(build_command),
    "nvcc_version": nvcc,
    "gcc_version": gcc,
    "cmake_version": cmake,
    "binaries": {
        "llama-server": {"sha256": server_hash},
        "llama-cli": {"sha256": cli_hash},
        "llama-bench": {"sha256": bench_hash},
    },
    "built_at": built_at,
}
with open(temporary, "w", encoding="utf-8") as stream:
    json.dump(manifest, stream, sort_keys=True, indent=2)
    stream.write("\n")
os.replace(temporary, output)
PY

printf '{"ok":true}\n'
