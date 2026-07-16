#!/usr/bin/env python3
"""Run deterministic accuracy suites against a plain-completions endpoint."""

from __future__ import annotations

import argparse
import decimal
import fcntl
import hashlib
import importlib.util
import json
import math
import os
import random
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from types import ModuleType
from typing import Any, BinaryIO


REQUEST_TIMEOUT_S = 300
SEED = 42
REPO_ROOT = Path(__file__).resolve().parent.parent
EVALSETS_DIR = REPO_ROOT / "evalsets"
PINS_PATH = EVALSETS_DIR / "pins.json"
LEDGER_PATH = REPO_ROOT / "results" / "holdout-ledger.json"
ENCODER_PATH = (
    REPO_ROOT / "vendor" / "official-encoding" / "encoding" / "encoding_dsv4.py"
)
EXPECTED_ROWS = {"gsm8k": 1319, "mmlu-pro": 12032, "humaneval": 164}
DATASET_FILES = {
    "gsm8k": EVALSETS_DIR / "gsm8k-test.jsonl",
    "mmlu-pro": EVALSETS_DIR / "mmlu-pro-test.jsonl",
    "humaneval": EVALSETS_DIR / "humaneval.jsonl",
}
PIN_KEYS = {"gsm8k": "gsm8k", "mmlu-pro": "mmlu_pro", "humaneval": "humaneval"}
PIN_EXPECTATIONS = {
    "gsm8k": {
        "dataset": "openai/gsm8k",
        "config": "main",
        "split": "test",
        "file": "gsm8k-test.jsonl",
    },
    "mmlu-pro": {
        "dataset": "TIGER-Lab/MMLU-Pro",
        "config": "default",
        "split": "test",
        "file": "mmlu-pro-test.jsonl",
    },
    "humaneval": {
        "dataset": "openai/openai_humaneval",
        "config": "openai_humaneval",
        "split": "test",
        "file": "humaneval.jsonl",
    },
}
MAX_TOKENS = {"gsm8k": 512, "mmlu-pro": 256, "humaneval": 512}
HUMANEVAL_STOPS = ["\ndef ", "\nclass ", "\nif __name__", "\nprint("]
GSM_ANSWER_RE = re.compile(r"Answer:\s*(-?[\d,\.]+)", re.IGNORECASE)
NUMBER_RE = re.compile(r"-?(?:\d[\d,]*)(?:\.\d+)?")
MMLU_ANSWER_RE = re.compile(r"Answer:\s*([A-J])", re.IGNORECASE)
LETTER_RE = re.compile(r"(?<![A-Za-z])([A-J])(?![A-Za-z])")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True, help="server root URL")
    parser.add_argument("--api-key-file", type=Path, help="file containing bearer token")
    parser.add_argument("--out", required=True, type=Path, help="results JSON path")
    parser.add_argument("--stack-label", required=True, help="stack name recorded in output")
    parser.add_argument(
        "--extra-body",
        default=None,
        help="JSON object merged into every request before harness-critical keys",
    )
    parser.add_argument("--suite", required=True, choices=("gsm8k", "mmlu-pro", "humaneval"))
    parser.add_argument("--split", required=True, choices=("dev", "holdout", "all"))
    parser.add_argument(
        "--transcripts-dir", required=True, type=Path, help="directory for one JSON transcript per item"
    )
    parser.add_argument(
        "--completions-endpoint",
        default="/v1/completions",
        help="plain completions path (default: /v1/completions)",
    )
    parser.add_argument(
        "--config-hash",
        help="serving-config identifier (required for holdout runs)",
    )
    args = parser.parse_args()
    if args.extra_body is not None:
        try:
            args.extra_body = json.loads(args.extra_body)
        except json.JSONDecodeError as error:
            parser.error(f"--extra-body is not valid JSON: {error}")
        if not isinstance(args.extra_body, dict):
            parser.error("--extra-body must be a JSON object")
    if not args.completions_endpoint.startswith("/"):
        parser.error("--completions-endpoint must start with /")
    args.base_url = args.base_url.rstrip("/")
    if not args.base_url:
        parser.error("--base-url must not be empty")
    if args.suite == "humaneval" and args.split != "all":
        parser.error("HumanEval supports --split all only")
    if args.suite != "humaneval" and args.split == "all":
        parser.error("GSM8K and MMLU-Pro support --split dev or holdout only")
    if args.split == "holdout" and not args.config_hash:
        parser.error("--config-hash is required for holdout runs")
    if args.config_hash is not None and not args.config_hash.strip():
        parser.error("--config-hash must not be empty")
    return args


