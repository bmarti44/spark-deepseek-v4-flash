# Decision

| Candidate | Eligibility | GSM8K holdout | MMLU-Pro holdout | HumanEval | Composite | 4K valid reps | 4K decode valid-only tok/s | 4K decode all numeric reps tok/s |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| ds4 | eligible | 98.00% (98/100; 95% CI 93.00–99.45%) | 70.45% (174/247; 95% CI 64.48–75.79%) | 89.63% (147/164; 95% CI 84.03–93.43%) | 86.03% | 4/5 | 18.739 | 17.004 |
| llamacpp | eligible | 97.00% (97/100; 95% CI 91.55–98.97%) | 74.09% (183/247; 95% CI 68.29–79.15%) | 73.78% (121/164; 95% CI 66.56–79.91%) | 81.62% | 5/5 | 13.882 | 13.882 |

**Verdict:** DS4

**Candidate selected:** ds4

**Rule branch:** `both_eligible_composite_delta_over_3_higher_composite_speed_at_least_10`

**Composite delta:** 4.40 percentage points, over the 3.00-point threshold.

## Operational data outside the rule

- ds4 TTFT median: 4K 5.336s; 16K 21.778s.
- llamacpp TTFT median: 4K 14.268s; 16K 57.789s.

- ds4 context envelope: warm >28K fails — see `results/speed-ds4-dspark.json`'s 28672 cell.
- llamacpp context envelope: 28K valid.

## Caveats

- Speed cells use N=5 samples.
- The decision rule uses the valid-only 4K decode median; the all-reps median includes invalid reps with numeric `decode_tok_s` and ignores nulls.
- The composite ignores prefill and TTFT.
- Holdout accuracy values are single-run holdouts.
- A sole eligible candidate must have composite >=60.0% and 4K decode >=5.0 tok/s; otherwise the frozen verdict is NO_GO.

## Context-envelope exception

### ds4

The ds4 engine (DSpark profile, commit baa88902) fails warm-server requests above ~28K prompt tokens with HTTP 500 (lazy session-graph allocation; DS4_SESSION_LAZY_GRAPH=0 was tested and rejected because eager allocation breached the memory watchdog). The speed suite records this as 5/5 invalid reps in the 28672-token cell, so suite_valid=false. Protocol v2 pre-registered the 4K cell as the decision metric and the max-context cell as an engine-envelope check; this exception accepts the documented envelope: candidate A serves prompts up to ~28K tokens only. If A wins, the endpoint documentation MUST state this limit, and B remains the fallback for full-context workloads.

Accepted cells: `[0, 4096, 16384]`
