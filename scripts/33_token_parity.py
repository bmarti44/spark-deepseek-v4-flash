#!/usr/bin/env python3
"""Gate evaluation on prompt-token parity with a serving backend."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shlex
import sys
import tempfile
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from types import ModuleType
from typing import Any


REQUEST_TIMEOUT_S = 300
REPO_ROOT = Path(__file__).resolve().parent.parent
TOKENIZER_PATH = REPO_ROOT / "vendor" / "official-encoding" / "tokenizer.json"
ENCODER_PATH = (
    REPO_ROOT / "vendor" / "official-encoding" / "encoding" / "encoding_dsv4.py"
)
DEFAULT_DS4_CLI = REPO_ROOT / "vendor" / "ds4" / "ds4"

PROBES: tuple[tuple[str, list[dict[str, str]]], ...] = (
    (
        "short_factual",
        [
            {"role": "system", "content": "You are a helpful assistant."},
            {"role": "user", "content": "What is the capital of Japan?"},
        ],
    ),
    (
        "math",
        [{"role": "user", "content": "Compute 17 * 23 and give only the result."}],
    ),
    (
        "two_turn_chat",
        [
            {"role": "user", "content": "My favorite color is teal."},
            {"role": "assistant", "content": "Understood."},
            {"role": "user", "content": "What color did I name?"},
        ],
    ),
    (
        "empty_system",
        [
            {"role": "system", "content": ""},
            {"role": "user", "content": "Reply with OK."},
        ],
    ),
    (
        "unicode",
        [{"role": "user", "content": "Translate ‘naïve café’ to 日本語. Emoji: 🧪🚀"}],
    ),
    (
        "code",
        [
            {
                "role": "user",
                "content": "In Python, what does `yield from iterable` do? Give one sentence.",
            }
        ],
    ),
)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", required=True, choices=("llamacpp", "ds4"))
    parser.add_argument(
        "--base-url",
        help="server root URL (required for llamacpp; unused for ds4 CLI parity)",
    )
    parser.add_argument("--api-key-file", type=Path, help="file containing bearer token")
    parser.add_argument("--out", required=True, type=Path, help="result JSON path")
    parser.add_argument(
        "--ds4-token-dump",
        type=Path,
        help="combined transcript produced by the emitted ds4 CLI command",
    )
    parser.add_argument(
        "--ds4-cli",
        type=Path,
        default=DEFAULT_DS4_CLI,
        help=f"ds4 CLI path used in emitted command (default: {DEFAULT_DS4_CLI})",
    )
    parser.add_argument(
        "--ds4-model",
        type=Path,
        default=Path("ds4flash.gguf"),
        help="GGUF passed to ds4 --model (default: ds4flash.gguf)",
    )
    args = parser.parse_args()
    if args.backend == "llamacpp":
        if not args.base_url:
            parser.error("--base-url is required for --backend llamacpp")
        args.base_url = args.base_url.rstrip("/")
        if not args.base_url:
            parser.error("--base-url must not be empty")
    elif args.api_key_file is not None:
        parser.error("--api-key-file is not used for --backend ds4")
    if args.ds4_token_dump is None:
        args.ds4_token_dump = args.out.with_name(args.out.name + ".ds4-token-dump.txt")
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


def load_tokenizer() -> Any:
    try:
        from tokenizers import Tokenizer
    except ImportError as error:
        raise RuntimeError("tokenizers is required; install requirements-harness.txt") from error
    if not TOKENIZER_PATH.is_file():
        raise RuntimeError(f"pinned tokenizer is missing: {TOKENIZER_PATH}")
    return Tokenizer.from_file(str(TOKENIZER_PATH))


def render_probes(encoder: ModuleType, tokenizer: Any) -> list[dict[str, Any]]:
    rendered: list[dict[str, Any]] = []
    for name, messages in PROBES:
        prompt = encoder.encode_messages(messages, thinking_mode="chat")
        if not isinstance(prompt, str) or not prompt:
            raise RuntimeError(f"official encoder returned an invalid prompt for {name}")
        # The official README says encode_messages emits BOS, role, and </think>
        # special tokens as literal text. Tokenizing that rendered text with
        # add_special_tokens=False recognizes those literals exactly once.
        ids = tokenizer.encode(prompt, add_special_tokens=False).ids
        if not ids:
            raise RuntimeError(f"reference tokenizer returned no IDs for {name}")
        rendered.append(
            {
                "name": name,
                "rendered_prompt": prompt,
                "rendered_chars": len(prompt),
                "ref_token_ids": ids,
                "ref_token_count": len(ids),
            }
        )
    return rendered


class Client:
    def __init__(self, base_url: str, api_key: str | None) -> None:
        self.base_url = base_url
        self.api_key = api_key

    def tokenize(self, content: str) -> tuple[list[int], Any]:
        payload = {
            "content": content,
            "add_special": False,
            "with_pieces": False,
        }
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        headers = {"Accept": "application/json", "Content-Type": "application/json"}
        if self.api_key is not None:
            headers["Authorization"] = f"Bearer {self.api_key}"
        request = urllib.request.Request(
            self.base_url + "/tokenize", data=body, headers=headers, method="POST"
        )
        try:
            with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_S) as response:
                status = response.status
                raw = response.read()
        except urllib.error.HTTPError as error:
            raw = error.read()
            raise RuntimeError(
                f"POST /tokenize returned HTTP {error.code}: "
                f"{raw.decode('utf-8', errors='replace')}"
            ) from error
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise RuntimeError(f"POST /tokenize failed: {type(error).__name__}: {error}") from error
        if status != 200:
            raise RuntimeError(
                f"POST /tokenize returned HTTP {status}: {raw.decode('utf-8', errors='replace')}"
            )
        try:
            document = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise RuntimeError(
                f"POST /tokenize returned invalid JSON: {error}; "
                f"body={raw.decode('utf-8', errors='replace')}"
            ) from error
        ids = document.get("tokens") if isinstance(document, dict) else None
        if (
            not isinstance(ids, list)
            or not ids
            or any(not isinstance(token, int) or isinstance(token, bool) for token in ids)
        ):
            raise RuntimeError(f"POST /tokenize returned invalid token IDs: {document!r}")
        return ids, document


def ds4_dump_command(
    probes: list[dict[str, Any]], cli: Path, model: Path, dump_path: Path
) -> str:
    target = shlex.quote(str(dump_path))
    target_dir = shlex.quote(str(dump_path.parent))
    commands = ["set -e", f"mkdir -p -- {target_dir}", f": > {target}"]
    for probe in probes:
        marker = f"=== DS4_TOKEN_DUMP {probe['name']} ==="
        commands.append(f"printf '%s\\n' {shlex.quote(marker)} >> {target}")
        argv = [
            str(cli),
            "--model",
            str(model),
            "--dump-tokens",
            "-p",
            probe["rendered_prompt"],
        ]
        commands.append(f"{shlex.join(argv)} >> {target}")
    return "\n".join(commands)


def parse_ds4_dump(path: Path, probe_names: list[str]) -> tuple[dict[str, list[int]], str]:
    transcript = path.read_text(encoding="utf-8")
    lines = transcript.splitlines()
    found: dict[str, list[int]] = {}
    index = 0
    while index < len(lines):
        line = lines[index]
        prefix = "=== DS4_TOKEN_DUMP "
        if not line.startswith(prefix) or not line.endswith(" ==="):
            raise RuntimeError(f"unexpected ds4 dump line {index + 1}: {line!r}")
        name = line[len(prefix) : -4]
        if name not in probe_names:
            raise RuntimeError(f"unknown probe marker in ds4 dump: {name!r}")
        if name in found:
            raise RuntimeError(f"duplicate probe marker in ds4 dump: {name!r}")
        index += 1
        if index >= len(lines):
            raise RuntimeError(f"ds4 dump ends before token IDs for {name}")
        try:
            token_ids = json.loads(lines[index])
        except json.JSONDecodeError as error:
            raise RuntimeError(f"invalid ds4 token ID array for {name}: {error}") from error
        if (
            not isinstance(token_ids, list)
            or not token_ids
            or any(not isinstance(token, int) or isinstance(token, bool) for token in token_ids)
        ):
            raise RuntimeError(f"invalid ds4 token IDs for {name}: {token_ids!r}")
        found[name] = token_ids
        index += 1
        # Piece lines belong to this probe and are retained verbatim in the
        # result transcript; the next marker begins the next exact ID array.
        while index < len(lines) and not lines[index].startswith(prefix):
            index += 1
    missing = sorted(set(probe_names) - set(found))
    if missing:
        raise RuntimeError(f"ds4 dump is missing probes: {missing!r}")
    return found, transcript


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


def main() -> int:
    args = parse_args()
    encoder = load_encoder()
    tokenizer = load_tokenizer()
    probes = render_probes(encoder, tokenizer)
    result: dict[str, Any] = {
        "backend": args.backend,
        "parity_level": "exact-ids",
        "parity_transport": "http-tokenize" if args.backend == "llamacpp" else "ds4-cli-dump",
        "capability_reason": (
            "llama.cpp exposes POST /tokenize with token IDs"
            if args.backend == "llamacpp"
            else "ds4-server has no tokenize route; ds4 CLI exposes --dump-tokens exact IDs"
        ),
        "started_at": utc_now(),
        "finished_at": None,
        "probes": [],
        "pass": False,
    }

    if args.backend == "llamacpp":
        client = Client(args.base_url, load_api_key(args.api_key_file))
        for probe in probes:
            try:
                backend_ids, response = client.tokenize(probe["rendered_prompt"])
                matched = backend_ids == probe["ref_token_ids"]
                result["probes"].append(
                    {
                        **probe,
                        "backend_token_ids": backend_ids,
                        "backend_token_count": len(backend_ids),
                        "exact_ids_match": matched,
                        "backend_response": response,
                    }
                )
            except Exception as error:
                result["probes"].append(
                    {
                        **probe,
                        "backend_token_ids": None,
                        "backend_token_count": None,
                        "exact_ids_match": False,
                        "backend_response": None,
                        "error": f"{type(error).__name__}: {error}",
                    }
                )
    else:
        command = ds4_dump_command(probes, args.ds4_cli, args.ds4_model, args.ds4_token_dump)
        result["ds4_token_dump_file"] = str(args.ds4_token_dump)
        result["ds4_token_dump_command"] = command
        if not args.ds4_token_dump.is_file():
            result["status"] = "token-dump-required"
            result["error"] = (
                f"ds4 token dump does not exist: {args.ds4_token_dump}; "
                "run ds4_token_dump_command exactly, then rerun this gate"
            )
            result["probes"] = [
                {
                    **probe,
                    "backend_token_count": None,
                    "exact_ids_match": False,
                }
                for probe in probes
            ]
            result["finished_at"] = utc_now()
            write_json(args.out, result)
            print(result["error"], file=sys.stderr)
            print(command, file=sys.stderr)
            return 2
        try:
            backend_by_name, transcript = parse_ds4_dump(
                args.ds4_token_dump, [probe["name"] for probe in probes]
            )
        except Exception as error:
            result["status"] = "invalid-token-dump"
            result["error"] = f"{type(error).__name__}: {error}"
            result["probes"] = [
                {
                    **probe,
                    "backend_token_count": None,
                    "exact_ids_match": False,
                }
                for probe in probes
            ]
            result["finished_at"] = utc_now()
            write_json(args.out, result)
            print(result["error"], file=sys.stderr)
            return 1
        result["ds4_token_dump_transcript"] = transcript
        for probe in probes:
            backend_ids = backend_by_name[probe["name"]]
            matched = backend_ids == probe["ref_token_ids"]
            result["probes"].append(
                {
                    **probe,
                    "backend_token_ids": backend_ids,
                    "backend_token_count": len(backend_ids),
                    "exact_ids_match": matched,
                }
            )

    result["pass"] = all(probe["exact_ids_match"] for probe in result["probes"])
    result["status"] = "passed" if result["pass"] else "failed"
    result["finished_at"] = utc_now()
    write_json(args.out, result)
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
