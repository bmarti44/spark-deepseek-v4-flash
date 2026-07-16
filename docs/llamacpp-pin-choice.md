# llama.cpp pin choice (T2.1, orchestrator-performed)

**Pinned commit: `32e789fdfd598e9a1872da55ac941e4d94f030bd`** (upstream `ggml-org/llama.cpp` master, 2026-07-16).

## Why this commit

DeepSeek-V4 support merged upstream on 2026-06-29 (`8c146a836`, PR #24162). The pinned commit is the newest master at clone time and contains every V4-relevant follow-up present in upstream history:

| Commit | What it fixes/adds | Why it matters here |
|---|---|---|
| `8c146a836` | DeepSeek V4 architecture (PR #24162) | the model itself |
| `00f5442cc` | `GGML_OP_LIGHTNING_INDEXER` (PR #24231) | V4 sparse-attention indexer op |
| `024c46ae4` | fix quantized KV cache for dsv4 (PR #25202) | the "quantized-K garbage output" bug from the plan review — fixed upstream; we still run fp16 K cache at baseline out of caution |
| `2ed3c1abb` | f16 KQ masks w/ FA, remove raw_k repeats in V4 (PR #25370) | correctness/perf with flash attention |
| `33a75f41c` | DeepseekV4: reduce graph splits (PR #25702) | decode performance |
| `d1b34251b` | spec: add DFlash speculative decoding (PR #22105) | potential dev-phase speed uplift (needs a DFlash-format draft model — availability unverified) |
| `2969d6d15` | MTP speculative decoding infra (`draft-mtp`) | potential dev-phase uplift if the Unsloth GGUF retains the MTP head (unverified) |

## Baseline mitigations retained (from plan review round 1)
Single slot (`-np 1`), RAM prompt cache disabled, fp16 K cache, explicit `-c`/batch sizes. Speculative decoding stays OFF at baseline; `draft-mtp`/DFlash are dev-tuning experiments only, measured on the dev split.

## Risk note
Master-of-today can carry non-V4 regressions; accepted because (a) the SHA is frozen (no drift), (b) golden correctness tests gate before any benchmark, (c) the alternative (the bare merge commit) lacks the three correctness/perf fixes above.
