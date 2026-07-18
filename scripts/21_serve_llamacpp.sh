#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

STACK=llamacpp
PORT=8011
RUNTIME_DIR=/run/dsv4
LOCK_FILE=$RUNTIME_DIR/inference.lock
STATE_FILE=$RUNTIME_DIR/llamacpp.state.json
TARGET_FILE=$RUNTIME_DIR/llamacpp.engine.target
WATCHDOG_READY=$RUNTIME_DIR/llamacpp.memwatch.ready
startup_cleanup_armed=false
memwatch_pid=
memwatch_start_ticks=0
flock_pid=
flock_start_ticks=0
flock_pgid=
server_pid=
server_start_ticks=0
server_pgid=
target_tmp=
start_gate=
target_published=false
published_target_pid=
published_target_pgid=
published_target_start_ticks=
state_published=false

usage() {
    cat <<'EOF'
Usage: 21_serve_llamacpp.sh [start|stop|status] [OPTIONS]

Start (the default), stop, or inspect the loopback-only llama.cpp server.

Options:
  -h, --help  Show this help

Environment:
  LLAMACPP_HOME  Build root (default: $HOME/llamacpp-project)
  MODEL_PATH     First GGUF split shard (default: repository UD-Q2_K_XL shard)
  API_KEY_FILE   Optional API key path (unset/empty disables engine auth)
  CTX            Context length (default: 32768)
  DSV4_VERIFY_WEIGHTS  Verification mode: size or full (default: size)

Every shard is size-checked against the MANIFEST-frozen repository manifest.
Full mode additionally hashes every shard; the selected mode is logged. The
server binary must match the committed build manifest.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

pid_alive() {
    [[ $1 =~ ^[0-9]+$ ]] && (( $1 > 1 )) && kill -0 "$1" 2>/dev/null
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

signal_engine_identity() {
    local signal=$1 pid=$2 expected_pgid=$3 expected_ticks=$4
    local identity current_pgid= current_ticks=
    identity=$(proc_identity "$pid") || identity=
    [[ -z $identity ]] || read -r current_pgid current_ticks <<<"$identity"
    if [[ -z $current_ticks || $current_ticks != "$expected_ticks" ]]; then
        printf 'ERROR: FAIL_CLOSED refusing %s for pid %s (start time mismatch).\n' \
            "$signal" "$pid" >&2
        return 1
    fi
    if [[ $current_pgid != "$expected_pgid" ]]; then
        printf 'ERROR: FAIL_CLOSED %s process-group mismatch for pid %s; signaling verified pid only (expected pgid %s, got %s).\n' \
            "$signal" "$pid" "$expected_pgid" "${current_pgid:-unavailable}" >&2
        kill -"$signal" -- "$pid" 2>/dev/null || true
        return 2
    fi
    kill -"$signal" -- "-$expected_pgid" 2>/dev/null || true
}

signal_verified_pid() {
    local signal=$1 pid=$2 expected_ticks=$3
    [[ $(proc_start_ticks "$pid" 2>/dev/null || true) == "$expected_ticks" ]] || {
        printf 'ERROR: FAIL_CLOSED refusing %s for pid %s (start time mismatch).\n' \
            "$signal" "$pid" >&2
        return 1
    }
    kill -"$signal" -- "$pid" 2>/dev/null || true
}

cleanup_failed_start() {
    local rc=$1 start_group_signaled=false watchdog_disarmed=false identity_ok=true
    "$startup_cleanup_armed" || return "$rc"
    startup_cleanup_armed=false
    trap - ERR EXIT

    # Preserve supervision until the engine/start group is dead. During the
    # gated window flock_pid is the verified provisional group leader; after
    # discovery server_pid verifies the same process group through the engine.
    if [[ ${server_pid:-} =~ ^[0-9]+$ && ${server_pgid:-} =~ ^[0-9]+$ ]] &&
            (( server_pid > 1 && server_pgid > 1 )) &&
            [[ $(proc_start_ticks "$server_pid" 2>/dev/null || true) == "${server_start_ticks:-0}" ]]; then
        signal_engine_identity TERM "$server_pid" "$server_pgid" "$server_start_ticks" \
            || identity_ok=false
        if [[ $(proc_start_ticks "$server_pid" 2>/dev/null || true) == "$server_start_ticks" ]]; then
            signal_engine_identity KILL "$server_pid" "$server_pgid" "$server_start_ticks" \
                || identity_ok=false
        fi
        start_group_signaled=true
    elif [[ ${flock_pid:-} =~ ^[0-9]+$ && ${flock_pgid:-} =~ ^[0-9]+$ ]] &&
            (( flock_pid > 1 && flock_pgid > 1 )) &&
            verify_aux_identity "$flock_pid" "${flock_start_ticks:-0}" \
                "$LOCK_FILE" flock; then
        signal_engine_identity TERM "$flock_pid" "$flock_pgid" "$flock_start_ticks" \
            || identity_ok=false
        if [[ $(proc_start_ticks "$flock_pid" 2>/dev/null || true) == "$flock_start_ticks" ]]; then
            signal_engine_identity KILL "$flock_pid" "$flock_pgid" "$flock_start_ticks" \
                || identity_ok=false
        fi
        start_group_signaled=true
    fi
    if "$start_group_signaled"; then
        wait "$flock_pid" 2>/dev/null || true
    fi

    # The watchdog accepts only an identity-bound DISARM record after the
    # supervised start group is dead. Missing or malformed targets fail closed.
    if "$target_published" && "$identity_ok" \
            && [[ "$(proc_start_ticks "$published_target_pid" 2>/dev/null || true)" != "$published_target_start_ticks" ]]; then
        publish_disarm "$published_target_pid" "$published_target_pgid" \
            "$published_target_start_ticks"
        watchdog_disarmed=true
    fi
    if [[ ${memwatch_pid:-} =~ ^[0-9]+$ ]] && (( memwatch_pid > 1 )) &&
            verify_aux_identity "$memwatch_pid" "${memwatch_start_ticks:-0}" \
                '01_memwatch.sh' memwatch; then
        kill -TERM "$memwatch_pid" 2>/dev/null || true
        wait "$memwatch_pid" 2>/dev/null || true
        if pid_alive "$memwatch_pid" &&
                verify_aux_identity "$memwatch_pid" "$memwatch_start_ticks" \
                    '01_memwatch.sh' memwatch; then
            kill -KILL "$memwatch_pid" 2>/dev/null || true
        fi
    fi

    "$state_published" && rm -f -- "$STATE_FILE"
    "$watchdog_disarmed" && rm -f -- "$WATCHDOG_READY"
    [[ -z ${target_tmp:-} ]] || rm -f -- "$target_tmp"
    [[ -z ${start_gate:-} ]] || rm -f -- "$start_gate"
    return "$rc"
}

on_start_error() {
    local rc=$?
    cleanup_failed_start "$rc"
    exit "$rc"
}

on_start_exit() {
    local rc=$?
    cleanup_failed_start "$rc"
}

mem_available_gib() {
    awk '$1 == "MemAvailable:" {printf "%.6f\n", $2 / 1048576; found=1; exit}
         END {if (!found) exit 1}' /proc/meminfo
}

read_state() {
    local state_output
    state_output=$(python3 - "$STATE_FILE" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        state = json.load(stream)
    for key in ("server_pid", "flock_pid", "memwatch_pid", "port"):
        value = state[key]
        if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
            raise ValueError(f"invalid {key}")
    baseline = state["mem_available_baseline_gib"]
    if not isinstance(baseline, (int, float)) or isinstance(baseline, bool) or baseline < 0:
        raise ValueError("invalid mem_available_baseline_gib")
    start_ticks = state["server_start_ticks"]
    if not isinstance(start_ticks, int) or isinstance(start_ticks, bool) or start_ticks <= 0:
        raise ValueError("invalid server_start_ticks")
    for key in ("flock_start_ticks", "memwatch_start_ticks"):
        value = state.get(key, 0)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise ValueError(f"invalid {key}")
    boot_id = state["boot_id"]
    if not isinstance(boot_id, str) or not boot_id or any(char.isspace() for char in boot_id):
        raise ValueError("invalid boot_id")
    print(state["server_pid"])
    print(state["flock_pid"])
    print(state["memwatch_pid"])
    print(state["port"])
    print(baseline)
    print(start_ticks)
    print(boot_id)
    print(state.get("flock_start_ticks", 0))
    print(state.get("memwatch_start_ticks", 0))
except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
    print(f"invalid state file: {error}", file=sys.stderr)
    sys.exit(1)
PY
    ) || die "cannot read state file: $STATE_FILE"
    mapfile -t STATE_VALUES <<<"$state_output"
    server_pid=${STATE_VALUES[0]}
    flock_pid=${STATE_VALUES[1]}
    memwatch_pid=${STATE_VALUES[2]}
    state_port=${STATE_VALUES[3]}
    baseline_gib=${STATE_VALUES[4]}
    server_start_ticks=${STATE_VALUES[5]}
    state_boot_id=${STATE_VALUES[6]}
    flock_start_ticks=${STATE_VALUES[7]}
    memwatch_start_ticks=${STATE_VALUES[8]}
}

verify_state_identity() {
    local current_ticks current_boot_id reason
    current_ticks=$(proc_start_ticks "$server_pid") || current_ticks=
    current_boot_id=$(< /proc/sys/kernel/random/boot_id) || current_boot_id=
    if [[ -n $current_ticks && $current_ticks == "$server_start_ticks" &&
            -n $current_boot_id && $current_boot_id == "$state_boot_id" ]]; then
        return 0
    fi
    if [[ -z $current_ticks ]]; then
        reason='server_pid is dead'
    elif [[ $current_boot_id != "$state_boot_id" ]]; then
        reason='boot ID mismatch'
    else
        reason='server PID start time mismatch'
    fi
    printf 'ERROR: stale %s state (%s); removing %s without signaling.\n' \
        "$STACK" "$reason" "$STATE_FILE" >&2
    rm -f -- "$STATE_FILE"
    return 1
}

verify_aux_identity() {
    local pid=$1 expected_ticks=$2 signature=$3 label=$4 current_ticks cmdline
    if (( expected_ticks > 0 )); then
        current_ticks=$(proc_start_ticks "$pid") || current_ticks=
        [[ -n $current_ticks && $current_ticks == "$expected_ticks" ]] || {
            printf 'ERROR: unverified %s pid %s (start time mismatch).\n' "$label" "$pid" >&2
            return 1
        }
        return 0
    fi
    [[ -r /proc/$pid/cmdline ]] || return 1
    cmdline=$(tr '\0' ' ' <"/proc/$pid/cmdline") || return 1
    [[ $cmdline == *"$signature"* ]] || {
        printf 'ERROR: unverified legacy %s pid %s (command mismatch).\n' "$label" "$pid" >&2
        return 1
    }
}

verify_watchdog_armed() {
    local marker ready_pid ready_pgid ready_ticks ready_role ready_extra
    local target_pid target_pgid target_ticks target_role target_extra identity
    local current_pgid= current_ticks=
    read -r marker ready_pid ready_pgid ready_ticks ready_role ready_extra \
        <"$WATCHDOG_READY" 2>/dev/null || return 1
    read -r target_pid target_pgid target_ticks target_role target_extra \
        <"$TARGET_FILE" 2>/dev/null || return 1
    [[ $marker == ARMED && -z ${ready_extra:-} && -z ${target_extra:-} &&
        $ready_pid == "$target_pid" && $ready_pgid == "$target_pgid" &&
        $ready_ticks == "$target_ticks" && $ready_role == "$target_role" &&
        $target_pid == "$server_pid" && $target_ticks == "$server_start_ticks" &&
        $target_role == engine ]] || return 1
    identity=$(proc_identity "$target_pid") || return 1
    read -r current_pgid current_ticks <<<"$identity"
    [[ $current_pgid == "$target_pgid" && $current_ticks == "$target_ticks" ]] || return 1
    armed_target_pid=$target_pid
    armed_target_pgid=$target_pgid
    armed_target_start_ticks=$target_ticks
}

write_state() {
    local temporary=$STATE_FILE.tmp.$$
    [[ $(proc_start_ticks "$server_pid" 2>/dev/null || true) == "$server_start_ticks" ]] \
        || die "server pid $server_pid changed identity before state publication"
    state_boot_id=$(< /proc/sys/kernel/random/boot_id) \
        || die 'cannot read kernel boot ID'
    [[ $(proc_start_ticks "$flock_pid" 2>/dev/null || true) == "$flock_start_ticks" ]] \
        || die "flock pid $flock_pid changed identity before state publication"
    [[ $(proc_start_ticks "$memwatch_pid" 2>/dev/null || true) == "$memwatch_start_ticks" ]] \
        || die "memwatch pid $memwatch_pid changed identity before state publication"
    python3 - "$temporary" "$STATE_FILE" "$server_pid" "$flock_pid" \
        "$memwatch_pid" "$PORT" "$started_at" "$baseline_gib" \
        "$server_start_ticks" "$state_boot_id" "$flock_start_ticks" \
        "$memwatch_start_ticks" <<'PY'
import json
import os
import sys

(temporary, output, server, flock, watchdog, port, started, baseline,
 start_ticks, boot_id, flock_ticks, watchdog_ticks) = sys.argv[1:]
state = {
    "server_pid": int(server),
    "flock_pid": int(flock),
    "memwatch_pid": int(watchdog),
    "port": int(port),
    "started_at": started,
    "mem_available_baseline_gib": float(baseline),
    "server_start_ticks": int(start_ticks),
    "flock_start_ticks": int(flock_ticks),
    "memwatch_start_ticks": int(watchdog_ticks),
    "boot_id": boot_id,
}
with open(temporary, "w", encoding="utf-8") as stream:
    json.dump(state, stream, separators=(",", ":"))
    stream.write("\n")
os.replace(temporary, output)
PY
}

terminate_from_state() {
    local seconds current target recovery_ok=true flock_verified=false memwatch_verified=false
    local watchdog_armed=false identity_ok=true
    read_state
    verify_state_identity || return 2
    verify_aux_identity "$flock_pid" "$flock_start_ticks" "$LOCK_FILE" flock && flock_verified=true
    verify_aux_identity "$memwatch_pid" "$memwatch_start_ticks" '01_memwatch.sh' memwatch && memwatch_verified=true
    verify_watchdog_armed && watchdog_armed=true
    if ! "$memwatch_verified" || ! "$watchdog_armed"; then
        printf 'ERROR: watchdog is DEGRADED; stopping only the verified server PID without a process-group signal.\n' >&2
        identity_ok=false
    fi

    if "$memwatch_verified" && "$watchdog_armed"; then
        signal_engine_identity TERM "$server_pid" "$armed_target_pgid" \
            "$server_start_ticks" || identity_ok=false
    else
        signal_verified_pid TERM "$server_pid" "$server_start_ticks" || identity_ok=false
    fi

    for ((seconds=0; seconds < 60; seconds++)); do
        pid_alive "$server_pid" || break
        sleep 1
    done
    if pid_alive "$server_pid"; then
        printf 'Server did not exit after 60 seconds; sending SIGKILL.\n' >&2
        if "$memwatch_verified" && "$watchdog_armed"; then
            signal_engine_identity KILL "$server_pid" "$armed_target_pgid" \
                "$server_start_ticks" || identity_ok=false
        else
            signal_verified_pid KILL "$server_pid" "$server_start_ticks" || identity_ok=false
        fi
    fi
    for ((seconds=0; seconds < 5; seconds++)); do
        pid_alive "$server_pid" || break
        sleep 1
    done
    if pid_alive "$server_pid"; then
        printf 'ERROR: server remains alive after SIGKILL; watchdog stays armed.\n' >&2
        return 1
    fi
    if "$watchdog_armed" && "$identity_ok"; then
        publish_disarm "$armed_target_pid" "$armed_target_pgid" \
            "$armed_target_start_ticks"
    fi
    if "$memwatch_verified" &&
            verify_aux_identity "$memwatch_pid" "$memwatch_start_ticks" \
                '01_memwatch.sh' memwatch; then
        kill -TERM "$memwatch_pid" 2>/dev/null || true
        for ((seconds=0; seconds < 50; seconds++)); do
            pid_alive "$memwatch_pid" || break
            sleep 0.1
        done
        if pid_alive "$memwatch_pid" &&
                verify_aux_identity "$memwatch_pid" "$memwatch_start_ticks" \
                    '01_memwatch.sh' memwatch; then
            kill -KILL "$memwatch_pid" 2>/dev/null || true
        fi
    fi

    target=$(awk -v base="$baseline_gib" 'BEGIN {value=base-5; if (value<0) value=0; printf "%.6f", value}')
    recovery_ok=false
    for ((seconds=0; seconds <= 120; seconds++)); do
        current=$(mem_available_gib) || current=0
        if awk -v current="$current" -v target="$target" 'BEGIN {exit !(current >= target)}'; then
            recovery_ok=true
            printf 'Memory recovered: MemAvailable=%s GiB (target >= %s GiB).\n' "$current" "$target" >&2
            break
        fi
        if (( seconds % 5 == 0 )); then
            printf 'Waiting for memory recovery: MemAvailable=%s GiB, target >= %s GiB (%d/120 s).\n' \
                "$current" "$target" "$seconds" >&2
        fi
        (( seconds == 120 )) || sleep 1
    done
    rm -f -- "$STATE_FILE" "$WATCHDOG_READY"
    "$recovery_ok" || { printf 'ERROR: memory did not recover within 120 seconds.\n' >&2; return 1; }
    "$identity_ok" || return 1
}

do_stop() {
    [[ -e $STATE_FILE ]] || die "$STACK is not running (state file absent)"
    local rc
    if terminate_from_state; then
        rc=0
    else
        rc=$?
    fi
    (( rc != 2 )) || die "$STACK is not running (stale state removed)"
    (( rc == 0 )) || return "$rc"
    printf '{"ok":true,"stack":"%s","stopped":true}\n' "$STACK"
}

do_status() {
    [[ -r $STATE_FILE ]] || { printf 'ERROR: %s is not running (state file absent)\n' "$STACK" >&2; return 1; }
    read_state
    verify_state_identity || { printf 'ERROR: %s is not running (stale state removed)\n' "$STACK" >&2; return 1; }
    local server_alive=false flock_alive=false memwatch_alive=false watchdog_armed=false healthy=false
    pid_alive "$server_pid" && server_alive=true
    pid_alive "$flock_pid" && verify_aux_identity "$flock_pid" "$flock_start_ticks" "$LOCK_FILE" flock \
        && flock_alive=true
    pid_alive "$memwatch_pid" && verify_aux_identity "$memwatch_pid" "$memwatch_start_ticks" '01_memwatch.sh' memwatch \
        && memwatch_alive=true
    "$memwatch_alive" && verify_watchdog_armed && watchdog_armed=true
    if "$server_alive" && curl --silent --show-error --fail --max-time 3 \
            "http://127.0.0.1:$state_port/health" >/dev/null 2>&1; then
        healthy=true
    fi
    "$server_alive" || printf 'ERROR: server_pid is dead\n' >&2
    "$flock_alive" || printf 'ERROR: flock_pid is dead\n' >&2
    "$memwatch_alive" || printf 'ERROR: memwatch_pid is dead\n' >&2
    "$watchdog_armed" || printf 'ERROR: watchdog is DEGRADED (armed identity handshake is invalid)\n' >&2
    "$healthy" || printf 'ERROR: server health check failed\n' >&2
    python3 - "$STATE_FILE" "$server_alive" "$flock_alive" "$memwatch_alive" "$watchdog_armed" "$healthy" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    result = json.load(stream)
for key, value in zip(
    ("server_alive", "flock_alive", "memwatch_alive", "watchdog_armed", "healthy"),
    sys.argv[2:],
):
    result[key] = value == "true"
print(json.dumps(result, separators=(",", ":")))
PY
    "$server_alive" && "$healthy" && "$flock_alive" && "$memwatch_alive" && "$watchdog_armed"
}

shell_quote() {
    local value=${1//\'/\'\\\'\'}
    printf "'%s'" "$value"
}

build_server_command() {
    local item command_text=''
    for item in "$@"; do
        [[ $item != *$'\n'* && $item != *$'\r'* ]] || die 'server command values must not contain newlines'
        command_text+="$(shell_quote "$item") "
    done
    printf '%s' "$command_text"
}

publish_target() {
    local pid=$1 pgid=$2 start_ticks=$3 role=$4
    [[ $pid =~ ^[0-9]+$ && $pgid =~ ^[0-9]+$ && $start_ticks =~ ^[0-9]+$ ]] \
        || die 'cannot publish non-numeric watchdog target identity'
    [[ $role == provisional || $role == engine ]] || die "invalid watchdog target role: $role"
    target_tmp=$TARGET_FILE.tmp.$$
    printf '%s %s %s %s\n' "$pid" "$pgid" "$start_ticks" "$role" >"$target_tmp"
    mv -- "$target_tmp" "$TARGET_FILE"
    target_tmp=
    target_published=true
    published_target_pid=$pid
    published_target_pgid=$pgid
    published_target_start_ticks=$start_ticks
}

publish_disarm() {
    local pid=$1 pgid=$2 start_ticks=$3
    [[ $pid =~ ^[0-9]+$ && $pgid =~ ^[0-9]+$ && $start_ticks =~ ^[0-9]+$ ]] \
        || die 'cannot publish non-numeric watchdog disarm identity'
    target_tmp=$TARGET_FILE.tmp.$$
    printf 'DISARM %s %s %s\n' "$pid" "$pgid" "$start_ticks" >"$target_tmp"
    mv -- "$target_tmp" "$TARGET_FILE"
    target_tmp=
    target_published=false
}

wait_for_watchdog_target() {
    local expected_pid=$1 expected_pgid=$2 expected_ticks=$3 expected_role=$4
    local marker ack_pid ack_pgid ack_ticks ack_role extra attempt
    for ((attempt=0; attempt < 250; attempt++)); do
        if read -r marker ack_pid ack_pgid ack_ticks ack_role extra \
                <"$WATCHDOG_READY" 2>/dev/null &&
                [[ $marker == ARMED && $ack_pid == "$expected_pid" &&
                    $ack_pgid == "$expected_pgid" && $ack_ticks == "$expected_ticks" &&
                    $ack_role == "$expected_role" && -z ${extra:-} ]]; then
            return 0
        fi
        pid_alive "$memwatch_pid" || die 'memory watchdog exited before acknowledging its target'
        sleep 0.02
    done
    die "memory watchdog did not acknowledge $expected_role target before launch"
}

discover_server_pid() {
    local children child attempt rc flock_comm
    for ((attempt=0; attempt < 200; attempt++)); do
        # Until the launcher execs into flock, its only children are the
        # transient gate-wait `sleep` processes; scanning then would race and
        # capture a sleep pid. flock's sole child is the engine command.
        flock_comm=$(cat "/proc/$flock_pid/comm" 2>/dev/null || true)
        if [[ $flock_comm == flock && -r /proc/$flock_pid/task/$flock_pid/children ]]; then
            read -r children < "/proc/$flock_pid/task/$flock_pid/children" || true
            for child in $children; do
                if pid_alive "$child" && proc_start_ticks "$child" >/dev/null 2>&1; then
                    server_pid=$child
                    return 0
                fi
            done
        fi
        if ! pid_alive "$flock_pid"; then
            set +e
            wait "$flock_pid"
            rc=$?
            set -e
            (( rc == 75 )) && die 'another inference server holds the residency lock'
            die "server launcher exited before the server process appeared (exit $rc); see $SERVER_LOG"
        fi
        sleep 0.05
    done
    die "server process did not appear; see $SERVER_LOG"
}

verify_live_artifacts() {
    local selected
    selected=$(printf '%s\n' "${weights[@]}")
    python3 - "$WEIGHTS_MANIFEST" "$BUILD_MANIFEST" "$BINARY" \
        "$verify_weights" "$selected" <<'PY'
import hashlib
import json
import os
import stat
import sys

weights_manifest_path, build_manifest_path, binary_path, verify_mode, selected = sys.argv[1:]
paths = selected.splitlines()
try:
    if os.path.islink(binary_path):
        raise ValueError(f"server binary is a symlink: {binary_path}")
    with open(build_manifest_path, encoding="utf-8") as stream:
        build_manifest = json.load(stream)
    expected = build_manifest["binaries"]["llama-server"]["sha256"]
    if not isinstance(expected, str) or len(expected) != 64:
        raise ValueError("invalid llama-server sha256 in committed build manifest")
    digest = hashlib.sha256()
    with open(binary_path, "rb") as binary:
        for chunk in iter(lambda: binary.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != expected:
        raise ValueError(f"server binary sha256 mismatch: {binary_path}")

    # The llama-server executable is a thin launcher; the actual engine code
    # (incl. the CUDA fatbinary in libggml-cuda.so) lives in the shared libraries
    # loaded from the binary's directory via RUNPATH. Verify every library the
    # build manifest records, so an incremental rebuild of a .so cannot slip
    # unverified code past the unchanged thin binary.
    # Required and non-empty: an absent or {} shared_libraries would silently skip
    # library verification, leaving the CUDA code (where fusion behaviour and
    # memory use live) unchecked behind an unchanged thin binary.
    shared_libraries = build_manifest.get("shared_libraries")
    if not isinstance(shared_libraries, dict) or not shared_libraries:
        raise ValueError(
            "build manifest must record a non-empty shared_libraries map "
            "(the launcher alone does not identify the loaded engine code)"
        )
    if True:
        binary_dir = os.path.dirname(binary_path)
        for lib_name, lib_entry in shared_libraries.items():
            if os.path.basename(lib_name) != lib_name or lib_name in (".", ".."):
                raise ValueError(f"invalid shared library name in manifest: {lib_name!r}")
            lib_expected = lib_entry.get("sha256") if isinstance(lib_entry, dict) else None
            if not isinstance(lib_expected, str) or len(lib_expected) != 64:
                raise ValueError(f"invalid sha256 for shared library {lib_name}")
            lib_path = os.path.join(binary_dir, lib_name)
            if not os.path.exists(lib_path):
                raise ValueError(f"manifest shared library is missing: {lib_path}")
            lib_digest = hashlib.sha256()
            with open(lib_path, "rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    lib_digest.update(chunk)
            if lib_digest.hexdigest() != lib_expected:
                raise ValueError(f"shared library sha256 mismatch: {lib_path}")

    with open(weights_manifest_path, encoding="utf-8") as stream:
        weights_manifest = json.load(stream)
    entries = {item["name"]: item for item in weights_manifest["files"]}
    if set(entries) != {os.path.basename(path) for path in paths}:
        raise ValueError("selected shard names do not exactly match weights manifest")
    for path in paths:
        if os.path.islink(path):
            raise ValueError(f"model shard is a symlink: {path}")
        info = os.stat(path)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError(f"model shard is not a regular file: {path}")
        if info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            raise ValueError(f"model shard is group/other writable: {path}")
        entry = entries[os.path.basename(path)]
        expected_bytes = entry.get("bytes")
        if not isinstance(expected_bytes, int) or isinstance(expected_bytes, bool):
            raise ValueError(f"invalid shard byte size in manifest: {path}")
        if info.st_size != expected_bytes:
            raise ValueError(f"model shard byte-size mismatch: {path}")
        if verify_mode == "full":
            shard_digest = hashlib.sha256()
            with open(path, "rb") as shard:
                for chunk in iter(lambda: shard.read(16 * 1024 * 1024), b""):
                    shard_digest.update(chunk)
            if shard_digest.hexdigest() != entry["sha256"]:
                raise ValueError(f"model shard sha256 mismatch: {path}")
except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
    print(f"live artifact integrity check failed: {error}", file=sys.stderr)
    sys.exit(1)
PY
}

do_start() {
    [[ -n ${HOME:-} ]] || die 'HOME is not set'
    LLAMACPP_HOME=${LLAMACPP_HOME:-$HOME/llamacpp-project}
    CTX=${CTX:-32768}
    [[ $CTX =~ ^[1-9][0-9]*$ ]] || die 'CTX must be a positive integer'
    API_KEY_FILE=${API_KEY_FILE:-}
    verify_weights=${DSV4_VERIFY_WEIGHTS:-size}
    [[ $verify_weights == size || $verify_weights == full ]] \
        || die 'DSV4_VERIFY_WEIGHTS must be size or full'

    SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || die 'cannot resolve script directory'
    REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P) || die 'cannot resolve repository root'
    MODEL_PATH=${MODEL_PATH:-$REPO_ROOT/weights/unsloth-ud-q2_k_xl/DeepSeek-V4-Flash-UD-Q2_K_XL-00001-of-00003.gguf}
    MEMBUDGET=$REPO_ROOT/scripts/02_membudget.py
    MEMWATCH=$REPO_ROOT/scripts/01_memwatch.sh
    # DSV4_SERVER_BINARY / DSV4_BUILD_MANIFEST let a benchmark run point the
    # watchdog-protected server at an alternate build (e.g. a candidate rebuild)
    # with its own committed manifest. Defaults preserve production exactly.
    BINARY=${DSV4_SERVER_BINARY:-$LLAMACPP_HOME/src/llama.cpp/build/bin/llama-server}
    BUILD_MANIFEST=${DSV4_BUILD_MANIFEST:-$REPO_ROOT/configs/build-manifests/llamacpp.json}
    WEIGHTS_MANIFEST=$REPO_ROOT/weights/unsloth-ud-q2_k_xl/manifest.json
    LOG_DIR=$HOME/logs
    SERVER_LOG=$LOG_DIR/llamacpp-server.log
    MEMWATCH_LOG=$LOG_DIR/memwatch-llamacpp.log

    for command_name in python3 flock setsid curl awk ps tr date mkdir; do need_command "$command_name"; done
    [[ -x $BINARY ]] || die "llama-server is missing or not executable: $BINARY"
    [[ -r $BUILD_MANIFEST ]] || die "committed build manifest is missing or unreadable: $BUILD_MANIFEST"
    [[ -r $WEIGHTS_MANIFEST ]] || die "weights manifest is missing or unreadable: $WEIGHTS_MANIFEST"
    [[ -r $MEMBUDGET && -r $MEMWATCH ]] || die 'memory safety scripts are missing or unreadable'
    if [[ -n $API_KEY_FILE ]]; then
        [[ -f $API_KEY_FILE && -r $API_KEY_FILE ]] \
            || die "API key file is missing or unreadable: $API_KEY_FILE"
    else
        printf 'loopback-unauthenticated; must be fronted by the auth proxy\n' >&2
    fi
    mkdir -p -- "$RUNTIME_DIR" "$LOG_DIR" || die 'cannot create runtime or log directory'
    chmod 700 -- "$RUNTIME_DIR" "$LOG_DIR" || die 'cannot secure runtime or log directory'

    if [[ -e $STATE_FILE ]]; then
        read_state
        verify_state_identity && die "$STACK is already running with pid $server_pid"
    fi

    if [[ $MODEL_PATH =~ ^(.*)-00001-of-00003\.gguf$ ]]; then
        local shard_prefix=${BASH_REMATCH[1]}
        weights=(
            "$shard_prefix-00001-of-00003.gguf"
            "$shard_prefix-00002-of-00003.gguf"
            "$shard_prefix-00003-of-00003.gguf"
        )
    else
        die 'MODEL_PATH must name the first shard with suffix -00001-of-00003.gguf'
    fi
    if [[ $verify_weights == full ]]; then
        printf 'Weight verification mode: full SHA-256 against repository manifest.\n' >&2
    else
        printf 'Weight verification mode: size-only against repository manifest (set DSV4_VERIFY_WEIGHTS=full for SHA-256).\n' >&2
    fi
    verify_live_artifacts

    local help_output
    help_output=$("$BINARY" --help 2>&1) || die 'llama-server --help failed'
    grep -F -- '--cache-ram' <<<"$help_output" >/dev/null \
        || die 'llama-server lacks required --cache-ram support; RAM prompt cache cannot be disabled'

    local budget rc
    set +e
    # overhead-gib 6: llama.cpp non-weight footprint for this config (compute
    # buffers at b=2048/ub=512, CUDA context, KV pool) measures 3-5 GiB; 6 keeps
    # slack without double-counting against the hard 16 GiB floor.
    # DSV4_MEM_FLOOR_GIB lets a benchmark run relax the projected-free floor
    # (still well above the 12 GiB watchdog kill line); defaults to 16.
    mem_floor_gib=${DSV4_MEM_FLOOR_GIB:-16}
    budget=$(python3 "$MEMBUDGET" --weights "${weights[@]}" --ctx "$CTX" \
        --kv-bytes-per-token 4096 --overhead-gib 6 --floor-gib "$mem_floor_gib" 2>&1)
    rc=$?
    set -e
    if (( rc != 0 )); then
        printf '%s\n' "$budget" >&2
        die 'memory budget gate failed'
    fi
    baseline_gib=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["mem_available_now_gib"])' <<<"$budget") \
        || die 'memory budget gate returned invalid JSON'

    local -a server_command
    # DSV4_BATCH / DSV4_UBATCH size the prefill compute buffers, which dominate
    # the CUDA graph-capture memory peak at startup. Lowering -ub is the main
    # lever to keep that peak under the UMA limit on this tight host; it costs a
    # little prefill throughput and does NOT affect decode. Defaults = originals.
    batch=${DSV4_BATCH:-2048}
    ubatch=${DSV4_UBATCH:-512}
    # Digit-bounded (<=5 digits) so a huge decimal cannot wrap fixed-width Bash
    # arithmetic (a value congruent to 1 mod 2^64 would otherwise pass every
    # comparison as 1 while the original string reaches llama-server).
    [[ $batch =~ ^[1-9][0-9]{0,4}$ && $ubatch =~ ^[1-9][0-9]{0,4}$ ]] \
        || die 'DSV4_BATCH/DSV4_UBATCH must be positive integers of at most 5 digits'
    # Upper bound: the prompt-processing graph scales with -ub, and the memory
    # budget gate does not (fixed overhead), so an oversized -ub could reserve a
    # huge graph and OOM at load. Cap at the frozen defaults; -ub must not exceed
    # -b, and -b must not exceed the context.
    (( ubatch <= batch )) || die "DSV4_UBATCH ($ubatch) must not exceed DSV4_BATCH ($batch)"
    (( batch <= CTX )) || die "DSV4_BATCH ($batch) must not exceed CTX ($CTX)"
    (( batch <= 2048 && ubatch <= 512 )) \
        || die "DSV4_BATCH/DSV4_UBATCH must not exceed the frozen memory-budgeted maxima 2048/512"
    server_command=("$BINARY" --model "$MODEL_PATH")
    [[ -z $API_KEY_FILE ]] || server_command+=(--api-key-file "$API_KEY_FILE")
    server_command+=(--host 127.0.0.1 --port "$PORT" -c "$CTX" -np 1 -ngl 999
        -b "$batch" -ub "$ubatch" --no-warmup --cache-ram 0)
    # Keep the default fp16 K/V cache: upstream quantized-K bugs make -ctk/-ctv
    # inappropriate for this production baseline.

    local command_text
    command_text=$(build_server_command "${server_command[@]}")
    printf '\n===== llama.cpp session start %s ctx=%s =====\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CTX" >>"$SERVER_LOG"
    rm -f -- "$TARGET_FILE" "$WATCHDOG_READY"
    startup_cleanup_armed=true
    trap on_start_error ERR
    trap on_start_exit EXIT
    setsid bash "$MEMWATCH" --target-file "$TARGET_FILE" --ready-file "$WATCHDOG_READY" --threshold-gib 12 \
        --interval-sec 1 --log "$MEMWATCH_LOG" >/dev/null 2>&1 &
    memwatch_pid=$!
    memwatch_start_ticks=$(proc_start_ticks "$memwatch_pid") \
        || die "cannot read start time for memwatch pid $memwatch_pid"
    for ((watchdog_wait=0; watchdog_wait < 100; watchdog_wait++)); do
        [[ -e $WATCHDOG_READY ]] && break
        pid_alive "$memwatch_pid" || die 'memory watchdog failed during initialization'
        sleep 0.05
    done
    [[ -e $WATCHDOG_READY ]] || { signal_verified_pid TERM "$memwatch_pid" "$memwatch_start_ticks" || true; die 'memory watchdog initialization timed out'; }

    # The dedicated start group is gated so the watchdog target is published
    # before the engine can exec. The launcher becomes flock without changing
    # PID/start-ticks, and the engine remains in this process group.
    start_gate=$RUNTIME_DIR/$STACK.start.gate.$$
    rm -f -- "$start_gate"
    setsid bash -Eeuo pipefail -c '
        gate=$1
        lock_file=$2
        command_text=$3
        while [[ ! -e $gate ]]; do sleep 0.02; done
        exec flock -n -E 75 "$lock_file" -c "$command_text"
    ' dsv4-start-group "$start_gate" "$LOCK_FILE" "$command_text" >>"$SERVER_LOG" 2>&1 &
    flock_pid=$!
    flock_start_ticks=$(proc_start_ticks "$flock_pid") \
        || die "cannot read start time for flock pid $flock_pid"
    flock_pgid=$(ps -o pgid= -p "$flock_pid" | tr -d '[:space:]') \
        || die "cannot determine provisional process group for pid $flock_pid"
    [[ $flock_pgid =~ ^[0-9]+$ ]] && (( flock_pgid > 1 )) \
        || die "invalid provisional process group: $flock_pgid"
    publish_target "$flock_pid" "$flock_pgid" "$flock_start_ticks" provisional
    wait_for_watchdog_target "$flock_pid" "$flock_pgid" "$flock_start_ticks" provisional
    : >"$start_gate"
    discover_server_pid
    server_start_ticks=$(proc_start_ticks "$server_pid") \
        || die "cannot read start time for server pid $server_pid"
    server_pgid=$(ps -o pgid= -p "$server_pid" | tr -d '[:space:]') \
        || die "cannot determine server process group for pid $server_pid"
    [[ $server_pgid =~ ^[0-9]+$ ]] && (( server_pgid > 1 )) \
        || die "invalid server process group: $server_pgid"
    [[ $server_pgid == "$flock_pgid" ]] \
        || die "engine escaped provisional process group: expected $flock_pgid, got $server_pgid"
    publish_target "$server_pid" "$server_pgid" "$server_start_ticks" engine
    rm -f -- "$start_gate"
    start_gate=
    started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    state_published=true
    write_state || die 'failed to write state file'

    local deadline
    deadline=$((SECONDS + 600))
    while (( SECONDS < deadline )); do
        if ! pid_alive "$server_pid"; then
            die "llama.cpp server exited during startup; see $SERVER_LOG"
        fi
        if curl --silent --show-error --fail --max-time 3 \
                "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
            printf '{"ok":true,"stack":"llamacpp","pid":%d,"port":%d}\n' "$server_pid" "$PORT"
            startup_cleanup_armed=false
            trap - ERR EXIT
            return 0
        fi
        if (( SECONDS < deadline )); then
            sleep 2
        fi
    done
    die 'llama.cpp readiness timed out after 600 seconds'
}

action=start
action_seen=false
while (( $# > 0 )); do
    case $1 in
        start|stop|status)
            "$action_seen" && { usage >&2; exit 2; }
            action=$1
            action_seen=true
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

case $action in
    start) do_start ;;
    stop)
        need_command python3; need_command ps; need_command awk; need_command tr
        do_stop
        ;;
    status)
        need_command python3; need_command curl
        do_status
        ;;
esac