def load_api_key(path: Path | None) -> str | None:
    if path is None:
        return None
    key = path.read_text(encoding="utf-8").strip()
    if not key:
        raise ValueError(f"API key file is empty: {path}")
    return key


def load_encoder() -> ModuleType:
    if not ENCODER_PATH.is_file():
        raise RuntimeError(f"official encoder is missing: {ENCODER_PATH}")
    spec = importlib.util.spec_from_file_location("official_encoding_dsv4", ENCODER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot construct import spec for {ENCODER_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.dont_write_bytecode = True
    spec.loader.exec_module(module)
    if not callable(getattr(module, "encode_messages", None)):
        raise RuntimeError(f"official encoder has no encode_messages(): {ENCODER_PATH}")
    return module


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def load_pins() -> tuple[dict[str, Any], dict[str, str]]:
    try:
        document = json.loads(PINS_PATH.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RuntimeError(f"cannot read {PINS_PATH}: {error}") from error
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        raise RuntimeError(f"invalid pins schema in {PINS_PATH}")
    entries = document.get("datasets")
    if not isinstance(entries, dict):
        raise RuntimeError(f"invalid datasets object in {PINS_PATH}")
    revisions: dict[str, str] = {}
    for key, entry in entries.items():
        if not isinstance(entry, dict):
            raise RuntimeError(f"invalid pins entry: {key}")
        dataset = entry.get("dataset")
        revision = entry.get("revision")
        if not isinstance(dataset, str) or not isinstance(revision, str) or len(revision) != 40:
            raise RuntimeError(f"invalid dataset/revision in pins entry: {key}")
        revisions[dataset] = revision
    return document, revisions


def load_jsonl(suite: str, pins: dict[str, Any]) -> list[dict[str, Any]]:
    path = DATASET_FILES[suite]
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise RuntimeError(f"cannot read {path}: {error}") from error
    if len(lines) != EXPECTED_ROWS[suite]:
        raise RuntimeError(f"{path} has {len(lines)} rows; expected {EXPECTED_ROWS[suite]}")
    entry = pins["datasets"].get(PIN_KEYS[suite])
    if not isinstance(entry, dict):
        raise RuntimeError(f"pins entry is missing for {suite}")
    for key, expected_value in PIN_EXPECTATIONS[suite].items():
        if entry.get(key) != expected_value:
            raise RuntimeError(
                f"pins mismatch for {suite}.{key}: "
                f"expected={expected_value!r} actual={entry.get(key)!r}"
            )
    if entry.get("rows") != len(lines):
        raise RuntimeError(f"pins row count does not match {path}")
    digest = sha256_file(path)
    if entry.get("sha256") != digest:
        raise RuntimeError(
            f"SHA-256 mismatch for {path}: pinned={entry.get('sha256')!r} actual={digest}"
        )
    rows: list[dict[str, Any]] = []
    for line_number, line in enumerate(lines, 1):
        try:
            row = json.loads(line)
        except json.JSONDecodeError as error:
            raise RuntimeError(f"{path} line {line_number} is invalid JSON: {error}") from error
        if not isinstance(row, dict):
            raise RuntimeError(f"{path} line {line_number} is not an object")
        validate_dataset_row(suite, row, line_number)
        rows.append(row)
    return rows


def validate_dataset_row(suite: str, row: dict[str, Any], line_number: int) -> None:
    expected_fields = {
        "gsm8k": {"question", "answer"},
        "mmlu-pro": {"question_id", "question", "options", "answer", "category"},
        "humaneval": {"task_id", "prompt", "canonical_solution", "test", "entry_point"},
    }[suite]
    if set(row) != expected_fields:
        raise RuntimeError(
            f"{suite} line {line_number} fields differ: "
            f"expected={sorted(expected_fields)!r} actual={sorted(row)!r}"
        )
    if suite == "gsm8k":
        if not isinstance(row["question"], str) or not isinstance(row["answer"], str):
            raise RuntimeError(f"GSM8K line {line_number} has non-string fields")
        if "#### " not in row["answer"]:
            raise RuntimeError(f"GSM8K line {line_number} has no #### reference answer")
        reference = row["answer"].rsplit("#### ", 1)[1].strip().replace(",", "")
        try:
            reference_number = decimal.Decimal(reference)
        except decimal.InvalidOperation as error:
            raise RuntimeError(f"GSM8K line {line_number} has an invalid reference number") from error
        if not reference_number.is_finite():
            raise RuntimeError(f"GSM8K line {line_number} has a non-finite reference number")
    elif suite == "mmlu-pro":
        if not isinstance(row["question_id"], (str, int)) or isinstance(row["question_id"], bool):
            raise RuntimeError(f"MMLU-Pro line {line_number} has invalid question_id")
        if not isinstance(row["question"], str) or not isinstance(row["category"], str):
            raise RuntimeError(f"MMLU-Pro line {line_number} has invalid question/category")
        options = row["options"]
        if (
            not isinstance(options, list)
            or not 1 <= len(options) <= 10
            or any(not isinstance(option, str) for option in options)
        ):
            raise RuntimeError(f"MMLU-Pro line {line_number} has invalid options")
        if not isinstance(row["answer"], str) or not re.fullmatch(r"[A-J]", row["answer"].upper()):
            raise RuntimeError(f"MMLU-Pro line {line_number} has invalid answer")
    elif any(not isinstance(row[field], str) for field in expected_fields):
        raise RuntimeError(f"HumanEval line {line_number} has non-string fields")


def select_indices(suite: str, split: str, rows: list[dict[str, Any]]) -> list[int]:
    if suite == "gsm8k":
        indices = list(range(1319))
        random.Random(SEED).shuffle(indices)
        return indices[:100] if split == "dev" else indices[100:200]
    if suite == "humaneval":
        return list(range(len(rows)))

    by_category: dict[str, list[tuple[str | int, int]]] = {}
    for index, row in enumerate(rows):
        category = row.get("category")
        question_id = row.get("question_id")
        if not isinstance(category, str) or not isinstance(question_id, (str, int)):
            raise RuntimeError(f"MMLU-Pro row {index} has invalid category/question_id")
        by_category.setdefault(category, []).append((question_id, index))

    selected: list[int] = []
    total = len(rows)
    for category in sorted(by_category):
        id_types = {type(question_id) for question_id, _ in by_category[category]}
        if len(id_types) != 1:
            raise RuntimeError(f"MMLU-Pro category {category!r} mixes question_id types")
        category_rows = sorted(by_category[category], key=lambda pair: pair[0])
        quota = round(500 * len(category_rows) / total)
        selected_indices = {
            index
            for _, index in sorted(
                category_rows,
                key=lambda pair: (
                    hashlib.sha256(str(pair[0]).encode("utf-8")).hexdigest(),
                    pair[0],
                ),
            )[:quota]
        }
        selected_in_question_id_order = [
            index for _, index in category_rows if index in selected_indices
        ]
        parity = 0 if split == "dev" else 1
        selected.extend(
            index
            for position, index in enumerate(selected_in_question_id_order)
            if position % 2 == parity
        )
    return selected


def render_item(
    suite: str, row: dict[str, Any], encoder: ModuleType | None
) -> tuple[str, str]:
    if suite == "humaneval":
        prompt = row.get("prompt")
        if not isinstance(prompt, str):
            raise RuntimeError("HumanEval prompt is not a string")
        # The official encoder only implements chat-message rendering. HumanEval
        # is a raw code-continuation task, so it must bypass the chat wrapper.
        return prompt, "raw"
    if encoder is None:
        raise RuntimeError("official encoder was not loaded")
    question = row.get("question")
    if not isinstance(question, str):
        raise RuntimeError(f"{suite} question is not a string")
    if suite == "gsm8k":
        content = question + (
            "\n\nThink briefly if needed, then end with the final numeric answer on its own "
            "line in the form: Answer: <number>"
        )
    else:
        options = row.get("options")
        if not isinstance(options, list) or not options or len(options) > 10:
            raise RuntimeError("MMLU-Pro options must be a nonempty list of at most 10 items")
        option_lines = []
        for option_index, option in enumerate(options):
            if not isinstance(option, str):
                raise RuntimeError("MMLU-Pro option is not a string")
            option_lines.append(f"{chr(ord('A') + option_index)}. {option}")
        content = question + "\n\n" + "\n".join(option_lines) + (
            "\n\nReply with the single letter of the correct option in the form: "
            "Answer: <letter>"
        )
    rendered = encoder.encode_messages([{"role": "user", "content": content}], thinking_mode="chat")
    if not isinstance(rendered, str) or not rendered:
        raise RuntimeError("official encoder returned an invalid prompt")
    return rendered, "official-encoder-chat-nonthinking"


def response_preview_without_prompt(raw: bytes, prompt: str) -> str:
    """Preserve an error body while ensuring it cannot echo the full prompt."""
    try:
        document = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return raw.decode("utf-8", errors="replace").replace(
            prompt, "<rendered-prompt-redacted>"
        )
    return json.dumps(
        redact_prompt(document, prompt), ensure_ascii=False, separators=(",", ":")
    )


class Client:
    def __init__(
        self,
        base_url: str,
        api_key: str | None,
        endpoint: str,
        extra_body: dict[str, Any] | None,
    ) -> None:
        self.base_url = base_url
        self.api_key = api_key
        self.endpoint = endpoint
        self.extra_body = dict(extra_body or {})

    def headers(self) -> dict[str, str]:
        headers = {"Accept": "application/json"}
        if self.api_key is not None:
            headers["Authorization"] = f"Bearer {self.api_key}"
        return headers

    def get_model(self) -> tuple[str, Any]:
        request = urllib.request.Request(
            self.base_url + "/v1/models", headers=self.headers(), method="GET"
        )
        try:
            with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_S) as response:
                status = response.status
                raw = response.read()
        except urllib.error.HTTPError as error:
            raw = error.read()
            raise RuntimeError(
                f"GET /v1/models returned HTTP {error.code}: {raw.decode('utf-8', errors='replace')}"
            ) from error
        if status != 200:
            raise RuntimeError(
                f"GET /v1/models returned HTTP {status}: {raw.decode('utf-8', errors='replace')}"
            )
        try:
            document = json.loads(raw)
            data = document["data"]
        except (UnicodeDecodeError, json.JSONDecodeError, KeyError, TypeError) as error:
            raise RuntimeError(f"invalid models response: {raw.decode('utf-8', errors='replace')}") from error
        if not isinstance(data, list) or len(data) != 1:
            raise RuntimeError(f"expected exactly one model, received {data!r}")
        model = data[0].get("id") if isinstance(data[0], dict) else None
        if not isinstance(model, str) or not model:
            raise RuntimeError(f"model id is missing or invalid: {data[0]!r}")
        return model, document

    def complete(
        self, model: str, prompt: str, max_tokens: int, stops: list[str] | None
    ) -> tuple[str, Any, dict[str, Any]]:
        payload = dict(self.extra_body)
        payload.update(
            {
                "model": model,
                "prompt": prompt,
                "max_tokens": max_tokens,
                "temperature": 0,
                "seed": SEED,
                "stream": False,
            }
        )
        if stops is not None:
            payload["stop"] = stops
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        headers = self.headers()
        headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            self.base_url + self.endpoint, data=body, headers=headers, method="POST"
        )
        started = time.perf_counter()
        try:
            with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_S) as response:
                status = response.status
                raw = response.read()
        except urllib.error.HTTPError as error:
            raw = error.read()
            raise RuntimeError(
                f"POST {self.endpoint} returned HTTP {error.code}: "
                f"{response_preview_without_prompt(raw, prompt)}"
            ) from error
        elapsed = time.perf_counter() - started
        if status != 200:
            raise RuntimeError(
                f"POST {self.endpoint} returned HTTP {status}: "
                f"{response_preview_without_prompt(raw, prompt)}"
            )
        try:
            document = json.loads(raw)
            completion = document["choices"][0]["text"]
        except (UnicodeDecodeError, json.JSONDecodeError, KeyError, IndexError, TypeError) as error:
            raise RuntimeError(
                f"invalid completions response: {response_preview_without_prompt(raw, prompt)}"
            ) from error
        if not isinstance(completion, str):
            raise RuntimeError(f"completion text is not a string: {completion!r}")
        # Prompts are deliberately omitted here. Every transcript has its SHA-256,
        # and only the seeded audit sample stores the rendered prompt itself.
        recorded_payload = {key: value for key, value in payload.items() if key != "prompt"}
        request_record = {
            "endpoint": self.endpoint,
            "payload_without_prompt": recorded_payload,
            "elapsed_s": elapsed,
        }
        return completion, document, request_record


