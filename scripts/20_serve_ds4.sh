#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

STACK=ds4
PORT=8012
RUNTIME_DIR=/run/dsv4
LOCK_FILE=$RUNTIME_DIR/inference.lock
STATE_FILE=$RUNTIME_DIR/ds4.state.json
TARGET_FILE=$RUNTIME_DIR/ds4.engine.target
WATCHDOG_READY=$RUNTIME_DIR/ds4.memwatch.ready
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
state_published=false

usage() {
    cat <<'EOF'
Usage: 20_serve_ds4.sh [start|stop|status] [OPTIONS]

Start (the default), stop, or inspect the loopback-only ds4 server.

Options:
  --profile dspark|mtp|plain  Serving profile (default: dspark)
  --full-verify              Also SHA-256 hash selected GGUFs before launch
  -h, --help                 Show this help

GGUF byte sizes from manifest.json are always checked. --full-verify also
hashes the selected files; hashing roughly 85 GB can take several minutes.

Environment: DS4_HOME (default: $HOME/ds4-project), CTX (default: 32768).
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

cleanup_failed_start() {
    local rc=$1 start_group_signaled=false
    "$startup_cleanup_armed" || return "$rc"
    startup_cleanup_armed=false
    trap - ERR EXIT

    # Preserve supervision until the engine/start group is dead. During the
    # gated window flock_pid is the verified provisional group leader; after
    # discovery server_pid verifies the same process group through the engine.
    if [[ ${server_pid:-} =~ ^[0-9]+$ && ${server_pgid:-} =~ ^[0-9]+$ ]] &&
            (( server_pid > 1 && server_pgid > 1 )) &&
            [[ $(proc_start_ticks "$server_pid" 2>/dev/null || true) == "${server_start_ticks:-0}" ]]; then
        kill -TERM -- "-$server_pgid" 2>/dev/null || true
        kill -KILL -- "-$server_pgid" 2>/dev/null || true
        start_group_signaled=true
    elif [[ ${flock_pid:-} =~ ^[0-9]+$ && ${flock_pgid:-} =~ ^[0-9]+$ ]] &&
            (( flock_pid > 1 && flock_pgid > 1 )) &&
            verify_aux_identity "$flock_pid" "${flock_start_ticks:-0}" \
                "$LOCK_FILE" flock; then
        kill -TERM -- "-$flock_pgid" 2>/dev/null || true
        kill -KILL -- "-$flock_pgid" 2>/dev/null || true
        start_group_signaled=true
    fi
    if "$start_group_signaled"; then
        wait "$flock_pid" 2>/dev/null || true
    fi

    # Explicit disarm handshake: engine first, retract target, then TERM the
    # watchdog. TERM while the target still exists is an emergency SIGKILL path.
    "$target_published" && rm -f -- "$TARGET_FILE"
    target_published=false
    if [[ ${memwatch_pid:-} =~ ^[0-9]+$ ]] && (( memwatch_pid > 1 )) &&
            verify_aux_identity "$memwatch_pid" "${memwatch_start_ticks:-0}" \
                '01_memwatch.sh' memwatch; then
        kill -TERM "$memwatch_pid" 2>/dev/null || true
        wait "$memwatch_pid" 2>/dev/null || true
        kill -KILL "$memwatch_pid" 2>/dev/null || true
    fi

    "$state_published" && rm -f -- "$STATE_FILE"
    rm -f -- "$WATCHDOG_READY"
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
    local pgid seconds current target recovery_ok=true flock_verified=false memwatch_verified=false
    read_state
    verify_state_identity || return 2
    verify_aux_identity "$flock_pid" "$flock_start_ticks" "$LOCK_FILE" flock && flock_verified=true
    verify_aux_identity "$memwatch_pid" "$memwatch_start_ticks" '01_memwatch.sh' memwatch && memwatch_verified=true

    pgid=$(ps -o pgid= -p "$server_pid" 2>/dev/null | tr -d '[:space:]' || true)
    if "$flock_verified" && [[ $pgid =~ ^[0-9]+$ ]] && (( pgid > 1 )); then
        kill -TERM -- "-$pgid" 2>/dev/null || true
    else
        kill -TERM "$server_pid" 2>/dev/null || true
    fi

    for ((seconds=0; seconds < 60; seconds++)); do
        pid_alive "$server_pid" || break
        sleep 1
    done
    if pid_alive "$server_pid"; then
        printf 'Server did not exit after 60 seconds; sending SIGKILL.\n' >&2
        if "$flock_verified" && [[ $pgid =~ ^[0-9]+$ ]] && (( pgid > 1 )); then
            kill -KILL -- "-$pgid" 2>/dev/null || true
        else
            kill -KILL "$server_pid" 2>/dev/null || true
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
    rm -f -- "$TARGET_FILE"
    if "$memwatch_verified"; then
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
    local server_alive=false flock_alive=false memwatch_alive=false healthy=false
    pid_alive "$server_pid" && server_alive=true
    pid_alive "$flock_pid" && verify_aux_identity "$flock_pid" "$flock_start_ticks" "$LOCK_FILE" flock \
        && flock_alive=true
    pid_alive "$memwatch_pid" && verify_aux_identity "$memwatch_pid" "$memwatch_start_ticks" '01_memwatch.sh' memwatch \
        && memwatch_alive=true
    if "$server_alive" && curl --silent --show-error --fail --max-time 3 \
            "http://127.0.0.1:$state_port/v1/models" >/dev/null 2>&1; then
        local stats
        stats=$(curl --silent --show-error --fail --max-time 3 \
            "http://127.0.0.1:$state_port/v1/stats" 2>/dev/null || true)
        grep -Eq 'artifact_source[^a-zA-Z]*(built|imported)' <<<"$stats" && healthy=true
    fi
    "$server_alive" || printf 'ERROR: server_pid is dead\n' >&2
    "$flock_alive" || printf 'ERROR: flock_pid is dead\n' >&2
    "$memwatch_alive" || printf 'ERROR: memwatch_pid is dead\n' >&2
    "$healthy" || printf 'ERROR: server health check failed\n' >&2
    python3 - "$STATE_FILE" "$server_alive" "$flock_alive" "$memwatch_alive" "$healthy" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    result = json.load(stream)
for key, value in zip(("server_alive", "flock_alive", "memwatch_alive", "healthy"), sys.argv[2:]):
    result[key] = value == "true"
print(json.dumps(result, separators=(",", ":")))
PY
    "$server_alive" && "$healthy" && "$flock_alive" && "$memwatch_alive"
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
    local children child attempt rc
    for ((attempt=0; attempt < 100; attempt++)); do
        if [[ -r /proc/$flock_pid/task/$flock_pid/children ]]; then
            read -r children < "/proc/$flock_pid/task/$flock_pid/children" || true
            for child in $children; do
                if pid_alive "$child"; then
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

verify_models() {
    local selected
    selected=$(printf '%s\n' "${weights[@]}")
    python3 - "$MANIFEST" "$BUILD_MANIFEST" "$BINARY" "$full_verify" "$selected" <<'PY'
import hashlib
import json
import os
import stat
import sys

manifest_path, build_manifest_path, binary_path, full_verify, selected = sys.argv[1:]
paths = selected.splitlines()
try:
    if os.path.islink(binary_path):
        raise ValueError(f"server binary is a symlink: {binary_path}")
    with open(build_manifest_path, encoding="utf-8") as stream:
        build_manifest = json.load(stream)
    expected_binary_sha = build_manifest["binaries"]["ds4-server"]["sha256"]
    binary_digest = hashlib.sha256()
    with open(binary_path, "rb") as binary:
        for chunk in iter(lambda: binary.read(1024 * 1024), b""):
            binary_digest.update(chunk)
    if binary_digest.hexdigest() != expected_binary_sha:
        raise ValueError(f"server binary sha256 mismatch: {binary_path}")

    with open(manifest_path, encoding="utf-8") as stream:
        manifest = json.load(stream)
    entries = {os.path.basename(item["path"]): item for item in manifest["files"]}
    for path in paths:
        if os.path.islink(path):
            raise ValueError(f"model file is a symlink: {path}")
        info = os.stat(path)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError(f"model path is not a regular file: {path}")
        if info.st_uid != os.geteuid():
            raise ValueError(f"model file is not owned by the service user: {path}")
        if info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            raise ValueError(f"model file is group/other writable: {path}")
        entry = entries.get(os.path.basename(path))
        if entry is None:
            raise ValueError(f"model is absent from manifest: {path}")
        if info.st_size != entry["bytes"]:
            raise ValueError(f"model byte-size mismatch: {path}")
        if full_verify == "true":
            digest = hashlib.sha256()
            with open(path, "rb") as model:
                for chunk in iter(lambda: model.read(16 * 1024 * 1024), b""):
                    digest.update(chunk)
            if digest.hexdigest() != entry["sha256"]:
                raise ValueError(f"model sha256 mismatch: {path}")
except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
    print(f"model integrity check failed: {error}", file=sys.stderr)
    sys.exit(1)
PY
}

do_start() {
    [[ -n ${HOME:-} ]] || die 'HOME is not set'
    DS4_HOME=${DS4_HOME:-$HOME/ds4-project}
    CTX=${CTX:-32768}
    [[ $CTX =~ ^[1-9][0-9]*$ ]] || die 'CTX must be a positive integer'

    SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || die 'cannot resolve script directory'
    REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P) || die 'cannot resolve repository root'
    MEMBUDGET=$REPO_ROOT/scripts/02_membudget.py
    MEMWATCH=$REPO_ROOT/scripts/01_memwatch.sh
    BINARY=$DS4_HOME/src/ds4/ds4-server
    BUILD_MANIFEST=$DS4_HOME/build-manifest.json
    GGUF_DIR=$DS4_HOME/gguf
    MANIFEST=$GGUF_DIR/manifest.json
    BASE=$GGUF_DIR/DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix.gguf
    MTP=$GGUF_DIR/DeepSeek-V4-Flash-MTP-Q4K-Q8_0-F32.gguf
    DRAFTER=$GGUF_DIR/DSpark-drafter-Q2K-Q8.gguf
    LOG_DIR=$HOME/logs
    SERVER_LOG=$LOG_DIR/ds4-server.log
    MEMWATCH_LOG=$LOG_DIR/memwatch-ds4.log

    for command_name in python3 flock setsid curl awk ps tr date mkdir; do need_command "$command_name"; done
    [[ -x $BINARY ]] || die "ds4 server is missing or not executable: $BINARY"
    [[ -r $BUILD_MANIFEST ]] || die "build manifest is missing or unreadable: $BUILD_MANIFEST"
    [[ -r $MANIFEST ]] || die "model manifest is missing or unreadable: $MANIFEST"
    [[ -r $MEMBUDGET && -r $MEMWATCH ]] || die 'memory safety scripts are missing or unreadable'
    mkdir -p -- "$RUNTIME_DIR" "$LOG_DIR" || die 'cannot create runtime or log directory'
    chmod 700 -- "$RUNTIME_DIR" "$LOG_DIR" || die 'cannot secure runtime or log directory'

    if [[ -e $STATE_FILE ]]; then
        read_state
        verify_state_identity && die "$STACK is already running with pid $server_pid"
    fi

    case $profile in
        dspark) weights=("$BASE" "$MTP" "$DRAFTER") ;;
        mtp) weights=("$BASE" "$MTP") ;;
        plain) weights=("$BASE") ;;
        *) die "invalid profile: $profile" ;;
    esac
    verify_models

    local budget rc
    set +e
    # overhead-gib 6: candidate B measured ~0.1 GiB non-weight overhead on this
    # host; ds4's boot-time artifact repacks add device allocations but the
    # project's published single-Spark footprint (~81 GiB loaded + large KV
    # pool) leaves margin. Floor stays 16; the 12 GiB watchdog is the backstop.
    budget=$(python3 "$MEMBUDGET" --weights "${weights[@]}" --ctx "$CTX" \
        --kv-bytes-per-token 2048 --overhead-gib 6 --floor-gib 16 2>&1)
    rc=$?
    set -e
    if (( rc != 0 )); then
        printf '%s\n' "$budget" >&2
        die 'memory budget gate failed'
    fi
    baseline_gib=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["mem_available_now_gib"])' <<<"$budget") \
        || die 'memory budget gate returned invalid JSON'

    local -a server_command
    # NOTE: DS4_SESSION_LAZY_GRAPH=0 (pre-allocated session graph) was tested
    # and REJECTED: with the dspark profile at ctx=32768 it leaves so little
    # headroom that a 32K prefill burst breaches the 12 GiB watchdog line
    # (verified 2026-07-16 - watchdog SIGKILLed the server, preventing a UMA
    # freeze). Lazy default serves prompts up to ~30K and 500s gracefully
    # beyond; documented engine envelope.
    server_command=(env -u DS4_CUDA_WEIGHT_IPC_MANIFEST -u DS4_CONT_DSPARK -u DS4_DSPARK_MODEL
        DS4_LOCK_FILE=/run/dsv4/ds4-engine.lock DS4_CUDA_BUILD_ARTIFACTS=1)
    case $profile in
        dspark)
            server_command+=(DS4_CONT_MTP_MODE=2 DS4_CONT_DSPARK=1 "DS4_DSPARK_MODEL=$DRAFTER"
                "$BINARY" --cuda -m "$BASE" --mtp "$MTP" --host 127.0.0.1 --port "$PORT" -c "$CTX")
            ;;
        mtp)
            server_command+=(DS4_CONT_MTP_MODE=2 "$BINARY" --cuda -m "$BASE" --mtp "$MTP"
                --host 127.0.0.1 --port "$PORT" -c "$CTX")
            ;;
        plain)
            server_command+=(DS4_CONT_MTP_MODE=0 "$BINARY" --cuda -m "$BASE"
                --host 127.0.0.1 --port "$PORT" -c "$CTX")
            ;;
    esac
    # Security baseline: never add --cors, --trace, --kv-disk-dir, --role,
    # --listen, or --coordinator; they expand data exposure or network roles.

    local command_text
    command_text=$(build_server_command "${server_command[@]}")
    printf '\n===== ds4 session start %s profile=%s ctx=%s =====\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$profile" "$CTX" >>"$SERVER_LOG"
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
    [[ -e $WATCHDOG_READY ]] || { kill -TERM "$memwatch_pid" 2>/dev/null || true; die 'memory watchdog initialization timed out'; }

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

    local deadline stats
    deadline=$((SECONDS + 600))
    while (( SECONDS < deadline )); do
        if ! pid_alive "$server_pid"; then
            die "ds4 server exited during startup; see $SERVER_LOG"
        fi
        if curl --silent --show-error --fail --max-time 3 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then
            stats=$(curl --silent --show-error --fail --max-time 3 "http://127.0.0.1:$PORT/v1/stats" 2>/dev/null || true)
            if grep -Eq 'artifact_source[^a-zA-Z]*none' <<<"$stats"; then
                die 'ds4 readiness failed: artifact source is none (raw-tier fallback)'
            fi
            if grep -Eq 'artifact_source[^a-zA-Z]*(built|imported)' <<<"$stats"; then
                printf '{"ok":true,"stack":"ds4","pid":%d,"port":%d}\n' "$server_pid" "$PORT"
                startup_cleanup_armed=false
                trap - ERR EXIT
                return 0
            fi
        fi
        if (( SECONDS < deadline )); then
            sleep 2
        fi
    done
    die 'ds4 readiness timed out after 600 seconds'
}

action=start
profile=dspark
full_verify=false
action_seen=false
while (( $# > 0 )); do
    case $1 in
        start|stop|status)
            "$action_seen" && { usage >&2; exit 2; }
            action=$1
            action_seen=true
            shift
            ;;
        --profile)
            (( $# >= 2 )) || { usage >&2; exit 2; }
            profile=$2
            shift 2
            ;;
        --full-verify) full_verify=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

case $action in
    start) do_start ;;
    stop)
        [[ $profile == dspark && $full_verify == false ]] || die 'start-only options cannot be used with stop'
        need_command python3; need_command ps; need_command awk; need_command tr
        do_stop
        ;;
    status)
        [[ $profile == dspark && $full_verify == false ]] || die 'start-only options cannot be used with status'
        need_command python3; need_command curl
        do_status
        ;;
esac
