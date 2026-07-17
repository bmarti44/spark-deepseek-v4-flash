# Reproducing the DGX Spark evaluation

Set one path variable for the clone. The tracked setup scripts default `DSV4_REPO` to the
repository containing them; the production installer substitutes its resolved value into
the systemd unit templates. Commands below start in that directory unless stated otherwise:

```bash
export DSV4_REPO=${DSV4_REPO:-/home/bmarti44/spark-deepseek-v4-flash}
cd "$DSV4_REPO"
```

## 1. Hardware and OS prerequisites

Use one NVIDIA DGX Spark with a GB10 (`sm_121`), 128 GB unified memory, aarch64 DGX OS,
CUDA 13, and enough local storage for both weight sets and build trees. The measured host
record in [configs/versions.lock](configs/versions.lock) is Ubuntu 24.04.4, kernel
`6.17.0-1026-nvidia`, NVIDIA driver `580.159.03`, and CUDA `13.0`. The first committed
preflight record is [results/preflight-p0.json](results/preflight-p0.json); use that file,
not copied numbers in prose, as the measured baseline.

GB10 CPU and GPU allocations draw from the same UMA pool. Exhaustion on this host has
caused a hard freeze rather than a recoverable process OOM. The static memory-budget gate,
12 GiB external watchdog, watchdog-before-engine ordering, and single-residency lock are
therefore non-negotiable. Do not launch either server binary directly. The preflight also
requires at least 350 GiB free on `/`, 100 GiB `MemAvailable`, no GPU compute process,
less than 1 GiB swap in use, the locked driver and kernel, and inactive Ollama.

As the repository owner, inspect the stock host before setup:

```bash
cd "$DSV4_REPO"
./scripts/00_preflight.sh --out /tmp/preflight.json
```

## 2. One-time host setup

Run these as root, in order. Steps 01 through 03 are the benchmark-host setup; step 04 is
deferred until a winner exists and production is being installed.

```bash
cd "$DSV4_REPO"
sudo env DSV4_REPO="$DSV4_REPO" bash setup/01-bwrap-apparmor.sh
sudo env DSV4_REPO="$DSV4_REPO" bash setup/02-dgxos-update.sh
```

Step 01 installs a targeted AppArmor exception for `/usr/bin/bwrap`, preserving the global
unprivileged-user-namespace restriction. It supported the implementation agent's sandbox.
Step 02 performs `apt-get update` and `apt-get full-upgrade -y`, then reboots after a
15-second warning. A full upgrade is intentionally not package-reproducible: repositories
can advance after this evaluation. It does not update EC, UEFI, or other firmware. After
the reboot, compare the actual OS, kernel, driver, CUDA, and tool versions with
[configs/versions.lock](configs/versions.lock); `00_preflight.sh` must pass before any build
or benchmark. Do not silently update the lock to bless a different host:

```bash
cd "$DSV4_REPO"
./scripts/00_preflight.sh --out /tmp/preflight-after-update.json
sudo env DSV4_REPO="$DSV4_REPO" bash setup/03-dsv4-user.sh
```

Step 03 creates the unprivileged `dsv4` system account, delegates only passwordless
repository-owner → `dsv4` execution through `/etc/sudoers.d/dsv4-delegate`, creates
`/run/dsv4` through tmpfiles, creates `/etc/deepseek-v4-flash`, disables Ollama, adds the owner to the
`dsv4` group for the evaluation phase, and activates the tracked `.githooks` by setting
`core.hooksPath=.githooks` for this clone.

The repository also relies on an ACL that step 03 does **not** install. This omission is
called out in [docs/adversarial-review-2026-07-16.md](docs/adversarial-review-2026-07-16.md)
and assumed by [setup/04-production-hardening.sh](setup/04-production-hardening.sh). Apply
the missing traversal, current-tree read/execute, and inherited read/execute ACLs explicitly
as root:

```bash
sudo setfacl -m u:dsv4:--x "$(dirname "$DSV4_REPO")"
sudo setfacl -R -m u:dsv4:rX "$DSV4_REPO"
sudo find "$DSV4_REPO" -type d -exec setfacl -d -m u:dsv4:rX {} +
```

