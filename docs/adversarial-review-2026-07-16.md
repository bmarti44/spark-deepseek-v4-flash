Reviewed committed snapshot `1e87d64a4ccec52c42a9799643a8761e0d79fbbf`. A live evaluation was creating untracked HumanEval and holdout artifacts during review; I excluded those results and did not inspect holdout answers.

## Prioritized findings

1. **CONFIRMED-BROKEN — “Frozen” gates were changed after observing failures.**

   The original golden requirement explicitly says malformed JSON must return 4xx, not 5xx ([tasks/08-golden-and-speed-harness.md](/home/bmarti44/spark-deepseek-v4-flash/tasks/08-golden-and-speed-harness.md:24)). Commit `78f2eab` enforced that. After B returned 500, commit `6d53758` changed the accepted range to 400–599 ([scripts/32_golden_tests.py](/home/bmarti44/spark-deepseek-v4-flash/scripts/32_golden_tests.py:561)) and updated the verification manifest. B’s result records HTTP 500 as passing ([results/golden-llamacpp.json](/home/bmarti44/spark-deepseek-v4-flash/results/golden-llamacpp.json:77)). Under the declared frozen rule, B fails golden eligibility.

   Speed was also adapted after A’s first partial run. `git show fc97ac6` shows the top context reduced from 32,256 to 28,672 specifically for A’s engine envelope and the prompt changed from “Continue this text naturally” to an instruction demanding 600 words. Before that change A had 5/5 invalid reps at 0 context, 3/5 invalid at 16K, and 5/5 failures at 32,256. Both candidates eventually received the revised test, but the protocol was selected after seeing A’s weakness.

   Fix: tag an immutable protocol before candidate execution. Any change becomes a new version and requires a clean rerun of both candidates. Never overwrite the original evidence or call the revised version frozen.

2. **CONFIRMED-BROKEN — MMLU scoring manufactures correct answers from truncated reasoning.**

   The fallback uppercases the entire completion and selects the last standalone letter A–J ([scripts/31_bench_accuracy.py](/home/bmarti44/spark-deepseek-v4-flash/scripts/31_bench_accuracy.py:68), [score implementation](/home/bmarti44/spark-deepseek-v4-flash/scripts/31_bench_accuracy.py:493)). Consequently:

   - `"I don't know"` scores correct when the expected answer is I.
   - `"Answer: Banana"` scores B.
   - Lowercase articles, variable names, and units become answer candidates.

   My exact replay reproduced the committed 164/253, proving the JSON was generated consistently—but also found:

   - 189 completions had an `Answer:` match.
   - 64 lacked one; all 64 ended with `finish_reason: "length"`.
   - Eight truncated completions were credited via fallback.
   - At least five are undeniable false positives: `I` from simple-interest notation ([00272-344.json](/home/bmarti44/spark-deepseek-v4-flash/results/transcripts/mmlu-dev-llamacpp/00272-344.json:6)), `H` from chemistry notation ([03936-4061.json](/home/bmarti44/spark-deepseek-v4-flash/results/transcripts/mmlu-dev-llamacpp/03936-4061.json:6)), `J` from joules ([04407-4539.json](/home/bmarti44/spark-deepseek-v4-flash/results/transcripts/mmlu-dev-llamacpp/04407-4539.json:6)), `D` from depth variable `d` ([09162-9351.json](/home/bmarti44/spark-deepseek-v4-flash/results/transcripts/mmlu-dev-llamacpp/09162-9351.json:6)), and `A` from prose in another truncated response.

   Therefore 64.8% is overstated. Removing only the five definite false positives gives at most 159/253 = **62.85%**. Enforcing the requested `Answer:` format gives 156/253 = **61.66%**, not 64.82%. The reported `invalid_count` of six ([result](/home/bmarti44/spark-deepseek-v4-flash/results/acc-mmlu-dev-llamacpp.json:14)) conceals the 64 length-truncated, markerless responses.

   Fix: require an anchored final answer, inspect `finish_reason`, and mark truncations without a valid final marker incorrect/invalid. Increase the token budget or use constrained label decoding, then rerun every MMLU evaluation. GSM8K’s committed 97/100 did replay cleanly; 99/100 used explicit `Answer:` and its lone fallback was incorrect.

