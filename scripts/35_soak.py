#!/usr/bin/env python3
"""Sustained-load soak test for an OpenAI-compatible DeepSeek-V4-Flash endpoint.

Drives a single-client, back-to-back decode-heavy workload for a fixed duration
while sampling host memory and probing server health, then emits an auditable
JSON verdict consumed by scripts/34_decision.py (which requires kind="soak" and
pass=true).

The pass bit is NOT a self-report to be taken on faith: every gate is recomputed
here from raw per-request timings, per-second memory samples, and health probes
that are all written into the output so a reviewer can recompute the verdict.

Gates (ALL must hold for pass=true):
  1. zero request errors           — every request returns 200 with a usage object
  2. n_requests >= --min-requests  — enough samples for windowed comparison
  3. decode degradation <= thresh  — median decode tok/s of the last time-window
                                      vs the first window (catches thermal/mem drift)
  4. mem_available_min >= floor    — host MemAvailable never neared the 12 GiB
                                      watchdog SIGKILL line (UMA OOM = hard freeze)
  5. health probes all healthy     — /v1/models stayed 200 for the whole run

Decode throughput per request uses the server-reported usage.completion_tokens
over the wall time between the first and last streamed content chunk — the same
definition scripts/30_bench_speed.py uses.
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True, help="server root URL")
    parser.add_argument("--api-key-file", type=Path, help="file with bearer token")
    parser.add_argument("--stack-label", required=True)
    parser.add_argument("--config-hash", required=True)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--model", help="model id; default: first from /v1/models")
    parser.add_argument(
        "--extra-body",
        default="{}",
        help="JSON merged into each request (e.g. thinking-mode control)",
    )
    parser.add_argument("--duration-seconds", type=int, default=1800)
    parser.add_argument("--max-tokens", type=int, default=256)
    parser.add_argument("--degradation-threshold", type=float, default=0.25)
    parser.add_argument("--min-requests", type=int, default=30)
    parser.add_argument(
        "--mem-floor-gib",
        type=float,
        default=12.0,
        help="fail if host MemAvailable ever drops below this (watchdog line)",
    )
    parser.add_argument(
        "--window-seconds",
        type=int,
        default=120,
        help="length of the first/last comparison windows",
    )
    parser.add_argument("--request-timeout", type=float, default=600.0)
    return parser.parse_args()


def load_api_key(path: Path | None) -> str | None:
    if path is None:
        return None
    return path.read_text(encoding="utf-8").strip()


def mem_available_gib() -> float:
    with open("/proc/meminfo", encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("MemAvailable:"):
                kib = float(line.split()[1])
                return kib / (1024.0 * 1024.0)
    raise RuntimeError("MemAvailable not found in /proc/meminfo")


class MemorySampler(threading.Thread):
    """Sample MemAvailable once per second on a background thread."""

    def __init__(self, interval: float = 1.0) -> None:
        super().__init__(daemon=True)
        self.interval = interval
        self._stop = threading.Event()
        self.samples: list[dict[str, float]] = []
        self.min_gib = float("inf")

    def run(self) -> None:
        start = time.monotonic()
        while not self._stop.is_set():
            gib = mem_available_gib()
            self.samples.append({"t": round(time.monotonic() - start, 2), "gib": round(gib, 3)})
            self.min_gib = min(self.min_gib, gib)
            self._stop.wait(self.interval)

    def stop(self) -> None:
        self._stop.set()


class Client:
    def __init__(self, base_url: str, api_key: str | None, timeout: float) -> None:
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.timeout = timeout

    def _headers(self) -> dict[str, str]:
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        return headers

    def health(self) -> int:
        request = urllib.request.Request(
            self.base_url + "/v1/models", headers=self._headers(), method="GET"
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.status
        except urllib.error.HTTPError as error:
            return error.code
        except (urllib.error.URLError, TimeoutError, OSError):
            return 0

    def get_model(self) -> str:
        request = urllib.request.Request(
            self.base_url + "/v1/models", headers=self._headers(), method="GET"
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            document = json.loads(response.read().decode("utf-8"))
        data = document.get("data") or document.get("models")
        if not data:
            raise RuntimeError("no models returned by /v1/models")
        first = data[0]
        model_id = first.get("id") or first.get("name") or first.get("model")
        if not model_id:
            raise RuntimeError(f"cannot determine model id from {first!r}")
        return model_id

    def stream_decode(self, payload: dict[str, Any]) -> dict[str, Any]:
        body = json.dumps(payload).encode("utf-8")
        headers = self._headers()
        headers["Accept"] = "text/event-stream"
        request = urllib.request.Request(
            self.base_url + "/v1/chat/completions", data=body, headers=headers, method="POST"
        )
        first_content_at: float | None = None
        last_content_at: float | None = None
        usage: dict[str, Any] | None = None
        done = False
        with urllib.request.urlopen(request, timeout=self.timeout) as response:
            if response.status != 200:
                raise RuntimeError(f"HTTP {response.status}")
            for raw_line in response:
                line = raw_line.decode("utf-8", errors="strict").strip()
                if not line or not line.startswith("data:"):
                    continue
                data = line[len("data:"):].strip()
                if data == "[DONE]":
                    done = True
                    break
                event = json.loads(data)
                event_usage = event.get("usage")
                if isinstance(event_usage, dict):
                    usage = event_usage
                for choice in event.get("choices", []):
                    delta = choice.get("delta", {})
                    content = delta.get("content")
                    if content:
                        now = time.monotonic()
                        if first_content_at is None:
                            first_content_at = now
                        last_content_at = now
        return {
            "done": done,
            "first_content_at": first_content_at,
            "last_content_at": last_content_at,
            "usage": usage,
        }


PROMPT = (
    "You are a careful technical writer. Write a clear, self-contained explanation "
    "of how a mixture-of-experts transformer routes tokens to experts, why sparse "
    "activation saves compute, and what trade-offs quantization introduces. Use "
    "complete sentences and keep going until you have covered the topic thoroughly."
)


def main() -> int:
    args = parse_args()
    try:
        extra_body = json.loads(args.extra_body)
    except json.JSONDecodeError as error:
        print(f"invalid --extra-body JSON: {error}", file=sys.stderr)
        return 2
    if not isinstance(extra_body, dict):
        print("--extra-body must be a JSON object", file=sys.stderr)
        return 2

    api_key = load_api_key(args.api_key_file)
    client = Client(args.base_url, api_key, args.request_timeout)
    model = args.model or client.get_model()

    baseline_mem = mem_available_gib()
    sampler = MemorySampler(interval=1.0)
    sampler.start()

    reps: list[dict[str, Any]] = []
    errors: list[dict[str, Any]] = []
    health_probes: list[dict[str, Any]] = []

    started_at = utc_now()
    start = time.monotonic()
    deadline = start + args.duration_seconds
    next_health = start
    index = 0
    while time.monotonic() < deadline:
        now = time.monotonic()
        if now >= next_health:
            code = client.health()
            health_probes.append({"t": round(now - start, 2), "status": code})
            next_health = now + 30.0
        payload: dict[str, Any] = {
            "model": model,
            "messages": [{"role": "user", "content": PROMPT}],
            "max_tokens": args.max_tokens,
            "temperature": 0,
            "stream": True,
            "stream_options": {"include_usage": True},
        }
        payload.update(extra_body)
        t0 = time.monotonic()
        try:
            result = client.stream_decode(payload)
            if not result["done"]:
                raise RuntimeError("stream did not terminate with [DONE]")
            usage = result["usage"]
            if not isinstance(usage, dict):
                raise RuntimeError("no usage object in stream")
            completion_tokens = usage.get("completion_tokens")
            if not isinstance(completion_tokens, int) or completion_tokens < 1:
                raise RuntimeError(f"invalid completion_tokens: {completion_tokens!r}")
            first_at = result["first_content_at"]
            last_at = result["last_content_at"]
            if first_at is None or last_at is None or last_at <= first_at or completion_tokens < 2:
                raise RuntimeError("insufficient content chunks to measure decode")
            decode_tok_s = (completion_tokens - 1) / (last_at - first_at)
            reps.append(
                {
                    "index": index,
                    "t_start": round(t0 - start, 3),
                    "completion_tokens": completion_tokens,
                    "ttft_s": round(first_at - t0, 4),
                    "decode_tok_s": round(decode_tok_s, 4),
                }
            )
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, OSError, RuntimeError) as error:
            errors.append({"index": index, "t": round(t0 - start, 3), "error": f"{type(error).__name__}: {error}"})
        index += 1

    elapsed = time.monotonic() - start
    sampler.stop()
    sampler.join(timeout=5)
    final_health = client.health()
    health_probes.append({"t": round(elapsed, 2), "status": final_health})
    finished_at = utc_now()

    # --- windowed decode degradation ---
    window = args.window_seconds
    first_window = [r["decode_tok_s"] for r in reps if r["t_start"] < window]
    last_window = [r["decode_tok_s"] for r in reps if r["t_start"] >= elapsed - window]
    first_median = statistics.median(first_window) if first_window else None
    last_median = statistics.median(last_window) if last_window else None
    if first_median and last_median is not None and first_median > 0:
        degradation = (first_median - last_median) / first_median
    else:
        degradation = None

    all_decode = [r["decode_tok_s"] for r in reps]
    overall_median = statistics.median(all_decode) if all_decode else None
    min_mem = round(sampler.min_gib, 3) if sampler.min_gib != float("inf") else None

    gates = {
        "zero_errors": len(errors) == 0,
        "enough_requests": len(reps) >= args.min_requests,
        "degradation_within_threshold": (
            degradation is not None and degradation <= args.degradation_threshold
        ),
        "memory_above_floor": (min_mem is not None and min_mem >= args.mem_floor_gib),
        "health_all_ok": all(p["status"] == 200 for p in health_probes),
    }
    passed = all(gates.values())
    failed_gates = [name for name, ok in gates.items() if not ok]

    document = {
        "kind": "soak",
        "pass": passed,
        "stack_label": args.stack_label,
        "config_hash": args.config_hash,
        "model": model,
        "started_at": started_at,
        "finished_at": finished_at,
        "duration_seconds_requested": args.duration_seconds,
        "duration_seconds_actual": round(elapsed, 1),
        "n_requests": len(reps),
        "n_errors": len(errors),
        "max_tokens": args.max_tokens,
        "extra_body": extra_body,
        "gates": gates,
        "failed_gates": failed_gates,
        "degradation_threshold": args.degradation_threshold,
        "degradation_fraction": None if degradation is None else round(degradation, 4),
        "decode_first_window_median_tok_s": None if first_median is None else round(first_median, 4),
        "decode_last_window_median_tok_s": None if last_median is None else round(last_median, 4),
        "decode_overall_median_tok_s": None if overall_median is None else round(overall_median, 4),
        "window_seconds": window,
        "n_first_window": len(first_window),
        "n_last_window": len(last_window),
        "mem_floor_gib": args.mem_floor_gib,
        "mem_available_baseline_gib": round(baseline_mem, 3),
        "mem_available_min_gib": min_mem,
        "n_mem_samples": len(sampler.samples),
        "health_probes": health_probes,
        "errors": errors,
        "reps": reps,
        "mem_samples": sampler.samples,
    }

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")

    print(
        f"soak {args.stack_label}: pass={passed} n={len(reps)} errors={len(errors)} "
        f"degradation={document['degradation_fraction']} "
        f"decode first/last/overall="
        f"{document['decode_first_window_median_tok_s']}/"
        f"{document['decode_last_window_median_tok_s']}/"
        f"{document['decode_overall_median_tok_s']} tok/s "
        f"mem_min={min_mem} GiB"
    )
    if failed_gates:
        print(f"  FAILED gates: {failed_gates}")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
