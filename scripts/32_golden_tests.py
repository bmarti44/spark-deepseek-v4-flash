#!/usr/bin/env python3
"""Run correctness checks against an OpenAI-compatible chat server."""

from __future__ import annotations

import argparse
import json
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable


REQUEST_TIMEOUT_S = 300
SUSTAINED_TIMEOUT_S = 600
SEED = 42
REPO_ROOT = Path(__file__).resolve().parent.parent
TOKENIZER_PATH = REPO_ROOT / "vendor" / "official-encoding" / "tokenizer.json"
FIXTURE_PATH = REPO_ROOT / "fixtures" / "ctx-32k.txt"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True, help="server root URL")
    parser.add_argument("--api-key-file", type=Path, help="file containing bearer token")
    parser.add_argument("--out", required=True, type=Path, help="results JSON path")
    parser.add_argument("--stack-label", required=True, help="stack name recorded in output")
    parser.add_argument(
        "--health-path",
        default="/health",
        help="health endpoint path (default: /health)",
    )
    parser.add_argument(
        "--ctx",
        type=int,
        default=32768,
        help="configured server context size in tokens (default: 32768)",
    )
    parser.add_argument(
        "--extra-body",
        default=None,
        help="JSON object merged into every chat request body (per-stack mode control, e.g. '{\"enable_thinking\":false}')",
    )
    args = parser.parse_args()
    if args.extra_body is not None:
        try:
            args.extra_body = json.loads(args.extra_body)
        except json.JSONDecodeError as error:
            parser.error(f"--extra-body is not valid JSON: {error}")
        if not isinstance(args.extra_body, dict):
            parser.error("--extra-body must be a JSON object")
    if args.ctx <= 0:
        parser.error("--ctx must be positive")
    if not args.health_path.startswith("/"):
        parser.error("--health-path must start with /")
    args.base_url = args.base_url.rstrip("/")
    if not args.base_url:
        parser.error("--base-url must not be empty")
    return args


