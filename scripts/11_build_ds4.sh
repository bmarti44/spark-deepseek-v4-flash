#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

usage() {
    cat <<'EOF'
Usage: 11_build_ds4.sh [--help]

Build the pinned ds4 engine with the official GB10 cuda-spark target, verify
the resulting CUDA architecture and binaries, and write a build manifest.
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
DS4_HOME="${DS4_HOME:-$HOME/ds4-project}"
SRC_DIR="$DS4_HOME/src/ds4"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" \
    || die_env 'cannot resolve script directory'
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)" \
    || die_env 'cannot resolve repository root'
PIN_FILE="$REPO_ROOT/configs/pins/ds4-weights.json"
BUILD_COMMAND='make -C $SRC_DIR -j$(nproc) cuda-spark'

for command_name in python3 git make nproc sha256sum gcc uname; do
    command -v "$command_name" >/dev/null 2>&1 \
        || die_env "required command not found: $command_name"
done
[[ -r "$PIN_FILE" ]] || die_env "pin file is not readable: $PIN_FILE"

engine_commit="$(python3 - "$PIN_FILE" <<'PY'
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        print(json.load(stream)["git_pins"]["engine"]["commit"])
except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
    print(f"invalid pin file: {error}", file=sys.stderr)
    sys.exit(2)
PY
)" || die_env "failed to parse pin file: $PIN_FILE"
[[ "$engine_commit" =~ ^[0-9a-f]{40}$ ]] || die_env 'invalid engine commit pin'

[[ "$(uname -m)" == aarch64 ]] || die_env 'this build requires uname -m to report aarch64'
[[ -d "$SRC_DIR" ]] || die_build "engine source directory is absent: $SRC_DIR"
actual_commit="$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null)" \
    || die_build "cannot read engine HEAD: $SRC_DIR"
[[ "$actual_commit" == "$engine_commit" ]] \
    || die_build "engine HEAD mismatch: expected $engine_commit, got $actual_commit"

export PATH="/usr/local/cuda/bin:$PATH"
command -v nvcc >/dev/null 2>&1 || die_env 'nvcc not found after adding /usr/local/cuda/bin to PATH'
command -v cuobjdump >/dev/null 2>&1 \
    || die_env 'cuobjdump not found after adding /usr/local/cuda/bin to PATH'
nvcc_version="$(nvcc --version)" || die_env 'nvcc --version failed'
[[ "$nvcc_version" =~ release[[:space:]]13\. ]] \
    || die_env 'nvcc release must start with 13.'
gcc_version="$(gcc --version)" || die_env 'gcc --version failed'
gcc_version=${gcc_version%%$'\n'*}

printf 'Building pinned engine with cuda-spark target...\n' >&2
make -C "$SRC_DIR" -j"$(nproc)" cuda-spark >&2 || die_build 'cuda-spark build failed'

# The target also builds ds4-agent and ds4_weight_server; they must NEVER be
# executed in service. Serving uses only ds4-server.
binaries=(ds4 ds4-server ds4-bench)
for binary in "${binaries[@]}"; do
    [[ -f "$SRC_DIR/$binary" && -x "$SRC_DIR/$binary" ]] \
        || die_build "required executable is missing: $SRC_DIR/$binary"
done

set +o pipefail
elf_head="$(cuobjdump --list-elf "$SRC_DIR/ds4-server" 2>/dev/null | head)"
set -o pipefail
[[ "$elf_head" == *sm_121* ]] \
    || die_build 'ds4-server CUDA objects do not report sm_121'
"$SRC_DIR/ds4" --help >/dev/null 2>&1 || die_build 'ds4 --help smoke test failed'

hashes=()
for binary in "${binaries[@]}"; do
    digest="$(sha256sum -- "$SRC_DIR/$binary")" \
        || die_build "cannot hash binary: $binary"
    hashes+=("${digest%% *}")
done

built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || die_env 'cannot obtain current UTC time'
manifest="$DS4_HOME/build-manifest.json"
manifest_tmp="$manifest.partial"
python3 - "$manifest_tmp" "$manifest" "$engine_commit" "$BUILD_COMMAND" \
    "$nvcc_version" "$gcc_version" "$built_at" \
    "${hashes[0]}" "${hashes[1]}" "${hashes[2]}" <<'PY' \
    || die_build 'failed to write build manifest'
import json
import os
import sys

(temporary, output, commit, command, nvcc, gcc, built_at,
 ds4_hash, server_hash, bench_hash) = sys.argv[1:]
manifest = {
    "engine_commit": commit,
    "build_command": command,
    "nvcc_version": nvcc,
    "gcc_version": gcc,
    "binaries": {
        "ds4": {"sha256": ds4_hash},
        "ds4-server": {"sha256": server_hash},
        "ds4-bench": {"sha256": bench_hash},
    },
    "built_at": built_at,
}
with open(temporary, "w", encoding="utf-8") as stream:
    json.dump(manifest, stream, sort_keys=True, indent=2)
    stream.write("\n")
os.replace(temporary, output)
PY

printf '{"ok":true}\n'
