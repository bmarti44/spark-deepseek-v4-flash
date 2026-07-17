# DeepSeek-V4-Flash on a single DGX Spark

This repository records a frozen comparison of `entrpi/ds4-on-spark` and upstream
llama.cpp on an NVIDIA GB10 DGX Spark, plus the hardened production service.

## Decision and production status

The frozen ≤28K benchmark selected **ds4**: composite accuracy 86.03% versus 81.62%,
with higher measured speed. That result remains the benchmark record in
[results/DECISION.md](results/DECISION.md).

Brian made a product override in
[results/DECISION-OVERRIDE.md](results/DECISION-OVERRIDE.md): **llama.cpp is the
production engine** because the product roadmap requires contexts approaching 1M tokens,
while ds4 failed warm requests above roughly 28K on this host. ds4 is parked as the
faster small-context alternative; its benchmark evidence is unchanged.

Production traffic follows `Tailscale Serve → Caddy :8010 → authenticated streaming
helper :8014 → llama.cpp :8011`. Every listener is loopback-only on the host, Funnel is
forbidden, the helper strips credentials before the engine, and a watchdog protects the
shared-memory machine from an unrecoverable UMA freeze.

## Reproduce and operate

- [REPRODUCING.md](REPRODUCING.md) gives the pinned host, build, benchmark, audit, and
  `llamacpp` production-install sequence.
- [docs/runbook.md](docs/runbook.md) covers day-2 operation and incidents.
- [PROTOCOL.md](PROTOCOL.md) defines the frozen evaluation versions.
- [docs/threat-model.md](docs/threat-model.md) states what the evidence does and does not
  prove.
