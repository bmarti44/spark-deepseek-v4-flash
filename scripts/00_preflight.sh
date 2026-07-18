#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

readonly GIB=$((1024 * 1024 * 1024))
# 350 GiB is the SETUP requirement (room to fetch both weight sets + build trees).
# Running an already-loaded engine needs far less free disk (only logs), so
# DSV4_MIN_ROOT_FREE_GIB lets the production unit set a runtime-appropriate floor.
readonly MIN_ROOT_FREE_GIB=${DSV4_MIN_ROOT_FREE_GIB:-350}
# Positive-integer guard: a typo (0, negative, non-numeric) must not silently turn
# the disk floor into an always-pass condition.
# Bound the digit count too: MIN_ROOT_FREE_GIB * GIB (2^30) must not overflow
# signed 64-bit Bash arithmetic into a non-positive floor (always-pass). 6 digits
# (<=999999 GiB) keeps the product ~1e15, far below 2^63.
if ! [[ $MIN_ROOT_FREE_GIB =~ ^[1-9][0-9]{0,5}$ ]]; then
    printf '00_preflight.sh: DSV4_MIN_ROOT_FREE_GIB must be a positive integer, got %q\n' \
        "$MIN_ROOT_FREE_GIB" >&2
    exit 2
fi
readonly MIN_ROOT_FREE_BYTES=$((MIN_ROOT_FREE_GIB * GIB))
readonly MIN_MEM_AVAILABLE_KIB=$((100 * 1024 * 1024))
readonly MAX_SWAP_USED_KIB=$((1024 * 1024))

lock_file="configs/versions.lock"
out_file="-"
checks_file=""

usage() {
    cat <<'EOF'
Usage: scripts/00_preflight.sh [--lock-file PATH] [--out PATH]

Run read-only host safety checks and emit one JSON report. The default lock
file is configs/versions.lock; the default output is stdout.
EOF
}

die() {
    printf '00_preflight.sh: %s\n' "$*" >&2
    exit 2
}

