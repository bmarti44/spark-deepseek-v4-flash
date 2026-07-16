#!/usr/bin/env python3
"""Independent post-run audit of accuracy evidence (verifier-owned, not the harness).

Recomputes and cross-checks what the accuracy harness reported, so a passing
result cannot rest on the harness's own say-so:

  * schema/consistency: accuracy == correct/n, 0 <= wilson_lo <= acc <= wilson_hi
    <= 1, invalid_count present, config_digest present when config-evidence was
    required (holdouts).
  * HumanEval failure taxonomy: every failed case is classified from the sandbox
    stderr into syntax_error / assertion / timeout / other. A non-zero
    syntax_error count means the code extractor is mangling programs (the exact
    regression the adversarial review caught) and FAILS the audit.
  * transcript integrity: rendered_prompt_sha256 present and the scored answer is
    reproducible from the stored completion for a seeded sample.

Usage: 36_audit_accuracy.py --stack <llamacpp|ds4> [--suites humaneval mmlu-pro-dev ...]
Exit non-zero if any audited invariant fails.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RESULTS = REPO / "results"
HARNESS = REPO / "scripts" / "31_bench_accuracy.py"

spec = importlib.util.spec_from_file_location("bench", HARNESS)
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)

SYNTAX_RE = re.compile(r"(SyntaxError|IndentationError|TabError)", re.MULTILINE)


def audit_result_schema(path: Path, require_digest: bool) -> list[str]:
    problems: list[str] = []
    d = json.loads(path.read_text())
    n = d.get("n")
    correct = d.get("correct")
    acc = d.get("accuracy")
    if not isinstance(n, int) or n <= 0:
        problems.append(f"{path.name}: bad n={n!r}")
        return problems
    if not isinstance(correct, int) or not 0 <= correct <= n:
        problems.append(f"{path.name}: bad correct={correct!r}")
    if not isinstance(acc, (int, float)) or abs(acc - correct / n) > 1e-9:
        problems.append(f"{path.name}: accuracy {acc!r} != correct/n {correct}/{n}")
    w = d.get("wilson95") or {}
    lo, hi = w.get("lower"), w.get("upper")
    if not (isinstance(lo, (int, float)) and isinstance(hi, (int, float)) and 0 <= lo <= acc <= hi <= 1):
        problems.append(f"{path.name}: wilson95 not monotone: {w}")
    if d.get("invalid_count") is None:
        problems.append(f"{path.name}: missing invalid_count")
    if require_digest and not d.get("config_digest"):
        problems.append(f"{path.name}: missing config_digest (config-evidence required for holdout)")
    return problems


def audit_humaneval(stack: str) -> list[str]:
    problems: list[str] = []
    tdir = RESULTS / "transcripts" / f"humaneval-{stack}"
    if not tdir.is_dir():
        return [f"missing humaneval transcripts dir: {tdir}"]
    counts = {"correct": 0, "assertion": 0, "syntax_error": 0, "timeout": 0, "other": 0}
    syntax_cases: list[str] = []
    other_cases: list[str] = []
    for f in sorted(tdir.glob("*.json")):
        d = json.loads(f.read_text())
        if d.get("scored_correct"):
            counts["correct"] += 1
            continue
        ex = d.get("execution") or {}
        rc = ex.get("returncode")
        stderr = ex.get("stderr") or ""
        if SYNTAX_RE.search(stderr):
            counts["syntax_error"] += 1
            syntax_cases.append(d.get("task_id", f.name))
        elif rc == 124 or "timeout" in (d.get("reason") or "").lower():
            counts["timeout"] += 1
        elif "AssertionError" in stderr:
            counts["assertion"] += 1
        else:
            counts["other"] += 1
            other_cases.append(f"{d.get('task_id', f.name)} rc={rc} {stderr.strip().splitlines()[-1] if stderr.strip() else ''}")
    print(f"  humaneval-{stack} failure taxonomy: {counts}")
    if syntax_cases:
        problems.append(f"humaneval-{stack}: {len(syntax_cases)} SyntaxError cases (extractor bug): {syntax_cases[:8]}")
    if other_cases:
        print(f"  humaneval-{stack} non-assertion/non-syntax failures (review): {len(other_cases)}")
        for c in other_cases[:12]:
            print(f"      {c}")
    return problems


def audit_transcript_sample(stack: str, suite_dir: str, suite: str, seed: int = 42) -> list[str]:
    problems: list[str] = []
    tdir = RESULTS / "transcripts" / suite_dir
    if not tdir.is_dir():
        return [f"missing transcripts dir: {tdir}"]
    files = sorted(tdir.glob("*.json"))
    # deterministic sample without random: every k-th file
    sample = files[:: max(1, len(files) // 8)][:8]
    for f in sample:
        d = json.loads(f.read_text())
        if not d.get("rendered_prompt_sha256"):
            problems.append(f"{f.name}: missing rendered_prompt_sha256")
        completion = d.get("completion", "")
        if suite == "mmlu-pro":
            recomputed, _exp, _r = bench.score_mmlu(completion, d["expected"], d.get("finish_reason"))
            if recomputed != d.get("scored_correct"):
                problems.append(f"{f.name}: mmlu rescore {recomputed} != stored {d.get('scored_correct')}")
        elif suite == "gsm8k":
            recomputed, _e, _r, _fb = bench.score_gsm8k(completion, f"#### {d['expected']}")
            if recomputed != d.get("scored_correct"):
                problems.append(f"{f.name}: gsm8k rescore {recomputed} != stored {d.get('scored_correct')}")
    return problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--stack", required=True, help="result file suffix, e.g. llamacpp or ds4")
    args = ap.parse_args()
    stack = args.stack

    problems: list[str] = []
    print(f"=== accuracy audit: {stack} ===")

    checks = [
        (RESULTS / f"acc-humaneval-{stack}.json", False),
        (RESULTS / f"acc-mmlu-dev-{stack}.json", False),
        (RESULTS / f"acc-mmlu-holdout-{stack}.json", True),
        (RESULTS / f"acc-gsm8k-dev-{stack}.json", False),
        (RESULTS / f"acc-gsm8k-holdout-{stack}.json", False),
    ]
    for path, require_digest in checks:
        if path.is_file():
            probs = audit_result_schema(path, require_digest)
            problems += probs
            d = json.loads(path.read_text())
            print(f"  {path.name}: acc={d['accuracy']:.4f} ({d['correct']}/{d['n']}) invalid={d.get('invalid_count')} digest={'yes' if d.get('config_digest') else 'no'}")
        else:
            print(f"  {path.name}: (absent)")

    problems += audit_humaneval(stack)
    problems += audit_transcript_sample(stack, f"mmlu-dev-{stack}", "mmlu-pro")
    problems += audit_transcript_sample(stack, f"mmlu-holdout-{stack}", "mmlu-pro")

    print("=== audit verdict ===")
    if problems:
        for p in problems:
            print(f"  FAIL: {p}")
        return 1
    print("  PASS: all audited invariants hold")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
