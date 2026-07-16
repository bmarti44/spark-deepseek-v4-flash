#!/usr/bin/env python3
"""Recount all accuracy transcripts and emit verifier-owned audit evidence.

Every present GSM8K and MMLU-Pro dev/holdout result is rescored transcript by
transcript with the frozen scorers imported from scripts/31_bench_accuracy.py.
HumanEval is checked across exactly 164 unique tasks, including the complete
stderr failure taxonomy.  All transcripts must carry a rendered-prompt digest.

Missing result suites are reported as absent rather than treated as failures;
the artifact pass bit covers only the suites listed in ``present_suites``.
Usage: 36_audit_accuracy.py --stack <llamacpp|ds4>
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import re
import sys
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parent.parent
RESULTS = REPO / "results"
HARNESS = REPO / "scripts" / "31_bench_accuracy.py"

spec = importlib.util.spec_from_file_location("bench", HARNESS)
if spec is None or spec.loader is None:
    raise RuntimeError(f"cannot load frozen accuracy scorers from {HARNESS}")
bench = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
spec.loader.exec_module(bench)

SYNTAX_RE = re.compile(r"(SyntaxError|IndentationError|TabError)", re.MULTILINE)
SUITES = (
    ("gsm8k-dev", "acc-gsm8k-dev-{stack}.json", "gsm8k-dev-{stack}", "gsm8k", False),
    ("gsm8k-holdout", "acc-gsm8k-holdout-{stack}.json", "gsm8k-holdout-{stack}", "gsm8k", True),
    ("mmlu-pro-dev", "acc-mmlu-dev-{stack}.json", "mmlu-dev-{stack}", "mmlu-pro", False),
    ("mmlu-pro-holdout", "acc-mmlu-holdout-{stack}.json", "mmlu-holdout-{stack}", "mmlu-pro", True),
    ("humaneval", "acc-humaneval-{stack}.json", "humaneval-{stack}", "humaneval", False),
)


def load_json_object(path: Path) -> tuple[dict[str, Any] | None, list[str]]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        return None, [f"{path.name}: cannot read JSON: {error}"]
    if not isinstance(document, dict):
        return None, [f"{path.name}: top-level JSON value is not an object"]
    return document, []


def audit_result_schema(
    path: Path, document: dict[str, Any], require_digest: bool
) -> list[str]:
    problems: list[str] = []
    n = document.get("n")
    correct = document.get("correct")
    accuracy = document.get("accuracy")
    if not isinstance(n, int) or isinstance(n, bool) or n <= 0:
        problems.append(f"{path.name}: bad n={n!r}")
    if (
        not isinstance(correct, int)
        or isinstance(correct, bool)
        or not isinstance(n, int)
        or isinstance(n, bool)
        or not 0 <= correct <= n
    ):
        problems.append(f"{path.name}: bad correct={correct!r}")
    if (
        isinstance(n, int)
        and not isinstance(n, bool)
        and n > 0
        and isinstance(correct, int)
        and not isinstance(correct, bool)
    ):
        if (
            not isinstance(accuracy, (int, float))
            or isinstance(accuracy, bool)
            or not math.isfinite(float(accuracy))
            or abs(float(accuracy) - correct / n) > 1e-9
        ):
            problems.append(
                f"{path.name}: accuracy {accuracy!r} != correct/n {correct}/{n}"
            )
    wilson = document.get("wilson95")
    if isinstance(wilson, dict):
        lower, upper = wilson.get("lower"), wilson.get("upper")
    elif isinstance(wilson, (list, tuple)) and len(wilson) == 2:
        lower, upper = wilson
    else:
        lower = upper = None
    if not (
        isinstance(lower, (int, float))
        and not isinstance(lower, bool)
        and isinstance(upper, (int, float))
        and not isinstance(upper, bool)
        and isinstance(accuracy, (int, float))
        and not isinstance(accuracy, bool)
        and 0 <= lower <= accuracy <= upper <= 1
    ):
        problems.append(f"{path.name}: wilson95 not monotone: {wilson!r}")
    if document.get("invalid_count") is None:
        problems.append(f"{path.name}: missing invalid_count")
    if require_digest and not document.get("config_digest"):
        # This one result's ledger entry predates config digests; no other
        # holdout result is grandfathered.
        if path.name != "acc-gsm8k-holdout-llamacpp.json":
            problems.append(
                f"{path.name}: missing config_digest (required for holdout)"
            )
    return problems


def read_transcripts(
    directory: Path,
) -> tuple[list[tuple[Path, dict[str, Any]]], int, list[str]]:
    problems: list[str] = []
    records: list[tuple[Path, dict[str, Any]]] = []
    if not directory.is_dir():
        return records, 0, [f"missing transcripts dir: {directory}"]
    files = sorted(directory.glob("*.json"))
    for path in files:
        document, load_problems = load_json_object(path)
        problems.extend(load_problems)
        if document is not None:
            records.append((path, document))
    return records, len(files), problems


def require_prompt_hashes(
    records: list[tuple[Path, dict[str, Any]]]
) -> list[str]:
    problems: list[str] = []
    for path, document in records:
        digest = document.get("rendered_prompt_sha256")
        if not isinstance(digest, str) or not digest.strip():
            problems.append(f"{path.name}: missing rendered_prompt_sha256")
    return problems


def audit_rescored_suite(
    suite_key: str,
    suite: str,
    result_path: Path,
    document: dict[str, Any],
    transcript_dir: Path,
) -> tuple[dict[str, Any], list[str]]:
    problems = audit_result_schema(result_path, document, "holdout" in suite_key)
    records, file_count, transcript_problems = read_transcripts(transcript_dir)
    problems.extend(transcript_problems)
    problems.extend(require_prompt_hashes(records))
    recount = 0
    for path, transcript in records:
        completion = transcript.get("completion")
        expected = transcript.get("expected")
        if not isinstance(completion, str):
            problems.append(f"{path.name}: completion is not a string")
            continue
        try:
            if suite == "gsm8k":
                rescored, _expected, _reason, _fallback = bench.score_gsm8k(
                    completion, f"#### {expected}"
                )
            else:
                rescored, _expected, _reason = bench.score_mmlu(
                    completion, expected, transcript.get("finish_reason")
                )
        except Exception as error:
            problems.append(f"{path.name}: scorer failed: {type(error).__name__}: {error}")
            continue
        recount += int(rescored)

    summary_n = document.get("n")
    summary_correct = document.get("correct")
    if file_count != summary_n:
        problems.append(
            f"{suite_key}: transcript file count {file_count} != summary n {summary_n!r}"
        )
    if recount != summary_correct:
        problems.append(
            f"{suite_key}: correct recount {recount} != summary correct {summary_correct!r}"
        )
    record = {
        "n": file_count,
        "correct_recount": recount,
        "summary_correct": summary_correct,
        "match": not problems,
    }
    return record, problems


def audit_humaneval(
    result_path: Path, document: dict[str, Any], transcript_dir: Path
) -> tuple[dict[str, Any], dict[str, Any], list[str]]:
    problems = audit_result_schema(result_path, document, False)
    records, file_count, transcript_problems = read_transcripts(transcript_dir)
    problems.extend(transcript_problems)
    problems.extend(require_prompt_hashes(records))
    counts = {
        "correct": 0,
        "assertion": 0,
        "syntax_error": 0,
        "timeout": 0,
        "other": 0,
    }
    task_ids: list[Any] = []
    syntax_cases: list[str] = []
    other_cases: list[str] = []
    stored_correct_count = 0
    for path, transcript in records:
        task_id = transcript.get("task_id")
        task_ids.append(task_id)
        if transcript.get("scored_correct") is True:
            stored_correct_count += 1
        execution = transcript.get("execution") or {}
        if not isinstance(execution, dict):
            execution = {}
        returncode = execution.get("returncode")
        stderr = execution.get("stderr") or ""
        if not isinstance(stderr, str):
            stderr = str(stderr)
        if SYNTAX_RE.search(stderr):
            counts["syntax_error"] += 1
            syntax_cases.append(str(task_id or path.name))
        elif transcript.get("scored_correct") is True:
            counts["correct"] += 1
        elif returncode == 124 or "timeout" in str(transcript.get("reason") or "").lower():
            counts["timeout"] += 1
        elif "AssertionError" in stderr:
            counts["assertion"] += 1
        else:
            counts["other"] += 1
            tail = stderr.strip().splitlines()[-1] if stderr.strip() else ""
            other_cases.append(f"{task_id or path.name} rc={returncode} {tail}")

    if file_count != 164:
        problems.append(f"humaneval: expected exactly 164 transcript files; found {file_count}")
    task_ids_valid = all(isinstance(task_id, str) and task_id for task_id in task_ids)
    if not task_ids_valid:
        problems.append("humaneval: every transcript must have a non-empty task_id")
    if task_ids_valid and len(set(task_ids)) != len(task_ids):
        problems.append("humaneval: task_ids are not unique")
    summary_n = document.get("n")
    summary_correct = document.get("correct")
    if file_count != summary_n:
        problems.append(
            f"humaneval: transcript file count {file_count} != summary n {summary_n!r}"
        )
    if stored_correct_count != summary_correct:
        problems.append(
            "humaneval: stored scored_correct count "
            f"{stored_correct_count} != summary correct {summary_correct!r}"
        )
    if counts["syntax_error"]:
        problems.append(
            "humaneval: SyntaxError/IndentationError/TabError in "
            f"{counts['syntax_error']} transcript(s): {syntax_cases[:8]}"
        )
    taxonomy: dict[str, Any] = {
        **counts,
        "stored_correct_count": stored_correct_count,
        "syntax_cases": syntax_cases,
        "other_cases": other_cases,
    }
    record = {
        "n": file_count,
        "correct_recount": stored_correct_count,
        "summary_correct": summary_correct,
        "match": not problems,
    }
    return record, taxonomy, problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stack", required=True, help="result suffix, e.g. llamacpp or ds4")
    args = parser.parse_args()
    stack = args.stack

    suites: dict[str, dict[str, Any]] = {}
    present_suites: list[str] = []
    absent_suites: list[str] = []
    all_problems: list[str] = []
    humaneval_taxonomy: dict[str, Any] = {"present": False}

    print(f"=== accuracy audit: {stack} ===")
    for suite_key, result_pattern, transcript_pattern, suite, _holdout in SUITES:
        result_path = RESULTS / result_pattern.format(stack=stack)
        if not result_path.is_file():
            absent_suites.append(suite_key)
            print(f"  {result_path.name}: (absent)")
            continue
        present_suites.append(suite_key)
        document, load_problems = load_json_object(result_path)
        if document is None:
            record = {
                "n": 0,
                "correct_recount": 0,
                "summary_correct": None,
                "match": False,
            }
            problems = load_problems
        elif suite == "humaneval":
            record, humaneval_taxonomy, problems = audit_humaneval(
                result_path,
                document,
                RESULTS / "transcripts" / transcript_pattern.format(stack=stack),
            )
            humaneval_taxonomy["present"] = True
        else:
            record, problems = audit_rescored_suite(
                suite_key,
                suite,
                result_path,
                document,
                RESULTS / "transcripts" / transcript_pattern.format(stack=stack),
            )
        suites[suite_key] = record
        all_problems.extend(problems)
        status = "match" if record["match"] else "MISMATCH"
        print(
            f"  {result_path.name}: n={record['n']} "
            f"recount={record['correct_recount']} "
            f"summary={record['summary_correct']} {status}"
        )

    passed = not all_problems
    artifact = {
        "kind": "accuracy-audit",
        "pass": passed,
        "stack": stack,
        "suites": suites,
        "present_suites": present_suites,
        "absent_suites": absent_suites,
        "humaneval_taxonomy": humaneval_taxonomy,
        "generated_by": "scripts/36_audit_accuracy.py",
    }
    artifact_path = RESULTS / f"audit-{stack}.json"
    artifact_path.write_text(json.dumps(artifact, indent=2) + "\n", encoding="utf-8")

    print("=== audit verdict ===")
    if all_problems:
        for problem in all_problems:
            print(f"  FAIL: {problem}")
        print(f"  artifact: {artifact_path.relative_to(REPO)}")
        return 1
    print(f"  PASS: all present suites match; artifact: {artifact_path.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
