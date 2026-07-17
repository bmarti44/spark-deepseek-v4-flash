#!/usr/bin/env python3
"""Protocol v5: offline deterministic re-grade of HumanEval from stored transcripts.

The v4 HumanEval runs generated completions with no stop sequences and
temperature 0 / seed 42; generation parameters are identical under v4/v5, so a
protocol-v5 re-grade only needs to re-EXTRACT and re-EXECUTE the stored
completions — no server, no residency swap. This script:

  1. loads the pinned HumanEval dataset (same pins/sha checks as 31),
  2. reads every stored transcript, binds it to its dataset row (task_id match
     AND rendered_prompt_sha256 recomputed from the pinned row),
  3. re-extracts with scripts/31's protocol-v5 extract_humaneval_code and
     re-executes in the same locked-down docker sandbox (run_humaneval),
  4. rewrites the transcripts and the acc-humaneval-<stack>.json summary IN
     PLACE (git history preserves the v4 originals), with a `rescore` block
     recording provenance.

Usage: 37_rescore_humaneval.py --stack {ds4,llamacpp}
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import sys
import tempfile
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parent.parent

INVALID_REASON_PREFIXES = (
    "invalid:",
    "unparseable:",
    "sandbox timeout",
    "sandbox host timeout",
    "sandbox launch failed",
    "no anchored answer",
    "truncated without answer",
)


def load_bench() -> Any:
    path = REPO / "scripts" / "31_bench_accuracy.py"
    spec = importlib.util.spec_from_file_location("bench31", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stack", required=True, choices=("ds4", "llamacpp"))
    args = parser.parse_args()

    bench = load_bench()
    summary_path = REPO / "results" / f"acc-humaneval-{args.stack}.json"
    summary_bytes = summary_path.read_bytes()
    summary = json.loads(summary_bytes)
    if summary.get("suite") != "humaneval":
        raise RuntimeError(f"{summary_path} is not a humaneval summary")
    transcript_dir = Path(summary["transcript_dir"])
    if not transcript_dir.is_dir():
        raise RuntimeError(f"transcript dir missing: {transcript_dir}")

    pins, _revisions = bench.load_pins()
    rows = bench.load_jsonl("humaneval", pins)
    harness_line = bench.load_harness_manifest_line()

    transcript_paths = sorted(transcript_dir.glob("*.json"))
    if len(transcript_paths) != summary.get("n"):
        raise RuntimeError(
            f"{len(transcript_paths)} transcripts != summary n {summary.get('n')!r}"
        )

    started_at = bench.utc_now()
    correct_count = 0
    invalid_count = 0
    changed: list[dict[str, Any]] = []
    with tempfile.TemporaryDirectory(prefix="dsv4-humaneval-rescore-") as temp:
        cases_root = Path(temp)
        for run_position, path in enumerate(transcript_paths):
            source_bytes = path.read_bytes()
            transcript = json.loads(source_bytes)
            index = transcript["index"]
            row = rows[index]
            if row["task_id"] != transcript["task_id"]:
                raise RuntimeError(
                    f"{path.name}: task_id {transcript['task_id']!r} != dataset row "
                    f"{row['task_id']!r} at index {index}"
                )
            rendered, _rendering = bench.render_item("humaneval", row, None)
            prompt_sha = hashlib.sha256(rendered.encode("utf-8")).hexdigest()
            if prompt_sha != transcript["rendered_prompt_sha256"]:
                raise RuntimeError(
                    f"{path.name}: rendered_prompt_sha256 does not match the pinned "
                    "dataset row — transcript is not bound to this dataset"
                )
            previous_correct = transcript.get("scored_correct")
            previous_reason = transcript.get("reason")
            scored_correct, expected, reason, execution = bench.run_humaneval(
                row, transcript["completion"], cases_root, f"case-{run_position:05d}"
            )
            transcript["scored_correct"] = scored_correct
            transcript["expected"] = expected
            transcript["reason"] = reason
            transcript["execution"] = execution
            transcript["rescore"] = {
                "protocol_version": "v5",
                "previous_scored_correct": previous_correct,
                "previous_reason": previous_reason,
                "source_transcript_sha256": hashlib.sha256(source_bytes).hexdigest(),
                "rescored_at": bench.utc_now(),
            }
            bench.write_json(path, transcript)
            if scored_correct:
                correct_count += 1
            if reason.startswith(INVALID_REASON_PREFIXES):
                invalid_count += 1
            if scored_correct != previous_correct:
                changed.append(
                    {
                        "task_id": row["task_id"],
                        "was": previous_correct,
                        "now": scored_correct,
                        "reason": reason,
                    }
                )
            print(
                f"[{run_position + 1}/{len(transcript_paths)}] {row['task_id']} "
                f"correct={scored_correct}"
                + (f" (was {previous_correct})" if scored_correct != previous_correct else ""),
                flush=True,
            )

    finished_at = bench.utc_now()
    previous_correct_total = summary["correct"]
    summary["correct"] = correct_count
    summary["accuracy"] = correct_count / summary["n"]
    summary["wilson95"] = bench.wilson95(correct_count, summary["n"])
    summary["invalid_count"] = invalid_count
    summary["rescore"] = {
        "protocol_version": "v5",
        "method": (
            "offline re-extraction (ast.parse-validated candidates) + docker sandbox "
            "re-execution of stored v4 completions; generation untouched"
        ),
        "source_summary_sha256": hashlib.sha256(summary_bytes).hexdigest(),
        "previous_correct": previous_correct_total,
        "changed": changed,
        "harness_manifest_line": harness_line,
        "rescore_script": "scripts/37_rescore_humaneval.py",
        "started_at": started_at,
        "finished_at": finished_at,
    }
    bench.write_json(summary_path, summary)
    print(
        f"RESCORE {args.stack}: {previous_correct_total} -> {correct_count}/{summary['n']} "
        f"({summary['accuracy']:.1%}), {len(changed)} item(s) changed, "
        f"invalid_count={invalid_count}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
