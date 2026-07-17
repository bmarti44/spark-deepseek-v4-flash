# Production runbook

This runbook covers day-2 operation after `scripts/41_install_service.sh llamacpp` has
installed the product endpoint behind Caddy and Tailscale Serve. The frozen ≤28K benchmark
verdict remains ds4, but Brian's 1M-context-roadmap override makes llama.cpp the production
engine and parks ds4 as an alternative. Set the clone path once for manual wrapper commands:

```bash
export DSV4_REPO=${DSV4_REPO:-/home/bmarti44/spark-deepseek-v4-flash}
```

## Start, stop, and status

The selected engine is a oneshot systemd unit whose serve wrapper manages the engine,
residency lock, watchdog, and `/run/dsv4` state. The auth helper, Caddy, and guard have
separate units.

For the production llama.cpp installation:

```bash
sudo systemctl start deepseek-v4-flash-llamacpp.service dsv4-authhelper.service dsv4-caddy.service dsv4-guard.timer
sudo systemctl status deepseek-v4-flash-llamacpp.service dsv4-authhelper.service dsv4-caddy.service dsv4-guard.timer
sudo -u dsv4 -H "$DSV4_REPO/scripts/21_serve_llamacpp.sh" status
```

For a deliberate parked-ds4 maintenance run, never leave both engines enabled:

```bash
sudo systemctl stop dsv4-guard.timer deepseek-v4-flash-llamacpp.service
sudo -u dsv4 -H "$DSV4_REPO/scripts/20_serve_ds4.sh" start --profile dspark
sudo -u dsv4 -H "$DSV4_REPO/scripts/20_serve_ds4.sh" status
```

For an intentional stop, stop the guard timer first or it may restart the engine at its
next check:

```bash
sudo systemctl stop dsv4-guard.timer
sudo systemctl stop deepseek-v4-flash-llamacpp.service
```

The equivalent engine-level stops, which validate recorded process identity and wait for
memory recovery, are:

```bash
sudo -u dsv4 -H "$DSV4_REPO/scripts/21_serve_llamacpp.sh" stop
```

Run only the command for the selected stack. Re-enable supervision after maintenance:

```bash
sudo systemctl start dsv4-guard.timer
```

## Health checks

The local endpoint is Caddy on port 8010; it streams through the authenticating helper,
which holds the 64-request concurrency slot for the entire engine response and strips the
Authorization header before upstream. The auth-header file is
root/`dsv4auth` readable, so invoke local checks through sudo:

```bash
sudo curl --silent --show-error --fail --max-time 10 -H @/etc/deepseek-v4-flash/auth-header http://127.0.0.1:8010/v1/models
curl --silent --show-error --max-time 10 http://127.0.0.1:8010/v1/models
```

The first must return model JSON; the second must be rejected with HTTP 401. To check the
tailnet path from an authorized client, use the node DNS name shown by `tailscale status`
and the key delivered to that client:

```bash
TAILNET_URL="https://$(tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')"
curl --silent --show-error --fail --max-time 10 -H "Authorization: Bearer $DSV4_API_KEY" "$TAILNET_URL/v1/models"
```

Also inspect routing on the host:

```bash
tailscale serve status
tailscale funnel status
```

When configuring or replacing the Serve route, keep the mutation and verification
together:

```bash
sudo tailscale serve --bg http://127.0.0.1:8010
sudo "$DSV4_REPO/scripts/42_verify_exposure.sh"
```

Serve must target `http://127.0.0.1:8010`, never engine port 8011/8012 or helper port
8013/8014, and Funnel must remain off. After any Tailscale Serve, Funnel, reset, or other
routing configuration change, immediately run the complete chain check as root:

```bash
sudo "$DSV4_REPO/scripts/42_verify_exposure.sh"
```

It rejects unsafe or unparseable routes, proves Funnel is off and unauthenticated traffic is
401, and delegates the authenticated 200 probe to the `dsv4auth` service user so root does
not read the key into shell state.

## Key rotation

The installer rotates the 64-hex bearer key by default, backs up only the immediately
previous key as root-only `/etc/deepseek-v4-flash/api-key.prev`, rebuilds the auth-header
file, and restarts the auth helper. Re-run it with the installed winner:

```bash
cd "$DSV4_REPO"
sudo env DSV4_REPO="$DSV4_REPO" bash scripts/41_install_service.sh llamacpp
```

Use `--keep-key` only for an intentional reinstall without rotation:

```bash
sudo env DSV4_REPO="$DSV4_REPO" bash scripts/41_install_service.sh llamacpp --keep-key
```

Run only the selected-stack command. Deliver the current
`/etc/deepseek-v4-flash/api-key` out of band through a trusted password manager or an
authenticated encrypted channel, then remove the superseded key from clients. Never put a
key in shell history, tickets, chat, logs, or the repository.

## Guard timer

`dsv4-guard.timer` runs about 60 seconds after boot and every 60 seconds thereafter. Its
oneshot service runs the selected serve script's `status`; a failed engine health check,
dead server, dead residency-lock holder, or dead watchdog causes `systemctl restart` of the
selected engine unit. The unit itself has `Restart=no`; the timer provides the restart
policy while the external memory watchdog provides emergency termination.

Silence automatic restarts for maintenance before stopping or changing the engine:

```bash
sudo systemctl stop dsv4-guard.timer
```

Inspect guard activity with:

```bash
sudo systemctl status dsv4-guard.timer dsv4-guard.service
sudo journalctl -u dsv4-guard.service --since today
```

## Watchdog and engine logs

Persistent logs owned by `dsv4` are:

