# T1.3 + T2.4 — Write scripts/20_serve_ds4.sh and scripts/21_serve_llamacpp.sh

The ONLY files you may create or modify are `scripts/20_serve_ds4.sh` and `scripts/21_serve_llamacpp.sh`. No git, no sudo, no network. Read `docs/ds4-security-review.md` §E13/E14 and `scripts/10_fetch_ds4.sh`/`13_build_llamacpp.sh` for conventions. Both scripts run AS user `dsv4`.

## Shared contract (both scripts)
- `umask 077`; bash strict mode; `--help`.
- Subcommands: `start` (default), `stop`, `status`.
- **Single-model residency**: `start` acquires an exclusive non-blocking flock on `/run/dsv4/inference.lock` and HOLDS it for the server's lifetime by launching the server as: `setsid flock -n -E 75 /run/dsv4/inference.lock -c '<server command>' &` — flock exit code 75 (lock held) must produce the error "another inference server holds the residency lock". setsid gives the server its own process group so the external memory watchdog can group-kill it without killing anything else.
- **Memory budget gate**: before launching, run `python3 <repo>/scripts/02_membudget.py` with the stack-specific parameters below; if it fails (exit ≠0), abort with its JSON on stderr.
- **Watchdog**: after the server process exists, start `bash <repo>/scripts/01_memwatch.sh --target-pid <server pid> --threshold-gib 12 --interval-sec 1 --log $LOG_DIR/memwatch-<stack>.log` in the background (also setsid).
- State file `/run/dsv4/<stack>.state.json`: `{server_pid, flock_pid, memwatch_pid, port, started_at, mem_available_baseline_gib}` written atomically. `stop` reads it, SIGTERMs the server's process group, waits up to 60 s for exit, SIGKILLs if needed, kills the watchdog, then waits up to 120 s for MemAvailable to recover to ≥ (baseline − 5 GiB), reporting progress; removes state file. `status` prints the state file + whether pids are alive; exits 0 only if server alive and healthy (probe the health URL).
- **Readiness** (in `start`): poll the stack's health URL every 2 s up to 300 s (model load from NVMe takes a while). On timeout: kill everything (as in stop) and exit 1.
- `LOG_DIR=$HOME/logs` (create). Server stdout/stderr → `$LOG_DIR/<stack>-server.log` (append, with a session-start marker line).
- On success `start` prints `{"ok":true,"stack":"<name>","pid":N,"port":N}` and exits 0, leaving server+watchdog running.
- Ports: ds4 backend = 127.0.0.1:8012; llama.cpp = 127.0.0.1:8011. Bind loopback explicitly.
- Env knobs (both): `DS4_HOME`/`LLAMACPP_HOME` as in earlier scripts; `CTX` (default 32768).

## scripts/20_serve_ds4.sh specifics (per audit E13.3/E14)
- Paths: binary `$DS4_HOME/src/ds4/ds4-server`; weights in `$DS4_HOME/gguf/` (base = `DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix.gguf`, mtp = `DeepSeek-V4-Flash-MTP-Q4K-Q8_0-F32.gguf`, drafter = `DSpark-drafter-Q2K-Q8.gguf`).
- Pre-launch integrity: verify sha256 of the three GGUFs against `$DS4_HOME/gguf/manifest.json` (fast path: verify byte sizes always, full sha256 only when `--full-verify` given — hashing 85 GB takes minutes; document this). Refuse symlinked model files.
- `--profile dspark|mtp|plain` (default `dspark`):
  - dspark: env `DS4_CUDA_BUILD_ARTIFACTS=1 DS4_CONT_MTP_MODE=2 DS4_CONT_DSPARK=1 DS4_DSPARK_MODEL=<drafter path>`; server args `--cuda -m <base> --mtp <mtp> --host 127.0.0.1 --port 8012 -c $CTX`
  - mtp: same minus `DS4_CONT_DSPARK`/`DS4_DSPARK_MODEL`
  - plain: `DS4_CUDA_BUILD_ARTIFACTS=1 DS4_CONT_MTP_MODE=0`, no `--mtp` arg
- Env always: `DS4_LOCK_FILE=/run/dsv4/ds4-engine.lock` (NEVER the default /tmp/ds4.lock — symlink-attack finding).
- FORBIDDEN args (do not include, add a comment why): `--cors`, `--trace`, `--kv-disk-dir`, `--role`, `--listen`, `--coordinator`.
- membudget params: weights = the 2 or 3 GGUF files of the profile (pass file paths with `--weights`), `--kv-bytes-per-token 2048 --overhead-gib 10 --floor-gib 16`.
- Readiness: `http://127.0.0.1:8012/v1/models` returns 200, THEN `curl http://127.0.0.1:8012/v1/stats` must contain artifact source `built` (grep for `"built"`); if it reports `none`, readiness FAILS (raw-tier fallback = wrong performance profile; audit §E13 readiness rule).

## scripts/21_serve_llamacpp.sh specifics
- Paths: binary `$LLAMACPP_HOME/src/llama.cpp/build/bin/llama-server`; model = first shard `/home/bmarti44/spark-deepseek-v4-flash/weights/unsloth-ud-q2_k_xl/DeepSeek-V4-Flash-UD-Q2_K_XL-00001-of-00003.gguf` (llama.cpp auto-loads the remaining split shards; allow override via `MODEL_PATH` env).
- API key: `--api-key-file "${API_KEY_FILE:-/etc/deepseek-v4-flash/api-key}"` — fatal error with a clear message if the file is missing/unreadable.
- Server args: `--host 127.0.0.1 --port 8011 -c $CTX -np 1 -ngl 999 -b 2048 -ub 512 --no-warmup` plus RAM-prompt-cache disabled: check `llama-server --help` output at runtime for `--cache-ram` and pass `--cache-ram 0` if supported (fail with a clear message if the flag is absent — do NOT silently skip; the orchestrator will reassess).
- K cache stays fp16 (default — do NOT pass -ctk/-ctv quantized types; comment why: upstream quantized-K bug history).
- membudget params: `--weights` all three UD-Q2_K_XL shards, `--kv-bytes-per-token 4096 --overhead-gib 10 --floor-gib 16`.
- Readiness: `http://127.0.0.1:8011/health` returns 200 (llama-server serves /health without auth).

## Definition of done
`bash -n` clean on both; `--help` works on both; `status` on a non-running stack exits nonzero cleanly. Do NOT start any server yourself (no model is loadable in your sandbox anyway).

Final message: files created + deviations (should be none).
