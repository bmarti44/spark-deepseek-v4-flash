#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

usage() {
    cat <<'EOF'
Usage: 10_fetch_ds4.sh [--verify-only]

Fetch the pinned ds4 engine source and model weights, or verify the existing
engine and weights without downloading anything.
EOF
}

die_verify() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

die_env() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}

verify_only=false
if (( $# > 1 )); then
    usage >&2
    exit 2
fi
case "${1:-}" in
    '') ;;
    --verify-only) verify_only=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

[[ -n "${HOME:-}" ]] || die_env 'HOME is not set'
DS4_HOME="${DS4_HOME:-$HOME/ds4-project}"
SRC_DIR="$DS4_HOME/src/ds4"
GGUF_DIR="$DS4_HOME/gguf"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" \
    || die_env 'cannot resolve script directory'
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)" \
    || die_env 'cannot resolve repository root'
PIN_FILE="$REPO_ROOT/configs/pins/ds4-weights.json"

for command_name in python3 git sha256sum stat; do
    command -v "$command_name" >/dev/null 2>&1 \
        || die_env "required command not found: $command_name"
done
[[ -r "$PIN_FILE" ]] || die_env "pin file is not readable: $PIN_FILE"

mapfile -t pin_rows < <(python3 - "$PIN_FILE" <<'PY'
import json
import os
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        pins = json.load(stream)
    engine = pins["git_pins"]["engine"]
    print("engine\t{}\t{}".format(engine["repo"], engine["commit"]))
    sources = pins["sources"]
    for item in pins["files"]:
        revision = sources[item["repo"]]["revision"]
        values = (
            item["role"], item["repo"], revision, item["path"],
            str(item["bytes"]), item["sha256"], os.path.basename(item["path"]),
        )
        if any("\t" in value or "\n" in value for value in values):
            raise ValueError("tabs and newlines are not allowed in pin values")
        print("file\t" + "\t".join(values))
except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
    print(f"invalid pin file: {error}", file=sys.stderr)
    sys.exit(2)
PY
) || die_env "failed to parse pin file: $PIN_FILE"

