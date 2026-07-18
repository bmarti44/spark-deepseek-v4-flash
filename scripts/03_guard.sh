#!/usr/bin/env bash
# DeepSeek V4 Flash engine guard with a consecutive-failure circuit breaker.
# Invoked as root by dsv4-guard.service (which sets STACK via EnvironmentFile).
#
# Why a counter and not only systemd StartLimit: the guard's restart is BLOCKING
# and engine readiness can take ~600 s, so slow repeated startup failures (e.g. a
# startup OOM) never accumulate enough starts inside StartLimit's sliding time
# window to trip it. This breaker counts CONSECUTIVE unhealthy checks instead of
# time, so N failed restart attempts latch regardless of how slow each one is,
# preventing the guard from re-hitting a dangerous load peak indefinitely.
set -Eeuo pipefail

STACK=${STACK:?guard: STACK is not set (expected from EnvironmentFile)}
STATE_DIR=/run/dsv4
COUNTER=$STATE_DIR/guard-consecutive-failures
readonly MAX_CONSECUTIVE_FAILURES=3

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)

case "$STACK" in
    ds4)      script=$REPO_ROOT/scripts/20_serve_ds4.sh;      unit=deepseek-v4-flash-ds4.service ;;
    llamacpp) script=$REPO_ROOT/scripts/21_serve_llamacpp.sh; unit=deepseek-v4-flash-llamacpp.service ;;
    *) echo "guard: invalid STACK=$STACK" >&2; exit 1 ;;
esac

read_count() {
    local c
    c=$(cat "$COUNTER" 2>/dev/null || echo 0)
    [[ $c =~ ^[0-9]+$ ]] || c=0
    printf '%s' "$c"
}

echo "guard: checking stack=$STACK"
if /usr/sbin/runuser -u dsv4 -- "$script" status; then
    echo "guard: stack=$STACK healthy"
    rm -f -- "$COUNTER"   # reset the breaker on a healthy check
    exit 0
fi

count=$(read_count)
if (( count >= MAX_CONSECUTIVE_FAILURES )); then
    echo "guard: stack=$STACK UNHEALTHY and circuit breaker OPEN ($count >= $MAX_CONSECUTIVE_FAILURES consecutive failed restarts); NOT restarting. A repeated startup failure (e.g. a load-time OOM) must be investigated by hand. To resume: 'rm $COUNTER' then 'systemctl restart $unit'." >&2
    exit 1
fi

mkdir -p -- "$STATE_DIR"
printf '%s\n' "$((count + 1))" >"$COUNTER"
echo "guard: stack=$STACK unhealthy; restart attempt $((count + 1))/$MAX_CONSECUTIVE_FAILURES of $unit"
if systemctl restart "$unit"; then
    echo "guard: restart attempt completed unit=$unit (next check confirms health)"
else
    echo "guard: restart command failed for $unit (rc=$?)" >&2
fi