3. **CONFIRMED-BROKEN — The once-only holdout ledger does not enforce once-only evaluation.**

   `config_hash` is merely a caller-supplied nonempty string ([scripts/31_bench_accuracy.py](/home/bmarti44/spark-deepseek-v4-flash/scripts/31_bench_accuracy.py:98)); changing it or `stack_label` bypasses the ledger key ([ledger check](/home/bmarti44/spark-deepseek-v4-flash/scripts/31_bench_accuracy.py:672)). More seriously, the ledger entry is appended only after all prompts and the result file finish ([append point](/home/bmarti44/spark-deepseek-v4-flash/scripts/31_bench_accuracy.py:835)).

   I observed this failure live: `results/holdout-ledger.json` was zero bytes while 26 holdout transcripts already existed. Interrupting the job then would disclose holdout performance but leave no record preventing a modified configuration from retrying.

   Fix: derive the configuration digest from engine binary, weights, canonical flags, harness, dataset and tokenizer hashes. Atomically append a permanent `started` entry before the first request. Store the ledger root-owned or externally, and never permit deletion or reuse after a partial run.

4. **CONFIRMED-BROKEN — The decision generator ignores A’s failed speed suite and long-context instability.**

   A’s 28,672-token cell failed 5/5 with HTTP 500 lazy-graph allocation errors ([results/speed-ds4-dspark.json](/home/bmarti44/spark-deepseek-v4-flash/results/speed-ds4-dspark.json:225)); the report correctly says `suite_valid: false` ([same file](/home/bmarti44/spark-deepseek-v4-flash/results/speed-ds4-dspark.json:277)). Yet the decision code reads only the 4K median ([scripts/34_decision.py](/home/bmarti44/spark-deepseek-v4-flash/scripts/34_decision.py:132)), and eligibility checks only golden, parity and a caller assertion named stability ([scripts/34_decision.py](/home/bmarti44/spark-deepseek-v4-flash/scripts/34_decision.py:236)).

   A can therefore win while its official speed suite is failed. The separate golden run successfully handled 29,513 prompt tokens ([results/golden-ds4-dspark.json](/home/bmarti44/spark-deepseek-v4-flash/results/golden-ds4-dspark.json:87)), demonstrating state-dependent long-context reliability: cold succeeds, warm sequential load fails.

   Fix: require `suite_valid`, warm max-context success, and a versioned soak artifact for eligibility. Bind stability to an evidence file rather than `--stability ds4=pass`. Define and enforce the actual supported context envelope.

5. **CONFIRMED-BROKEN — The security identity boundary gives community inference code the production credential.**

   Setup grants `bmarti44` passwordless execution as `dsv4` and membership in the `dsv4` group ([setup/03-dsv4-user.sh](/home/bmarti44/spark-deepseek-v4-flash/setup/03-dsv4-user.sh:24)). The installer makes the API key `root:dsv4` mode 0640 ([scripts/41_install_service.sh](/home/bmarti44/spark-deepseek-v4-flash/scripts/41_install_service.sh:33)). Both engines, Caddy and the helper run as that same user.

   `id bmarti44` confirmed membership in `dsv4`. Thus the automation account and both community engines can read the future production key. This directly contradicts the claim that untrusted GGUF parsing is contained in an account “with no credentials” ([configs/pins/ds4-weights.json](/home/bmarti44/spark-deepseek-v4-flash/configs/pins/ds4-weights.json:5)).

   Fix: remove the delegation and group membership before production. Use separate engine, proxy and key-reader identities. Prefer fronting both engines with the trusted proxy so neither inference engine needs access to the bearer key.

