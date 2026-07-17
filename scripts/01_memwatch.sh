#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

target_file=""
ready_file=""
target_pid=""
target_pgid=""
target_start_ticks=""
threshold_gib="12"
interval_sec="1"
log_file=""
sample_number=0
armed=false
expected_exit=false
handling_failure=false

usage() {
    cat <<'EOF'
Usage: scripts/01_memwatch.sh --target-file PATH --ready-file PATH --log PATH [OPTIONS]

Watch MemAvailable immediately, then watch and terminate the engine process
group after its PID and PGID are published to PATH.

Options:
  --target-file PATH     File containing "PID PGID START_TICKS" once engine starts
  --ready-file PATH      Created only after watchdog initialization succeeds
  --threshold-gib N      Breach threshold in GiB (default: 12)
  --interval-sec N       Sampling interval in seconds (default: 1)
  --log PATH             Append-only watchdog log (required)
  -h, --help             Show this help
EOF
}

is_positive_number() {
    awk -v value="$1" 'BEGIN {exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0)}'
}

timestamp_utc() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

safe_log() {
    local message=$1
    if ! printf 'ts=%s %s\n' "$(timestamp_utc 2>/dev/null || printf unknown)" "$message" >>"$log_file"; then
        printf '01_memwatch.sh: log write failure; %s\n' "$message" >&2
        return 1
    fi
}

