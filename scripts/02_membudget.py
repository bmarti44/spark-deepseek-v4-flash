#!/usr/bin/env python3
"""Calculate whether a model preload fits the current UMA memory budget."""

from __future__ import annotations

import argparse
import glob
import json
import math
import os
import sys
from pathlib import Path


BYTES_PER_GIB = 2**30
KIB_PER_GIB = 2**20


def nonnegative_float(value: str) -> float:
    """Parse a finite, non-negative floating-point argument."""
    number = float(value)
    if not math.isfinite(number) or number < 0:
        raise argparse.ArgumentTypeError("must be a finite number >= 0")
    return number


def nonnegative_int(value: str) -> int:
    """Parse a non-negative integer argument."""
    number = int(value)
    if number < 0:
        raise argparse.ArgumentTypeError("must be >= 0")
    return number


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Calculate a static model preload memory budget. All GiB values use "
            "binary gibibytes (1 GiB = 2^30 bytes)."
        )
    )
    weights = parser.add_mutually_exclusive_group(required=True)
    weights.add_argument(
        "--weights",
        nargs="+",
        metavar="PATH_OR_GLOB",
        help="one or more weight files or glob patterns; matched file sizes are summed",
    )
    weights.add_argument(
        "--weights-gib",
        type=nonnegative_float,
        help="weight size in GiB instead of discovering files",
    )
    parser.add_argument("--ctx", type=nonnegative_int, required=True, help="context length in tokens")
    parser.add_argument(
        "--kv-bytes-per-token",
        type=nonnegative_float,
        required=True,
        help="KV-cache bytes allocated per context token",
    )
    parser.add_argument(
        "--overhead-gib",
        type=nonnegative_float,
        default=8.0,
        help="CUDA context and compute-buffer overhead in GiB (default: 8.0)",
    )
    parser.add_argument(
        "--extra-gib",
        type=nonnegative_float,
        default=0.0,
        help="additional allocation, such as a drafter, in GiB (default: 0)",
    )
    parser.add_argument(
        "--floor-gib",
        type=nonnegative_float,
        default=16.0,
        help="minimum projected free memory in GiB (default: 16.0)",
    )
    parser.add_argument("--out", default="-", metavar="PATH", help="JSON output path (default: stdout)")
    return parser


def resolve_weight_files(patterns: list[str], parser: argparse.ArgumentParser) -> list[str]:
    """Expand patterns into a stable, de-duplicated list of regular files."""
    matched: set[str] = set()
    for pattern in patterns:
        paths = glob.glob(pattern)
        if not paths:
            parser.error(f"weight path or glob matched no files: {pattern}")
        for path in paths:
            if not os.path.isfile(path):
                parser.error(f"weight path is not a regular file: {path}")
            matched.add(os.path.abspath(path))
    return sorted(matched)


def read_mem_available_gib() -> float:
    """Read MemAvailable from procfs and convert KiB to GiB."""
    with open("/proc/meminfo", encoding="ascii") as meminfo:
        for line in meminfo:
            key, value = line.split(":", maxsplit=1)
            if key == "MemAvailable":
                fields = value.split()
                if len(fields) != 2 or fields[1] != "kB":
                    raise RuntimeError("unexpected MemAvailable format in /proc/meminfo")
                return int(fields[0]) / KIB_PER_GIB
    raise RuntimeError("MemAvailable is missing from /proc/meminfo")


def rounded(value: float) -> float:
    return round(value, 2)


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    weight_files: list[str] | None = None
    if args.weights is not None:
        weight_files = resolve_weight_files(args.weights, parser)
        weights_gib = sum(os.path.getsize(path) for path in weight_files) / BYTES_PER_GIB
    else:
        weights_gib = args.weights_gib

    mem_available_now_gib = read_mem_available_gib()
    kv_cache_gib = args.ctx * args.kv_bytes_per_token / BYTES_PER_GIB
    projected_free_gib = mem_available_now_gib - (
        weights_gib + kv_cache_gib + args.overhead_gib + args.extra_gib
    )
    passed = projected_free_gib >= args.floor_gib

    report = {
        "weights": args.weights,
        "weight_files": weight_files,
        "weights_gib": rounded(weights_gib),
        "ctx": args.ctx,
        "kv_bytes_per_token": rounded(args.kv_bytes_per_token),
        "overhead_gib": rounded(args.overhead_gib),
        "extra_gib": rounded(args.extra_gib),
        "mem_available_now_gib": rounded(mem_available_now_gib),
        "projected_free_gib": rounded(projected_free_gib),
        "floor_gib": rounded(args.floor_gib),
        "pass": passed,
    }
    output = json.dumps(report, separators=(",", ":")) + "\n"

    if args.out == "-":
        sys.stdout.write(output)
    else:
        Path(args.out).write_text(output, encoding="utf-8")
    return 0 if passed else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"02_membudget.py: {error}", file=sys.stderr)
        raise SystemExit(2)