6. **CONFIRMED-BROKEN — Secret lint exemptions can hide the exact generated API-key format.**

   Production keys are `openssl rand -hex 32`, exactly 64 hexadecimal characters ([scripts/41_install_service.sh](/home/bmarti44/spark-deepseek-v4-flash/scripts/41_install_service.sh:37)). The full scanner recognizes 64-hex strings, but entire paths including `configs/pins/*`, `evalsets/pins.json` and `results/transcripts/*` are exempted from that rule ([scripts/lint_secrets.sh](/home/bmarti44/spark-deepseek-v4-flash/scripts/lint_secrets.sh:4), [exemptions](/home/bmarti44/spark-deepseek-v4-flash/scripts/lint_secrets.sh:9)).

   Empirical test: a synthetic 64-hex value matched the normal pattern and did not match the exempt-path pattern. `gitleaks` is not installed, so no second scanner catches it.

   Fix: validate exact checksum fields and manifest syntax rather than exempting whole directories. Allowlist known digest values or specific JSON keys, while continuing to flag unknown high-entropy 64-hex strings.

7. **LIKELY-ISSUE — The production installer is incomplete and internally inconsistent.**

   It preserves any existing key ([scripts/41_install_service.sh](/home/bmarti44/spark-deepseek-v4-flash/scripts/41_install_service.sh:37)) but tells llama clients they received a “NEW production key” ([same script](/home/bmarti44/spark-deepseek-v4-flash/scripts/41_install_service.sh:99)). It prints `tailscale serve status` but never configures the Serve target. It also does not disable the losing inference stack.

   There is no rate, request-size or concurrency limiting in the Caddy configuration ([configs/caddy/Caddyfile](/home/bmarti44/spark-deepseek-v4-flash/configs/caddy/Caddyfile:9)), despite the security audit requiring a rate-limited proxy ([docs/ds4-security-review.md](/home/bmarti44/spark-deepseek-v4-flash/docs/ds4-security-review.md:193)). A valid key can therefore drive expensive concurrent long-context requests into the memory cliff.

   Fix: rotate atomically by default, configure and verify the exact Tailscale target, disable the loser, and enforce request-size, concurrency and rate limits.

8. **LIKELY-ISSUE — Process supervision can report healthy after safety mechanisms die, and stale state can kill unrelated processes.**

   Status reports `flock_alive` and `memwatch_alive` but returns success using only server health ([scripts/21_serve_llamacpp.sh](/home/bmarti44/spark-deepseek-v4-flash/scripts/21_serve_llamacpp.sh:154)). The systemd unit is `Type=oneshot`, `RemainAfterExit=yes`, and `Restart=no` ([llama unit](/home/bmarti44/spark-deepseek-v4-flash/configs/systemd/deepseek-v4-flash-llamacpp.service:9)). A dead watchdog or server can leave systemd reporting the unit active.

   State contains bare PIDs without process start time, executable identity or boot ID ([scripts/20_serve_ds4.sh](/home/bmarti44/spark-deepseek-v4-flash/scripts/20_serve_ds4.sh:47)). Stop obtains whatever PGID currently owns the recorded PID and signals the entire group ([same script](/home/bmarti44/spark-deepseek-v4-flash/scripts/20_serve_ds4.sh:105)). PID reuse can target unrelated work.

   Fix: run the engine and watchdog as foreground systemd services in the same cgroup. Otherwise record and verify `/proc` start time, executable, UID, PGID and boot ID, and make status fail if either the lock holder or watchdog is absent.