(( ${#pin_rows[@]} >= 2 )) || die_env 'pin file has no engine or weight entries'
IFS=$'\t' read -r row_type engine_repo engine_commit <<<"${pin_rows[0]}"
[[ "$row_type" == engine && "$engine_commit" =~ ^[0-9a-f]{40}$ ]] \
    || die_env 'invalid engine pin'

roles=()
repos=()
revisions=()
paths=()
sizes=()
digests=()
basenames=()
for row in "${pin_rows[@]:1}"; do
    IFS=$'\t' read -r row_type role repo revision path bytes sha256 filename <<<"$row"
    [[ "$row_type" == file && -n "$role" && -n "$repo" && -n "$path" ]] \
        || die_env 'invalid weight entry in pin file'
    [[ "$revision" =~ ^[0-9a-f]{40}$ && "$bytes" =~ ^[0-9]+$ \
       && "$sha256" =~ ^[0-9a-f]{64}$ && -n "$filename" ]] \
        || die_env "invalid pins for weight: ${filename:-unknown}"
    roles+=("$role")
    repos+=("$repo")
    revisions+=("$revision")
    paths+=("$path")
    sizes+=("$bytes")
    digests+=("$sha256")
    basenames+=("$filename")
done

verify_engine() {
    [[ -d "$SRC_DIR" ]] || die_verify "engine source directory is absent: $SRC_DIR"
    local actual
    actual="$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null)" \
        || die_verify "cannot read engine HEAD: $SRC_DIR"
    [[ "$actual" == "$engine_commit" ]] \
        || die_verify "engine HEAD mismatch: expected $engine_commit, got $actual"
}

verify_weight() {
    local file=$1 expected_size=$2 expected_sha=$3 actual_size actual_sha
    [[ -f "$file" ]] || die_verify "weight file is absent: $file"
    actual_size="$(stat -c %s -- "$file")" \
        || die_verify "cannot read size of weight file: $file"
    if [[ "$actual_size" != "$expected_size" ]]; then
        rm -f -- "$file"
        die_verify "weight size mismatch (deleted): $file"
    fi
    actual_sha="$(sha256sum -- "$file")" \
        || die_verify "cannot hash weight file: $file"
    actual_sha=${actual_sha%% *}
    if [[ "$actual_sha" != "$expected_sha" ]]; then
        rm -f -- "$file"
        die_verify "weight sha256 mismatch (deleted): $file"
    fi
}

if "$verify_only"; then
    printf 'Verifying pinned engine HEAD...\n' >&2
    verify_engine
    for i in "${!basenames[@]}"; do
        printf 'Verifying weight %s...\n' "${basenames[$i]}" >&2
        verify_weight "$GGUF_DIR/${basenames[$i]}" "${sizes[$i]}" "${digests[$i]}"
    done
else
    mkdir -p -- "$DS4_HOME/src" "$GGUF_DIR" \
        || die_env "cannot create directories under $DS4_HOME"
    if [[ ! -e "$SRC_DIR" ]]; then
        printf 'Cloning pinned engine repository...\n' >&2
        git clone -- "$engine_repo" "$SRC_DIR" >&2 \
            || die_verify 'engine clone failed'
    fi
    printf 'Fetching engine origin...\n' >&2
    git -C "$SRC_DIR" fetch origin >&2 || die_verify 'engine fetch failed'
    git -C "$SRC_DIR" checkout --detach "$engine_commit" >&2 \
        || die_verify "engine checkout failed: $engine_commit"
    verify_engine

    downloads_needed=false
    for i in "${!basenames[@]}"; do
        final="$GGUF_DIR/${basenames[$i]}"
        if [[ -e "$final" ]]; then
            [[ -f "$final" ]] || die_verify "weight path is not a regular file: $final"
            actual_size="$(stat -c %s -- "$final")" \
                || die_verify "cannot read size of weight file: $final"
            if [[ "$actual_size" != "${sizes[$i]}" ]]; then
                rm -f -- "$final"
                die_verify "weight size mismatch (deleted): $final"
            fi
            printf 'Weight already present with pinned size: %s\n' "${basenames[$i]}" >&2
        else
            downloads_needed=true
        fi
    done

    if "$downloads_needed"; then
        free_bytes="$(python3 - "$GGUF_DIR" <<'PY'
import shutil
import sys
print(shutil.disk_usage(sys.argv[1]).free)
PY
)" || die_env "cannot determine free space for $GGUF_DIR"
        minimum_bytes=$((120 * 1024 * 1024 * 1024))
        (( free_bytes >= minimum_bytes )) \
            || die_env "less than 120 GiB free on the $GGUF_DIR filesystem"
    fi

    command -v curl >/dev/null 2>&1 || die_env 'required command not found: curl'
    for i in "${!basenames[@]}"; do
        final="$GGUF_DIR/${basenames[$i]}"
        [[ -e "$final" ]] && continue
        partial="$final.partial"
        url="https://huggingface.co/${repos[$i]}/resolve/${revisions[$i]}/${paths[$i]}"
        printf 'Downloading weight %s...\n' "${basenames[$i]}" >&2
        curl -L --fail --retry 5 --retry-delay 10 --continue-at - \
            --output "$partial" -- "$url" >&2 \
            || die_verify "download failed: ${basenames[$i]}"
        actual_size="$(stat -c %s -- "$partial")" \
            || die_verify "cannot read downloaded weight: ${basenames[$i]}"
        actual_sha="$(sha256sum -- "$partial")" \
            || die_verify "cannot hash downloaded weight: ${basenames[$i]}"
        actual_sha=${actual_sha%% *}
        if [[ "$actual_size" != "${sizes[$i]}" || "$actual_sha" != "${digests[$i]}" ]]; then
            rm -f -- "$partial"
            die_verify "downloaded weight mismatch (deleted): ${basenames[$i]}"
        fi
        mv -- "$partial" "$final" || die_verify "cannot install weight: ${basenames[$i]}"
        chmod 444 -- "$final" || die_verify "cannot make weight read-only: ${basenames[$i]}"
    done
fi

verified_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    || die_env 'cannot obtain current UTC time'
manifest_tmp="$GGUF_DIR/manifest.json.partial"
python3 - "$PIN_FILE" "$manifest_tmp" "$engine_commit" "$verified_at" <<'PY' \
    || die_verify 'failed to write weight manifest'
import json
import os
import sys

pin_file, output, engine_commit, verified_at = sys.argv[1:]
with open(pin_file, encoding="utf-8") as stream:
    pins = json.load(stream)
manifest = {
    "repos": {name: data["revision"] for name, data in pins["sources"].items()},
    "revisions": {name: data["revision"] for name, data in pins["sources"].items()},
    "files": [
        {
            "role": item["role"],
            "repo": item["repo"],
            "path": item["path"],
            "bytes": item["bytes"],
            "sha256": item["sha256"],
        }
        for item in pins["files"]
    ],
    "engine_commit": engine_commit,
    "verified_at": verified_at,
}
with open(output, "w", encoding="utf-8") as stream:
    json.dump(manifest, stream, sort_keys=True, indent=2)
    stream.write("\n")
os.replace(output, os.path.join(os.path.dirname(output), "manifest.json"))
PY

printf '{"ok":true,"engine_commit":"%s","files_present":%d}\n' \
    "$engine_commit" "${#basenames[@]}"