while (($# > 0)); do
    case "$1" in
        --lock-file)
            (($# >= 2)) || die "--lock-file requires a path"
            lock_file=$2
            shift 2
            ;;
        --out)
            (($# >= 2)) || die "--out requires a path"
            out_file=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

command -v python3 >/dev/null 2>&1 || die "python3 is required"
checks_file=$(mktemp "${TMPDIR:-/tmp}/preflight-checks.XXXXXX")
trap 'rm -f "$checks_file"' EXIT

add_check() {
    local name=$1
    local expected=$2
    local actual=$3
    local passed=$4

    python3 -c '
import json, sys
print(json.dumps({
    "name": sys.argv[1],
    "expected": sys.argv[2],
    "actual": sys.argv[3],
    "pass": sys.argv[4] == "true",
}, separators=(",", ":")))
' "$name" "$expected" "$actual" "$passed" >>"$checks_file"
}

lock_value() {
    local key=$1

    if [[ ! -r "$lock_file" ]]; then
        return 1
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
for part in sys.argv[2].split("."):
    value = value[part]
if not isinstance(value, str):
    raise TypeError("lock value is not a string")
print(value)
' "$lock_file" "$key" 2>/dev/null
    elif command -v jq >/dev/null 2>&1; then
        jq -er --arg key "$key" 'getpath($key | split(".")) | strings' "$lock_file"
    else
        return 1
    fi
}

root_free_bytes="unavailable"
root_free_pass=false
if root_free_bytes=$(df -B1 --output=avail / 2>/dev/null | awk 'NR == 2 {print $1}'); then
    if [[ $root_free_bytes =~ ^[0-9]+$ ]] && ((root_free_bytes >= MIN_ROOT_FREE_BYTES)); then
        root_free_pass=true
    fi
else
    root_free_bytes="unavailable"
fi
add_check "root_filesystem_free_space" ">= ${MIN_ROOT_FREE_BYTES} bytes (${MIN_ROOT_FREE_GIB} GiB)" "${root_free_bytes} bytes" "$root_free_pass"

mem_available_kib=$(awk '$1 == "MemAvailable:" {print $2; found=1} END {if (!found) exit 1}' /proc/meminfo 2>/dev/null || true)
mem_available_pass=false
if [[ $mem_available_kib =~ ^[0-9]+$ ]] && ((mem_available_kib >= MIN_MEM_AVAILABLE_KIB)); then
    mem_available_pass=true
fi
add_check "mem_available" ">= ${MIN_MEM_AVAILABLE_KIB} KiB (100 GiB)" "${mem_available_kib:-unavailable} KiB" "$mem_available_pass"

gpu_processes="unavailable"
gpu_processes_pass=false
if gpu_processes=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null); then
    gpu_processes=$(printf '%s\n' "$gpu_processes" | awk 'NF {gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print}' | paste -sd, -)
    if [[ -z $gpu_processes ]]; then
        gpu_processes_pass=true
        gpu_processes="none"
    fi
fi
add_check "gpu_compute_processes" "none" "$gpu_processes" "$gpu_processes_pass"

expected_driver=$(lock_value "host.driver" || true)
actual_driver="unavailable"
driver_pass=false
if actual_driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null); then
    actual_driver=$(printf '%s\n' "$actual_driver" | awk 'NF {gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print}' | paste -sd, -)
fi
if [[ -n $expected_driver && $actual_driver == "$expected_driver" ]]; then
    driver_pass=true
fi
add_check "driver_version" "${expected_driver:-unavailable from lock file}" "$actual_driver" "$driver_pass"

expected_kernel=$(lock_value "host.kernel" || true)
actual_kernel=$(uname -r 2>/dev/null || true)
kernel_pass=false
if [[ -n $expected_kernel && $actual_kernel == "$expected_kernel" ]]; then
    kernel_pass=true
fi
add_check "kernel_version" "${expected_kernel:-unavailable from lock file}" "${actual_kernel:-unavailable}" "$kernel_pass"

ollama_status=$(systemctl is-active ollama.service 2>/dev/null || true)
ollama_status=${ollama_status:-unknown}
ollama_pass=false
if [[ $ollama_status != "active" ]]; then
    ollama_pass=true
fi
add_check "ollama_service" "not active" "$ollama_status" "$ollama_pass"

swap_values=$(awk '
    $1 == "SwapTotal:" {total=$2; have_total=1}
    $1 == "SwapFree:" {free=$2; have_free=1}
    END {
        if (!have_total || !have_free) exit 1
        print total, free
    }
' /proc/meminfo 2>/dev/null || true)
swap_used_kib="unavailable"
swap_pass=false
if read -r swap_total_kib swap_free_kib <<<"$swap_values" &&
        [[ $swap_total_kib =~ ^[0-9]+$ && $swap_free_kib =~ ^[0-9]+$ ]] &&
        ((swap_total_kib >= swap_free_kib)); then
    swap_used_kib=$((swap_total_kib - swap_free_kib))
    if ((swap_used_kib < MAX_SWAP_USED_KIB)); then
        swap_pass=true
    fi
fi
add_check "swap_in_use" "< ${MAX_SWAP_USED_KIB} KiB (1 GiB)" "${swap_used_kib} KiB" "$swap_pass"

timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
report=$(python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    checks = [json.loads(line) for line in handle if line.strip()]
report = {
    "timestamp_utc": sys.argv[2],
    "checks": checks,
    "pass": all(check["pass"] for check in checks),
}
print(json.dumps(report, separators=(",", ":")))
' "$checks_file" "$timestamp_utc")

if [[ $out_file == "-" ]]; then
    printf '%s\n' "$report"
else
    printf '%s\n' "$report" >"$out_file"
fi

if python3 -c 'import json, sys; raise SystemExit(not json.loads(sys.argv[1])["pass"])' "$report"; then
    exit 0
fi
exit 1
