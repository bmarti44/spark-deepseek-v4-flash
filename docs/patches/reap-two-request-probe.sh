#!/usr/bin/env bash
# Two-request crash probe for the REAP GGUF. Usage: reap-probe.sh LABEL BINARY [extra llama-server args...]
set -u
LABEL=$1; BINARY=$2; shift 2
LOG=/tmp/reap-probe-$LABEL.log
sudo -n -u dsv4 -H pkill -f 'port 8021' 2>/dev/null; sleep 2
sudo -n -u dsv4 -H env HOME=/home/dsv4 ${PROBE_ENV:-} nohup "$BINARY" \
  -m /home/bmarti44/spark-deepseek-v4-flash/weights/xik94-reap162b/DSV4-Flash-162B-REAP-Q3_K_M.gguf \
  --host 127.0.0.1 --port 8021 -c 32768 -np 1 -ngl 999 --no-warmup --no-mmap --cache-ram 0 \
  "$@" >"$LOG" 2>&1 &
for i in $(seq 1 80); do
  curl -sf --max-time 2 http://127.0.0.1:8021/health >/dev/null 2>&1 && break
  grep -q 'exiting due to model loading error' "$LOG" 2>/dev/null && { echo "$LABEL: LOAD-ERROR"; exit 1; }
  sleep 3
done
curl -sf --max-time 2 http://127.0.0.1:8021/health >/dev/null || { echo "$LABEL: NEVER-HEALTHY"; exit 1; }
req() {
  curl -s --max-time 300 -X POST http://127.0.0.1:8021/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"d\",\"messages\":[{\"role\":\"user\",\"content\":\"$1\"}],\"max_tokens\":64,\"temperature\":0,\"cache_prompt\":false}" \
    -o /dev/null -w '%{http_code}'
}
r1=$(req "Write one sentence about ships.")
r2=$(req "What is 6*7? Answer briefly.")
r3=$(req "Name one color.")
echo "$LABEL: r1=$r1 r2=$r2 r3=$r3 $( [ "$r2" = 200 ] && [ "$r3" = 200 ] && echo SURVIVES || echo CRASHES-ON-REUSE )"
grep -a 'CUDA error' "$LOG" | head -1
sudo -n -u dsv4 -H pkill -f 'port 8021' 2>/dev/null
exit 0