9. **LIKELY-ISSUE — Runtime integrity is weaker than the fetch/build evidence implies.**

   llama.cpp startup checks only that shards are readable and nonsymlinks ([scripts/21_serve_llamacpp.sh](/home/bmarti44/spark-deepseek-v4-flash/scripts/21_serve_llamacpp.sh:216)); it does not verify the binary or model hashes even though the build script creates a binary manifest. DS4 hashes its binary against a manifest but hashes models only with optional `--full-verify` ([scripts/20_serve_ds4.sh](/home/bmarti44/spark-deepseek-v4-flash/scripts/20_serve_ds4.sh:22)). Its engine, binary and manifests share the writable `/home/dsv4` trust domain.

   Fix: install binaries, weights and manifests root-owned/read-only, verify all hashes at service start, and give the engine write access only to logs and volatile state.

10. **LIKELY-ISSUE — Speed reporting has measurable survivor bias and inadequate sampling.**

   A’s valid-only 4K median is 18.739 tok/s. Including the excluded 96-token rep’s measured 15.843 tok/s yields a median of **17.004 tok/s**, so the published headline is inflated by **10.2%**. Its valid 4K samples span 16.57–20.91 with IQR 3.689 ([results/speed-ds4-dspark.json](/home/bmarti44/spark-deepseek-v4-flash/results/speed-ds4-dspark.json:101)); B’s 4K IQR is only 0.0109 ([results/speed-llamacpp.json](/home/bmarti44/spark-deepseek-v4-flash/results/speed-llamacpp.json:146)).

   The exclusion is mechanical, not manually cherry-picked, and it does not reverse the conclusion: all-rep A is still about 22.5% faster than B at 4K. But N=5, with only four A survivors, is not a stable production estimate.

   Fix: force a common output length through supported constrained generation, report both all-observed and valid-only statistics, use representative paired prompts, and increase repetitions with bootstrap intervals.

11. **LIKELY-ISSUE — Accuracy tests bypass the actual production chat-rendering path.**

   The harness uses the official encoder in non-thinking mode ([scripts/31_bench_accuracy.py](/home/bmarti44/spark-deepseek-v4-flash/scripts/31_bench_accuracy.py:335)) and sends the rendered string to `/v1/completions` ([same file](/home/bmarti44/spark-deepseek-v4-flash/scripts/31_bench_accuracy.py:402)). Production clients will use `/v1/chat/completions`, whose backend template and default thinking behavior are not exercised.

   The six parity probes tokenize already-rendered official strings ([scripts/33_token_parity.py](/home/bmarti44/spark-deepseek-v4-flash/scripts/33_token_parity.py:149)); they prove sampled tokenizer-ID equality, not that each server’s chat-template path renders the same text. DS4’s smoke evidence says chat thinking is on by default ([results/smoke-ds4.json](/home/bmarti44/spark-deepseek-v4-flash/results/smoke-ds4.json:5)), while production does not freeze the evaluated non-thinking mode.

   Fix: evaluate the exact production endpoint and request body. Bind the result to binary, model and service-config hashes, and extend parity across long, multi-turn, Unicode and tool-like conversations.

12. **IMPROVEMENT — The decision rule ignores uncertainty, prefill latency and workload envelope.**

   Composite is an unweighted average of three small, differently sized suites ([scripts/34_decision.py](/home/bmarti44/spark-deepseek-v4-flash/scripts/34_decision.py:225)). The 3-point switch rule ignores its own Wilson intervals. B’s MMLU dev interval is 58.8–70.4%, far wider than three points.

   It also ignores TTFT/prefill. At about 29.5K prompt tokens, A’s golden TTFT was 37.3 seconds versus B’s 113.4 seconds ([A](/home/bmarti44/spark-deepseek-v4-flash/results/golden-ds4-dspark.json:92), [B](/home/bmarti44/spark-deepseek-v4-flash/results/golden-llamacpp.json:96)). That is operationally material even though it happens to favor the already faster candidate.

   Fix: use paired confidence intervals or bootstrap comparisons, predeclare weights, and include TTFT, end-to-end latency and maximum warm context in the rule.

