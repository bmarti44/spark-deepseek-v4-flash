# Evaluation protocol versions

The adversarial review (2026-07-16) correctly found that gate definitions changed
after observing candidate failures, while being described as "frozen". This file
makes protocol versioning explicit. Protocol v8 is binding with the entry below.
Numbers used by the
decision come from the version applicable to each suite: v2 speed/golden and the
non-HumanEval accuracy suites, v4 generation plus v5 grading for HumanEval, and
v6-or-later verifier enforcement. A later verifier version does not relabel or
silently rerun the underlying measurement.

## v1 → v2 changes and why

| Change | Trigger | Fairness handling |
|---|---|---|
| golden `error_schema`: required 4xx on malformed JSON → accepts 4xx–5xx WITH a JSON error body AND a healthy follow-up probe | B (llama.cpp) returns 500 with a well-formed error object | Intent of the check is graceful failure, not a specific status code. A passes under both versions; A's golden is RERUN under v2 for a uniform record. |
| speed suite: top context cell 32256 → 28672; continuation prompt demands ≥600 words | A's engine envelope (warm >28K prompts fail; lazy session graph) and early-stop invalid reps on open-ended prompts | Both candidates' recorded speed runs used the FINAL protocol (A was rerun after the change; B only ever ran the final version). |
| MMLU-Pro scoring: last-letter fallback + 256 max_tokens → anchored `Answer: <letter>` required, `finish_reason` length without marker = invalid, max_tokens 768 | Adversarial review proved the fallback credits truncated reasoning ("I don't know" → I; 8 confirmed false credits in B's dev run) | All v1 MMLU results are VOID for both candidates. MMLU dev+holdout regenerate under v2 for both. The regeneration is a protocol correction declared before any of A's accuracy numbers existed; configs are unchanged; other suites' v1 results replayed clean and stand. |
| holdout ledger: appended at completion, caller-supplied config hash → `started` entry before first request, config digest derived from binary/weights/flags hashes | Adversarial review: interruption discloses holdout without a ledger record | Applies from v2 onward. |

## v2 → v3 changes and why (scored review of 2026-07-16, overall 38/100)

A second independent review (Codex sol high; tasks/review-2026-07-16-sol-high.md)
found the *integrity layer* gameable even though its evidence replay reproduced
every committed aggregate. v3 hardens verification WITHOUT changing any scorer,
prompt, rendering, dataset, split, or generation parameter — therefore **all v2
accuracy/speed/golden/parity results remain valid** and are not rerun.

| Change | Kind | Why it does not void v2 results |
|---|---|---|
| `34_decision.py` recomputes speed medians and soak/audit summaries from raw arrays; requires `suite_valid`; requires an accuracy-audit artifact per candidate; sole-candidate floor (composite ≥60, 4K decode ≥5 tok/s) | decision-layer, added BEFORE any decision was generated | Inputs unchanged; only how much the decision trusts them changed. |
| speed `suite_valid=false` makes a candidate ineligible unless `results/envelope-exception-<stack>.json` documents the accepted envelope | decision-layer | v2 pre-registered "4K cell is the decision metric; 28K cell = engine-envelope check". A's known warm->28K failure gets an exception file stating exactly that pre-registered scope; the exception is surfaced verbatim in DECISION.md rather than silently ignored (the review showed silence was the risk). |
| `35_soak.py` thresholds frozen as constants; caching-resistant prompt rotation; sampler/window/duration honesty gates | new tool, no soak evidence existed yet | First soak evidence is produced under v3. |
| `36_audit_accuracy.py` full-recount (every transcript), count/uniqueness checks, machine-readable pass artifact | verifier-side | Recount of unchanged transcripts; scoring identical. |
| watchdog starts before engine; memwatch fails closed; systemd preflight blocking; guard timer; auth-helper rate/concurrency limits; installer end-to-end verification | ops/security | Not part of any measurement. |
| threat model documented (docs/threat-model.md): operator-adversary is OUT of scope; public GitHub history is the witness | documentation | Scores the controls against the real setting. |

## v3 → v4 changes and why (A's HumanEval run, 2026-07-16 ~18:25 ET)

| Change | Trigger | Fairness handling |
|---|---|---|
| HumanEval generation: stop list `["\ndef ", "\nclass ", "\nif __name__", "\nprint("]` → none (generation bounded by max_tokens 512; extractor handles all styles) | A scored 0/164 with `finish_reason=stop` on EVERY item: A's quant answers each task with prose + a fenced full function re-declaration, and the `"\ndef "` stop truncated at the fence header before any body was generated. The stop list assumed base-model continuation style. | Harness defect, not a model result. HumanEval is VOID for BOTH candidates (A's 0/164 and B's v2 133/164) and reruns under v4 for both. B's rerun requires a residency swap back to B after A's remaining evidence. GSM8K and MMLU-Pro are untouched — the stop list applied only to HumanEval (`HUMANEVAL_STOPS`, used nowhere else). |

## v4 → v5 changes and why (B's HumanEval audit failure, 2026-07-16)

| Change | Trigger | Fairness handling |
|---|---|---|
| `extract_humaneval_code` validates candidates with `ast.parse` and returns the first that parses, in a fixed order: (1) every fenced block re-declaring `def <entry_point>` (standalone), (2) the prompt+continuation splice, (3) the splice of the completion truncated at the classic HumanEval stop words (`\ndef `, `\nclass `, `\nif __name__`, `\nprint(`) applied POST-HOC, (4) longest parseable line-prefix of the splice. No candidate parses → v4 behavior. | B's v4 rerun (104/164) FAILED the independent audit: 23 SyntaxError transcripts. Two extractor defects, both harness-side: (a) the fence regex paired a completion's CLOSING fence with a later fence and extracted the garbage between them; (b) completions that finish the function then ramble until `max_tokens` cuts mid-line left an unparseable tail in the splice. | Harness defect, not a model result. Generation is untouched (same prompts, temperature 0, seed 42, max_tokens 512, no stops), so stored v4 completions are re-graded OFFLINE and deterministically for BOTH candidates by `scripts/37_rescore_humaneval.py` (re-extraction + sandbox re-execution; no servers). Candidate order tries the plain splice BEFORE the stop-word cut so the post-hoc stops can only rescue otherwise-unparseable completions, never change the grade of ones that already parse. Under v5 the audit's SyntaxError taxonomy must be 0 for both stacks. |

## v5 → v6 changes and why (round-2 verifier review, 2026-07-16)

These changes harden only the decision and verifier boundary. They do not alter
any scorer, prompt, rendering, dataset, split, generation parameter, or soak
measurement, so the standing rule classifies them as non-voiding.

| Change | Kind | Why it does not void existing results |
|---|---|---|
| `36_audit_accuracy.py` loads the pinned rows through script 31, derives the exact split indices and suite sizes, verifies transcript identities and re-rendered prompt hashes, reconstructs reference answers, and rescoring GSM8K/MMLU-Pro without trusting transcript fields. | verifier-side recount hardening | Stored completions and script 31's frozen renderers/scorers are unchanged; only independent provenance checks are added. |
| The accuracy audit re-extracts and re-executes all 164 HumanEval completions in script 31's Docker sandbox, compares fresh verdicts with stored verdict fields, and builds its failure taxonomy only from fresh executions. | verifier-side execution hardening | No generation or extraction rule changes; this independently repeats the v5 offline grading. |
| Accuracy audit artifacts bind every audited `acc-*.json`, the deterministic transcript-tree digest, pinned evalset files, and script 31's current manifest entry. `34_decision.py` recomputes these bindings from current files and requires exact suite and transcript counts. | verifier/decision artifact binding | Raw evidence and scores are unchanged; stale or substituted evidence now fails closed. |
| `34_decision.py` recomputes every soak gate from raw request, error, memory, and health arrays using script 35's frozen constants; reported gates must be true and identical. Health requires a conservative minimum probe population, so an empty probe list cannot pass. | decision-layer verification hardening | Existing soak samples and frozen thresholds are unchanged; the consumer no longer trusts producer booleans. |
| Context-envelope exceptions must identify exactly the speed cells that failed and may accept only cells whose raw reps show they passed. | decision-layer exception hardening | The speed measurements and pre-registered exception policy are unchanged; the exception is now bound to its cited evidence. |
| `verification/MANIFEST.sha256` covers `configs/versions.lock`, every build manifest, pinned evalset JSONL and pins files, and all modified verifier files. Results remain outside the manifest: Git history witnesses result artifacts, while accuracy-audit binding hashes witness the current accuracy results and transcripts. | integrity-scope clarification | This expands verification coverage without changing measurement inputs or outputs. |
| `results/decision.json` is tracked alongside `results/DECISION.md` as the machine-readable decision witness. | witness completeness | The report is derived from existing evidence and does not affect any measurement. |

## v6 → v7 changes and why (round-3 review, 2026-07-17)

Every v7 change is verifier, operational, security, or reproducibility hardening.
No prompt, rendering, extraction, scoring, generation control, dataset, split,
measured speed sample, or soak threshold changes, so the existing measurements are
not voided.

| Change | Kind | Why it does not void existing results |
|---|---|---|
| The memory watchdog treats TERM/INT/HUP while an identity-verified target is published as an emergency: it SIGKILLs the verified process group first and exits nonzero. Graceful stops explicitly stop the engine, retract the target, then TERM the disarmed watchdog. A gated provisional start-group target closes the pre-engine identity window, and failed-start cleanup kills the engine group before disarming/stopping the watchdog and releasing files. | memory-safety/operations | Serving lifecycle only; benchmark definitions and stored measurements are unchanged. |
| `34_decision.py` verifies every manifest checksum in-process, separately binds the current script 31 bytes to its manifest line, cross-checks every audit recount/summary against its `acc-*.json`, binds all recorded speed identity controls and the tokenizer, and provides a no-write `--validate-evidence-only` path. | decision-layer verification hardening | It rejects substituted or stale evidence without changing any measured value or decision threshold. |
| Soak verification binds stack/config/model/max-token/extra-body identity, requires every raw timestamp to be finite, nonnegative, unique, strictly monotonic, and inside the run, and enforces the frozen 1-second memory and 30-second health spacing with ±50% tolerance. | decision-layer verification hardening | Script 35 and its frozen intervals/thresholds are unchanged; v7 validates the already-recorded raw arrays more completely. |
| Scripts 31 and 36 inspect local `python:3.12-slim` before any HumanEval sandbox execution, require its RepoDigest to equal `configs/pins/humaneval-runtime.json`, and record the resolved digest. | sandbox provenance/preflight | The recorded HumanEval executions already used this pinned digest; this makes that precondition fail-closed and explicit without changing extraction, execution, or grading. |
| The auth helper authenticates before charging the keyed-client bucket, uses a separate 30-burst/0.5-per-second rejected-auth bucket, applies a 10-second header/socket timeout, and caps connections at 128 before worker dispatch. `42_verify_exposure.sh` centralizes repeatable local-auth, Serve-route, forbidden-port, and Funnel-off checks, and script 41 invokes it. | security/operations | Production exposure and resource controls are outside benchmark measurement. |
| `DSV4_LEDGER_NAMESPACE` gives a clean-room reproducer a distinct once-only ledger identity while retaining the empty namespace for this repository. Entries record the namespace; committed entries must never be edited or deleted. The manifest also adds both source weight-pin documents and the new exposure verifier. | process integrity/reproducibility | Namespacing permits an independent witness without changing this repository's historical entries or any scoring rule. |
| The lone `llamacpp` GSM8K holdout exception is restricted to the canonical SHA-256 ``59053fc37c43` (full value frozen in configs/pins/holdout-grandfather.json)` of ledger entry zero. That holdout was carried into v2 before the v2 started-entry mechanism existed; commit `02891bcfa8e1381e035afa750644caad0ef0f1fc` introduced `results/holdout-ledger.json` and publicly witnesses the exact pre-start-record content. Any edit breaks the exception. | explicit historical exception | This narrows an existing grandfather rather than accepting new evidence; the stored completion/scoring evidence is unchanged and remains independently auditable. |
| Reproduction guidance now records the unpinned host full-upgrade limitation, observed package/driver/kernel versions, the pinned gitleaks install, namespace procedure, and mandatory exposure recheck after Tailscale changes. | documentation | Documents operational reality; no measurement changes. |

## v7 → v8 changes and why (round-4 review, 2026-07-17)

Every v8 change is verifier, operational, process-integrity, or reproducibility
hardening. No scorer, prompt, rendering, extractor, dataset, split, generation control,
recorded speed sample, soak measurement, or soak threshold changed. The existing
measurements are therefore not voided.

| Change | Kind | Why it does not void existing results |
|---|---|---|
| The watchdog disarms only after an atomic `DISARM PID PGID START_TICKS` record matches its armed identity. Missing, unreadable, mismatched, or unauthenticated target state fails closed. Every engine signal rechecks both start ticks and the published process group, while status and the systemd guard require the live watchdog, `ARMED` ready record, target record, and process identity to agree. | memory-safety/operations | Serving lifecycle and failure handling only; no benchmark request or measurement definition changed. |
| Both serve wrappers size-check selected weights against MANIFEST-frozen manifests and hash their live server binary against the committed build manifest. llama.cpp additionally supports logged full-shard verification through `DSV4_VERIFY_WEIGHTS=full`; ds4 retains its full-verification flag. | benchmark operations/evidence binding | This rejects substituted live bytes before launch without changing prompts, generation, or scoring. |
| The decision verifier independently reapplies speed-rep completion-count, tokenizer-agreement, and timing predicates, recomputes TTFT medians, accepts portable model-path suffixes, strengthens soak endpoint coverage/request/rotation checks, and validates HumanEval runtime provenance against its pin. | decision-layer verification hardening | Raw speed, soak, and audit evidence is unchanged; only the consumer's distrust and portability improved. |
| The accuracy auditor requires each holdout result to have the exact started/completed ledger pair and ordered timestamps. Only the existing content-hash-pinned grandfather may omit `started`. | process-integrity verification | This verifies the historical once-only witness and does not alter a completion or score. |
| Reproduction now uses the reproducer's generated build manifests for fresh accuracy evidence, freezes the known-good harness resolution, records DGX OS Docker installation/version, and puts authenticated, HTTPS-enabled Tailscale setup before production installation. | reproducibility/security documentation | Documentation and dependency identity only; measured evidence is untouched. |
| The installer requires explicit acknowledgement before installing a stack other than the production-selected llama.cpp, and the MANIFEST adds the gitleaks policy, harness lock, and repository weight manifest. | operations/integrity scope | Production choice enforcement and file coverage are outside benchmark measurement. |

After the batch lands, the Docker-capable operator—not the implementation sandbox—must
regenerate derived artifacts in this order:

```bash
.venv-harness/bin/python scripts/36_audit_accuracy.py --stack ds4
.venv-harness/bin/python scripts/36_audit_accuracy.py --stack llamacpp
.venv-harness/bin/python scripts/34_decision.py --soak-evidence ds4=results/soak-ds4.json,llamacpp=results/soak-llamacpp.json --audit-evidence ds4=results/audit-ds4.json,llamacpp=results/audit-llamacpp.json
```

The first two commands apply script 36's ledger-pair rule while refreshing audit bindings
and Docker provenance. Only then may script 34 consume those regenerated audits with its
new speed, soak, path, and runtime checks and refresh `results/decision.json` plus
`results/DECISION.md`. This derived-artifact sequence is not a rerun of generation or any
measured suite.

## Standing rule

Any future gate/harness change after a candidate has produced results under the
current version requires: a new version entry here, voiding of affected results
for ALL candidates, and rerun under the new version. "Frozen" means frozen per
version, enforced by verification/MANIFEST.sha256. Changes that only add
integrity checks on unchanged raw evidence (recomputation, recounting, artifact
requirements) are decision-layer hardening and do not void measurement results;
they must still be recorded here before the decision runs.
