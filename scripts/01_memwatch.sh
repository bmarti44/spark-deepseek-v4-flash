#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

target_file=""
ready_file=""
target_pid=""
target_pgid=""
target_start_ticks=""
target_role=""
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
  --target-file PATH     Armed identity or "DISARM PID PGID START_TICKS"
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
    local identity
    identity=$(proc_identity "$1") || return 1
    printf '%s\n' "${identity#* }"
}

proc_identity() {
    local stat_line
    local -a stat_fields
    [[ $1 =~ ^[0-9]+$ ]] && [[ -r /proc/$1/stat ]] || return 1
    IFS= read -r stat_line <"/proc/$1/stat" || return 1
    stat_line=${stat_line##*) }
    read -r -a stat_fields <<<"$stat_line"
    (( ${#stat_fields[@]} > 19 )) || return 1
    [[ ${stat_fields[2]} =~ ^[0-9]+$ && ${stat_fields[19]} =~ ^[0-9]+$ ]] || return 1
    printf '%s %s\n' "${stat_fields[2]}" "${stat_fields[19]}"
}

refresh_target() {
    local first second third fourth extra previous_identity identity current_pgid current_ticks
    local new_pid new_pgid new_start_ticks new_role
    local previously_armed=$armed
    [[ -e $target_file ]] || return 2
    if ! read -r first second third fourth extra <"$target_file"; then
        return 2
    fi
    if [[ $first == DISARM ]]; then
        [[ -z ${extra:-} && $second =~ ^[0-9]+$ && $third =~ ^[0-9]+$ &&
                $fourth =~ ^[0-9]+$ ]] || return 2
        if ! "$armed" || [[ $second != "$target_pid" || $third != "$target_pgid" ||
                $fourth != "$target_start_ticks" ]]; then
            printf '01_memwatch.sh: FAIL_CLOSED unauthenticated DISARM record expected=%s/%s/%s actual=%s/%s/%s\n' \
                "${target_pid:-unarmed}" "${target_pgid:-unarmed}" \
                "${target_start_ticks:-unarmed}" "$second" "$third" "$fourth" >&2
            return 2
        fi
        safe_log "DISARMED target_pid=$target_pid target_pgid=$target_pgid target_start_ticks=$target_start_ticks target_role=$target_role" \
            || return 2
        printf 'DISARMED %s %s %s\n' "$target_pid" "$target_pgid" \
            "$target_start_ticks" >"$ready_file" || return 2
        armed=false
        expected_exit=true
        exit 0
    fi
    new_pid=$first
    new_pgid=$second
    new_start_ticks=$third
    new_role=$fourth
    # A missing role is accepted as a legacy final-engine target. New publishers
    # always identify provisional versus final targets explicitly.
    [[ -n ${new_role:-} ]] || new_role=engine
    [[ -z ${extra:-} && $new_pid =~ ^[0-9]+$ && $new_pgid =~ ^[0-9]+$ &&
            $new_start_ticks =~ ^[0-9]+$ && $new_role =~ ^(provisional|engine)$ ]] \
        || return 2
    (( new_pid > 1 && new_pgid > 1 && new_start_ticks > 0 )) || return 2
    identity=$(proc_identity "$new_pid") || identity=
    current_pgid=
    current_ticks=
    [[ -z $identity ]] || read -r current_pgid current_ticks <<<"$identity"
    if [[ -z $current_ticks || $current_ticks != "$new_start_ticks" ]]; then
        printf '01_memwatch.sh: FAIL_CLOSED target identity mismatch; refusing to arm pid=%s expected_start_ticks=%s actual_start_ticks=%s\n' \
            "$new_pid" "$new_start_ticks" "${current_ticks:-unavailable}" >&2
        return 2
    fi
    if [[ $current_pgid != "$new_pgid" ]]; then
        printf '01_memwatch.sh: FAIL_CLOSED target process-group mismatch; refusing to arm pid=%s expected_pgid=%s actual_pgid=%s\n' \
            "$new_pid" "$new_pgid" "${current_pgid:-unavailable}" >&2
        return 2
    fi

    previous_identity=${target_pid:-}:${target_pgid:-}:${target_start_ticks:-}:${target_role:-}
    if "$previously_armed" &&
            [[ $previous_identity != "$new_pid:$new_pgid:$new_start_ticks:$new_role" ]] &&
            ! [[ $target_role == provisional && $new_role == engine &&
                $new_pgid == "$target_pgid" ]]; then
        printf '01_memwatch.sh: FAIL_CLOSED armed target record changed without an authorized provisional-to-engine transition\n' >&2
        return 2
    fi

    target_pid=$new_pid
    target_pgid=$new_pgid
    target_start_ticks=$new_start_ticks
    target_role=$new_role
    armed=true
    if ! "$previously_armed" || [[ $previous_identity != "$target_pid:$target_pgid:$target_start_ticks:$target_role" ]]; then
        safe_log "ARMED target_pid=$target_pid target_pgid=$target_pgid target_start_ticks=$target_start_ticks target_role=$target_role" \
            || return 2
        printf 'ARMED %s %s %s %s\n' \
            "$target_pid" "$target_pgid" "$target_start_ticks" "$target_role" >"$ready_file" \
            || return 2
    fi
}

signal_verified_target() {
    local signal=$1 identity current_pgid= current_ticks=
    identity=$(proc_identity "$target_pid") || identity=
    if [[ -n $identity ]]; then
        read -r current_pgid current_ticks <<<"$identity"
    fi
    if [[ -z $current_ticks || $current_ticks != "$target_start_ticks" ]]; then
        printf '01_memwatch.sh: FAIL_CLOSED refusing %s; pid=%s expected_start_ticks=%s actual_start_ticks=%s\n' \
            "$signal" "$target_pid" "$target_start_ticks" \
            "${current_ticks:-unavailable}" >&2
        return 1
    fi
    if [[ $current_pgid != "$target_pgid" ]]; then
        printf '01_memwatch.sh: FAIL_CLOSED %s process-group mismatch; signaling verified pid only pid=%s expected_pgid=%s actual_pgid=%s\n' \
            "$signal" "$target_pid" "$target_pgid" \
            "${current_pgid:-unavailable}" >&2
        kill -"$signal" -- "$target_pid" 2>/dev/null || true
        return 2
    fi
    kill -"$signal" -- "-$target_pgid" 2>/dev/null || true
}

# mode "immediate": SIGKILL now — used on memory breach, where every second of
# grace risks a hard UMA freeze. mode "graceful": TERM, 10s, then KILL — used on
# watchdog-internal failures where memory itself is not known to be critical.
terminate_engine_group() {
    local mode=${1:-immediate}
    local seconds
    local identity_ok=true
    "$armed" || return 0
    if [[ $mode == graceful ]]; then
        signal_verified_target TERM || identity_ok=false
        for ((seconds=0; seconds < 10; seconds++)); do
            [[ -d /proc/$target_pid ]] || break
            sleep 1
        done
        if [[ ! -d /proc/$target_pid ]]; then
            "$identity_ok" && return 0
            return 1
        fi
    fi
    signal_verified_target KILL || identity_ok=false
    "$identity_ok"
}

fail_closed() {
    local reason=${1:-unexpected watchdog exit}
    local mode=${2:-graceful}
    "$handling_failure" && return 0
    handling_failure=true
    safe_log "FAIL_CLOSED reason=$reason target_pid=${target_pid:-unarmed} target_pgid=${target_pgid:-unarmed} target_start_ticks=${target_start_ticks:-unarmed}" || true
    printf '01_memwatch.sh: FAIL_CLOSED reason=%s target_pid=%s target_pgid=%s\n' \
        "$reason" "${target_pid:-unarmed}" "${target_pgid:-unarmed}" >&2
    terminate_engine_group "$mode" || true
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
    local signal=${1:-TERM}
    trap - ERR
    if ! "$armed" && [[ ! -e $target_file ]]; then
        expected_exit=true
        safe_log "STOP unarmed signal=$signal" || \
            printf '01_memwatch.sh: clean unarmed stop; log write failed\n' >&2
        exit 0
    fi
    if ! refresh_target; then
        "$armed" && terminate_engine_group immediate || true
        expected_exit=true
        safe_log "FAIL_CLOSED signal=$signal armed_target_unreadable" || true
        printf '01_memwatch.sh: FAIL_CLOSED %s received with a missing, unreadable, or invalid armed target; exiting nonzero\n' \
            "$signal" >&2
        exit 1
    fi
    if ! terminate_engine_group immediate; then
        expected_exit=true
        safe_log "FAIL_CLOSED signal=$signal emergency_kill_identity_failure target_pid=$target_pid" || true
        printf '01_memwatch.sh: FAIL_CLOSED %s emergency engine-group kill failed identity verification\n' \
            "$signal" >&2
        exit 1
    fi
    safe_log "EMERGENCY_STOP signal=$signal target_pid=$target_pid target_pgid=$target_pgid target_role=$target_role" || true
    printf '01_memwatch.sh: EMERGENCY_STOP %s received while armed; verified engine group SIGKILLed\n' \
        "$signal" >&2
    expected_exit=true
    exit 3
}

trap on_error ERR
trap on_exit EXIT
trap 'on_term TERM' TERM
trap 'on_term INT' INT
trap 'on_term HUP' HUP

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
printf '%s\n' READY >"$ready_file"

while true; do
    available_kib=$(awk '$1 == "MemAvailable:" {print $2; found=1; exit} END {if (!found) exit 1}' /proc/meminfo)
    [[ $available_kib =~ ^[0-9]+$ ]] || { fail_closed 'invalid_MemAvailable'; exit 1; }

    if "$armed"; then
        refresh_target || { fail_closed 'missing_invalid_or_unverifiable_armed_target' immediate; exit 1; }
    elif [[ -e $target_file ]]; then
        refresh_target || { fail_closed 'invalid_or_unverifiable_target_file'; exit 1; }
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
            safe_log "BREACH mem_available_gib=$available_gib threshold_gib=$threshold_gib target_role=$target_role" || true
            cat /proc/meminfo >>"$log_file" 2>/dev/null || \
                printf '%s\n' '01_memwatch.sh: failed to append /proc/meminfo after breach kill' >&2
            expected_exit=true
            exit 2
        fi
        safe_log "BREACH mem_available_gib=$available_gib threshold_gib=$threshold_gib"
        safe_log 'BREACH while_unarmed; continuing_to_watch'
    fi

    if "$armed" && [[ ! -d /proc/$target_pid ]]; then
        safe_log 'FAIL_CLOSED target_exited_without_authenticated_disarm' || true
        printf '01_memwatch.sh: FAIL_CLOSED armed target exited without an authenticated DISARM record\n' >&2
        expected_exit=true
        exit 1
    fi
    sleep "$interval_sec"
done
