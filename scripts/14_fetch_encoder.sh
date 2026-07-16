#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

usage() {
    cat <<'EOF'
Usage: 14_fetch_encoder.sh [--verify-only]

Fetch the official pinned encoder and tokenizer into vendor/official-encoding,
or verify the existing files without downloading anything.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
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

for command_name in python3 git stat; do
    command -v "$command_name" >/dev/null 2>&1 \
        || die "required command not found: $command_name"
done
if ! "$verify_only"; then
    command -v curl >/dev/null 2>&1 || die 'required command not found: curl'
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" \
    || die 'cannot resolve script directory'
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)" \
    || die 'cannot resolve repository root'
PIN_FILE="$REPO_ROOT/configs/pins/official-encoding.json"
DEST_DIR="$REPO_ROOT/vendor/official-encoding"
[[ -r "$PIN_FILE" ]] || die "pin file is not readable: $PIN_FILE"

pin_data="$(python3 - "$PIN_FILE" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        pins = json.load(stream)
    repo = pins["repo"]
    revision = pins["revision"]
    files = pins["files"]
    if not isinstance(repo, str) or not repo or "\t" in repo or "\n" in repo:
        raise ValueError("invalid repo")
    if not isinstance(revision, str) or len(revision) != 40:
        raise ValueError("invalid revision")
    int(revision, 16)
    if not isinstance(files, list) or not files:
        raise ValueError("files must be a non-empty list")
    print(f"pin\t{repo}\t{revision}")
    for item in files:
        path = item["path"]
        size = item["bytes"]
        oid = item["git_oid_sha1"]
        if (
            not isinstance(path, str)
            or not path
            or path.startswith("/")
            or ".." in path.split("/")
            or "\t" in path
            or "\n" in path
        ):
            raise ValueError(f"invalid file path: {path!r}")
        if not isinstance(size, int) or size < 0:
            raise ValueError(f"invalid byte count for {path}")
        if not isinstance(oid, str) or len(oid) != 40:
            raise ValueError(f"invalid git oid for {path}")
        int(oid, 16)
        print(f"file\t{path}\t{size}\t{oid}")
except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
    print(f"invalid pin file: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
)" || die "failed to parse pin file: $PIN_FILE"

mapfile -t pin_rows <<<"$pin_data"
(( ${#pin_rows[@]} >= 2 )) || die 'pin file contains no file entries'
IFS=$'\t' read -r row_type repo revision <<<"${pin_rows[0]}"
[[ "$row_type" == pin && -n "$repo" && -n "$revision" ]] \
    || die 'invalid pin header'

paths=()
sizes=()
oids=()
for row in "${pin_rows[@]:1}"; do
    IFS=$'\t' read -r row_type path size oid <<<"$row"
    [[ "$row_type" == file && -n "$path" && "$size" =~ ^[0-9]+$ \
       && "$oid" =~ ^[0-9a-f]{40}$ ]] || die 'invalid pin file entry'
    paths+=("$path")
    sizes+=("$size")
    oids+=("$oid")
done

verify_file() {
    local relative=$1 expected_size=$2 expected_oid=$3 file=$4
    local actual_size actual_oid
    [[ -f "$file" && ! -L "$file" ]] || die "file is absent or not regular: $relative"
    actual_size="$(stat -c %s -- "$file")" || die "cannot stat file: $relative"
    if [[ "$actual_size" != "$expected_size" ]]; then
        rm -f -- "$file"
        die "size mismatch (deleted): $relative"
    fi
    actual_oid="$(git hash-object -- "$file")" || die "cannot hash file: $relative"
    if [[ "$actual_oid" != "$expected_oid" ]]; then
        rm -f -- "$file"
        die "git oid mismatch (deleted): $relative"
    fi
}

if ! "$verify_only"; then
    mkdir -p -- "$DEST_DIR" || die "cannot create destination: $DEST_DIR"
fi

for i in "${!paths[@]}"; do
    relative=${paths[$i]}
    final="$DEST_DIR/$relative"
    if [[ -e "$final" || -L "$final" ]]; then
        verify_file "$relative" "${sizes[$i]}" "${oids[$i]}" "$final"
        if ! "$verify_only"; then
            chmod 644 -- "$final" || die "cannot set permissions: $relative"
        fi
        printf 'Verified %s\n' "$relative" >&2
        continue
    fi
    "$verify_only" && die "file is absent: $relative"

    parent=$(dirname -- "$final")
    mkdir -p -- "$parent" || die "cannot create parent directory: $relative"
    partial="$final.partial.$$"
    rm -f -- "$partial"
    url="https://huggingface.co/$repo/resolve/$revision/$relative"
    printf 'Downloading %s\n' "$relative" >&2
    if ! curl -L --fail --retry 5 --retry-delay 2 \
        --output "$partial" -- "$url" >&2; then
        rm -f -- "$partial"
        die "download failed: $relative"
    fi
    verify_file "$relative" "${sizes[$i]}" "${oids[$i]}" "$partial"
    mv -- "$partial" "$final" || die "cannot install file: $relative"
    chmod 644 -- "$final" || die "cannot set permissions: $relative"
done

python3 - "$repo" "$revision" "$verify_only" "${paths[@]}" <<'PY'
import json
import sys

repo, revision, verify_only, *paths = sys.argv[1:]
summary = {
    "status": "verified",
    "mode": "verify-only" if verify_only == "true" else "fetch",
    "repo": repo,
    "revision": revision,
    "destination": "vendor/official-encoding",
    "files": paths,
}
print(json.dumps(summary, separators=(",", ":"), sort_keys=True))
PY
