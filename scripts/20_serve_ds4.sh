#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

STACK=ds4
PORT=8012
RUNTIME_DIR=/run/dsv4
LOCK_FILE=$RUNTIME_DIR/inference.lock
STATE_FILE=$RUNTIME_DIR/ds4.state.json

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
    print(state["server_pid"])
    print(state["flock_pid"])
    print(state["memwatch_pid"])
    print(state["port"])
    print(baseline)
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
}

write_state() {
    local temporary=$STATE_FILE.tmp.$$
    python3 - "$temporary" "$STATE_FILE" "$server_pid" "$flock_pid" \
        "$memwatch_pid" "$PORT" "$started_at" "$baseline_gib" <<'PY'
import json
import os
import sys

temporary, output, server, flock, watchdog, port, started, baseline = sys.argv[1:]
state = {
    "server_pid": int(server),
    "flock_pid": int(flock),
    "memwatch_pid": int(watchdog),
    "port": int(port),
    "started_at": started,
    "mem_available_baseline_gib": float(baseline),
}
with open(temporary, "w", encoding="utf-8") as stream:
    json.dump(state, stream, separators=(",", ":"))
    stream.write("\n")
os.replace(temporary, output)
PY
}

terminate_from_state() {
    local pgid seconds current target recovery_ok=true
    read_state

    pgid=$(ps -o pgid= -p "$server_pid" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ $pgid =~ ^[0-9]+$ ]] && (( pgid > 1 )); then
        kill -TERM -- "-$pgid" 2>/dev/null || true
    else
        kill -TERM "$server_pid" "$flock_pid" 2>/dev/null || true
    fi

    for ((seconds=0; seconds < 60; seconds++)); do
        pid_alive "$server_pid" || break
        sleep 1
    done
    if pid_alive "$server_pid"; then
        printf 'Server did not exit after 60 seconds; sending SIGKILL.\n' >&2
        if [[ $pgid =~ ^[0-9]+$ ]] && (( pgid > 1 )); then
            kill -KILL -- "-$pgid" 2>/dev/null || true
        else
            kill -KILL "$server_pid" "$flock_pid" 2>/dev/null || true
        fi
    fi
    kill -TERM "$memwatch_pid" 2>/dev/null || true

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
    rm -f -- "$STATE_FILE"
    "$recovery_ok" || { printf 'ERROR: memory did not recover within 120 seconds.\n' >&2; return 1; }
}

do_stop() {
    [[ -e $STATE_FILE ]] || die "$STACK is not running (state file absent)"
    terminate_from_state
    printf '{"ok":true,"stack":"%s","stopped":true}\n' "$STACK"
}

do_status() {
    [[ -r $STATE_FILE ]] || { printf 'ERROR: %s is not running (state file absent)\n' "$STACK" >&2; return 1; }
    read_state
    local server_alive=false flock_alive=false memwatch_alive=false healthy=false
    pid_alive "$server_pid" && server_alive=true
    pid_alive "$flock_pid" && flock_alive=true
    pid_alive "$memwatch_pid" && memwatch_alive=true
    if "$server_alive" && curl --silent --show-error --fail --max-time 3 \
            "http://127.0.0.1:$state_port/v1/models" >/dev/null 2>&1; then
        local stats
        stats=$(curl --silent --show-error --fail --max-time 3 \
            "http://127.0.0.1:$state_port/v1/stats" 2>/dev/null || true)
        [[ $stats == *'"built"'* && $stats != *'"none"'* ]] && healthy=true
    fi
    python3 - "$STATE_FILE" "$server_alive" "$flock_alive" "$memwatch_alive" "$healthy" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    result = json.load(stream)
for key, value in zip(("server_alive", "flock_alive", "memwatch_alive", "healthy"), sys.argv[2:]):
    result[key] = value == "true"
print(json.dumps(result, separators=(",", ":")))
PY
    "$server_alive" && "$healthy"
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
        pid_alive "$server_pid" && die "$STACK is already running with pid $server_pid"
        kill -TERM "$memwatch_pid" 2>/dev/null || true
        rm -f -- "$STATE_FILE"
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
    setsid flock -n -E 75 "$LOCK_FILE" -c "$command_text" >>"$SERVER_LOG" 2>&1 &
    flock_pid=$!
    discover_server_pid

    setsid bash "$MEMWATCH" --target-pid "$server_pid" --threshold-gib 12 \
        --interval-sec 1 --log "$MEMWATCH_LOG" >/dev/null 2>&1 &
    memwatch_pid=$!
    pid_alive "$memwatch_pid" || { kill -TERM -- "-$flock_pid" 2>/dev/null || true; die 'memory watchdog failed to start'; }
    started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    write_state || { kill -TERM -- "-$flock_pid" 2>/dev/null || true; kill -TERM "$memwatch_pid" 2>/dev/null || true; die 'failed to write state file'; }

    local deadline stats
    deadline=$((SECONDS + 300))
    while (( SECONDS < deadline )); do
        if ! pid_alive "$server_pid"; then
            terminate_from_state || true
            die "ds4 server exited during startup; see $SERVER_LOG"
        fi
        if curl --silent --show-error --fail --max-time 3 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then
            stats=$(curl --silent --show-error --fail --max-time 3 "http://127.0.0.1:$PORT/v1/stats" 2>/dev/null || true)
            if [[ $stats == *'"none"'* ]]; then
                terminate_from_state || true
                die 'ds4 readiness failed: artifact source is none (raw-tier fallback)'
            fi
            if [[ $stats == *'"built"'* ]]; then
                printf '{"ok":true,"stack":"ds4","pid":%d,"port":%d}\n' "$server_pid" "$PORT"
                return 0
            fi
        fi
        if (( SECONDS < deadline )); then
            sleep 2
        fi
    done
    terminate_from_state || true
    die 'ds4 readiness timed out after 300 seconds'
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
