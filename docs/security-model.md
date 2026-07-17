# Production security model

The selected inference stack is reachable remotely only through Tailscale
Serve. Every application listener remains bound to loopback on the Spark. The
production selection is llama.cpp under the documented product override; ds4
remains an installable parked alternative using the same proxy chain.

```text
tailnet client
  |  tailnet identity + Tailscale HTTPS
  v
tailscaled on Spark
  |
  v
127.0.0.1:8010 Caddy (dsv4auth)
  |
  v
127.0.0.1:8014 authenticating streaming proxy (dsv4auth)
  |  120/min token bucket; 240 burst; 64 full-request slots
  |  Authorization stripped here
  +-- 127.0.0.1:8011 llama.cpp production engine
      (or 127.0.0.1:8012 for a parked-ds4 installation)
```

## Loopback exposure

| Port | Process | Authentication | Exposure |
|---:|---|---|---|
| 8010 | Caddy | Bearer token on every path | Only Tailscale Serve target |
| 8014 | Auth streaming proxy | Validates exactly one bearer header | Internal Caddy upstream only |
| 8012 | ds4 engine | None | Internal loopback backend only |
| 8011 | llama.cpp engine | None in production | Internal loopback backend only |

Tailscale supplies encrypted, tailnet-only transport and device/user policy;
it does not replace the application bearer key. Tailscale Serve must target
only port 8010, never either engine or the helper. The installer supplies port
8012 for ds4 or 8011 for llama.cpp to the helper's root-controlled environment.
Caddy limits request bodies to 10 MB and forwards every path to the helper. The
helper authenticates, rate-limits, holds one of 64 slots until the complete
streamed response finishes, and strips `Authorization` before the selected engine.

The llama.cpp serve script still accepts an optional `API_KEY_FILE` for
gate-phase use. Production deliberately leaves it unset because the engine
cannot read the production key and must be fronted by the helper.

## Key isolation and rotation

`dsv4auth` is a dedicated no-login system identity. Caddy and the auth helper
run as that user. The production key is
`/etc/deepseek-v4-flash/api-key`, owned by `root:dsv4auth` with mode `0640` in
a `root:dsv4auth` mode-`0750` directory. The adjacent `env` file contains the
key path, selected stack, and loopback upstream/listener configuration. The
`dsv4` engine account and repository owner cannot read the key.

The production hardening step removes the owner of `DSV4_REPO` from the `dsv4`
group. Repo ACLs provide the read access needed to run the checked-in scripts,
and the existing scoped sudoers rule remains the supported way for that owner
to operate the engine as `dsv4`.

The service installer rotates the key by default. Before replacement it copies
the old key to `/etc/deepseek-v4-flash/api-key.prev`, owned by root and mode
`0600`; only the immediately previous key is retained. `--keep-key` is an
explicit opt-out. The installer restarts the auth helper so the in-memory key
matches the file. An operator then delivers the new key to each authorized
laptop out-of-band and removes the superseded credential there. Tokens must
not be logged, committed, or placed on long-lived process command lines.

## Process and network isolation

The `dsv4` account owns the engine builds, weights, logs, and runtime state but
has no production credential. The auth tier uses its separate
`/run/dsv4auth` runtime directory; engines use `/run/dsv4`. All units deny IP
traffic by default and allow only IPv4/IPv6 loopback, with address families
restricted to IP and Unix sockets. This prevents accidental LAN/WAN exposure
and blocks outbound engine, agent, or weight-server roles.

The inference units do not automatically restart. Serve scripts enforce the
memory budget and exclusive residency lock, publish PID/PGID/start-ticks to the
watchdog, record process start time and kernel boot ID, and refuse to signal stale PIDs. Status succeeds only
while the server is healthy and the server, lock holder, and memory watchdog
are all alive. The watchdog kills an unsafe run; an operator reviews logs
before manually restarting the selected stack.

## Accepted home-lab risks

This is a single-administrator home-lab box, not a hostile multi-tenant host.
The repository owner retains scoped passwordless sudo authority to run commands
as `dsv4`, so compromise of that administrator account still permits control of
the inference service. Engine binaries, manifests, and weights also live in
the `dsv4`-writable home trust domain. A compromised engine account could
replace those files together. The mitigation is provenance/revision pinning:
build manifests pin binary hashes, both serve scripts verify their server
binary at every start, and model manifests pin weight sizes and hashes (with
full weight hashing available where supported). Moving immutable artifacts to
a root-owned deployment tree is deferred for this home-lab deployment.
