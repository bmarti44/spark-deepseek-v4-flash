#!/usr/bin/env python3
"""Generate the frozen mechanical stack-decision report."""

from __future__ import annotations

import argparse
import json
import math
import os
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


class DecisionInputError(RuntimeError):
    """An input is absent or cannot safely be used by the frozen rule."""


def parse_stability(value: str) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for item in value.split(","):
        if item.count("=") != 1:
            raise argparse.ArgumentTypeError(
                "must be ds4=pass|fail,llamacpp=pass|fail"
            )
        stack, status = item.split("=", 1)
        if stack not in STACKS:
            raise argparse.ArgumentTypeError(f"unknown stability stack: {stack!r}")
        if stack in parsed:
            raise argparse.ArgumentTypeError(f"duplicate stability stack: {stack!r}")
        if status not in ("pass", "fail"):
            raise argparse.ArgumentTypeError(
                f"stability for {stack} must be 'pass' or 'fail'"
            )
        parsed[stack] = status
    missing = [stack for stack in STACKS if stack not in parsed]
    if missing:
        raise argparse.ArgumentTypeError(
            "missing stability stack(s): " + ", ".join(missing)
        )
    return parsed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--stability",
        required=True,
        type=parse_stability,
        metavar="ds4=pass,llamacpp=pass",
        help="orchestrator-asserted soak/stability status for both stacks",
    )
    return parser.parse_args()


def relative(path: Path) -> str:
    return path.relative_to(REPO_ROOT).as_posix()


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


def read_speed(path: Path) -> dict[str, Any]:
    document = load_object(path)
    cells = field(document, "cells", path)
    if not isinstance(cells, list):
        raise DecisionInputError(f"{relative(path)}.cells: expected an array")
    matches = [
        cell
        for cell in cells
        if isinstance(cell, dict) and cell.get("ctx_tokens") == 4096
    ]
    if len(matches) != 1:
        raise DecisionInputError(
            f"{relative(path)}.cells: expected exactly one cell with ctx_tokens==4096; "
            f"found {len(matches)}"
        )
    cell = matches[0]
    median = field(cell, "median_decode", path)
    if median is None:
        raise DecisionInputError(
            f"{relative(path)}: 4K cell required field 'median_decode' is null"
        )
    speed = require_number(median, f"{relative(path)} 4K median_decode")
    if speed < 0:
        raise DecisionInputError(f"{relative(path)} 4K median_decode: must be nonnegative")
    return {"ctx_tokens": 4096, "median_decode": speed}


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


def collect_candidate(stack: str, stability: str) -> dict[str, Any]:
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
    accuracy = {
        name: read_accuracy(paths[name], name) for name in ACCURACY_EXPECTATIONS
    }
    composite = sum(item["accuracy_percent"] for item in accuracy.values()) / 3.0
    checks = {
        "golden_pass": golden_pass,
        "parity_pass": parity_pass,
        "parity_level": parity_level,
        "stability": stability,
    }
    eligible = (
        golden_pass
        and parity_pass
        and parity_level == "exact-ids"
        and stability == "pass"
    )
    failed_checks: list[str] = []
    if not golden_pass:
        failed_checks.append("golden pass")
    if not parity_pass:
        failed_checks.append("parity pass")
    if parity_level != "exact-ids":
        failed_checks.append("parity exact-ids")
    if stability != "pass":
        failed_checks.append("stability pass")
    return {
        "input_files": {name: relative(path) for name, path in paths.items()},
        "eligibility_inputs": checks,
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
    eligible = [stack for stack in STACKS if candidates[stack]["eligible"]]
    if not eligible:
        return {"verdict": "NO_GO", "winner": None, "rule_branch": "zero_eligible"}
    if len(eligible) == 1:
        return {
            "verdict": "SOLE_CANDIDATE",
            "winner": eligible[0],
            "rule_branch": "one_eligible",
        }

    composites = {
        stack: candidates[stack]["composite_percent"] for stack in STACKS
    }
    delta = abs(composites["ds4"] - composites["llamacpp"])
    details: dict[str, Any] = {"absolute_composite_delta_points": delta}
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
            f"{candidate['composite_percent']:.2f}% | {candidate['speed']['median_decode']:.3f} |"
        )
    winner = decision.get("winner") or "—"
    return "\n".join(
        [
            "# Decision",
            "",
            "| Candidate | Eligibility | GSM8K holdout | MMLU-Pro holdout | HumanEval | Composite | 4K decode tok/s |",
            "|---|---|---:|---:|---:|---:|---:|",
            *rows,
            "",
            f"**Verdict:** {decision['verdict']}",
            "",
            f"**Candidate selected:** {winner}",
            "",
            f"**Rule branch:** `{decision['rule_branch']}`",
            "",
        ]
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
            stack: collect_candidate(stack, args.stability[stack]) for stack in STACKS
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
    print(f"VERDICT: {decision['verdict']}{winner_suffix}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