class Client:
    def __init__(
        self,
        base_url: str,
        api_key: str | None,
        extra_body: dict[str, Any] | None = None,
    ) -> None:
        self.base_url = base_url
        self.api_key = api_key
        # Merged into every chat payload BEFORE protocol-critical keys so it can
        # steer stack-specific modes (e.g. enable_thinking) but never override
        # stream/temperature/seed set by the harness itself.
        self.extra_body = dict(extra_body or {})

    def headers(self, *, authorized: bool = True) -> dict[str, str]:
        headers = {"Accept": "application/json"}
        if authorized and self.api_key is not None:
            headers["Authorization"] = f"Bearer {self.api_key}"
        return headers

    def raw_request(
        self,
        method: str,
        path: str,
        body: bytes | None = None,
        *,
        authorized: bool = True,
        timeout: int = REQUEST_TIMEOUT_S,
        content_type: str | None = None,
    ) -> tuple[int, bytes, dict[str, str]]:
        headers = self.headers(authorized=authorized)
        if content_type is not None:
            headers["Content-Type"] = content_type
        request = urllib.request.Request(
            self.base_url + path,
            data=body,
            headers=headers,
            method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.status, response.read(), dict(response.headers.items())
        except urllib.error.HTTPError as error:
            return error.code, error.read(), dict(error.headers.items())

    def json_request(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None = None,
        *,
        authorized: bool = True,
        timeout: int = REQUEST_TIMEOUT_S,
    ) -> tuple[int, Any]:
        body = None
        content_type = None
        if payload is not None:
            body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            content_type = "application/json"
        status, raw, _ = self.raw_request(
            method,
            path,
            body,
            authorized=authorized,
            timeout=timeout,
            content_type=content_type,
        )
        try:
            decoded = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            preview = raw[:300].decode("utf-8", errors="replace")
            raise RuntimeError(
                f"HTTP {status} returned invalid JSON: {error}; body={preview!r}"
            ) from error
        return status, decoded

    def chat(
        self,
        model: str,
        messages: list[dict[str, str]],
        *,
        max_tokens: int = 128,
        authorized: bool = True,
    ) -> str:
        payload = dict(self.extra_body)
        payload.update({
            "model": model,
            "messages": messages,
            "max_tokens": max_tokens,
            "temperature": 0,
            "seed": SEED,
            "stream": False,
        })
        status, response = self.json_request(
            "POST", "/v1/chat/completions", payload, authorized=authorized
        )
        if status != 200:
            raise RuntimeError(f"chat returned HTTP {status}: {json_preview(response)}")
        try:
            content = response["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError) as error:
            raise RuntimeError(f"chat response has no completion: {json_preview(response)}") from error
        if not isinstance(content, str):
            raise RuntimeError(f"completion content is not a string: {content!r}")
        return content

    def stream_chat(
        self,
        payload: dict[str, Any],
        *,
        timeout: int = REQUEST_TIMEOUT_S,
    ) -> dict[str, Any]:
        request_payload = dict(self.extra_body)
        request_payload.update(payload)
        request_payload["stream"] = True
        request_payload["stream_options"] = {"include_usage": True}
        body = json.dumps(request_payload, separators=(",", ":")).encode("utf-8")
        headers = self.headers()
        headers["Content-Type"] = "application/json"
        headers["Accept"] = "text/event-stream"
        request = urllib.request.Request(
            self.base_url + "/v1/chat/completions",
            data=body,
            headers=headers,
            method="POST",
        )
        started = time.perf_counter()
        try:
            response = urllib.request.urlopen(request, timeout=timeout)
        except urllib.error.HTTPError as error:
            raw = error.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"stream returned HTTP {error.code}: {raw[:500]!r}") from error

        chunks = 0
        done = False
        content_parts: list[str] = []
        generated_parts: list[str] = []
        usage: dict[str, Any] | None = None
        first_content_at: float | None = None
        last_content_at: float | None = None
        try:
            with response:
                if response.status != 200:
                    raise RuntimeError(f"stream returned HTTP {response.status}")
                for raw_line in response:
                    line = raw_line.decode("utf-8", errors="strict").strip()
                    if not line or line.startswith(":"):
                        continue
                    if done:
                        raise RuntimeError("received SSE data after [DONE]")
                    if not line.startswith("data:"):
                        raise RuntimeError(f"unexpected SSE line: {line[:200]!r}")
                    data = line[5:].strip()
                    if data == "[DONE]":
                        done = True
                        continue
                    chunks += 1
                    event = json.loads(data)
                    event_usage = event.get("usage")
                    if event_usage is not None:
                        if not isinstance(event_usage, dict):
                            raise RuntimeError("SSE usage is not an object")
                        usage = event_usage
                    choices = event.get("choices", [])
                    if not isinstance(choices, list):
                        raise RuntimeError("SSE choices is not a list")
                    for choice in choices:
                        delta = choice.get("delta", {})
                        if not isinstance(delta, dict):
                            raise RuntimeError("SSE delta is not an object")
                        now = time.perf_counter()
                        emitted = False
                        reasoning = delta.get("reasoning_content")
                        if reasoning is not None:
                            if not isinstance(reasoning, str):
                                raise RuntimeError("reasoning_content delta is not a string")
                            if reasoning:
                                generated_parts.append(reasoning)
                                emitted = True
                        content = delta.get("content")
                        if content is not None:
                            if not isinstance(content, str):
                                raise RuntimeError("content delta is not a string")
                            if content:
                                content_parts.append(content)
                                generated_parts.append(content)
                                emitted = True
                        if emitted:
                            if first_content_at is None:
                                first_content_at = now
                            last_content_at = now
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise RuntimeError(f"invalid SSE stream: {error}") from error

        return {
            "chunks": chunks,
            "done": done,
            "content": "".join(content_parts),
            "generated_text": "".join(generated_parts),
            "usage": usage,
            "ttft_s": None if first_content_at is None else first_content_at - started,
            "first_content_at": first_content_at,
            "last_content_at": last_content_at,
        }


def json_preview(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))[:500]


def load_api_key(path: Path | None) -> str | None:
    if path is None:
        return None
    key = path.read_text(encoding="utf-8").strip()
    if not key:
        raise ValueError(f"API key file is empty: {path}")
    return key


def load_tokenizer() -> Any:
    try:
        from tokenizers import Tokenizer
    except ImportError as error:
        raise RuntimeError("tokenizers is required; install requirements-harness.txt") from error
    if not TOKENIZER_PATH.is_file():
        raise RuntimeError(f"pinned tokenizer is missing: {TOKENIZER_PATH}")
    return Tokenizer.from_file(str(TOKENIZER_PATH))


def token_count(tokenizer: Any, text: str) -> int:
    return len(tokenizer.encode(text, add_special_tokens=False).ids)