- `/home/dsv4/logs/ds4-server.log`
- `/home/dsv4/logs/memwatch-ds4.log`
- `/home/dsv4/logs/llamacpp-server.log`
- `/home/dsv4/logs/memwatch-llamacpp.log`

Inspect only the installed stack:

```bash
sudo -u dsv4 -H tail -n 200 /home/dsv4/logs/memwatch-ds4.log
sudo -u dsv4 -H tail -n 200 /home/dsv4/logs/ds4-server.log
```

or:

```bash
sudo -u dsv4 -H tail -n 200 /home/dsv4/logs/memwatch-llamacpp.log
sudo -u dsv4 -H tail -n 200 /home/dsv4/logs/llamacpp-server.log
```

`BREACH` means `MemAvailable` crossed below the frozen 12 GiB threshold. Once armed, the
watchdog immediately SIGKILLs the engine process group to avoid a UMA hard freeze. A
breach while unarmed is logged and monitoring continues until a target is published.
`FAIL_CLOSED` means the watchdog itself hit an internal error, unexpected exit, invalid
target, or log failure; it terminates an armed engine gracefully, then forcibly if needed,
because unsupervised inference is unsafe. Review the surrounding log and host memory state
before allowing the guard to restart the service.

## Memory-pressure triage

Stop the guard timer first. Before restarting, establish why memory is low and whether it
has recovered:

```bash
sudo systemctl stop dsv4-guard.timer
awk '/MemTotal|MemAvailable|SwapTotal|SwapFree/ {print}' /proc/meminfo
nvidia-smi
ps -eo pid,ppid,pgid,user,rss,stat,comm --sort=-rss
cd "$DSV4_REPO"
./scripts/00_preflight.sh --out /tmp/preflight-triage.json
```

Then inspect the selected memwatch and engine logs. Do not restart while another GPU
compute process is resident, swap is materially used, the preflight memory check fails, or
`MemAvailable` has not recovered. The serve wrapper will independently enforce its static
16 GiB projected floor and the residency lock.

## Upgrade an engine safely

An engine commit, model, build, context length, serving profile, batch size, cache setting,
thinking mode, or any other server/request flag change is a new candidate configuration.
Do not replace the production baseline in place and rely on old evidence.

1. Stop `dsv4-guard.timer` and the selected engine.
2. Record a new version in [../PROTOCOL.md](../PROTOCOL.md) when a frozen gate or harness
   changes. A candidate-only engine/flag change still needs a new config identity and new
   build/weight evidence.
3. Fetch and build from pinned inputs, preserving the old known-good artifacts.
4. Run the complete golden, exact-token-parity, speed, dev/once-only-holdout accuracy,
   frozen 30-minute soak, full audit, and decision sequence in
   [../REPRODUCING.md](../REPRODUCING.md).
5. Record the benchmark verdict separately from any product override, then install only the
   explicitly approved production engine. The installer disables the other engine and
   verifies the full auth chain and listener isolation.

Any affected protocol change after results exist voids affected results for all candidates
and requires symmetric reruns, as specified by `PROTOCOL.md`.

## Known limits

The benchmark-winning ds4 candidate's accepted envelope is limited: warm sequential prompts
above roughly 28K tokens have failed even though a cold long-context golden request passed.
Treat [../results/envelope-exception-ds4.json](../results/envelope-exception-ds4.json) and
[../results/speed-ds4-dspark.json](../results/speed-ds4-dspark.json) as the authoritative
record; reject or constrain workloads outside the accepted envelope rather than assuming
the configured 32K context is uniformly reliable.

The production llama.cpp candidate's long-context TTFT/prefill profile remains operationally
important even though its decode and correctness gates passed. Use
[../results/speed-llamacpp.json](../results/speed-llamacpp.json) as the canonical profile
and set client timeouts accordingly. Its larger-context behavior is the reason for the
product override and the basis of the 1M-context roadmap; it is not a claim that the current
32K configuration already serves 1M tokens.

## Incident: server unresponsive

The guard normally detects the failed wrapper status within about 60 seconds and restarts
the selected engine unit. Check the guard journal and selected logs. For a controlled manual
recovery, silence the guard, stop through the selected wrapper as `dsv4`, inspect the
memwatch log and `/proc/meminfo`, then restart the systemd unit only after memory recovers:

```bash
sudo systemctl stop dsv4-guard.timer
sudo -u dsv4 -H "$DSV4_REPO/scripts/20_serve_ds4.sh" stop
sudo -u dsv4 -H tail -n 200 /home/dsv4/logs/memwatch-ds4.log
sudo systemctl restart deepseek-v4-flash-ds4.service
sudo systemctl start dsv4-guard.timer
```

or:

```bash
sudo systemctl stop dsv4-guard.timer
sudo -u dsv4 -H "$DSV4_REPO/scripts/21_serve_llamacpp.sh" stop
sudo -u dsv4 -H tail -n 200 /home/dsv4/logs/memwatch-llamacpp.log
sudo systemctl restart deepseek-v4-flash-llamacpp.service
sudo systemctl start dsv4-guard.timer
```

If the state file is already absent because the watchdog killed the engine, the wrapper's
stop command may report that it is not running. Continue with memory and log triage; do not
bypass the recovery checks by launching a server binary directly.

## Incident: host froze

Perform a hard reboot. `/run` is tmpfs, so the systemd `RuntimeDirectory` contents, JSON
state, target/ready files, and inode carrying the residency lock are cleared across boot.
Even if a lock pathname is recreated, `flock` ownership is process-bound, so no stale
process can retain it after reboot. Before the enabled units start loading a model, inspect
the previous persistent memwatch log when possible and confirm host memory, swap, and GPU
process state. If investigation requires the engine to stay down, stop the guard timer and
engine unit immediately after boot.