def parse_decimal(text: str) -> decimal.Decimal | None:
    try:
        value = decimal.Decimal(text.replace(",", ""))
    except decimal.InvalidOperation:
        return None
    return value if value.is_finite() else None


def score_gsm8k(completion: str, answer: Any) -> tuple[bool, str, str]:
    if not isinstance(answer, str) or "#### " not in answer:
        raise RuntimeError(f"invalid GSM8K reference answer: {answer!r}")
    expected_text = answer.rsplit("#### ", 1)[1].strip()
    expected = parse_decimal(expected_text)
    if expected is None:
        raise RuntimeError(f"invalid GSM8K reference number: {expected_text!r}")
    explicit = GSM_ANSWER_RE.findall(completion)
    candidates = explicit if explicit else NUMBER_RE.findall(completion)
    if not candidates:
        return False, expected_text, "unparseable: no numeric answer found"
    candidate_text = candidates[-1]
    candidate = parse_decimal(candidate_text)
    if candidate is None:
        return False, expected_text, f"unparseable: invalid numeric answer {candidate_text!r}"
    if candidate == expected:
        return True, expected_text, "correct"
    return False, expected_text, f"incorrect: parsed={candidate_text!r} expected={expected_text!r}"


def score_mmlu(completion: str, answer: Any) -> tuple[bool, str, str]:
    if not isinstance(answer, str) or not re.fullmatch(r"[A-J]", answer.upper()):
        raise RuntimeError(f"invalid MMLU-Pro reference answer: {answer!r}")
    expected = answer.upper()
    explicit = MMLU_ANSWER_RE.findall(completion)
    fallback = LETTER_RE.findall(completion.upper()) if not explicit else []
    candidates = explicit or fallback
    if not candidates:
        return False, expected, "unparseable: no standalone answer letter A-J found"
    candidate = candidates[-1].upper()
    if candidate == expected:
        return True, expected, "correct"
    return False, expected, f"incorrect: parsed={candidate!r} expected={expected!r}"


