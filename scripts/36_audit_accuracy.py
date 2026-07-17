#!/usr/bin/env python3
"""Independently verify accuracy transcripts against the pinned evaluation sets.

Every frozen suite is required at its exact deterministic size.  GSM8K and
MMLU-Pro prompts, identities, reference answers, and scores are reconstructed
from pinned rows.  HumanEval completions are re-extracted and re-executed in
the frozen Docker sandbox.  The output binds the audited result files,
transcript tree, evalsets, and accuracy-harness manifest entry.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import re
import sys
import tempfile
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parent.parent
RESULTS = REPO / "results"
TRANSCRIPTS = RESULTS / "transcripts"
HARNESS = REPO / "scripts" / "31_bench_accuracy.py"

spec = importlib.util.spec_from_file_location("bench", HARNESS)
if spec is None or spec.loader is None:
    raise RuntimeError(f"cannot load frozen accuracy harness from {HARNESS}")
bench = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
spec.loader.exec_module(bench)

SYNTAX_RE = re.compile(r"(SyntaxError|IndentationError|TabError)", re.MULTILINE)
SUITES = (
    ("gsm8k-dev", "acc-gsm8k-dev-{stack}.json", "gsm8k-dev-{stack}", "gsm8k", "dev"),
    (
        "gsm8k-holdout",
        "acc-gsm8k-holdout-{stack}.json",
        "gsm8k-holdout-{stack}",
        "gsm8k",
        "holdout",
    ),
    ("mmlu-pro-dev", "acc-mmlu-dev-{stack}.json", "mmlu-dev-{stack}", "mmlu-pro", "dev"),
    (
        "mmlu-pro-holdout",
        "acc-mmlu-holdout-{stack}.json",
        "mmlu-holdout-{stack}",
        "mmlu-pro",
        "holdout",
    ),
    ("humaneval", "acc-humaneval-{stack}.json", "humaneval-{stack}", "humaneval", "all"),
)


def relative(path: Path) -> str:
    return path.relative_to(REPO).as_posix()


def load_json_object(path: Path) -> tuple[dict[str, Any] | None, list[str]]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        return None, [f"{path.name}: cannot read JSON: {error}"]
    if not isinstance(document, dict):
        return None, [f"{path.name}: top-level JSON value is not an object"]
    return document, []


def audit_result_schema(
    path: Path,
    document: dict[str, Any],
    suite: str,
    split: str,
    expected_n: int,
) -> list[str]:
    problems: list[str] = []
    if document.get("suite") != suite:
        problems.append(
            f"{path.name}: suite {document.get('suite')!r} != expected {suite!r}"
        )
    if document.get("split") != split:
        problems.append(
            f"{path.name}: split {document.get('split')!r} != expected {split!r}"
        )
    n = document.get("n")
    correct = document.get("correct")
    accuracy = document.get("accuracy")
    if not isinstance(n, int) or isinstance(n, bool) or n != expected_n:
        problems.append(f"{path.name}: n={n!r}; expected exactly {expected_n}")
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
    invalid_count = document.get("invalid_count")
    if not isinstance(invalid_count, int) or isinstance(invalid_count, bool):
        problems.append(f"{path.name}: bad invalid_count={invalid_count!r}")
    if split == "holdout" and not document.get("config_digest"):
        # This one result's ledger entry predates config digests; no other
        # holdout result is grandfathered.
        if path.name != "acc-gsm8k-holdout-llamacpp.json":
            problems.append(f"{path.name}: missing config_digest (required for holdout)")
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


def task_id_for_row(suite: str, index: int, row: dict[str, Any]) -> Any:
    if suite == "humaneval":
        return row["task_id"]
    if suite == "mmlu-pro":
        return row["question_id"]
    return index


def verify_transcript_binding(
    path: Path,
    transcript: dict[str, Any],
    suite: str,
    row: dict[str, Any],
    index: int,
    encoder: Any,
) -> tuple[str | None, list[str]]:
    problems: list[str] = []
    expected_task_id = task_id_for_row(suite, index, row)
    actual_task_id = transcript.get("task_id")
    if type(actual_task_id) is not type(expected_task_id) or actual_task_id != expected_task_id:
        problems.append(
            f"{path.name}: task_id/question_id {actual_task_id!r} "
            f"!= pinned row identity {expected_task_id!r}"
        )
    try:
        rendered, _rendering = bench.render_item(suite, row, encoder)
    except Exception as error:
        problems.append(
            f"{path.name}: pinned-row rendering failed: {type(error).__name__}: {error}"
        )
        rendered = None
    if rendered is not None:
        expected_prompt_hash = hashlib.sha256(rendered.encode("utf-8")).hexdigest()
        actual_prompt_hash = transcript.get("rendered_prompt_sha256")
        if actual_prompt_hash != expected_prompt_hash:
            problems.append(
                f"{path.name}: rendered_prompt_sha256 {actual_prompt_hash!r} "
                f"!= pinned-row rendering {expected_prompt_hash}"
            )
    expected = bench.expected_for_row(suite, row)
    if transcript.get("expected") != expected:
        problems.append(
            f"{path.name}: expected {transcript.get('expected')!r} "
            f"!= pinned-row expected {expected!r}"
        )
    completion = transcript.get("completion")
    if not isinstance(completion, str):
        problems.append(f"{path.name}: completion is not a string")
        completion = None
    return completion, problems


def records_by_pinned_index(
    suite_key: str,
    records: list[tuple[Path, dict[str, Any]]],
    expected_indices: list[int],
) -> tuple[dict[int, tuple[Path, dict[str, Any]]], list[str]]:
    problems: list[str] = []
    indexed: dict[int, tuple[Path, dict[str, Any]]] = {}
    expected_set = set(expected_indices)
    for path, transcript in records:
        index = transcript.get("index")
        if not isinstance(index, int) or isinstance(index, bool):
            problems.append(f"{path.name}: index is not an integer: {index!r}")
            continue
        if index not in expected_set:
            problems.append(f"{path.name}: index {index} is outside pinned {suite_key} split")
            continue
        if index in indexed:
            problems.append(
                f"{path.name}: duplicate pinned index {index}; first seen in "
                f"{indexed[index][0].name}"
            )
            continue
        indexed[index] = (path, transcript)
    missing = sorted(expected_set.difference(indexed))
    if missing:
        problems.append(f"{suite_key}: missing pinned transcript indices: {missing[:12]!r}")
    return indexed, problems


def audit_rescored_suite(
    suite_key: str,
    suite: str,
    split: str,
    result_path: Path,
    document: dict[str, Any],
    transcript_dir: Path,
    rows: list[dict[str, Any]],
    indices: list[int],
    encoder: Any,
) -> tuple[dict[str, Any], list[str]]:
    expected_n = len(indices)
    problems = audit_result_schema(result_path, document, suite, split, expected_n)
    records, file_count, transcript_problems = read_transcripts(transcript_dir)
    problems.extend(transcript_problems)
    if file_count != expected_n:
        problems.append(
            f"{suite_key}: transcript file count {file_count} != exact split size {expected_n}"
        )
    indexed, index_problems = records_by_pinned_index(suite_key, records, indices)
    problems.extend(index_problems)
    recount = 0
    for index in indices:
        record = indexed.get(index)
        if record is None:
            continue
        path, transcript = record
        completion, binding_problems = verify_transcript_binding(
            path, transcript, suite, rows[index], index, encoder
        )
        problems.extend(binding_problems)
        if completion is None:
            continue
        try:
            if suite == "gsm8k":
                rescored, _expected, _reason, _fallback = bench.score_gsm8k(
                    completion, rows[index]["answer"]
                )
            else:
                rescored, _expected, _reason = bench.score_mmlu(
                    completion, rows[index]["answer"], transcript.get("finish_reason")
                )
        except Exception as error:
            problems.append(f"{path.name}: scorer failed: {type(error).__name__}: {error}")
            continue
        recount += int(rescored)
        if transcript.get("scored_correct") is not rescored:
            problems.append(
                f"{path.name}: stored scored_correct={transcript.get('scored_correct')!r} "
                f"!= fresh verdict {rescored}"
            )

    summary_correct = document.get("correct")
    if recount != summary_correct:
        problems.append(
            f"{suite_key}: correct recount {recount} != summary correct {summary_correct!r}"
        )
    record = {
        "n": file_count,
        "expected_n": expected_n,
        "correct_recount": recount,
        "summary_correct": summary_correct,
        "match": not problems,
    }
    return record, problems


def audit_humaneval(
    result_path: Path,
    document: dict[str, Any],
    transcript_dir: Path,
    rows: list[dict[str, Any]],
    indices: list[int],
) -> tuple[dict[str, Any], dict[str, Any], list[str]]:
    expected_n = len(indices)
    problems = audit_result_schema(result_path, document, "humaneval", "all", expected_n)
    records, file_count, transcript_problems = read_transcripts(transcript_dir)
    problems.extend(transcript_problems)
    if file_count != expected_n:
        problems.append(
            f"humaneval: transcript file count {file_count} != exact split size {expected_n}"
        )
    indexed, index_problems = records_by_pinned_index("humaneval", records, indices)
    problems.extend(index_problems)
    counts = {
        "correct": 0,
        "assertion": 0,
        "syntax_error": 0,
        "timeout": 0,
        "other": 0,
    }
    syntax_cases: list[str] = []
    other_cases: list[str] = []
    with tempfile.TemporaryDirectory(prefix="dsv4-humaneval-audit-") as temporary_cases:
        cases_root = Path(temporary_cases)
        for position, index in enumerate(indices):
            record = indexed.get(index)
            if record is None:
                continue
            path, transcript = record
            row = rows[index]
            completion, binding_problems = verify_transcript_binding(
                path, transcript, "humaneval", row, index, None
            )
            problems.extend(binding_problems)
            if completion is None:
                continue
            fresh_correct, _expected, fresh_reason, fresh_execution = bench.run_humaneval(
                row, completion, cases_root, f"case-{position:05d}"
            )
            stored_execution = transcript.get("execution")
            if not isinstance(stored_execution, dict):
                problems.append(f"{path.name}: stored execution is not an object")
                stored_execution = {}
            if transcript.get("scored_correct") is not fresh_correct:
                problems.append(
                    f"{path.name}: stored scored_correct={transcript.get('scored_correct')!r} "
                    f"!= fresh verdict {fresh_correct}"
                )
            if stored_execution.get("returncode") != fresh_execution.get("returncode"):
                problems.append(
                    f"{path.name}: stored returncode={stored_execution.get('returncode')!r} "
                    f"!= fresh returncode={fresh_execution.get('returncode')!r}"
                )
            if stored_execution.get("stderr") != fresh_execution.get("stderr"):
                problems.append(f"{path.name}: stored stderr diverges from fresh execution")
            if transcript.get("reason") != fresh_reason:
                problems.append(
                    f"{path.name}: stored reason={transcript.get('reason')!r} "
                    f"!= fresh reason={fresh_reason!r}"
                )

            task_id = row["task_id"]
            returncode = fresh_execution.get("returncode")
            stderr = fresh_execution.get("stderr") or ""
            if not isinstance(stderr, str):
                stderr = str(stderr)
            if SYNTAX_RE.search(stderr):
                counts["syntax_error"] += 1
                syntax_cases.append(task_id)
            elif fresh_correct:
                counts["correct"] += 1
            elif returncode == 124 or "timeout" in fresh_reason.lower():
                counts["timeout"] += 1
            elif "AssertionError" in stderr:
                counts["assertion"] += 1
            else:
                counts["other"] += 1
                tail = stderr.strip().splitlines()[-1] if stderr.strip() else ""
                other_cases.append(f"{task_id} rc={returncode} {tail}")

    fresh_correct_count = counts["correct"]
    summary_correct = document.get("correct")
    if fresh_correct_count != summary_correct:
        problems.append(
            f"humaneval: fresh correct count {fresh_correct_count} "
            f"!= summary correct {summary_correct!r}"
        )
    if counts["syntax_error"]:
        problems.append(
            "humaneval: SyntaxError/IndentationError/TabError in "
            f"{counts['syntax_error']} fresh execution(s): {syntax_cases[:8]}"
        )
    taxonomy: dict[str, Any] = {
        **counts,
        "fresh_correct_count": fresh_correct_count,
        "syntax_cases": syntax_cases,
        "other_cases": other_cases,
        "present": True,
    }
    record = {
        "n": file_count,
        "expected_n": expected_n,
        "correct_recount": fresh_correct_count,
        "summary_correct": summary_correct,
        "match": not problems,
    }
    return record, taxonomy, problems


def transcript_tree_binding(stack: str) -> dict[str, Any]:
    paths: list[Path] = []
    for _suite_key, _result_pattern, transcript_pattern, _suite, _split in SUITES:
        directory = TRANSCRIPTS / transcript_pattern.format(stack=stack)
        if directory.is_dir():
            paths.extend(path for path in directory.rglob("*") if path.is_file())
    lines = [f"{relative(path)}:{bench.sha256_file(path)}" for path in sorted(paths)]
    payload = ("\n".join(lines) + ("\n" if lines else "")).encode("utf-8")
    return {
        "sha256": hashlib.sha256(payload).hexdigest(),
        "file_count": len(lines),
        "line_format": "repo-relative-path:sha256\\n, sorted by path",
    }


def build_bindings(stack: str) -> dict[str, Any]:
    accuracy_results = {
        relative(RESULTS / result_pattern.format(stack=stack)): bench.sha256_file(
            RESULTS / result_pattern.format(stack=stack)
        )
        for _suite_key, result_pattern, _transcript_pattern, _suite, _split in SUITES
    }
    evalset_paths = [bench.PINS_PATH, *bench.DATASET_FILES.values()]
    evalsets = {
        relative(path): bench.sha256_file(path) for path in sorted(evalset_paths)
    }
    return {
        "accuracy_result_sha256": accuracy_results,
        "transcript_tree": transcript_tree_binding(stack),
        "evalset_sha256": evalsets,
        "harness_manifest_line": bench.load_harness_manifest_line(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stack", required=True, help="result suffix, e.g. llamacpp or ds4")
    args = parser.parse_args()
    stack = args.stack

    pins, _revisions = bench.load_pins()
    rows_by_suite = {
        suite: bench.load_jsonl(suite, pins) for suite in bench.DATASET_FILES
    }
    encoder = bench.load_encoder()
    suites: dict[str, dict[str, Any]] = {}
    all_problems: list[str] = []
    humaneval_taxonomy: dict[str, Any] = {"present": False}

    print(f"=== accuracy audit: {stack} ===")
    for suite_key, result_pattern, transcript_pattern, suite, split in SUITES:
        result_path = RESULTS / result_pattern.format(stack=stack)
        rows = rows_by_suite[suite]
        indices = bench.select_indices(suite, split, rows)
        document, load_problems = load_json_object(result_path)
        if document is None:
            record = {
                "n": 0,
                "expected_n": len(indices),
                "correct_recount": 0,
                "summary_correct": None,
                "match": False,
            }
            problems = load_problems
        elif suite == "humaneval":
            record, humaneval_taxonomy, problems = audit_humaneval(
                result_path,
                document,
                TRANSCRIPTS / transcript_pattern.format(stack=stack),
                rows,
                indices,
            )
        else:
            record, problems = audit_rescored_suite(
                suite_key,
                suite,
                split,
                result_path,
                document,
                TRANSCRIPTS / transcript_pattern.format(stack=stack),
                rows,
                indices,
                encoder,
            )
        suites[suite_key] = record
        all_problems.extend(problems)
        status = "match" if record["match"] else "MISMATCH"
        print(
            f"  {result_path.name}: n={record['n']} "
            f"recount={record['correct_recount']} "
            f"summary={record['summary_correct']} {status}"
        )

    try:
        bindings = build_bindings(stack)
    except (OSError, RuntimeError) as error:
        all_problems.append(f"cannot compute audit bindings: {type(error).__name__}: {error}")
        bindings = None
    passed = not all_problems
    artifact = {
        "kind": "accuracy-audit",
        "pass": passed,
        "stack": stack,
        "suites": suites,
        "present_suites": list(suites),
        "absent_suites": [],
        "humaneval_taxonomy": humaneval_taxonomy,
        "bindings": bindings,
        "generated_by": "scripts/36_audit_accuracy.py",
    }
    artifact_path = RESULTS / f"audit-{stack}.json"
    bench.write_json(artifact_path, artifact)

    print("=== audit verdict ===")
    if all_problems:
        for problem in all_problems:
            print(f"  FAIL: {problem}")
        print(f"  artifact: {artifact_path.relative_to(REPO)}")
        return 1
    print(f"  PASS: all frozen suites match; artifact: {artifact_path.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
