#!/usr/bin/env python3
"""Fetch eval datasets as pinned parquet files and convert to the JSONL layout
scripts/31_bench_accuracy.py validates.

Replaces the datasets-server approach (anonymous API 429-rate-limits at our
volume). Every artifact is revision-pinned and SHA-256-verified from
configs/pins/eval-datasets.json before conversion. Orchestrator-authored.
"""

from __future__ import annotations

import hashlib
import json
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PIN_FILE = REPO_ROOT / "configs" / "pins" / "eval-datasets.json"
EVALSETS = REPO_ROOT / "evalsets"
OUT_PINS = EVALSETS / "pins.json"

# key -> (jsonl name, config label, row field subset)
SHAPES = {
    "gsm8k": ("gsm8k-test.jsonl", "main", ["question", "answer"]),
    "mmlu-pro": (
        "mmlu-pro-test.jsonl",
        "default",
        ["question_id", "question", "options", "answer", "category"],
    ),
    "humaneval": (
        "humaneval.jsonl",
        "openai_humaneval",
        ["task_id", "prompt", "canonical_solution", "test", "entry_point"],
    ),
}
PIN_KEYS = {"gsm8k": "gsm8k", "mmlu-pro": "mmlu_pro", "humaneval": "humaneval"}


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    try:
        import pyarrow.parquet as pq
    except ImportError:
        print("pyarrow is required (see requirements-harness.txt)", file=sys.stderr)
        return 2

    pins = json.loads(PIN_FILE.read_text(encoding="utf-8"))
    EVALSETS.mkdir(exist_ok=True)
    out_entries: dict[str, dict] = {}

    for entry in pins["datasets"]:
        key = entry["key"]
        jsonl_name, config, fields = SHAPES[key]
        parquet_path = EVALSETS / (key + ".parquet")

        if not (
            parquet_path.is_file()
            and parquet_path.stat().st_size == entry["bytes"]
            and sha256_file(parquet_path) == entry["sha256"]
        ):
            url = (
                f"https://huggingface.co/datasets/{entry['repo']}/resolve/"
                f"{entry['revision']}/{entry['path']}"
            )
            print(f"{key}: downloading {url}", file=sys.stderr)
            data = urllib.request.urlopen(url, timeout=120).read()
            if len(data) != entry["bytes"] or sha256_bytes(data) != entry["sha256"]:
                print(f"{key}: parquet size/sha mismatch — refusing", file=sys.stderr)
                return 1
            parquet_path.write_bytes(data)
        print(f"{key}: parquet verified", file=sys.stderr)

        table = pq.read_table(parquet_path)
        rows = table.to_pylist()
        if len(rows) != entry["expected_rows"]:
            print(
                f"{key}: {len(rows)} rows, expected {entry['expected_rows']}",
                file=sys.stderr,
            )
            return 1
        jsonl_path = EVALSETS / jsonl_name
        with jsonl_path.open("w", encoding="utf-8") as stream:
            for row in rows:
                slim = {}
                for field in fields:
                    if field not in row:
                        print(f"{key}: missing field {field!r}", file=sys.stderr)
                        return 1
                    slim[field] = row[field]
                stream.write(json.dumps(slim, ensure_ascii=False) + "\n")
        out_entries[PIN_KEYS[key]] = {
            "dataset": entry["repo"],
            "config": config,
            "split": "test",
            "file": jsonl_name,
            "revision": entry["revision"],
            "rows": len(rows),
            "sha256": sha256_file(jsonl_path),
            "source_parquet_sha256": entry["sha256"],
        }
        print(f"{key}: wrote {len(rows)} rows -> {jsonl_name}", file=sys.stderr)

    OUT_PINS.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "generated_at": datetime.now(timezone.utc).isoformat(),
                "datasets": out_entries,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(json.dumps({"ok": True, "datasets": sorted(out_entries)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