def expected_for_row(suite: str, row: dict[str, Any]) -> str:
    if suite == "gsm8k":
        return row["answer"].rsplit("#### ", 1)[1].strip()
    if suite == "mmlu-pro":
        return row["answer"].upper()
    return row["canonical_solution"]


def run_humaneval(
    row: dict[str, Any], completion: str, cases_root: Path, case_name: str
) -> tuple[bool, str, str, dict[str, Any]]:
    required = ("prompt", "canonical_solution", "test", "entry_point", "task_id")
    if any(not isinstance(row.get(field), str) for field in required):
        raise RuntimeError(f"HumanEval row has invalid fields: {row!r}")
    case_dir = cases_root / case_name
    case_dir.mkdir(mode=0o755)
    source = (
        row["prompt"]
        + completion
        + "\n\n"
        + row["test"]
        + f"\n\ncheck({row['entry_point']})\n"
    )
    main_path = case_dir / "main.py"
    main_path.write_text(source, encoding="utf-8")
    main_path.chmod(0o444)
    command = [
        "docker",
        "run",
        "--rm",
        "--network",
        "none",
        "--cap-drop",
        "ALL",
        "--security-opt",
        "no-new-privileges",
        "--memory",
        "512m",
        "--memory-swap",
        "512m",
        "--pids-limit",
        "128",
        "--cpus",
        "1",
        "--read-only",
        "--tmpfs",
        "/tmp",
        "-u",
        "65534:65534",
        "-v",
        f"{case_dir.resolve()}:/case:ro",
        "python:3.12-slim",
        "timeout",
        "10",
        "python",
        "/case/main.py",
    ]
    try:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        execution = {
            "command": command,
            "returncode": completed.returncode,
            "stdout": completed.stdout,
            "stderr": completed.stderr,
        }
        correct = completed.returncode == 0
        if correct:
            reason = "correct"
        elif completed.returncode == 124:
            reason = "sandbox timeout after 10 seconds"
        else:
            reason = f"sandbox failed with exit {completed.returncode}"
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout.decode("utf-8", errors="replace") if isinstance(error.stdout, bytes) else error.stdout
        stderr = error.stderr.decode("utf-8", errors="replace") if isinstance(error.stderr, bytes) else error.stderr
        execution = {
            "command": command,
            "returncode": None,
            "stdout": stdout or "",
            "stderr": stderr or "",
            "host_timeout_s": 30,
        }
        correct = False
        reason = "sandbox host timeout after 30 seconds"
    except (FileNotFoundError, OSError) as error:
        execution = {
            "command": command,
            "returncode": None,
            "stdout": "",
            "stderr": f"{type(error).__name__}: {error}",
        }
        correct = False
        reason = f"sandbox launch failed: {type(error).__name__}: {error}"
    return correct, row["canonical_solution"], reason, execution


