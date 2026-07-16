#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

target_pid=""
threshold_gib="12"
interval_sec="1"
log_file=""
sample_number=0

usage() {
    cat <<'EOF'
Usage: scripts/01_memwatch.sh --target-pid PID --log PATH [OPTIONS]

Watch MemAvailable and kill PID plus its process group if memory falls below
the configured threshold.

Options:
  --target-pid PID       Process to watch (required)
  --threshold-gib N      Breach threshold in GiB (default: 12)
  --interval-sec N       Sampling interval in seconds (default: 1)
  --log PATH             Append-only watchdog log (required)
  -h, --help             Show this help
EOF
}

die() {
    printf '01_memwatch.sh: %s\n' "$*" >&2
    exit 1
}

is_positive_number() {
    awk -v value="$1" 'BEGIN {exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0)}'
}

timestamp_utc() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

mem_available_kib() {
    awk '$1 == "MemAvailable:" {print $2; found=1; exit} END {if (!found) exit 1}' /proc/meminfo
}

target_exists() {
    [[ -d /proc/$target_pid ]]
}

log_sample() {
    local timestamp=$1
    local available_kib=$2
    local available_gib
    available_gib=$(awk -v kib="$available_kib" 'BEGIN {printf "%.2f", kib / 1048576}')
    printf 'ts=%s mem_available_gib=%s\n' "$timestamp" "$available_gib" >>"$log_file"
}

log_breach() {
    local timestamp=$1
    local available_kib=$2
    local available_gib
    available_gib=$(awk -v kib="$available_kib" 'BEGIN {printf "%.2f", kib / 1048576}')
    {
        printf 'ts=%s BREACH mem_available_gib=%s threshold_gib=%s\n' \
            "$timestamp" "$available_gib" "$threshold_gib"
        cat /proc/meminfo
    } >>"$log_file"
}

kill_target_and_group() {
    local pgid
    pgid=$(ps -o pgid= -p "$target_pid" 2>/dev/null | tr -d '[:space:]' || true)

    if [[ $pgid =~ ^[0-9]+$ ]] && ((pgid > 1)); then
        kill -9 -- "-$pgid" 2>/dev/null || true
    fi
    kill -9 -- "$target_pid" 2>/dev/null || true
}

while (($# > 0)); do
    case "$1" in
        --target-pid)
            (($# >= 2)) || die "--target-pid requires a PID"
            target_pid=$2
            shift 2
            ;;
        --threshold-gib)
            (($# >= 2)) || die "--threshold-gib requires a number"
            threshold_gib=$2
            shift 2
            ;;
        --interval-sec)
            (($# >= 2)) || die "--interval-sec requires a number"
            interval_sec=$2
            shift 2
            ;;
        --log)
            (($# >= 2)) || die "--log requires a path"
            log_file=$2
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

[[ $target_pid =~ ^[0-9]+$ ]] && ((target_pid > 1)) || die "--target-pid must be an integer greater than 1"
[[ -n $log_file ]] || die "--log is required"
is_positive_number "$threshold_gib" || die "--threshold-gib must be greater than zero"
is_positive_number "$interval_sec" || die "--interval-sec must be greater than zero"

trap 'exit 0' TERM

# Open the log before monitoring so path and permission errors fail immediately.
: >>"$log_file"

while true; do
    if ! target_exists; then
        exit 0
    fi

    available_kib=$(mem_available_kib) || die "could not read MemAvailable from /proc/meminfo"
    [[ $available_kib =~ ^[0-9]+$ ]] || die "MemAvailable is not numeric"
    sample_number=$((sample_number + 1))
    timestamp=$(timestamp_utc)

    if ((sample_number % 10 == 0)); then
        log_sample "$timestamp" "$available_kib"
    fi

    if awk -v kib="$available_kib" -v threshold="$threshold_gib" \
            'BEGIN {exit !(kib / 1048576 < threshold)}'; then
        log_breach "$timestamp" "$available_kib"
        kill_target_and_group
        exit 2
    fi

    sleep "$interval_sec"
done
