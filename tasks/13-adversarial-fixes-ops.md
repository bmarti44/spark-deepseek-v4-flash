# T-AR2 — Ops/security fixes from the adversarial review

ONLY these files may be modified/created: `scripts/20_serve_ds4.sh`, `scripts/21_serve_llamacpp.sh`, `scripts/41_install_service.sh`, `configs/caddy/Caddyfile`, `configs/systemd/dsv4-authhelper.service`, `configs/systemd/dsv4-caddy.service`, `configs/systemd/deepseek-v4-flash-llamacpp.service`, `setup/04-production-hardening.sh`, `docs/security-model.md`. No git/sudo/network. Surgical edits.

## 1. Key isolation (finding: engines + automation account can read the production key)
- New design: the bearer key is readable ONLY by a dedicated system user `dsv4auth`. Caddy + the auth helper run as `dsv4auth`; BOTH engines are fronted by Caddy (llama.cpp no longer uses --api-key-file in production).
- `setup/04-production-hardening.sh` (root; orchestrator runs): create system user `dsv4auth` (no home needed, nologin ok — helper runs via systemd); `chown root:dsv4auth /etc/deepseek-v4-flash/api-key; chmod 640`; REMOVE bmarti44 from the dsv4 group (`gpasswd -d bmarti44 dsv4 || true`) with a comment that repo ACLs already grant dsv4 read access and bmarti44 operates dsv4 via the scoped sudoers rule; print what changed.
- `configs/systemd/dsv4-authhelper.service` + `dsv4-caddy.service`: `User=dsv4auth`.
- `configs/caddy/Caddyfile`: single listener 127.0.0.1:8010 with `forward_auth` (keep as-is) but upstream selected by an env var: `reverse_proxy 127.0.0.1:{$DSV4_UPSTREAM_PORT}` (8012 ds4 / 8011 llamacpp); add `request_body { max_size 10MB }`. Keep header_up -Authorization.
- `configs/systemd/deepseek-v4-flash-llamacpp.service`: drop API_KEY_FILE env (engine now unauthenticated on loopback, fronted by Caddy).
- `scripts/21_serve_llamacpp.sh`: make `--api-key-file` OPTIONAL via env API_KEY_FILE (empty/unset = no auth flag, log a line "loopback-unauthenticated; must be fronted by the auth proxy"). Keep gate-phase usage working when the env is set.
- `scripts/41_install_service.sh`: ds4 AND llamacpp cases both install authhelper+caddy units with `Environment=DSV4_UPSTREAM_PORT=<port>` (use a systemd drop-in written by the installer: /etc/systemd/system/dsv4-caddy.service.d/upstream.conf); key generation: ROTATE BY DEFAULT (backup old key to /etc/deepseek-v4-flash/api-key.prev mode 600 root-only), `--keep-key` flag to opt out; ownership root:dsv4auth 640; disable the losing stack's unit if present (`systemctl disable --now deepseek-v4-flash-<other>.service 2>/dev/null || true`).

## 2. Serve script robustness (finding: stale-PID group kill; status lies)
Both serve scripts:
- write_state: add `server_start_ticks` = field 22 of /proc/<pid>/stat (starttime) and `boot_id` = /proc/sys/kernel/random/boot_id. stop/status: before ANY signal, verify current /proc/<pid>/stat starttime and boot_id match the state file; mismatch = treat as not-running (stale state), remove state file, never signal.
- status: exit 0 ONLY if server alive+healthy AND flock_pid alive AND memwatch_pid alive; report which are dead otherwise.
- 21 only (finding: no runtime integrity): before launch, sha256 the llama-server binary and compare to `$LLAMACPP_HOME/build-manifest.json` binaries["llama-server"].sha256; mismatch = fatal. (ds4 already does this.)

## 3. docs/security-model.md
Update to match: dsv4auth key isolation, both-engines-fronted architecture, rotation flow (installer default-rotates; laptop gets new key out-of-band), group-membership removal, remaining accepted risks (single-admin box: bmarti44 has scoped sudo to dsv4; binaries/weights in dsv4-writable home — accepted for home lab, listed with the mitigation that manifests pin hashes and serve scripts verify at start).

Definition of done: bash -n on all shell scripts; units remain parseable (comment-check); Caddyfile keeps forward_auth+uri. Final message: per-file summary + deviations.
