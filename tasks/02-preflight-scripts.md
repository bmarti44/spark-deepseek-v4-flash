# T0.4 — Preflight, memory watchdog, and memory-budget scripts

You are implementing one task inside the git repo at the current working directory. Do not run git commands (the orchestrator commits). NEVER delete or modify any existing file except those this brief names as yours. Do not write into `verification/`, `results/`, or `tasks/`. No network access. No sudo.

Context: NVIDIA DGX Spark GB10, 128 GB unified memory (UMA). A memory overcommit historically freezes the whole machine, so these three scripts are the project's memory-safety layer. They will be reviewed line-by-line and frozen by hash; write them clean and defensive (bash strict mode; small functions; no cleverness).

## File 1: `scripts/00_preflight.sh`
Read-only environment gate. Flags: `--lock-file configs/versions.lock` (default), `--out <path>` (default: stdout) for the JSON report.
Checks (each recorded as `{"name", "expected", "actual", "pass"}`):
1. Root filesystem free space ≥ 350 GB (from `df -B1 /`).
2. `MemAvailable` ≥ 100 GiB (from /proc/meminfo).
3. Zero GPU compute processes: `nvidia-smi --query-compute-apps=pid --format=csv,noheader` empty.
4. Driver version equals `host.driver` in versions.lock (`nvidia-smi --query-gpu=driver_version --format=csv,noheader`).
5. Kernel equals `host.kernel` (`uname -r`).
6. `ollama.service` is not active (`systemctl is-active ollama.service` != "active").
7. Swap in use < 1 GiB (/proc/meminfo SwapTotal-SwapFree).
Output: single JSON object `{"timestamp_utc", "checks": [...], "pass": bool}`; exit 0 iff all pass. Use `date -u +%Y-%m-%dT%H:%M:%SZ`. Parse versions.lock with `python3 -c` or `jq` (jq may not be installed — detect, prefer python3).

## File 2: `scripts/01_memwatch.sh`
External memory watchdog. Flags: `--target-pid <pid>` (required), `--threshold-gib <n>` (default 12), `--interval-sec <n>` (default 1), `--log <path>` (required).
Behavior: every interval, read MemAvailable; append a log line `ts=<iso8601> mem_available_gib=<float>` every 10th sample. If MemAvailable < threshold: log `BREACH` with a full copy of /proc/meminfo, send SIGKILL to the target pid AND its process group (kill -9 -- -<pgid> where pgid = target's process group; guard against pgid 0/1), then exit 2. If target pid no longer exists: exit 0. Handle SIGTERM cleanly (exit 0). No busy loops (sleep the interval).

## File 3: `scripts/02_membudget.py`
Static pre-load budget calculator (python3, stdlib only). Args:
`--weights <path-or-glob ...>` (one or more files/globs; sum their sizes) OR `--weights-gib <float>`;
`--ctx <int>` tokens; `--kv-bytes-per-token <float>`; `--overhead-gib <float>` (default 8.0; CUDA context + compute buffers); `--extra-gib <float>` (default 0; e.g. drafter); `--floor-gib <float>` (default 16.0); `--out <path>` (default stdout).
Reads current MemAvailable from /proc/meminfo. Computes:
projected_free_gib = mem_available_now_gib − (weights_gib + ctx*kv_bytes_per_token/2^30 + overhead_gib + extra_gib).
Output JSON: all inputs echoed, `mem_available_now_gib`, `projected_free_gib`, `floor_gib`, `pass` (projected ≥ floor). Exit 0 iff pass, else 1. Round floats to 2 decimals. GiB = 2^30 throughout (document in --help).

## Definition of done
- `bash -n` passes on both shell scripts; `python3 -m py_compile` passes on the .py.
- All three have `--help` text.
- `bash scripts/00_preflight.sh --out /tmp/preflight_test.json` runs without crashing (it MAY report pass=false on individual checks — that is fine, do not force-pass anything).
- `python3 scripts/02_membudget.py --weights-gib 90 --ctx 32768 --kv-bytes-per-token 4096 --overhead-gib 8 --floor-gib 16` runs and prints valid JSON.
- Do NOT test 01_memwatch.sh by killing real processes; validate with `bash -n` and a `--help` invocation only. The orchestrator tests kill behavior against a synthetic process.

Final message: list files created and any deviations (should be none).
