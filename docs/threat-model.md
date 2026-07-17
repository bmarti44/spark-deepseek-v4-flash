# Threat model

What the verification machinery in this repository does and does not defend against.
Reviewers should score the controls against this model, not against an idealized
multi-party audit regime.

## Setting

One operator (Brian) owns the hardware, the GitHub account, every credential, and the
decision. Claude (the orchestrator) plans, verifies, and commits; Codex (a second LLM
agent) implements tasks. There is no second human, no CI service, and no external
signing authority in the loop.

## Adversaries IN scope

1. **Reward-hacking implementer.** Codex-generated code that makes gates pass without
   making the thing true: weakened scorers, fabricated summaries, self-reported success.
   Controls: the frozen-harness manifest (`verification/MANIFEST.sha256`), Claude-run
   gates only (Codex self-reports never count), per-task diff review, transcript
   spot-checks, and the protocol-v6 audit in `scripts/36_audit_accuracy.py`. That audit
   reconstructs pinned rows/splits and prompt hashes, independently re-scores every
   GSM8K/MMLU-Pro transcript, re-extracts and Docker-executes every HumanEval completion,
   and binds result/transcript/evalset hashes in the artifact required by
   `scripts/34_decision.py`.
2. **Accidental evidence corruption.** Concurrent benchmark clients, stale servers,
   half-written results, config drift between what was measured and what is served.
   Controls: single-model residency lock, config digests binding results to binary+weights
   manifests, holdout ledger, decision-layer recomputation of summaries from raw arrays.
3. **Remote attackers on the served endpoint.** Key theft, auth bypass, resource
   exhaustion. Controls: Caddy sends all traffic through an authenticating streaming proxy,
   its key file is readable only by a dedicated no-login user, its token bucket and 64-slot
   cap cover the full upstream response, Authorization is stripped before the engine,
   loopback-only listeners, tailnet-only exposure with funnel off.
4. **The host freezing itself.** UMA exhaustion on this hardware is a hard freeze, so an
   honest-but-buggy engine is an adversary. Controls: static memory budget with floor,
   external watchdog that fails closed, watchdog-before-engine ordering, soak gates on
   memory headroom.

## Adversaries OUT of scope (accepted residual risk)

1. **The operator falsifying their own evidence.** The operator can rewrite git history,
   edit the ledger, re-run holdouts, or re-tune against the (public, deterministic)
   holdout selection. No local mechanism can stop the person who owns every key. The
   mitigation is *witnessing, not prevention*: evidence is pushed promptly to a public
   GitHub repository, so timestamps, hashes, and history are externally observable, and
   any later rewrite is detectable by anyone who cloned or cached it. A reviewer should
   treat "the operator could have..." findings as documentation issues (are they
   disclosed?) rather than control failures, unless the operator's claimed process is
   internally inconsistent.
2. **Compromise of the host or of GitHub itself.** Out of scope entirely.
3. **Malicious upstream weights/engines beyond pinned-hash verification.** Pinned
   revisions and SHA-256 manifests verify *identity*, not *behavior*; the ds4 engine's
   supply-chain posture is separately documented in `docs/ds4-security-review.md`.

## Standing consequences for the gates

- The manifest is a tamper-*evidence* mechanism inside one commit history, not a
  tamper-*proof* mechanism: it binds "the harness that ran" to "the bytes reviewed at
  that commit". Its guarantee is void across history rewrites — see out-of-scope #1.
- The holdout ledger enforces once-only *within honest operation*; its function is to
  make accidental double-runs impossible and deliberate ones visible in git history.
- Every gate's raw inputs (per-rep timings, memory samples, transcripts, sandbox stderr)
  are committed so that a third party can recompute every verdict offline.