13. **OBSERVATION — The 10→6 GiB overhead changes do not look like pure gate gaming, but the safety model is incomplete.**

   Recomputing from published baselines and actual weight sizes:

   - llama: overhead 10 projects 13.29 GiB free and fails; overhead 6 projects 17.29 GiB. Observed steady free was 23.3 GiB.
   - DS4: overhead 10 projects 13.94 GiB and fails; overhead 6 projects 17.94 GiB. Observed steady free was 19.3 GiB.

   Six GiB is conservative for observed steady state. The 12 GiB watchdog is also reachable—7.3 GiB below DS4 steady and 11.3 GiB below llama—not mathematically useless. The unresolved risk is a one-second polling interval against abrupt UMA allocations ([scripts/01_memwatch.sh](/home/bmarti44/spark-deepseek-v4-flash/scripts/01_memwatch.sh:5)) and a budget that does not account for the lazy graph allocation that actually broke A’s warm long-context run.

   Fix: measure peak transient memory across the full workload, choose headroom from that peak, and use kernel/cgroup enforcement where UMA accounting permits it.

14. **IMPROVEMENT — Reproducibility and production integration are unfinished.**

   The critical engine and weight inputs are SHA/revision pinned—this part is good. But [README.md](/home/bmarti44/spark-deepseek-v4-flash/README.md:5) still says work in progress and every operational section is TODO; [configs/versions.lock](/home/bmarti44/spark-deepseek-v4-flash/configs/versions.lock:26) has no artifacts; production units hardcode `/home/bmarti44`; and setup does not reproduce the manually added home-directory ACL needed by `dsv4`.

   `sha256sum -c verification/MANIFEST.sha256` passed, but the manifest contains only 15 harness files and excludes result JSON, transcripts, production configs and service scripts. At review time Caddy was absent and probes to ports 8010/8011/8012/8014 all returned curl rc 7/HTTP 000, so no end-to-end production path could be tested.

   Fix: create a signed release evidence manifest covering all inputs/results/configs, parameterize installation paths, complete the runbook, and test authentication, SSE, long context, restart, key rotation, rate limiting and watchdog recovery through the real Tailscale/Caddy route.

## Lower-confidence suspicions

- **LIKELY-ISSUE:** The pseudo-prose fixture may depress A’s speculative-draft acceptance relative to real chat/code workloads. A’s natural smoke prompt reported 0.69 acceptance, but the speed suite records no acceptance metric. This is plausible, not proven.
- **OBSERVATION:** Thermal counterbalancing is absent, but the runs were only about 30 minutes apart. B began warmer—62°C versus A’s 53°C—with the same reported 2418 MHz clock, so the available evidence does not support thermal state explaining A’s lead.
- **OBSERVATION:** Simple prefix-cache contamination is unlikely: the harness places a unique 32-token preamble at the start of every prompt. The result should still record cached-token counts to prove it.

## Verdict

**NO-GO: do not productionize or declare a winner from this evidence.**

The committed arithmetic and transcript provenance are mostly honest: I reproduced the dev selection exactly, found zero prompt-hash or response/completion mismatches, reproduced GSM8K 97/100 and the current MMLU scorer’s 164/253, and recomputed the speed medians. I found no evidence that results were fabricated.

At the time of this review the methodology was not sound enough: the supposedly frozen gates had been modified after failures, MMLU was materially over-scored, holdout secrecy was bypassable, A’s 5/5 long-context failure was ignored by the decision rule, and the credential/process isolation was not production-grade. The then-current decision command correctly failed closed because all six required final accuracy inputs were absent. The later protocol-v6 evidence and audit addressed these findings and produced the ds4 benchmark verdict recorded in `results/DECISION.md`; Brian's separate product override selected llama.cpp for production.

Current evidence says A is faster and dramatically better at prefill but warm-long-context unreliable; B is slower and more robust in the speed suite, but fails the original golden rule and has overstated MMLU accuracy. Neither is presently production-approved.