proc_start_ticks() {
    local stat_line
    local -a stat_fields
    [[ $1 =~ ^[0-9]+$ ]] && [[ -r /proc/$1/stat ]] || return 1
    IFS= read -r stat_line <"/proc/$1/stat" || return 1
    stat_line=${stat_line##*) }
    read -r -a stat_fields <<<"$stat_line"
    (( ${#stat_fields[@]} > 19 )) || return 1
    [[ ${stat_fields[19]} =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${stat_fields[19]}"
}

verify_target_identity() {
    local current_ticks
    current_ticks=$(proc_start_ticks "$target_pid") || current_ticks=
    if [[ -z $current_ticks || $current_ticks != "$target_start_ticks" ]]; then
        printf '01_memwatch.sh: FAIL_CLOSED target identity mismatch; refusing to signal pid=%s expected_start_ticks=%s actual_start_ticks=%s\n' \
            "$target_pid" "$target_start_ticks" "${current_ticks:-unavailable}" >&2
        return 1
    fi
}

# mode "immediate": SIGKILL now — used on memory breach, where every second of
# grace risks a hard UMA freeze. mode "graceful": TERM, 10s, then KILL — used on
# watchdog-internal failures where memory itself is not known to be critical.
terminate_engine_group() {
    local mode=${1:-immediate}
    local seconds
    "$armed" || return 0
    verify_target_identity || return 1
    if [[ $mode == graceful ]]; then
        if [[ $target_pgid =~ ^[0-9]+$ ]] && (( target_pgid > 1 )); then
            kill -TERM -- "-$target_pgid" 2>/dev/null || true
        else
            kill -TERM -- "$target_pid" 2>/dev/null || true
        fi
        for ((seconds=0; seconds < 10; seconds++)); do
            [[ -d /proc/$target_pid ]] || break
            sleep 1
        done
        [[ -d /proc/$target_pid ]] || return 0
    fi
    verify_target_identity || return 1
    if [[ $target_pgid =~ ^[0-9]+$ ]] && (( target_pgid > 1 )); then
        kill -KILL -- "-$target_pgid" 2>/dev/null || true
    fi
    kill -KILL -- "$target_pid" 2>/dev/null || true
}

fail_closed() {
    local reason=${1:-unexpected watchdog exit}
    "$handling_failure" && return 0
    handling_failure=true
    safe_log "FAIL_CLOSED reason=$reason target_pid=${target_pid:-unarmed} target_pgid=${target_pgid:-unarmed} target_start_ticks=${target_start_ticks:-unarmed}" || true
    terminate_engine_group graceful || true
}

on_error() {
    local rc=$?
    trap - ERR
    fail_closed "internal_error exit_status=$rc line=${BASH_LINENO[0]:-unknown}"
    exit "$rc"
}

on_exit() {
    local rc=$?
    trap - EXIT
    if ! "$expected_exit"; then
        fail_closed "unexpected_exit status=$rc"
    fi
}

on_term() {
    expected_exit=true
    safe_log 'STOP requested_by_supervisor' || fail_closed 'log_write_failure_during_stop'
    exit 0
}

trap on_error ERR
trap on_exit EXIT
trap on_term TERM INT HUP

while (($# > 0)); do
    case "$1" in
        --target-file)
            (($# >= 2)) || { printf '%s\n' '01_memwatch.sh: --target-file requires a path' >&2; exit 2; }
            target_file=$2
            shift 2
            ;;
        --ready-file)
            (($# >= 2)) || { printf '%s\n' '01_memwatch.sh: --ready-file requires a path' >&2; exit 2; }
            ready_file=$2
            shift 2
            ;;
        --threshold-gib)
            (($# >= 2)) || { printf '%s\n' '01_memwatch.sh: --threshold-gib requires a number' >&2; exit 2; }
            threshold_gib=$2
            shift 2
            ;;
        --interval-sec)
            (($# >= 2)) || { printf '%s\n' '01_memwatch.sh: --interval-sec requires a number' >&2; exit 2; }
            interval_sec=$2
            shift 2
            ;;
        --log)
            (($# >= 2)) || { printf '%s\n' '01_memwatch.sh: --log requires a path' >&2; exit 2; }
            log_file=$2
            shift 2
            ;;
        -h|--help)
            expected_exit=true
            usage
            exit 0
            ;;
        *)
            printf '01_memwatch.sh: unknown argument: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

[[ -n $target_file ]] || { printf '%s\n' '01_memwatch.sh: --target-file is required' >&2; exit 2; }
[[ -n $ready_file ]] || { printf '%s\n' '01_memwatch.sh: --ready-file is required' >&2; exit 2; }
[[ -n $log_file ]] || { printf '%s\n' '01_memwatch.sh: --log is required' >&2; exit 2; }
is_positive_number "$threshold_gib" || { printf '%s\n' '01_memwatch.sh: --threshold-gib must be greater than zero' >&2; exit 2; }
is_positive_number "$interval_sec" || { printf '%s\n' '01_memwatch.sh: --interval-sec must be greater than zero' >&2; exit 2; }

# Opening the log is itself supervised: failure reaches ERR and fail_closed.
: >>"$log_file"
safe_log "START target_file=$target_file threshold_gib=$threshold_gib"
initial_available_kib=$(awk '$1 == "MemAvailable:" {print $2; found=1; exit} END {if (!found) exit 1}' /proc/meminfo)
[[ $initial_available_kib =~ ^[0-9]+$ ]] || { fail_closed 'invalid_initial_MemAvailable'; exit 1; }
: >"$ready_file"

while true; do
    available_kib=$(awk '$1 == "MemAvailable:" {print $2; found=1; exit} END {if (!found) exit 1}' /proc/meminfo)
    [[ $available_kib =~ ^[0-9]+$ ]] || { fail_closed 'invalid_MemAvailable'; exit 1; }

    if ! "$armed" && [[ -e $target_file ]]; then
        read -r target_pid target_pgid target_start_ticks extra <"$target_file"
        [[ -z ${extra:-} && $target_pid =~ ^[0-9]+$ && $target_pgid =~ ^[0-9]+$ &&
                $target_start_ticks =~ ^[0-9]+$ ]] \
            || { fail_closed 'invalid_target_file'; exit 1; }
        (( target_pid > 1 && target_pgid > 1 && target_start_ticks > 0 )) \
            || { fail_closed 'invalid_target_identity'; exit 1; }
        verify_target_identity || { fail_closed 'target_start_ticks_mismatch_before_arm'; exit 1; }
        armed=true
        safe_log "ARMED target_pid=$target_pid target_pgid=$target_pgid target_start_ticks=$target_start_ticks"
    fi

    sample_number=$((sample_number + 1))
    if (( sample_number % 10 == 0 )); then
        available_gib=$(awk -v kib="$available_kib" 'BEGIN {printf "%.2f", kib / 1048576}')
        safe_log "mem_available_gib=$available_gib"
    fi

    if awk -v kib="$available_kib" -v threshold="$threshold_gib" \
            'BEGIN {exit !(kib / 1048576 < threshold)}'; then
        available_gib=$(awk -v kib="$available_kib" 'BEGIN {printf "%.2f", kib / 1048576}')
        if "$armed"; then
            # Memory breach handling is deliberately independent of all logging.
            # Disable ERR first, SIGKILL the verified engine identity, then make
            # best-effort evidence writes without falling into the graceful path.
            trap - ERR
            if ! terminate_engine_group immediate; then
                expected_exit=true
                exit 1
            fi
            safe_log "BREACH mem_available_gib=$available_gib threshold_gib=$threshold_gib" || true
            cat /proc/meminfo >>"$log_file" 2>/dev/null || \
                printf '%s\n' '01_memwatch.sh: failed to append /proc/meminfo after breach kill' >&2
            expected_exit=true
            exit 2
        fi
        safe_log "BREACH mem_available_gib=$available_gib threshold_gib=$threshold_gib"
        safe_log 'BREACH while_unarmed; continuing_to_watch'
    fi

    if "$armed" && [[ ! -d /proc/$target_pid ]]; then
        safe_log 'TARGET_EXITED normally'
        expected_exit=true
        exit 0
    fi
    sleep "$interval_sec"
done
