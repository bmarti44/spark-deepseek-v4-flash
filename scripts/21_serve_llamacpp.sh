#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

STACK=llamacpp
PORT=8011
RUNTIME_DIR=/run/dsv4
LOCK_FILE=$RUNTIME_DIR/inference.lock
STATE_FILE=$RUNTIME_DIR/llamacpp.state.json

usage() {
    cat <<'EOF'
Usage: 21_serve_llamacpp.sh [start|stop|status] [OPTIONS]

Start (the default), stop, or inspect the loopback-only llama.cpp server.

Options:
  -h, --help  Show this help

Environment:
  LLAMACPP_HOME  Build root (default: $HOME/llamacpp-project)
  MODEL_PATH     First GGUF split shard (default: repository UD-Q2_K_XL shard)
  API_KEY_FILE   API key path (default: /etc/deepseek-v4-flash/api-key)
  CTX            Context length (default: 32768)
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
            "http://127.0.0.1:$state_port/health" >/dev/null 2>&1; then
        healthy=true
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

verify_shards() {
    local path
    for path in "${weights[@]}"; do
        [[ ! -L $path ]] || die "model shard is a symlink: $path"
        [[ -f $path && -r $path ]] || die "model shard is missing or unreadable: $path"
    done
}

do_start() {
    [[ -n ${HOME:-} ]] || die 'HOME is not set'
    LLAMACPP_HOME=${LLAMACPP_HOME:-$HOME/llamacpp-project}
    CTX=${CTX:-32768}
    [[ $CTX =~ ^[1-9][0-9]*$ ]] || die 'CTX must be a positive integer'
    MODEL_PATH=${MODEL_PATH:-/home/bmarti44/spark-deepseek-v4-flash/weights/unsloth-ud-q2_k_xl/DeepSeek-V4-Flash-UD-Q2_K_XL-00001-of-00003.gguf}
    API_KEY_FILE=${API_KEY_FILE:-/etc/deepseek-v4-flash/api-key}

    SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || die 'cannot resolve script directory'
    REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P) || die 'cannot resolve repository root'
    MEMBUDGET=$REPO_ROOT/scripts/02_membudget.py
    MEMWATCH=$REPO_ROOT/scripts/01_memwatch.sh
    BINARY=$LLAMACPP_HOME/src/llama.cpp/build/bin/llama-server
    LOG_DIR=$HOME/logs
    SERVER_LOG=$LOG_DIR/llamacpp-server.log
    MEMWATCH_LOG=$LOG_DIR/memwatch-llamacpp.log

    for command_name in python3 flock setsid curl awk ps tr date mkdir; do need_command "$command_name"; done
    [[ -x $BINARY ]] || die "llama-server is missing or not executable: $BINARY"
    [[ -r $MEMBUDGET && -r $MEMWATCH ]] || die 'memory safety scripts are missing or unreadable'
    [[ -f $API_KEY_FILE && -r $API_KEY_FILE ]] \
        || die "API key file is missing or unreadable: $API_KEY_FILE"
    mkdir -p -- "$RUNTIME_DIR" "$LOG_DIR" || die 'cannot create runtime or log directory'
    chmod 700 -- "$RUNTIME_DIR" "$LOG_DIR" || die 'cannot secure runtime or log directory'

    if [[ -e $STATE_FILE ]]; then
        read_state
        pid_alive "$server_pid" && die "$STACK is already running with pid $server_pid"
        kill -TERM "$memwatch_pid" 2>/dev/null || true
        rm -f -- "$STATE_FILE"
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
    verify_shards

    local help_output
    help_output=$("$BINARY" --help 2>&1) || die 'llama-server --help failed'
    grep -F -- '--cache-ram' <<<"$help_output" >/dev/null \
        || die 'llama-server lacks required --cache-ram support; RAM prompt cache cannot be disabled'

    local budget rc
    set +e
    # overhead-gib 6: llama.cpp non-weight footprint for this config (compute
    # buffers at b=2048/ub=512, CUDA context, KV pool) measures 3-5 GiB; 6 keeps
    # slack without double-counting against the hard 16 GiB floor.
    budget=$(python3 "$MEMBUDGET" --weights "${weights[@]}" --ctx "$CTX" \
        --kv-bytes-per-token 4096 --overhead-gib 6 --floor-gib 16 2>&1)
    rc=$?
    set -e
    if (( rc != 0 )); then
        printf '%s\n' "$budget" >&2
        die 'memory budget gate failed'
    fi
    baseline_gib=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["mem_available_now_gib"])' <<<"$budget") \
        || die 'memory budget gate returned invalid JSON'

    local -a server_command
    server_command=("$BINARY" --model "$MODEL_PATH" --api-key-file "$API_KEY_FILE"
        --host 127.0.0.1 --port "$PORT" -c "$CTX" -np 1 -ngl 999 -b 2048 -ub 512
        --no-warmup --cache-ram 0)
    # Keep the default fp16 K/V cache: upstream quantized-K bugs make -ctk/-ctv
    # inappropriate for this production baseline.

    local command_text
    command_text=$(build_server_command "${server_command[@]}")
    printf '\n===== llama.cpp session start %s ctx=%s =====\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CTX" >>"$SERVER_LOG"
    setsid flock -n -E 75 "$LOCK_FILE" -c "$command_text" >>"$SERVER_LOG" 2>&1 &
    flock_pid=$!
    discover_server_pid

    setsid bash "$MEMWATCH" --target-pid "$server_pid" --threshold-gib 12 \
        --interval-sec 1 --log "$MEMWATCH_LOG" >/dev/null 2>&1 &
    memwatch_pid=$!
    pid_alive "$memwatch_pid" || { kill -TERM -- "-$flock_pid" 2>/dev/null || true; die 'memory watchdog failed to start'; }
    started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    write_state || { kill -TERM -- "-$flock_pid" 2>/dev/null || true; kill -TERM "$memwatch_pid" 2>/dev/null || true; die 'failed to write state file'; }

    local deadline
    deadline=$((SECONDS + 300))
    while (( SECONDS < deadline )); do
        if ! pid_alive "$server_pid"; then
            terminate_from_state || true
            die "llama.cpp server exited during startup; see $SERVER_LOG"
        fi
        if curl --silent --show-error --fail --max-time 3 \
                "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
            printf '{"ok":true,"stack":"llamacpp","pid":%d,"port":%d}\n' "$server_pid" "$PORT"
            return 0
        fi
        if (( SECONDS < deadline )); then
            sleep 2
        fi
    done
    terminate_from_state || true
    die 'llama.cpp readiness timed out after 300 seconds'
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