def prefix_with_exact_tokens(tokenizer: Any, text: str, target: int) -> tuple[str, int]:
    if target < 0:
        raise ValueError("token target must be non-negative")
    if target == 0:
        return "", 0
    encoding = tokenizer.encode(text, add_special_tokens=False)
    if len(encoding.ids) < target:
        raise RuntimeError(f"fixture has fewer than {target} tokens")
    end = encoding.offsets[target - 1][1]
    prefix = text[:end]
    actual = token_count(tokenizer, prefix)
    if actual != target:
        raise RuntimeError(
            f"tokenizer offset produced {actual} tokens instead of {target}"
        )
    return prefix, end


def build_needle_haystack(tokenizer: Any, fixture: str, target: int = 16000) -> str:
    needle = "The secret code word is BLUEBERRY-7421."
    prefix_target = int(target * 0.4)
    prefix, prefix_chars = prefix_with_exact_tokens(tokenizer, fixture, prefix_target)
    separator = "\n\n" + needle + "\n\n"
    remaining = fixture[prefix_chars:]
    candidate = prefix + separator + remaining
    encoding = tokenizer.encode(candidate, add_special_tokens=False)
    if len(encoding.ids) < target:
        raise RuntimeError(f"fixture is too short to build a {target}-token haystack")
    end = encoding.offsets[target - 1][1]
    haystack = candidate[:end]
    actual = token_count(tokenizer, haystack)
    if actual != target:
        raise RuntimeError(
            f"tokenizer offset produced a {actual}-token haystack instead of {target}"
        )
    depth = token_count(tokenizer, prefix + "\n\n") / target
    if not 0.39 <= depth <= 0.41:
        raise RuntimeError(f"needle depth is {depth:.4f}, expected approximately 0.4")
    return haystack


def check_result(name: str, function: Callable[[], Any]) -> dict[str, Any]:
    try:
        detail = function()
        return {"name": name, "pass": True, "detail": detail}
    except Exception as error:  # Every check converts every exception into a failure.
        return {"name": name, "pass": False, "detail": f"{type(error).__name__}: {error}"}


