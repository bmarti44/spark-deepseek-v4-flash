#!/usr/bin/env python3
"""Generate the frozen mechanical stack-decision report.

Frozen rule: both stacks require passing golden and exact-ID parity evidence,
a verifier-owned passing accuracy audit containing matching gsm8k-holdout,
mmlu-pro-holdout, and humaneval entries, and deeply validated soak evidence.
Soak validation requires the stack label, >=1500 actual seconds, >=30 requests,
all gates true, and first/last-window decode degradation plus minimum available
memory reproduced from raw arrays within 1e-6.  Accuracy result counts must equal
the audit counts.  The 4K and 16K valid-rep decode medians are also reproduced
within 1e-6 and speed suite_valid must be true, unless the stack has a valid
results/envelope-exception-<stack>.json whose reason is surfaced in DECISION.md.

Among eligible candidates, the existing composite/delta/speed rule applies.  A
sole eligible candidate additionally requires composite >=60.0 and 4K decode
>=5.0 tok/s; otherwise the verdict is NO_GO.  Reported hashes and digests are
truncated to at most 12 hexadecimal characters.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import statistics
import tempfile
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parent.parent
RESULTS_DIR = REPO_ROOT / "results"
STACKS = ("ds4", "llamacpp")
INPUT_PATHS = {
    "ds4": {
        "speed": RESULTS_DIR / "speed-ds4-dspark.json",
        "golden": RESULTS_DIR / "golden-ds4-dspark.json",
        "parity": RESULTS_DIR / "parity-ds4.json",
        "gsm8k-holdout": RESULTS_DIR / "acc-gsm8k-holdout-ds4.json",
        "mmlu-pro-holdout": RESULTS_DIR / "acc-mmlu-holdout-ds4.json",
        "humaneval": RESULTS_DIR / "acc-humaneval-ds4.json",
    },
    "llamacpp": {
        "speed": RESULTS_DIR / "speed-llamacpp.json",
        "golden": RESULTS_DIR / "golden-llamacpp.json",
        "parity": RESULTS_DIR / "parity-llamacpp.json",
        "gsm8k-holdout": RESULTS_DIR / "acc-gsm8k-holdout-llamacpp.json",
        "mmlu-pro-holdout": RESULTS_DIR / "acc-mmlu-holdout-llamacpp.json",
        "humaneval": RESULTS_DIR / "acc-humaneval-llamacpp.json",
    },
}
ACCURACY_EXPECTATIONS = {
    "gsm8k-holdout": ("gsm8k", "holdout"),
    "mmlu-pro-holdout": ("mmlu-pro", "holdout"),
    "humaneval": ("humaneval", "all"),
}
AUDIT_REQUIRED_SUITES = tuple(ACCURACY_EXPECTATIONS)
SOAK_REQUIRED_GATES = {
    "zero_errors",
    "enough_requests",
    "sampler_healthy",
    "mem_sample_density",
    "windows_disjoint",
    "windows_populated",
    "degradation_within_threshold",
    "memory_above_floor",
    "health_all_ok",
    "duration_met",
}
SOLE_CANDIDATE_COMPOSITE_FLOOR = 60.0
SOLE_CANDIDATE_SPEED_FLOOR = 5.0
SUMMARY_TOLERANCE = 1e-6


class DecisionInputError(RuntimeError):
    """An input is absent or cannot safely be used by the frozen rule."""


def parse_stack_evidence(value: str) -> dict[str, Path]:
    parsed: dict[str, Path] = {}
    for item in value.split(","):
        if item.count("=") != 1:
            raise argparse.ArgumentTypeError(
                "must be ds4=PATH,llamacpp=PATH"
            )
        stack, raw_path = item.split("=", 1)
        if stack not in STACKS:
            raise argparse.ArgumentTypeError(f"unknown evidence stack: {stack!r}")
        if stack in parsed:
            raise argparse.ArgumentTypeError(f"duplicate evidence stack: {stack!r}")
        if not raw_path:
            raise argparse.ArgumentTypeError(f"evidence path for {stack} is empty")
        parsed[stack] = Path(raw_path)
    missing = [stack for stack in STACKS if stack not in parsed]
    if missing:
        raise argparse.ArgumentTypeError(
            "missing evidence stack(s): " + ", ".join(missing)
        )
    return parsed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--soak-evidence",
        required=True,
        type=parse_stack_evidence,
        metavar="ds4=PATH,llamacpp=PATH",
        help="JSON soak evidence for both stacks",
    )
    parser.add_argument(
        "--audit-evidence",
        required=True,
        type=parse_stack_evidence,
        metavar="ds4=PATH,llamacpp=PATH",
        help="accuracy-audit JSON evidence for both stacks",
    )
    return parser.parse_args()


def relative(path: Path) -> str:
    return path.relative_to(REPO_ROOT).as_posix()


def path_label(path: Path) -> str:
    try:
        return relative(path.resolve())
    except ValueError:
        return str(path.resolve())


def require_files() -> None:
    paths = [path for stack in STACKS for path in INPUT_PATHS[stack].values()]
    missing = [relative(path) for path in paths if not path.is_file()]
    if missing:
        raise DecisionInputError("missing required input files: " + ", ".join(missing))


def load_object(path: Path) -> dict[str, Any]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise DecisionInputError(f"cannot read {relative(path)}: {error}") from error
    if not isinstance(document, dict):
        raise DecisionInputError(f"{relative(path)}: top-level JSON value must be an object")
    return document


def field(document: dict[str, Any], name: str, path: Path) -> Any:
    if name not in document:
        raise DecisionInputError(f"{relative(path)}: missing required field {name!r}")
    return document[name]


def require_bool(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        raise DecisionInputError(f"{label}: expected boolean, got {value!r}")
    return value


def require_number(value: Any, label: str) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise DecisionInputError(f"{label}: expected a number, got {value!r}")
    result = float(value)
    if not math.isfinite(result):
        raise DecisionInputError(f"{label}: expected a finite number, got {value!r}")
    return result


def require_int(value: Any, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool):
        raise DecisionInputError(f"{label}: expected an integer, got {value!r}")
    return value


def evidence_failure(path: Path, reason: str, **details: Any) -> dict[str, Any]:
    return {"path": path_label(path), "status": "fail", "reason": reason, **details}


def read_audit_evidence(path: Path, stack: str) -> dict[str, Any]:
    label = path_label(path)
    if not path.is_file():
        return evidence_failure(path, "file is missing")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        return evidence_failure(path, f"invalid JSON: {error}")
    if not isinstance(document, dict):
        return evidence_failure(path, "top-level JSON value is not an object")
    if (
        document.get("kind") != "accuracy-audit"
        or document.get("pass") is not True
        or document.get("stack") != stack
    ):
        return evidence_failure(
            path,
            "requires kind='accuracy-audit', pass=true, and matching stack",
            kind=document.get("kind"),
            passed=document.get("pass"),
            stack=document.get("stack"),
        )
    suites = document.get("suites")
    if not isinstance(suites, dict):
        return evidence_failure(path, "accuracy audit suites is not an object")
    counts: dict[str, int] = {}
    for suite in AUDIT_REQUIRED_SUITES:
        entry = suites.get(suite)
        if not isinstance(entry, dict) or entry.get("match") is not True:
            return evidence_failure(
                path, f"accuracy audit suite {suite!r} is absent or does not match"
            )
        n = entry.get("n")
        if not isinstance(n, int) or isinstance(n, bool) or n <= 0:
            return evidence_failure(path, f"accuracy audit suite {suite!r} has bad n={n!r}")
        counts[suite] = n
    return {
        "path": label,
        "status": "pass",
        "kind": document["kind"],
        "pass": True,
        "stack": stack,
        "suite_counts": counts,
    }


def summary_matches(actual: float | None, reported: Any) -> bool:
    if actual is None:
        return reported is None
    if not isinstance(reported, (int, float)) or isinstance(reported, bool):
        return False
    return math.isclose(actual, float(reported), rel_tol=0.0, abs_tol=SUMMARY_TOLERANCE)


def read_soak_evidence(path: Path, stack: str) -> dict[str, Any]:
    label = path_label(path)
    if not path.is_file():
        return evidence_failure(path, "file is missing")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        return evidence_failure(path, f"invalid JSON: {error}")
    if not isinstance(document, dict):
        return evidence_failure(path, "top-level JSON value is not an object")
    if document.get("kind") != "soak" or document.get("pass") is not True:
        return evidence_failure(path, "requires kind='soak' and pass=true")
    if document.get("stack_label") != stack:
        return evidence_failure(path, "soak stack_label does not match candidate")
    try:
        elapsed = require_number(
            document.get("duration_seconds_actual"), f"{label}.duration_seconds_actual"
        )
        n_requests = require_int(document.get("n_requests"), f"{label}.n_requests")
        window = require_number(document.get("window_seconds"), f"{label}.window_seconds")
    except DecisionInputError as error:
        return evidence_failure(path, str(error))
    if elapsed < 1500:
        return evidence_failure(path, "duration_seconds_actual is below 1500")
    if n_requests < 30:
        return evidence_failure(path, "n_requests is below 30")
    if window <= 0:
        return evidence_failure(path, "window_seconds must be positive")
    gates = document.get("gates")
    if not isinstance(gates, dict):
        return evidence_failure(path, "gates is not an object")
    if not SOAK_REQUIRED_GATES.issubset(gates):
        missing = sorted(SOAK_REQUIRED_GATES.difference(gates))
        return evidence_failure(path, "soak gates are incomplete: " + ", ".join(missing))
    if any(value is not True for value in gates.values()):
        return evidence_failure(path, "not every soak gate is true")
    reps = document.get("reps")
    mem_samples = document.get("mem_samples")
    if not isinstance(reps, list) or not isinstance(mem_samples, list):
        return evidence_failure(path, "raw reps and mem_samples arrays are required")
    if len(reps) != n_requests:
        return evidence_failure(path, "n_requests does not equal raw reps count")
    first: list[float] = []
    last: list[float] = []
    try:
        for index, rep in enumerate(reps):
            if not isinstance(rep, dict):
                raise DecisionInputError(f"{label}.reps[{index}] is not an object")
            t_start = require_number(rep.get("t_start"), f"{label}.reps[{index}].t_start")
            decode = require_number(
                rep.get("decode_tok_s"), f"{label}.reps[{index}].decode_tok_s"
            )
            if t_start < window:
                first.append(decode)
            if t_start >= elapsed - window:
                last.append(decode)
        memory_values: list[float] = []
        for index, sample in enumerate(mem_samples):
            if not isinstance(sample, dict):
                raise DecisionInputError(f"{label}.mem_samples[{index}] is not an object")
            memory_values.append(
                require_number(sample.get("gib"), f"{label}.mem_samples[{index}].gib")
            )
    except DecisionInputError as error:
        return evidence_failure(path, str(error))
    first_median = statistics.median(first) if first else None
    last_median = statistics.median(last) if last else None
    degradation = (
        (first_median - last_median) / first_median
        if first_median is not None
        and last_median is not None
        and first_median > 0
        else None
    )
    min_memory = min(memory_values) if memory_values else None
    summaries = (
        (first_median, document.get("decode_first_window_median_tok_s")),
        (last_median, document.get("decode_last_window_median_tok_s")),
        (degradation, document.get("degradation_fraction")),
        (min_memory, document.get("mem_available_min_gib")),
    )
    if any(not summary_matches(actual, reported) for actual, reported in summaries):
        return evidence_failure(path, "soak summary does not match raw samples")
    return {
        "path": label,
        "status": "pass",
        "kind": "soak",
        "pass": True,
        "duration_seconds_actual": elapsed,
        "n_requests": n_requests,
        "recomputed": {
            "decode_first_window_median_tok_s": first_median,
            "decode_last_window_median_tok_s": last_median,
            "degradation_fraction": degradation,
            "mem_available_min_gib": min_memory,
        },
    }


def read_speed(path: Path) -> dict[str, Any]:
    document = load_object(path)
    suite_valid = require_bool(
        field(document, "suite_valid", path), f"{relative(path)}.suite_valid"
    )
    cells = field(document, "cells", path)
    if not isinstance(cells, list):
        raise DecisionInputError(f"{relative(path)}.cells: expected an array")
    selected: dict[int, dict[str, Any]] = {}
    for context in (4096, 16384):
        matches = [
            cell
            for cell in cells
            if isinstance(cell, dict) and cell.get("ctx_tokens") == context
        ]
        if len(matches) != 1:
            raise DecisionInputError(
                f"{relative(path)}.cells: expected exactly one cell with "
                f"ctx_tokens=={context}; found {len(matches)}"
            )
        selected[context] = matches[0]
    ttft_medians: dict[str, float] = {}
    decode_medians: dict[str, float] = {}
    all_decode_medians: dict[str, float] = {}
    rep_counts: dict[str, int] = {}
    valid_rep_counts: dict[str, int] = {}
    for context, context_cell in selected.items():
        raw_median = field(context_cell, "median_decode", path)
        if raw_median is None:
            raise DecisionInputError(
                f"{relative(path)}: {context} cell median_decode is null"
            )
        reported_median = require_number(
            raw_median, f"{relative(path)} {context} median_decode"
        )
        raw_ttft = field(context_cell, "median_ttft", path)
        if raw_ttft is None:
            raise DecisionInputError(
                f"{relative(path)}: {context} cell required field 'median_ttft' is null"
            )
        ttft = require_number(raw_ttft, f"{relative(path)} {context} median_ttft")
        if ttft < 0:
            raise DecisionInputError(
                f"{relative(path)} {context} median_ttft: must be nonnegative"
            )
        ttft_medians[str(context)] = ttft
        reps = field(context_cell, "reps", path)
        if not isinstance(reps, list):
            raise DecisionInputError(
                f"{relative(path)} {context} reps: expected an array"
            )
        valid_decode_values: list[float] = []
        all_decode_values: list[float] = []
        for index, rep in enumerate(reps):
            if not isinstance(rep, dict):
                raise DecisionInputError(
                    f"{relative(path)} {context} reps[{index}]: expected an object"
                )
            valid = require_bool(
                field(rep, "valid", path),
                f"{relative(path)} {context} reps[{index}].valid",
            )
            raw_decode = field(rep, "decode_tok_s", path)
            if raw_decode is not None:
                decode = require_number(
                    raw_decode,
                    f"{relative(path)} {context} reps[{index}].decode_tok_s",
                )
                if decode < 0:
                    raise DecisionInputError(
                        f"{relative(path)} {context} reps[{index}].decode_tok_s is negative"
                    )
                all_decode_values.append(decode)
            if valid:
                if raw_decode is None:
                    raise DecisionInputError(
                        f"{relative(path)} {context} reps[{index}]: valid rep has null decode_tok_s"
                    )
                valid_decode_values.append(decode)
        if not valid_decode_values:
            raise DecisionInputError(
                f"{relative(path)} {context} reps: no valid numeric decode values"
            )
        recomputed = statistics.median(valid_decode_values)
        if not math.isclose(
            recomputed, reported_median, rel_tol=0.0, abs_tol=SUMMARY_TOLERANCE
        ):
            raise DecisionInputError(
                f"{relative(path)} {context} median_decode does not match valid reps"
            )
        decode_medians[str(context)] = recomputed
        all_decode_medians[str(context)] = statistics.median(all_decode_values)
        rep_counts[str(context)] = len(reps)
        valid_rep_counts[str(context)] = len(valid_decode_values)
    return {
        "ctx_tokens": 4096,
        "suite_valid": suite_valid,
        "median_decode": decode_medians["4096"],
        "median_decode_all_reps": all_decode_medians["4096"],
        "median_decode_by_context": decode_medians,
        "rep_count": rep_counts["4096"],
        "valid_rep_count": valid_rep_counts["4096"],
        "valid_reps_required": 4,
        "expected_rep_count": 5,
        "samples_pass": rep_counts["4096"] == 5 and valid_rep_counts["4096"] >= 4,
        "median_ttft_s": ttft_medians,
    }


def read_envelope_exception(stack: str) -> dict[str, Any] | None:
    path = RESULTS_DIR / f"envelope-exception-{stack}.json"
    if not path.is_file():
        return None
    document = load_object(path)
    reason = document.get("reason")
    accepted_cells = document.get("accepted_cells")
    if (
        document.get("kind") != "envelope-exception"
        or document.get("stack") != stack
        or not isinstance(reason, str)
        or not reason.strip()
        or not isinstance(accepted_cells, list)
    ):
        raise DecisionInputError(
            f"{relative(path)}: invalid context-envelope exception artifact"
        )
    return {
        "path": relative(path),
        "kind": document["kind"],
        "stack": stack,
        "reason": reason,
        "accepted_cells": accepted_cells,
    }


def read_accuracy(path: Path, report_name: str) -> dict[str, Any]:
    document = load_object(path)
    expected_suite, expected_split = ACCURACY_EXPECTATIONS[report_name]
    suite = field(document, "suite", path)
    split = field(document, "split", path)
    if suite != expected_suite:
        raise DecisionInputError(
            f"{relative(path)}.suite: expected {expected_suite!r}, got {suite!r}"
        )
    if split != expected_split:
        raise DecisionInputError(
            f"{relative(path)}.split: expected {expected_split!r}, got {split!r}"
        )
    n = require_int(field(document, "n", path), f"{relative(path)}.n")
    correct = require_int(field(document, "correct", path), f"{relative(path)}.correct")
    accuracy = require_number(
        field(document, "accuracy", path), f"{relative(path)}.accuracy"
    )
    wilson = field(document, "wilson95", path)
    if not isinstance(wilson, list) or len(wilson) != 2:
        raise DecisionInputError(f"{relative(path)}.wilson95: expected [lower, upper]")
    lower = require_number(wilson[0], f"{relative(path)}.wilson95[0]")
    upper = require_number(wilson[1], f"{relative(path)}.wilson95[1]")
    if n <= 0:
        raise DecisionInputError(f"{relative(path)}.n: must be positive")
    if not 0 <= correct <= n:
        raise DecisionInputError(f"{relative(path)}.correct: must be between 0 and n")
    if not 0.0 <= accuracy <= 1.0:
        raise DecisionInputError(f"{relative(path)}.accuracy: must be between 0 and 1")
    if not math.isclose(accuracy, correct / n, rel_tol=0.0, abs_tol=1e-12):
        raise DecisionInputError(
            f"{relative(path)}.accuracy: inconsistent with correct/n ({correct}/{n})"
        )
    if not 0.0 <= lower <= accuracy <= upper <= 1.0:
        raise DecisionInputError(
            f"{relative(path)}.wilson95: must satisfy 0 <= lower <= accuracy <= upper <= 1"
        )
    return {
        "suite": suite,
        "split": split,
        "n": n,
        "correct": correct,
        "accuracy": accuracy,
        "accuracy_percent": accuracy * 100.0,
        "wilson95": [lower, upper],
        "wilson95_percent": [lower * 100.0, upper * 100.0],
    }


def collect_candidate(
    stack: str, soak_path: Path, audit_path: Path
) -> dict[str, Any]:
    paths = INPUT_PATHS[stack]
    golden_document = load_object(paths["golden"])
    golden_pass = require_bool(
        field(golden_document, "pass", paths["golden"]),
        f"{relative(paths['golden'])}.pass",
    )
    parity_document = load_object(paths["parity"])
    parity_pass = require_bool(
        field(parity_document, "pass", paths["parity"]),
        f"{relative(paths['parity'])}.pass",
    )
    parity_level = field(parity_document, "parity_level", paths["parity"])
    if not isinstance(parity_level, str):
        raise DecisionInputError(
            f"{relative(paths['parity'])}.parity_level: expected a string"
        )
    speed = read_speed(paths["speed"])
    envelope_exception = read_envelope_exception(stack) if not speed["suite_valid"] else None
    speed_envelope_pass = speed["suite_valid"] or envelope_exception is not None
    soak = read_soak_evidence(soak_path, stack)
    stability_pass = soak["status"] == "pass"
    audit = read_audit_evidence(audit_path, stack)
    accuracy = {
        name: read_accuracy(paths[name], name) for name in ACCURACY_EXPECTATIONS
    }
    if audit["status"] == "pass":
        count_mismatches = [
            name
            for name, item in accuracy.items()
            if item["n"] != audit["suite_counts"][name]
        ]
        if count_mismatches:
            audit = {
                **audit,
                "status": "fail",
                "reason": "accuracy result n does not match audit count for: "
                + ", ".join(count_mismatches),
            }
    accuracy_audit_pass = audit["status"] == "pass"
    composite = sum(item["accuracy_percent"] for item in accuracy.values()) / 3.0
    checks = {
        "golden_pass": golden_pass,
        "parity_pass": parity_pass,
        "parity_level": parity_level,
        "stability": soak["status"],
        "accuracy_audit": audit["status"],
        "speed_suite_valid": speed["suite_valid"],
        "speed_envelope": "pass" if speed_envelope_pass else "fail",
        "speed_4k_samples_pass": speed["samples_pass"],
    }
    eligible = (
        golden_pass
        and parity_pass
        and parity_level == "exact-ids"
        and stability_pass
        and accuracy_audit_pass
        and speed_envelope_pass
        and speed["samples_pass"]
    )
    failed_checks: list[str] = []
    if not golden_pass:
        failed_checks.append("golden pass")
    if not parity_pass:
        failed_checks.append("parity pass")
    if parity_level != "exact-ids":
        failed_checks.append("parity exact-ids")
    if not stability_pass:
        failed_checks.append("stability pass")
    if not accuracy_audit_pass:
        failed_checks.append("accuracy audit")
    if not speed_envelope_pass:
        failed_checks.append("speed suite_valid")
    if not speed["samples_pass"]:
        failed_checks.append("4K speed has >=4 valid reps of 5")
    return {
        "input_files": {
            **{name: relative(path) for name, path in paths.items()},
            "soak": path_label(soak_path),
            "accuracy_audit": path_label(audit_path),
        },
        "eligibility_inputs": checks,
        "soak_evidence": soak,
        "accuracy_audit_evidence": audit,
        "context_envelope_exception": envelope_exception,
        "eligible": eligible,
        "failed_eligibility_checks": failed_checks,
        "accuracy": accuracy,
        "composite_percent": composite,
        "speed": speed,
    }


def higher_by(
    candidates: dict[str, dict[str, Any]], field_name: str
) -> str | None:
    left, right = STACKS
    left_value = candidates[left][field_name]
    right_value = candidates[right][field_name]
    if left_value == right_value:
        return None
    return left if left_value > right_value else right


def decide(candidates: dict[str, dict[str, Any]]) -> dict[str, Any]:
    composites = {
        stack: candidates[stack]["composite_percent"] for stack in STACKS
    }
    delta = abs(composites["ds4"] - composites["llamacpp"])
    details: dict[str, Any] = {
        "absolute_composite_delta_points": delta,
        "composite_delta_threshold_points": 3.0,
        "composite_delta_at_most_threshold": delta <= 3.0,
        "sole_candidate_composite_floor": SOLE_CANDIDATE_COMPOSITE_FLOOR,
        "sole_candidate_speed_4k_floor_tok_s": SOLE_CANDIDATE_SPEED_FLOOR,
    }
    eligible = [stack for stack in STACKS if candidates[stack]["eligible"]]
    if not eligible:
        return {
            "verdict": "NO_GO",
            "winner": None,
            "rule_branch": "zero_eligible",
            **details,
        }
    if len(eligible) == 1:
        sole = eligible[0]
        floor_pass = (
            composites[sole] >= SOLE_CANDIDATE_COMPOSITE_FLOOR
            and candidates[sole]["speed"]["median_decode"]
            >= SOLE_CANDIDATE_SPEED_FLOOR
        )
        if not floor_pass:
            return {
                "verdict": "NO_GO",
                "winner": None,
                "sole_eligible_candidate": sole,
                "rule_branch": "one_eligible_below_frozen_floor",
                **details,
            }
        return {
            "verdict": "SOLE_CANDIDATE",
            "winner": sole,
            "rule_branch": "one_eligible_meets_frozen_floor",
            **details,
        }

    if composites["ds4"] == composites["llamacpp"]:
        gsm = {
            stack: candidates[stack]["accuracy"]["gsm8k-holdout"]["accuracy_percent"]
            for stack in STACKS
        }
        winner = "ds4" if gsm["ds4"] > gsm["llamacpp"] else "llamacpp" if gsm["llamacpp"] > gsm["ds4"] else None
        if winner is not None:
            return {
                "verdict": winner.upper(),
                "winner": winner,
                "rule_branch": "exact_composite_tie_higher_gsm8k_holdout",
                **details,
            }
        speeds = {stack: candidates[stack]["speed"]["median_decode"] for stack in STACKS}
        winner = "ds4" if speeds["ds4"] > speeds["llamacpp"] else "llamacpp" if speeds["llamacpp"] > speeds["ds4"] else None
        if winner is None:
            raise DecisionInputError(
                "frozen rule cannot resolve candidates tied on composite, "
                "gsm8k-holdout, and speed"
            )
        return {
            "verdict": winner.upper(),
            "winner": winner,
            "rule_branch": "exact_composite_tie_equal_gsm8k_higher_speed",
            **details,
        }

    if delta <= 3.0:
        speeds = {stack: candidates[stack]["speed"]["median_decode"] for stack in STACKS}
        winner = "ds4" if speeds["ds4"] > speeds["llamacpp"] else "llamacpp" if speeds["llamacpp"] > speeds["ds4"] else None
        if winner is None:
            raise DecisionInputError(
                "frozen rule cannot select a higher-speed candidate because speeds are tied"
            )
        return {
            "verdict": winner.upper(),
            "winner": winner,
            "rule_branch": "both_eligible_composite_delta_at_most_3_higher_speed",
            **details,
        }

    winner = higher_by(candidates, "composite_percent")
    if winner is None:  # Unreachable because the exact tie was handled above.
        raise DecisionInputError("internal decision error: no higher-composite candidate")
    if candidates[winner]["speed"]["median_decode"] < 10.0:
        return {
            "verdict": "SURFACE_TO_BRIAN",
            "winner": None,
            "higher_composite_candidate": winner,
            "rule_branch": "both_eligible_composite_delta_over_3_higher_composite_speed_under_10",
            **details,
        }
    return {
        "verdict": winner.upper(),
        "winner": winner,
        "rule_branch": "both_eligible_composite_delta_over_3_higher_composite_speed_at_least_10",
        **details,
    }


def format_suite(item: dict[str, Any]) -> str:
    low, high = item["wilson95_percent"]
    return f"{item['accuracy_percent']:.2f}% ({item['correct']}/{item['n']}; 95% CI {low:.2f}–{high:.2f}%)"


def render_markdown(candidates: dict[str, dict[str, Any]], decision: dict[str, Any]) -> str:
    rows = []
    for stack in STACKS:
        candidate = candidates[stack]
        eligibility = "eligible" if candidate["eligible"] else "ineligible: " + ", ".join(candidate["failed_eligibility_checks"])
        accuracy = candidate["accuracy"]
        rows.append(
            f"| {stack} | {eligibility} | {format_suite(accuracy['gsm8k-holdout'])} | "
            f"{format_suite(accuracy['mmlu-pro-holdout'])} | {format_suite(accuracy['humaneval'])} | "
            f"{candidate['composite_percent']:.2f}% | "
            f"{candidate['speed']['valid_rep_count']}/{candidate['speed']['rep_count']} | "
            f"{candidate['speed']['median_decode']:.3f} | "
            f"{candidate['speed']['median_decode_all_reps']:.3f} |"
        )
    winner = decision.get("winner") or "—"
    delta = decision["absolute_composite_delta_points"]
    delta_relation = "at most" if delta <= 3.0 else "over"
    operational_lines = []
    exception_lines: list[str] = []
    for stack in STACKS:
        ttft = candidates[stack]["speed"]["median_ttft_s"]
        operational_lines.append(
            f"- {stack} TTFT median: 4K {ttft['4096']:.3f}s; "
            f"16K {ttft['16384']:.3f}s."
        )
        exception = candidates[stack]["context_envelope_exception"]
        if exception is not None:
            exception_lines.extend(
                [
                    f"### {stack}",
                    "",
                    exception["reason"],
                    "",
                    "Accepted cells: `"
                    + json.dumps(exception["accepted_cells"], ensure_ascii=False)
                    + "`",
                    "",
                ]
            )
    exception_section = (
        ["## Context-envelope exception", "", *exception_lines]
        if exception_lines
        else []
    )
    content = "\n".join(
        [
            "# Decision",
            "",
            "| Candidate | Eligibility | GSM8K holdout | MMLU-Pro holdout | HumanEval | Composite | 4K valid reps | 4K decode valid-only tok/s | 4K decode all numeric reps tok/s |",
            "|---|---|---:|---:|---:|---:|---:|---:|---:|",
            *rows,
            "",
            f"**Verdict:** {decision['verdict']}",
            "",
            f"**Candidate selected:** {winner}",
            "",
            f"**Rule branch:** `{decision['rule_branch']}`",
            "",
            f"**Composite delta:** {delta:.2f} percentage points, {delta_relation} "
            "the 3.00-point threshold.",
            "",
            "## Operational data outside the rule",
            "",
            *operational_lines,
            "",
            "- ds4 context envelope: warm >28K fails — see "
            "`results/speed-ds4-dspark.json`'s 28672 cell.",
            "- llamacpp context envelope: 28K valid.",
            "",
            "## Caveats",
            "",
            "- Speed cells use N=5 samples.",
            "- The decision rule uses the valid-only 4K decode median; the all-reps "
            "median includes invalid reps with numeric `decode_tok_s` and ignores nulls.",
            "- The composite ignores prefill and TTFT.",
            "- Holdout accuracy values are single-run holdouts.",
            "- A sole eligible candidate must have composite >=60.0% and 4K "
            "decode >=5.0 tok/s; otherwise the frozen verdict is NO_GO.",
            "",
            *exception_section,
        ]
    )
    return re.sub(
        r"(?<![0-9A-Fa-f])([0-9A-Fa-f]{12})[0-9A-Fa-f]+(?![0-9A-Fa-f])",
        r"\1",
        content,
    )


def atomic_write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    args = parse_args()
    try:
        require_files()
        candidates = {
            stack: collect_candidate(
                stack, args.soak_evidence[stack], args.audit_evidence[stack]
            )
            for stack in STACKS
        }
        decision = decide(candidates)
        machine_report = {
            "candidates": candidates,
            "decision": decision,
        }
        atomic_write_text(
            RESULTS_DIR / "decision.json",
            json.dumps(machine_report, ensure_ascii=False, indent=2) + "\n",
        )
        atomic_write_text(
            RESULTS_DIR / "DECISION.md", render_markdown(candidates, decision)
        )
    except DecisionInputError as error:
        print(f"FAIL CLOSED: {error}", file=os.sys.stderr)
        return 2
    winner_suffix = f" ({decision['winner']})" if decision.get("winner") else ""
    for stack in STACKS:
        if not candidates[stack]["eligible"]:
            evidence_reasons = [
                f"stability: {candidates[stack]['soak_evidence'].get('reason')}"
                if candidates[stack]["soak_evidence"]["status"] == "fail"
                else None,
                "accuracy audit: "
                + str(candidates[stack]["accuracy_audit_evidence"].get("reason"))
                if candidates[stack]["accuracy_audit_evidence"]["status"] == "fail"
                else None,
            ]
            detail = "; ".join(reason for reason in evidence_reasons if reason)
            print(
                f"INELIGIBLE {stack}: "
                + ", ".join(candidates[stack]["failed_eligibility_checks"])
                + (f" ({detail})" if detail else "")
            )
    print(f"VERDICT: {decision['verdict']}{winner_suffix}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