def wilson95(correct: int, total: int) -> list[float]:
    if total <= 0:
        raise ValueError("Wilson interval requires a positive sample count")
    z = 1.959963984540054
    proportion = correct / total
    denominator = 1 + z * z / total
    centre = (proportion + z * z / (2 * total)) / denominator
    margin = (
        z
        * math.sqrt(proportion * (1 - proportion) / total + z * z / (4 * total * total))
        / denominator
    )
    return [max(0.0, centre - margin), min(1.0, centre + margin)]


def safe_transcript_name(suite: str, dataset_index: int, row: dict[str, Any]) -> str:
    raw_id = row.get("task_id") if suite == "humaneval" else row.get("question_id", dataset_index)
    identifier = re.sub(r"[^A-Za-z0-9_.-]+", "_", str(raw_id)).strip("._") or str(dataset_index)
    return f"{dataset_index:05d}-{identifier}.json"


def redact_prompt(value: Any, prompt: str) -> Any:
    """Remove an echoed full prompt while preserving the rest of a transcript."""
    if isinstance(value, str):
        return value.replace(prompt, "<rendered-prompt-redacted>")
    if isinstance(value, list):
        return [redact_prompt(item, prompt) for item in value]
    if isinstance(value, dict):
        return {key: redact_prompt(item, prompt) for key, item in value.items()}
    return value