The first command permits traversal without listing the private home directory. The second
grants access to the existing clone; applying the default ACL to every existing directory
makes new descendants inherit access.

## 3. Harness environment

As the repository owner, create the isolated harness environment:

```bash
cd "$DSV4_REPO"
python3 -m venv .venv-harness
.venv-harness/bin/python -m pip install -r requirements-harness.txt
```

The harness pins `tokenizers` and `pyarrow`. HumanEval runs generated programs in the
`python:3.12-slim` Docker image with no network, dropped capabilities, read-only root,
memory/CPU/PID limits, and a timeout. Install Docker using the DGX OS-supported packaging,
ensure the benchmark operator can invoke it, and verify its presence before starting an
accuracy run:

```bash
docker --version
docker info
HUMANEVAL_IMAGE=$(python3 -c 'import json; print(json.load(open("configs/pins/humaneval-runtime.json"))["repo_digest"])')
docker pull "$HUMANEVAL_IMAGE"
docker tag "$HUMANEVAL_IMAGE" python:3.12-slim
test "$(docker inspect python:3.12-slim --format '{{index .RepoDigests 0}}')" = "$HUMANEVAL_IMAGE"
```

The evaluated repository digest is recorded exactly in
[configs/pins/humaneval-runtime.json](configs/pins/humaneval-runtime.json) as
`python@sha256:57cd7c3a…710de`; use the full value from that file, never the abbreviated
display here. The tag moved after the evaluation, so a current `python:3.12-slim` pull is
not equivalent. Run HumanEval and its protocol-v6 audit with the recorded digest identity.

Codex CLI is not required. It was an implementation agent, not a fetch, build, benchmark,
or serving dependency.

## 4. Fetch and verify pinned inputs

Fetch as `dsv4` where artifacts belong to its home; fetch the repository-owned Unsloth
GGUF, encoder, and evalsets as the repository owner:

```bash
cd "$DSV4_REPO"
./scripts/12_fetch_gguf.sh
sudo -u dsv4 -H ./scripts/10_fetch_ds4.sh
./scripts/14_fetch_encoder.sh
.venv-harness/bin/python ./scripts/16_fetch_evalsets.py
```

`scripts/12_fetch_gguf.sh` places the three-shard Unsloth GGUF and
`manifest.json` under `weights/unsloth-ud-q2_k_xl/`. `scripts/10_fetch_ds4.sh`
checks out the pinned ds4 engine and puts its base, MTP, and drafter weights plus
`manifest.json` under `/home/dsv4/ds4-project/`. The engine and artifact pins are in
[configs/versions.lock](configs/versions.lock) and [configs/pins/](configs/pins/).

Fetches go to partial files, verify pinned byte counts and SHA-256 before atomic
installation, and remove mismatches. Evalset Parquet inputs use the same SHA-256 model;
the converted JSONL hashes and dataset revisions land in
[evalsets/pins.json](evalsets/pins.json). The encoder is the documented exception:
[configs/pins/official-encoding.json](configs/pins/official-encoding.json) pins its
revision, byte counts, and Git blob SHA-1 OIDs, which `scripts/14_fetch_encoder.sh`
verifies with `git hash-object`.

Recheck without downloading:

```bash
./scripts/12_fetch_gguf.sh --verify-only
sudo -u dsv4 -H ./scripts/10_fetch_ds4.sh --verify-only
./scripts/14_fetch_encoder.sh --verify-only
```

`scripts/16_fetch_evalsets.py` has no verify-only flag; rerunning it verifies pinned
Parquet inputs and deterministically regenerates JSONL plus `evalsets/pins.json`.

## 5. Build both engines

Build as `dsv4`:

```bash
cd "$DSV4_REPO"
sudo -u dsv4 -H ./scripts/11_build_ds4.sh
sudo -u dsv4 -H ./scripts/13_build_llamacpp.sh
```

Both scripts require aarch64, CUDA 13, and `sm_121`. The ds4 build requires its checked-out
source to match the pinned commit and have a clean worktree. The llama.cpp builder checks
out the pinned commit itself and then enforces the same clean-worktree condition. They
verify CUDA architecture and smoke-test the binaries.