def main() -> int:
    args = parse_args()
    started_at = utc_now()
    checks: list[dict[str, Any]] = []
    model_holder: dict[str, str] = {}
    tokenizer_holder: dict[str, Any] = {}
    fixture_holder: dict[str, str] = {}

    try:
        api_key = load_api_key(args.api_key_file)
        client = Client(args.base_url, api_key, args.extra_body)
    except Exception as error:
        result = {
            "stack_label": args.stack_label,
            "base_url": args.base_url,
            "started_at": started_at,
            "finished_at": utc_now(),
            "pass": False,
            "checks": [
                {
                    "name": "setup",
                    "pass": False,
                    "detail": f"{type(error).__name__}: {error}",
                }
            ],
        }
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        return 1

    def tokenizer() -> Any:
        if "value" not in tokenizer_holder:
            tokenizer_holder["value"] = load_tokenizer()
        return tokenizer_holder["value"]

    def fixture() -> str:
        if "value" not in fixture_holder:
            fixture_holder["value"] = FIXTURE_PATH.read_text(encoding="utf-8")
        return fixture_holder["value"]

    def model() -> str:
        if "value" not in model_holder:
            raise RuntimeError("models_endpoint did not provide exactly one model")
        return model_holder["value"]

    def health() -> str:
        status, body, _ = client.raw_request("GET", args.health_path)
        if status != 200:
            raise RuntimeError(f"GET {args.health_path} returned HTTP {status}: {body[:300]!r}")
        return f"GET {args.health_path} returned HTTP 200"

    checks.append(check_result("health", health))

    def models_endpoint() -> str:
        status, response = client.json_request("GET", "/v1/models")
        if status != 200:
            raise RuntimeError(f"GET /v1/models returned HTTP {status}: {json_preview(response)}")
        data = response.get("data") if isinstance(response, dict) else None
        if not isinstance(data, list):
            raise RuntimeError(f"models response data is not a list: {json_preview(response)}")
        if len(data) != 1:
            raise RuntimeError(f"expected exactly one model, received {len(data)}")
        model_id = data[0].get("id") if isinstance(data[0], dict) else None
        if not isinstance(model_id, str) or not model_id:
            raise RuntimeError(f"model id is missing or invalid: {data[0]!r}")
        model_holder["value"] = model_id
        return f"exactly one model: {model_id}"

    checks.append(check_result("models_endpoint", models_endpoint))

    def prompt_check(prompt: str, expected: str) -> Callable[[], dict[str, str]]:
        def run() -> dict[str, str]:
            completion = client.chat(model(), [{"role": "user", "content": prompt}])
            if expected.casefold() not in completion.casefold():
                raise RuntimeError(f"expected {expected!r} in completion {completion!r}")
            return {"expected": expected, "completion": completion}

        return run

    checks.append(
        check_result(
            "basic_fact",
            prompt_check(
                "What is the capital of France? Answer with just the city name.", "Paris"
            ),
        )
    )
    checks.append(
        check_result(
            "arithmetic",
            prompt_check("Compute 17 * 23. Reply with just the number.", "391"),
        )
    )

    def determinism() -> dict[str, str]:
        messages = [{"role": "user", "content": "List the first 5 prime numbers."}]
        first = client.chat(model(), messages)
        second = client.chat(model(), messages)
        if first != second:
            raise RuntimeError(
                "completion mismatch: "
                + json.dumps({"first": first, "second": second}, ensure_ascii=False)
            )
        return {"first": first, "second": second}

    checks.append(check_result("determinism", determinism))

    def needle_16k() -> dict[str, Any]:
        if args.ctx < 17000:
            raise RuntimeError(
                f"server context is {args.ctx} tokens; at least 17000 is required (skip is fail)"
            )
        haystack = build_needle_haystack(tokenizer(), fixture())
        prompt = (
            haystack
            + "\n\nWhat is the secret code word? Reply with just the code word."
        )
        completion = client.chat(
            model(), [{"role": "user", "content": prompt}], max_tokens=64
        )
        if "blueberry-7421" not in completion.casefold():
            raise RuntimeError(f"secret code not found in completion: {completion!r}")
        return {
            "haystack_tokens": token_count(tokenizer(), haystack),
            "completion": completion,
        }

    checks.append(check_result("needle_16k", needle_16k))

    def multiturn_cache_consistency() -> dict[str, str]:
        first_user = "Remember the label CACHE-ANCHOR. Reply with only that label."
        final_user = "What label did I ask you to remember? Reply with only the label."
        expected_first_reply = "CACHE-ANCHOR"
        full_history = [
            {"role": "user", "content": first_user},
            {"role": "assistant", "content": expected_first_reply},
            {"role": "user", "content": final_user},
        ]
        full_answer = client.chat(model(), full_history)

        incremental_first_reply = client.chat(
            model(), [{"role": "user", "content": first_user}]
        )
        incremental_history = [
            {"role": "user", "content": first_user},
            {"role": "assistant", "content": incremental_first_reply},
            {"role": "user", "content": final_user},
        ]
        incremental_answer = client.chat(model(), incremental_history)
        if full_answer != incremental_answer:
            raise RuntimeError(
                "final completion mismatch: "
                + json.dumps(
                    {
                        "full_history": full_answer,
                        "incremental": incremental_answer,
                        "full_first_reply": expected_first_reply,
                        "incremental_first_reply": incremental_first_reply,
                    },
                    ensure_ascii=False,
                )
            )
        return {
            "full_history": full_answer,
            "incremental": incremental_answer,
            "incremental_first_reply": incremental_first_reply,
        }

    checks.append(
        check_result("multiturn_cache_consistency", multiturn_cache_consistency)
    )

    def streaming_sse() -> dict[str, Any]:
        stream = client.stream_chat(
            {
                "model": model(),
                "messages": [
                    {
                        "role": "user",
                        "content": "Write one short sentence about a blue river.",
                    }
                ],
                "max_tokens": 64,
                "temperature": 0,
                "seed": SEED,
            }
        )
        if stream["chunks"] <= 1:
            raise RuntimeError(f"received only {stream['chunks']} SSE data chunks")
        if not stream["done"]:
            raise RuntimeError("SSE stream did not terminate with [DONE]")
        if not stream["content"]:
            raise RuntimeError("concatenated content deltas are empty")
        if not isinstance(stream["usage"], dict):
            raise RuntimeError("SSE stream did not include a usage object")
        return {
            "data_chunks": stream["chunks"],
            "done": stream["done"],
            "content": stream["content"],
            "usage": stream["usage"],
        }

    checks.append(check_result("streaming_sse", streaming_sse))

    def error_schema() -> dict[str, Any]:
        invalid_status, invalid_body, _ = client.raw_request(
            "POST",
            "/v1/chat/completions",
            b'{"broken":',
            content_type="application/json",
        )
        # Intent: malformed JSON must yield a graceful, JSON-bodied error and
        # leave the server healthy. llama.cpp answers 500 with a parse-error
        # object; ds4 answers 4xx — both are graceful. Hangs/crashes fail.
        if not 400 <= invalid_status <= 599:
            raise RuntimeError(
                f"invalid JSON returned HTTP {invalid_status}; body={invalid_body[:300]!r}"
            )
        try:
            invalid_doc = json.loads(invalid_body)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise RuntimeError(
                f"invalid-JSON error response is not JSON itself: {error}; body={invalid_body[:300]!r}"
            ) from error
        if "error" not in invalid_doc:
            raise RuntimeError(f"error response lacks an error object: {invalid_doc!r}")
        health_status, _, _ = client.raw_request("GET", args.health_path)
        if health_status != 200:
            raise RuntimeError(
                f"server unhealthy after malformed-JSON request: HTTP {health_status}"
            )
        unknown_payload = {
            "model": "__golden_tests_unknown_model__",
            "messages": [{"role": "user", "content": "Reply with OK."}],
            "max_tokens": 16,
            "temperature": 0,
            "seed": SEED,
        }
        unknown_status, unknown_body, _ = client.raw_request(
            "POST",
            "/v1/chat/completions",
            json.dumps(unknown_payload, separators=(",", ":")).encode("utf-8"),
            content_type="application/json",
        )
        if 400 <= unknown_status <= 499:
            behavior = "rejected_unknown_model"
        elif 200 <= unknown_status <= 299:
            behavior = "served_configured_model"
        else:
            raise RuntimeError(
                f"unknown model returned HTTP {unknown_status}; body={unknown_body[:300]!r}"
            )
        return {
            "invalid_json_status": invalid_status,
            "unknown_model_status": unknown_status,
            "unknown_model_behavior": behavior,
        }

    checks.append(check_result("error_schema", error_schema))

    if args.api_key_file is not None:
        def auth_enforced() -> str:
            payload = {
                "model": model(),
                "messages": [{"role": "user", "content": "Reply with OK."}],
                "max_tokens": 8,
                "temperature": 0,
                "seed": SEED,
            }
            status, body, _ = client.raw_request(
                "POST",
                "/v1/chat/completions",
                json.dumps(payload, separators=(",", ":")).encode("utf-8"),
                authorized=False,
                content_type="application/json",
            )
            if status not in (401, 403):
                raise RuntimeError(
                    f"unauthorized inference returned HTTP {status}; body={body[:300]!r}"
                )
            return f"unauthorized inference returned HTTP {status}"

        checks.append(check_result("auth_enforced", auth_enforced))

    def sustained_ctx() -> dict[str, Any]:
        target = min(30000, int(args.ctx * 0.9))
        context, _ = prefix_with_exact_tokens(tokenizer(), fixture(), target)
        prompt = (
            context
            + "\n\nSummarize the text above in at most 64 tokens. Return only the summary."
        )
        stream = client.stream_chat(
            {
                "model": model(),
                "messages": [{"role": "user", "content": prompt}],
                "max_tokens": 64,
                "temperature": 0,
                "seed": SEED,
            },
            timeout=SUSTAINED_TIMEOUT_S,
        )
        if not stream["done"]:
            raise RuntimeError("sustained stream did not terminate with [DONE]")
        if stream["ttft_s"] is None:
            raise RuntimeError("sustained stream produced no content chunks")
        if not stream["content"]:
            raise RuntimeError("sustained stream final content is empty")
        return {
            "fixture_context_tokens": target,
            "prompt_tokens_client": token_count(tokenizer(), prompt),
            "ttft_s": stream["ttft_s"],
            "completion": stream["content"],
            "usage": stream["usage"],
        }

    checks.append(check_result("sustained_ctx", sustained_ctx))

    overall = all(check["pass"] for check in checks)
    result = {
        "stack_label": args.stack_label,
        "base_url": args.base_url,
        "started_at": started_at,
        "finished_at": utc_now(),
        "pass": overall,
        "checks": checks,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return 0 if overall else 1


if __name__ == "__main__":
    raise SystemExit(main())