def write_json(path: Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(document, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def acquire_holdout_ledger(
    stack_label: str, suite: str, config_hash: str
) -> tuple[BinaryIO, list[dict[str, Any]]]:
    LEDGER_PATH.parent.mkdir(parents=True, exist_ok=True)
    stream = LEDGER_PATH.open("a+b")
    fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
    stream.seek(0)
    raw = stream.read()
    if raw:
        try:
            entries = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            stream.close()
            raise RuntimeError(f"invalid holdout ledger {LEDGER_PATH}: {error}") from error
        if not isinstance(entries, list) or any(not isinstance(entry, dict) for entry in entries):
            stream.close()
            raise RuntimeError(f"holdout ledger is not a JSON array of objects: {LEDGER_PATH}")
    else:
        entries = []
    key = (stack_label, suite, config_hash)
    for entry in entries:
        if (entry.get("stack_label"), entry.get("suite"), entry.get("config_hash")) == key:
            stream.close()
            raise HoldoutAlreadyRun(
                f"holdout already recorded for stack={stack_label!r}, suite={suite!r}, "
                f"config_hash={config_hash!r}"
            )
    return stream, entries


def append_holdout_ledger(
    stream: BinaryIO, entries: list[dict[str, Any]], entry: dict[str, Any]
) -> None:
    entries.append(entry)
    encoded = (json.dumps(entries, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    stream.seek(0)
    stream.truncate()
    stream.write(encoded)
    stream.flush()
    os.fsync(stream.fileno())
    stream.close()


class HoldoutAlreadyRun(RuntimeError):
    pass


def main() -> int:
    args = parse_args()
    ledger_stream: BinaryIO | None = None
    ledger_entries: list[dict[str, Any]] | None = None
    if args.split == "holdout":
        try:
            ledger_stream, ledger_entries = acquire_holdout_ledger(
                args.stack_label, args.suite, args.config_hash
            )
        except HoldoutAlreadyRun as error:
            print(f"REFUSED: {error}", file=os.sys.stderr)
            return 3

    started_at = utc_now()
    try:
        pins, revisions = load_pins()
        rows = load_jsonl(args.suite, pins)
        indices = select_indices(args.suite, args.split, rows)
        if not indices:
            raise RuntimeError("deterministic split selected zero items")
        encoder = None if args.suite == "humaneval" else load_encoder()
        client = Client(
            args.base_url,
            load_api_key(args.api_key_file),
            args.completions_endpoint,
            args.extra_body,
        )
        model, models_response = client.get_model()
        args.transcripts_dir.mkdir(parents=True, exist_ok=True)
        audit_count = min(10, len(indices))
        audit_positions = set(random.Random(SEED).sample(range(len(indices)), audit_count))
        correct_count = 0
        invalid_count = 0
        transcript_files: list[str] = []

        with tempfile.TemporaryDirectory(prefix="dsv4-humaneval-") as temporary_cases:
            cases_root = Path(temporary_cases)
            for run_position, dataset_index in enumerate(indices):
                row = rows[dataset_index]
                rendered, rendering = render_item(args.suite, row, encoder)
                prompt_sha = hashlib.sha256(rendered.encode("utf-8")).hexdigest()
                item_id = row.get("task_id", row.get("question_id", dataset_index))
                completion = ""
                response_document: Any = None
                request_record: dict[str, Any] | None = None
                execution: dict[str, Any] | None = None
                expected: Any = expected_for_row(args.suite, row)
                scored_correct = False
                reason = ""
                try:
                    completion, response_document, request_record = client.complete(
                        model,
                        rendered,
                        MAX_TOKENS[args.suite],
                        HUMANEVAL_STOPS if args.suite == "humaneval" else None,
                    )
                    if args.suite == "gsm8k":
                        scored_correct, expected, reason = score_gsm8k(completion, row.get("answer"))
                    elif args.suite == "mmlu-pro":
                        scored_correct, expected, reason = score_mmlu(completion, row.get("answer"))
                    else:
                        scored_correct, expected, reason, execution = run_humaneval(
                            row, completion, cases_root, f"case-{run_position:05d}"
                        )
                except Exception as error:
                    scored_correct = False
                    error_text = str(error).replace(rendered, "<rendered-prompt-redacted>")
                    reason = f"invalid: {type(error).__name__}: {error_text}"

                if scored_correct:
                    correct_count += 1
                if reason.startswith(
                    (
                        "invalid:",
                        "unparseable:",
                        "sandbox timeout",
                        "sandbox host timeout",
                        "sandbox launch failed",
                    )
                ):
                    invalid_count += 1
                transcript: dict[str, Any] = {
                    "index": dataset_index,
                    "task_id": item_id,
                    "rendered_prompt_sha256": prompt_sha,
                    "rendering": rendering,
                    "completion": completion,
                    "expected": expected,
                    "scored_correct": scored_correct,
                    "reason": reason,
                    "request": request_record,
                    "response": redact_prompt(response_document, rendered),
                }
                if execution is not None:
                    transcript["execution"] = execution
                if run_position in audit_positions:
                    transcript["rendered_prompt"] = rendered
                transcript_path = args.transcripts_dir / safe_transcript_name(
                    args.suite, dataset_index, row
                )
                write_json(transcript_path, transcript)
                transcript_files.append(str(transcript_path.resolve()))
                print(
                    f"[{run_position + 1}/{len(indices)}] index={dataset_index} "
                    f"correct={scored_correct} reason={reason}",
                    flush=True,
                )

        finished_at = utc_now()
        result = {
            "stack_label": args.stack_label,
            "suite": args.suite,
            "split": args.split,
            "config_hash": args.config_hash,
            "model": model,
            "n": len(indices),
            "correct": correct_count,
            "accuracy": correct_count / len(indices),
            "wilson95": wilson95(correct_count, len(indices)),
            "invalid_count": invalid_count,
            "started_at": started_at,
            "finished_at": finished_at,
            "dataset_revisions": revisions,
            "transcript_dir": str(args.transcripts_dir.resolve()),
            "transcript_files": transcript_files,
            "models_response": models_response,
            "generation": {
                "endpoint": args.completions_endpoint,
                "temperature": 0,
                "seed": SEED,
                "max_tokens": MAX_TOKENS[args.suite],
                "stop": HUMANEVAL_STOPS if args.suite == "humaneval" else None,
                "extra_body": args.extra_body,
            },
        }
        write_json(args.out, result)
        if ledger_stream is not None and ledger_entries is not None:
            append_holdout_ledger(
                ledger_stream,
                ledger_entries,
                {
                    "stack_label": args.stack_label,
                    "suite": args.suite,
                    "config_hash": args.config_hash,
                    "completed_at": finished_at,
                    "result": str(args.out.resolve()),
                    "n": len(indices),
                    "correct": correct_count,
                },
            )
            ledger_stream = None
        return 0
    finally:
        if ledger_stream is not None:
            ledger_stream.close()


if __name__ == "__main__":
    raise SystemExit(main())