The live build manifests are `/home/dsv4/ds4-project/build-manifest.json` and
`/home/dsv4/llamacpp-project/build-manifest.json`; fetched weight manifests are beside the
weights. [configs/build-manifests/](configs/build-manifests/) contains the committed copies
that identify the evaluated binaries and ds4 weights. Accuracy commands bind the run to
these JSON documents with `--config-evidence`; llama.cpp additionally uses its fetched
`weights/unsloth-ud-q2_k_xl/manifest.json`.

## 6. Serve one candidate at a time

Always use the wrappers as `dsv4`:

```bash
sudo -u dsv4 -H ./scripts/20_serve_ds4.sh start --profile dspark --full-verify
sudo -u dsv4 -H ./scripts/20_serve_ds4.sh status
sudo -u dsv4 -H ./scripts/20_serve_ds4.sh stop
```

```bash
sudo -u dsv4 -H env API_KEY_FILE=/home/dsv4/.config/deepseek-v4-flash/api-key ./scripts/21_serve_llamacpp.sh start
sudo -u dsv4 -H ./scripts/21_serve_llamacpp.sh status
sudo -u dsv4 -H ./scripts/21_serve_llamacpp.sh stop
```

The llama.cpp engine has native bearer-token auth. This evaluation served it with a
gate-phase key (0600, owned by `dsv4`; create one with `openssl rand -hex 32` written to
`/home/dsv4/.config/deepseek-v4-flash/api-key` as `dsv4`, and grant your benchmarking user
read access with an ACL). Every documented llama.cpp gate command in section 7 includes
`--api-key-file /home/dsv4/.config/deepseek-v4-flash/api-key`. The ds4 engine has no native
auth, so its gate commands take no key. Production installs the selected engine behind the
authenticating proxy from section 8; the current product selection is llama.cpp.

Do not start both. Both wrappers hold `/run/dsv4/inference.lock` with `flock`; contention
fails rather than creating two resident models. They check binary/model manifests and a
16 GiB projected-free-memory floor, start the 12 GiB watchdog before the engine, publish
PID/start-time/boot-ID state under `/run/dsv4`, and wait up to 600 seconds for readiness.
Observed cold readiness is about five to seven minutes. State files are
`/run/dsv4/ds4.state.json` and `/run/dsv4/llamacpp.state.json`. Logs are under
`/home/dsv4/logs/`.

## 7. Run the frozen gates

First verify the frozen implementation and protocol bytes:

```bash
sha256sum -c verification/MANIFEST.sha256
```

Run gates as the repository owner against only the currently resident candidate. The commands below
are the evaluated labels, ports, thinking-mode controls, result paths, and flags. Re-run
the manifest check immediately before each candidate's gate sequence.

For ds4 on port 8012:

```bash
.venv-harness/bin/python scripts/32_golden_tests.py --base-url http://127.0.0.1:8012 --out results/golden-ds4-dspark.json --stack-label ds4-dspark --extra-body '{"enable_thinking":false}'
.venv-harness/bin/python scripts/33_token_parity.py --backend ds4 --out /tmp/parity-ds4-pending.json --ds4-cli /home/dsv4/ds4-project/src/ds4/ds4 --ds4-model /home/dsv4/ds4-project/gguf/DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix.gguf || test $? -eq 2
.venv-harness/bin/python -c 'import json; print(json.load(open("/tmp/parity-ds4-pending.json"))["ds4_token_dump_command"])' | sudo -u dsv4 -H bash
.venv-harness/bin/python scripts/33_token_parity.py --backend ds4 --out results/parity-ds4.json --ds4-token-dump /tmp/parity-ds4-pending.json.ds4-token-dump.txt --ds4-cli /home/dsv4/ds4-project/src/ds4/ds4 --ds4-model /home/dsv4/ds4-project/gguf/DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix.gguf
.venv-harness/bin/python scripts/30_bench_speed.py --base-url http://127.0.0.1:8012 --out results/speed-ds4-dspark.json --stack-label ds4-dspark --reps 5 --warmup 1 --extra-body '{"enable_thinking":false}'
```

For llama.cpp on port 8011:

```bash
.venv-harness/bin/python scripts/32_golden_tests.py --base-url http://127.0.0.1:8011 --api-key-file /home/dsv4/.config/deepseek-v4-flash/api-key --out results/golden-llamacpp.json --stack-label llamacpp-udq2kxl --extra-body '{"chat_template_kwargs":{"enable_thinking":false}}'
.venv-harness/bin/python scripts/33_token_parity.py --backend llamacpp --base-url http://127.0.0.1:8011 --api-key-file /home/dsv4/.config/deepseek-v4-flash/api-key --out results/parity-llamacpp.json
.venv-harness/bin/python scripts/30_bench_speed.py --base-url http://127.0.0.1:8011 --api-key-file /home/dsv4/.config/deepseek-v4-flash/api-key --out results/speed-llamacpp.json --stack-label llamacpp-udq2kxl --reps 5 --warmup 1 --ignore-eos-supported --extra-body '{"chat_template_kwargs":{"enable_thinking":false}}'
```

Run all accuracy suites for ds4:

```bash
.venv-harness/bin/python scripts/31_bench_accuracy.py --base-url http://127.0.0.1:8012 --out results/acc-gsm8k-dev-ds4.json --stack-label ds4-dspark --extra-body '{"enable_thinking":false}' --suite gsm8k --split dev --transcripts-dir results/transcripts/gsm8k-dev-ds4 --config-hash ds4-baa88902-dspark-ctx32768-nothink-v1 --config-evidence configs/build-manifests/ds4.json configs/build-manifests/ds4-weights.json
.venv-harness/bin/python scripts/31_bench_accuracy.py --base-url http://127.0.0.1:8012 --out results/acc-gsm8k-holdout-ds4.json --stack-label ds4-dspark --extra-body '{"enable_thinking":false}' --suite gsm8k --split holdout --transcripts-dir results/transcripts/gsm8k-holdout-ds4 --config-hash ds4-baa88902-dspark-ctx32768-nothink-v1 --config-evidence configs/build-manifests/ds4.json configs/build-manifests/ds4-weights.json
.venv-harness/bin/python scripts/31_bench_accuracy.py --base-url http://127.0.0.1:8012 --out results/acc-mmlu-dev-ds4.json --stack-label ds4-dspark --extra-body '{"enable_thinking":false}' --suite mmlu-pro --split dev --transcripts-dir results/transcripts/mmlu-dev-ds4 --config-hash ds4-baa88902-dspark-ctx32768-nothink-v1 --config-evidence configs/build-manifests/ds4.json configs/build-manifests/ds4-weights.json
.venv-harness/bin/python scripts/31_bench_accuracy.py --base-url http://127.0.0.1:8012 --out results/acc-mmlu-holdout-ds4.json --stack-label ds4-dspark --extra-body '{"enable_thinking":false}' --suite mmlu-pro --split holdout --transcripts-dir results/transcripts/mmlu-holdout-ds4 --config-hash ds4-baa88902-dspark-ctx32768-nothink-v1 --config-evidence configs/build-manifests/ds4.json configs/build-manifests/ds4-weights.json
.venv-harness/bin/python scripts/31_bench_accuracy.py --base-url http://127.0.0.1:8012 --out results/acc-humaneval-ds4.json --stack-label ds4-dspark --extra-body '{"enable_thinking":false}' --suite humaneval --split all --transcripts-dir results/transcripts/humaneval-ds4 --config-hash ds4-baa88902-dspark-ctx32768-nothink-v1 --config-evidence configs/build-manifests/ds4.json configs/build-manifests/ds4-weights.json
```

Run all accuracy suites for llama.cpp:

```bash
.venv-harness/bin/python scripts/31_bench_accuracy.py --base-url http://127.0.0.1:8011 --api-key-file /home/dsv4/.config/deepseek-v4-flash/api-key --out results/acc-gsm8k-dev-llamacpp.json --stack-label llamacpp-udq2kxl --extra-body '{"chat_template_kwargs":{"enable_thinking":false}}' --suite gsm8k --split dev --transcripts-dir results/transcripts/gsm8k-dev-llamacpp --config-hash llamacpp-32e789fd-udq2kxl-ctx32768-nothink-v1 --config-evidence configs/build-manifests/llamacpp.json weights/unsloth-ud-q2_k_xl/manifest.json
.venv-harness/bin/python scripts/31_bench_accuracy.py --base-url http://127.0.0.1:8011 --api-key-file /home/dsv4/.config/deepseek-v4-flash/api-key --out results/acc-gsm8k-holdout-llamacpp.json --stack-label llamacpp-udq2kxl --extra-body '{"chat_template_kwargs":{"enable_thinking":false}}' --suite gsm8k --split holdout --transcripts-dir results/transcripts/gsm8k-holdout-llamacpp --config-hash llamacpp-32e789fd-udq2kxl-ctx32768-nothink-v1 --config-evidence configs/build-manifests/llamacpp.json weights/unsloth-ud-q2_k_xl/manifest.json
.venv-harness/bin/python scripts/31_bench_accuracy.py --base-url http://127.0.0.1:8011 --api-key-file /home/dsv4/.config/deepseek-v4-flash/api-key --out results/acc-mmlu-dev-llamacpp.json --stack-label llamacpp-udq2kxl --extra-body '{"chat_template_kwargs":{"enable_thinking":false}}' --suite mmlu-pro --split dev --transcripts-dir results/transcripts/mmlu-dev-llamacpp --config-hash llamacpp-32e789fd-udq2kxl-ctx32768-nothink-v1 --config-evidence configs/build-manifests/llamacpp.json weights/unsloth-ud-q2_k_xl/manifest.json
.venv-harness/bin/python scripts/31_bench_accuracy.py --base-url http://127.0.0.1:8011 --api-key-file /home/dsv4/.config/deepseek-v4-flash/api-key --out results/acc-mmlu-holdout-llamacpp.json --stack-label llamacpp-udq2kxl --extra-body '{"chat_template_kwargs":{"enable_thinking":false}}' --suite mmlu-pro --split holdout --transcripts-dir results/transcripts/mmlu-holdout-llamacpp --config-hash llamacpp-32e789fd-udq2kxl-ctx32768-nothink-v1 --config-evidence configs/build-manifests/llamacpp.json weights/unsloth-ud-q2_k_xl/manifest.json
.venv-harness/bin/python scripts/31_bench_accuracy.py --base-url http://127.0.0.1:8011 --api-key-file /home/dsv4/.config/deepseek-v4-flash/api-key --out results/acc-humaneval-llamacpp.json --stack-label llamacpp-udq2kxl --extra-body '{"chat_template_kwargs":{"enable_thinking":false}}' --suite humaneval --split all --transcripts-dir results/transcripts/humaneval-llamacpp --config-hash llamacpp-32e789fd-udq2kxl-ctx32768-nothink-v1 --config-evidence configs/build-manifests/llamacpp.json weights/unsloth-ud-q2_k_xl/manifest.json
```

The holdout ledger is [results/holdout-ledger.json](results/holdout-ledger.json). Under
protocol v2 and later, the harness derives a digest from stack label, server binary,
weight evidence, suite/split, generation controls, and frozen harness hash. It atomically
records `started` before the first holdout request and refuses either a prior `started` or
`completed` entry for the same digest. This is once-only protection under honest operation,
not protection from the repository owner. Read [PROTOCOL.md](PROTOCOL.md) before any run:
changing a gate or scoring rule requires a protocol version entry and symmetric reruns.

### Clean-room reproduction and the holdout witness

A fresh reproducer must generate config evidence from their own built binary and fetched
weights rather than copying the evaluated host's live manifests. Those binary/weight hashes
produce a different config-digest identity, so the committed once-only ledger does not block
their independent holdout. If the hashes are identical, it is the same frozen identity and
the ledger correctly refuses another query.

Do not re-query the endpoint to “verify” this repository's published holdout numbers. Verify
them offline from the committed transcripts with `scripts/36_audit_accuracy.py`: protocol v6
reconstructs pinned rows and split indices, re-renders prompt hashes, re-scores GSM8K and
MMLU-Pro, re-extracts and sandbox-executes all HumanEval completions, and binds the results
and transcript tree. Editing or deleting the committed ledger voids its public-history
witness, even if replacement result files happen to contain the same summary numbers.

The soak duration and thresholds are constants, not CLI options. Run each while its stack
is resident:

```bash
.venv-harness/bin/python scripts/35_soak.py --base-url http://127.0.0.1:8012 --stack-label ds4 --config-hash ds4-baa88902-dspark-ctx32768-nothink-v1 --out results/soak-ds4.json --extra-body '{"enable_thinking":false}'
.venv-harness/bin/python scripts/35_soak.py --base-url http://127.0.0.1:8011 --api-key-file /home/dsv4/.config/deepseek-v4-flash/api-key --stack-label llamacpp --config-hash llamacpp-32e789fd-udq2kxl-ctx32768-nothink-v1 --out results/soak-llamacpp.json --extra-body '{"chat_template_kwargs":{"enable_thinking":false}}'
```

Each is a frozen 1,800-second sustained-load test with raw request, health, and per-second
memory evidence. After all accuracy artifacts exist, audit every transcript; each command
writes `results/audit-<stack>.json`:

```bash
.venv-harness/bin/python scripts/36_audit_accuracy.py --stack ds4
.venv-harness/bin/python scripts/36_audit_accuracy.py --stack llamacpp
```

Finally generate the mechanical decision. It fails closed if either candidate lacks required
evidence and reproduces `results/decision.json` plus `results/DECISION.md`:

```bash
.venv-harness/bin/python scripts/34_decision.py --soak-evidence ds4=results/soak-ds4.json,llamacpp=results/soak-llamacpp.json --audit-evidence ds4=results/audit-ds4.json,llamacpp=results/audit-llamacpp.json
```

## 8. Install the product override in production

The frozen benchmark verdict is ds4 for the measured ≤28K workload, and that record stands.
Brian's [product override](results/DECISION-OVERRIDE.md) selects llama.cpp for production
because the 1M-context roadmap is outside ds4's measured envelope; ds4 is parked. As root,
create the separate no-login `dsv4auth` identity, remove the repository owner from the
`dsv4` group, restrict the key directory, install pinned Caddy, and install llama.cpp:

```bash
cd "$DSV4_REPO"
sudo env DSV4_REPO="$DSV4_REPO" bash setup/04-production-hardening.sh
sudo apt-get update
sudo apt-get install -y caddy=2.6.2-6ubuntu0.24.04.3+esm2
```

The installer requires Caddy 2.6.2 and substitutes `DSV4_REPO` into the tracked unit
templates. Install the production stack named by the override:

```bash
sudo env DSV4_REPO="$DSV4_REPO" bash scripts/41_install_service.sh llamacpp
```

The installer rotates the bearer
key by default, retains only the immediately previous key as root-only `api-key.prev`,
validates the Caddyfile, disables the losing engine and generic Caddy unit, installs and
starts the selected engine/auth/proxy/guard units, waits up to 600 seconds, verifies an
unauthenticated 401 and authenticated 200, checks that required ports are loopback-only,
requires the engine and proxy-chain ports to be loopback-only, fails if Tailscale status
cannot be read, rejects Funnel, and permits Serve proxy targets only at port 8010.

Deliver `/etc/deepseek-v4-flash/api-key` to each authorized device out of band, using a
trusted password manager or an authenticated encrypted channel; do not print it into logs,
commit it, or put it on a process command line. Then expose only the authenticated proxy:

```bash
sudo tailscale serve --bg http://127.0.0.1:8010
tailscale serve status
```

Keep Funnel off. `tailscale funnel` would make the endpoint Internet-accessible; Serve is
intended to remain tailnet-only. Never route Serve directly to 8011, 8012, or 8014.

## 9. Expected evidence

The canonical record is the committed [results/](results/) tree: golden, parity, speed,
accuracy, transcript, soak, audit, exception, preflight, ledger, decision, and override
files present there. Do not compare against numbers copied into another document. The
mechanical verdict is ds4; the production engine is llama.cpp under the documented product
override, and ds4 is the parked alternative.

## 10. Security and protocol reading

Before interpreting or publishing a result, read [PROTOCOL.md](PROTOCOL.md),
[docs/threat-model.md](docs/threat-model.md),
[docs/adversarial-review-2026-07-16.md](docs/adversarial-review-2026-07-16.md),
[docs/research-fable-2026-07-16.md](docs/research-fable-2026-07-16.md), and
[docs/research-sol-2026-07-16.md](docs/research-sol-2026-07-16.md). The threat model makes
clear that pinned hashes prove identity, not benign behavior, and that public history is
the witness against later evidence rewriting.
