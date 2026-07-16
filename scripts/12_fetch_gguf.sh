#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

# All artifact pins (repo, revision, per-shard bytes + sha256) live in ONE
# place — configs/pins/unsloth-ud-q2_k_xl.json — so code never duplicates
# hash values and the secret scanner's checksum exemption stays narrow.
readonly MIN_FREE_BYTES=$((150 * 1024 * 1024 * 1024))
readonly PIN_FILE_REL="configs/pins/unsloth-ud-q2_k_xl.json"

usage() {
    cat <<'EOF'
Usage: scripts/12_fetch_gguf.sh [--verify-only]

Download and verify the pinned Unsloth UD-Q2_K_XL GGUF shards.

Options:
  --verify-only  Verify final files without downloading anything.
  -h, --help     Show this help message.
EOF
}

verify_only=false
while (($# > 0)); do
    case "$1" in
        --verify-only)
            verify_only=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf '12_fetch_gguf.sh: unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

repo_root=$(cd "$(dirname "$0")/.." && pwd)
destination="$repo_root/weights/unsloth-ud-q2_k_xl"
pin_file="$repo_root/$PIN_FILE_REL"

[[ -r $pin_file ]] || { printf '12_fetch_gguf.sh: pin file missing: %s\n' "$pin_file" >&2; exit 2; }

REPO=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["repo"])' "$pin_file")
REVISION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["revision"])' "$pin_file")
readonly REPO REVISION

declare -a FILE_PATHS=() FILE_BYTES=() FILE_SHA256=()
while IFS=$'\t' read -r p b s; do
    FILE_PATHS+=("$p"); FILE_BYTES+=("$b"); FILE_SHA256+=("$s")
done < <(python3 -c '
import json, sys
for f in json.load(open(sys.argv[1]))["files"]:
    print(f"{f[\"path\"]}\t{f[\"bytes\"]}\t{f[\"sha256\"]}")' "$pin_file")
((${#FILE_PATHS[@]} > 0)) || { printf '12_fetch_gguf.sh: pin file lists no files\n' >&2; exit 2; }

files_present=0
bytes_total=0
ok=false
summary_enabled=true

emit_summary() {
    local status=$?
    if [[ $summary_enabled == true ]]; then
        python3 -c '
import json, sys
print(json.dumps({
    "ok": sys.argv[1] == "true",
    "files_present": int(sys.argv[2]),
    "bytes_total": int(sys.argv[3]),
}, separators=(",", ":")))
' "$ok" "$files_present" "$bytes_total"
    fi
    exit "$status"
}
trap emit_summary EXIT

fail() {
    local status=$1
    shift
    printf '12_fetch_gguf.sh: %s\n' "$*" >&2
    exit "$status"
}

command -v python3 >/dev/null 2>&1 || fail 1 "python3 is required"
command -v sha256sum >/dev/null 2>&1 || fail 1 "sha256sum is required"
if [[ $verify_only == false ]]; then
    command -v curl >/dev/null 2>&1 || fail 1 "curl is required"
fi

df_target=$destination
while [[ ! -e $df_target ]]; do
    df_target=$(dirname "$df_target")
done
free_bytes=$(df -B1 --output=avail "$df_target" 2>/dev/null | awk 'NR == 2 {print $1}') ||
    fail 2 "could not determine free space for $destination"
[[ $free_bytes =~ ^[0-9]+$ ]] ||
    fail 2 "could not determine free space for $destination"
if ((free_bytes < MIN_FREE_BYTES)); then
    fail 2 "at least 150 GiB free is required on the destination filesystem (available: $free_bytes bytes)"
fi

if [[ $verify_only == false ]]; then
    mkdir -p "$destination"
fi

verification_failed=false
for i in "${!FILE_PATHS[@]}"; do
    file_path=${FILE_PATHS[$i]}
    name=${file_path##*/}
    expected_bytes=${FILE_BYTES[$i]}
    expected_sha256=${FILE_SHA256[$i]}
    final_file="$destination/$name"
    partial_file="$final_file.partial"

    if [[ -f $final_file ]]; then
        actual_bytes=$(stat -c %s "$final_file")
        if [[ $actual_bytes == "$expected_bytes" ]]; then
            printf '%s: present\n' "$name" >&2
        elif [[ $verify_only == true ]]; then
            printf '%s: size mismatch (expected %s, got %s)\n' \
                "$name" "$expected_bytes" "$actual_bytes" >&2
            rm -f "$final_file"
            verification_failed=true
            continue
        else
            printf '%s: invalid final file removed\n' "$name" >&2
            rm -f "$final_file"
        fi
    fi

    if [[ ! -f $final_file ]]; then
        if [[ $verify_only == true ]]; then
            printf '%s: missing\n' "$name" >&2
            verification_failed=true
            continue
        fi

        url="https://huggingface.co/$REPO/resolve/$REVISION/$file_path"
        printf '%s: downloading\n' "$name" >&2
        if ! curl -L --fail --retry 5 --retry-delay 10 --continue-at - \
            --output "$partial_file" "$url"; then
            fail 1 "download failed for $name"
        fi

        actual_bytes=$(stat -c %s "$partial_file")
        if [[ $actual_bytes != "$expected_bytes" ]]; then
            printf '%s: size mismatch (expected %s, got %s)\n' \
                "$name" "$expected_bytes" "$actual_bytes" >&2
            rm -f "$partial_file"
            fail 1 "verification failed for $name"
        fi

        actual_sha256=$(sha256sum "$partial_file" | awk '{print $1}')
        if [[ $actual_sha256 != "$expected_sha256" ]]; then
            printf '%s: sha256 mismatch\n' "$name" >&2
            rm -f "$partial_file"
            fail 1 "verification failed for $name"
        fi

        mv "$partial_file" "$final_file"
        printf '%s: installed\n' "$name" >&2
    else
        actual_sha256=$(sha256sum "$final_file" | awk '{print $1}')
        if [[ $actual_sha256 != "$expected_sha256" ]]; then
            printf '%s: sha256 mismatch\n' "$name" >&2
            rm -f "$final_file"
            if [[ $verify_only == true ]]; then
                verification_failed=true
                continue
            fi
            fail 1 "verification failed for $name"
        fi
        printf '%s: verified\n' "$name" >&2
    fi

    ((files_present += 1))
    ((bytes_total += expected_bytes))
done

if [[ $verification_failed == true ]]; then
    fail 1 "verification failed: one or more GGUF shards are missing or invalid"
fi

manifest_partial="$destination/manifest.json.partial"
verified_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
python3 - "$pin_file" "$manifest_partial" "$verified_at" <<'PY'
import json
import sys

pin_path, output, verified_at = sys.argv[1:]
with open(pin_path, encoding="utf-8") as handle:
    pins = json.load(handle)
files = [
    {"name": f["path"].rsplit("/", 1)[-1], "bytes": f["bytes"], "sha256": f["sha256"]}
    for f in pins["files"]
]
with open(output, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "repo": pins["repo"],
            "revision": pins["revision"],
            "files": files,
            "verified_at": verified_at,
        },
        handle,
        indent=2,
    )
    handle.write("\n")
PY
mv "$manifest_partial" "$destination/manifest.json"
printf 'manifest.json: written\n' >&2

ok=true
