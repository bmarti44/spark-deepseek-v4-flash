# T4.1 — Production artifacts for BOTH stacks (winner applied later)

ONLY these files may be created/modified:
`configs/systemd/deepseek-v4-flash-ds4.service`, `configs/systemd/deepseek-v4-flash-llamacpp.service`, `configs/systemd/dsv4-caddy.service`, `configs/caddy/Caddyfile`, `scripts/40_auth_helper.py`, `scripts/41_install_service.sh`, `docs/security-model.md`.
No git/sudo/network; nothing is installed by you — `41_install_service.sh` is what the ORCHESTRATOR runs with sudo later.

Context (read `docs/ds4-security-review.md` §E14 and both serve scripts): winner will be served on loopback by the existing serve scripts, exposed only through `tailscale serve` (tailnet-only HTTPS on the Spark). ds4 has NO native auth → Caddy fronts it on 127.0.0.1:8010 with a forward_auth helper. llama.cpp has native `--api-key-file` on 127.0.0.1:8011 and needs no proxy.

## systemd units (both stacks; only the winner gets installed)
- `deepseek-v4-flash-<stack>.service`: `User=dsv4`, `Group=dsv4`, ExecStart runs the existing serve script's `start` in FOREGROUND? No — the serve scripts daemonize. Instead: `Type=forking` is fragile; write the unit as `Type=oneshot` + `RemainAfterExit=yes` with `ExecStart=<serve script> start ...`, `ExecStop=<serve script> stop`, plus `ExecStartPre` running `scripts/00_preflight.sh --out /tmp/preflight-service.json || true` comment explaining pre-checks live in the serve script (membudget+lock). Production policy (plan §memory-safety 5): `Restart=no` for oneshot (document: supervised restarts are manual per runbook; OOM watchdog handles kills), `TimeoutStartSec=700`, `TimeoutStopSec=240`.
- Env: ds4 unit sets nothing secret; llamacpp unit sets `API_KEY_FILE=/etc/deepseek-v4-flash/api-key`.
- Hardening block in both: `NoNewPrivileges=yes`, `ProtectSystem=strict`, `ReadWritePaths=/run/dsv4 /home/dsv4`, `PrivateTmp=yes`, `ProtectHome=no` (dsv4's home is the working area; document why), `IPAddressAllow=127.0.0.0/8 ::1`, `IPAddressDeny=any`, `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX` (deny-all-egress defense per audit §E14 — the server only needs loopback).
- `After=network-online.target` + `Wants=`.

## Caddy front (ds4 only)
- `configs/caddy/Caddyfile`: listen 127.0.0.1:8010; `forward_auth 127.0.0.1:8014` (the helper) for ALL paths; on success `reverse_proxy 127.0.0.1:8012` with `header_up -Authorization` (strip before upstream). No admin API (`admin off`), no TLS (tailscale serve terminates TLS).
- `scripts/40_auth_helper.py`: ~60-line stdlib HTTP server on 127.0.0.1:8014. For each request: read Authorization headers via a method that exposes DUPLICATES (http.server headers.get_all); require EXACTLY ONE `Authorization: Bearer <token>`; constant-time compare (hmac.compare_digest) against the key file (path from env `API_KEY_FILE`, read at startup, re-read on SIGHUP); 204 on success, 401 otherwise; never log the header value. Runs as dsv4 via `configs/systemd/dsv4-caddy.service`... actually give the helper its own ExecStartPre in the caddy unit? Simpler: `dsv4-caddy.service` starts BOTH: `ExecStartPre=` no — write TWO ExecStart? Not allowed. Make dsv4-caddy.service a unit that runs caddy, and add `configs/systemd/dsv4-authhelper.service` (add to your allowed files) running the helper, with caddy unit `After=Requires=dsv4-authhelper.service`. Both `User=dsv4`, same hardening minus ReadWritePaths (none needed beyond /run/dsv4).
- Note in Caddyfile comments: caddy binary comes from apt (orchestrator installs); paths absolute.

## scripts/41_install_service.sh (orchestrator runs with sudo)
Args: `<ds4|llamacpp>`. Copies the right unit(s) to /etc/systemd/system/, generates the production API key if absent: `umask 077; openssl rand -hex 32 > /etc/deepseek-v4-flash/api-key; chown root:dsv4; chmod 640`, writes `/etc/deepseek-v4-flash/env` (`API_KEY_FILE=...`), `systemctl daemon-reload`, enables+starts the unit(s) (ds4 case: also authhelper+caddy), then prints verification commands. Refuses to run as non-root. For llamacpp: replaces the dsv4 gate-phase key path — document that clients must use the NEW key.

## docs/security-model.md
Concise: trust boundaries diagram (text), what's exposed where (loopback table incl. auth per endpoint), tailnet layer, key handling/rotation (rotate = rerun installer key step + restart + update laptop), ds4 public-metadata note (llama.cpp /health+/v1/models unauthenticated; ds4 fronted entirely by Caddy), egress-deny rationale, dsv4 isolation rationale.

Definition of done: `bash -n` on the shell script; `py_compile` on the helper; `systemd-analyze verify` NOT available to you (no sudo) — instead comment each unit carefully. Final message: files + deviations.
