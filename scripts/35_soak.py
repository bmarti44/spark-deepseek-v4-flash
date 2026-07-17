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
  2. enough requests               — at least 30 successful requests
  3. sampler healthy               — memory sampler raised no error and stayed alive
  4. memory sample density         — at least 0.8 samples per elapsed second
  5. windows disjoint              — elapsed time spans two frozen 300-second windows
  6. windows populated             — at least five requests start in each window
  7. decode degradation <= 0.25    — last-window median vs first-window median
  8. memory available >= 12 GiB    — never near the UMA watchdog SIGKILL line
  9. health probes all healthy     — /v1/models stayed 200 for the whole run
 10. duration met                  — elapsed time is at least 95% of 1800 seconds

Decode throughput per request uses the server-reported usage.completion_tokens
over the wall time between the first and last streamed content chunk — the same
definition scripts/30_bench_speed.py uses.
"""
from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DURATION = 1800
MAX_TOKENS = 256
DEG_THRESHOLD = 0.25
MIN_REQUESTS = 30
MEM_FLOOR_GIB = 12.0
WINDOW_SECONDS = 300
REQUEST_TIMEOUT = 600
HEALTH_PROBE_INTERVAL = 30.0
MIN_HEALTH_PROBES = max(
    10, math.floor(DURATION / HEALTH_PROBE_INTERVAL / 2)
)
FORBIDDEN_EXTRA_BODY_KEYS = {
    "model",
    "messages",
    "prompt",
    "max_tokens",
    "temperature",
    "stream",
    "stream_options",
    "n",
    "seed",
    "stop",
}


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
        self._stop_event = threading.Event()
        self.samples: list[dict[str, float]] = []
        self.min_gib = float("inf")
        self.error: str | None = None

    def run(self) -> None:
        try:
            start = time.monotonic()
            while not self._stop_event.is_set():
                gib = mem_available_gib()
                self.samples.append(
                    {"t": time.monotonic() - start, "gib": gib}
                )
                self.min_gib = min(self.min_gib, gib)
                self._stop_event.wait(self.interval)
        except Exception as error:  # preserve sampler failure as auditable evidence
            self.error = f"{type(error).__name__}: {error}"

    def stop(self) -> None:
        self._stop_event.set()


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


TOPIC_PROMPTS = (
    "Explain how mixture-of-experts transformers route tokens, save compute through "
    "sparse activation, and trade quality for efficiency under quantization.",
    "Explain how a database query planner chooses indexes and join orders, and how "
    "cardinality estimation errors affect execution time.",
    "Explain how TCP congestion control detects capacity, responds to packet loss, "
    "and balances throughput against latency.",
    "Explain how a compiler lowers source code into an intermediate representation, "
    "applies optimizations, and preserves program semantics.",
    "Explain how distributed consensus tolerates failures, why quorum intersection "
    "matters, and what network partitions imply for availability.",
    "Explain how a generational garbage collector identifies live objects, promotes "
    "survivors, and controls pause times.",
    "Explain how a modern filesystem uses journaling, caching, and copy-on-write to "
    "balance durability, consistency, and performance.",
    "Explain how public-key cryptography supports signatures and key exchange, and "
    "why implementations must defend against side channels.",
)
BASE_PROMPT = (
    "You are a careful technical writer. Write a clear, self-contained explanation "
    "using complete sentences, and continue until the topic is covered thoroughly. "
)


class HealthProber(threading.Thread):
    """Probe endpoint health independently of long-running decode requests."""

    def __init__(
        self, client: Client, start: float, interval: float = HEALTH_PROBE_INTERVAL
    ) -> None:
        super().__init__(daemon=True)
        self.client = client
        self.start_time = start
        self.interval = interval
        self._stop_event = threading.Event()
        self.probes: list[dict[str, Any]] = []

    def run(self) -> None:
        while not self._stop_event.is_set():
            probe_started = time.monotonic()
            code = self.client.health()
            self.probes.append(
                {"t": probe_started - self.start_time, "status": code}
            )
            remaining = self.interval - (time.monotonic() - probe_started)
            if remaining > 0:
                self._stop_event.wait(remaining)

    def stop(self) -> None:
        self._stop_event.set()


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
    forbidden = sorted(FORBIDDEN_EXTRA_BODY_KEYS.intersection(extra_body))
    if forbidden:
        print(
            "--extra-body contains forbidden request key(s): " + ", ".join(forbidden),
            file=sys.stderr,
        )
        return 2

    api_key = load_api_key(args.api_key_file)
    client = Client(args.base_url, api_key, REQUEST_TIMEOUT)
    model = args.model or client.get_model()

    baseline_mem = mem_available_gib()
    sampler = MemorySampler(interval=1.0)
    sampler.start()

    reps: list[dict[str, Any]] = []
    errors: list[dict[str, Any]] = []
    started_at = utc_now()
    start = time.monotonic()
    health_prober = HealthProber(client, start)
    health_prober.start()
    deadline = start + DURATION
    index = 0
    while time.monotonic() < deadline:
        prompt_index = index % len(TOPIC_PROMPTS)
        prompt = (
            f"[soak request {index}] "
            + BASE_PROMPT
            + TOPIC_PROMPTS[prompt_index]
        )
        payload: dict[str, Any] = {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": MAX_TOKENS,
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
                    "prompt_index": prompt_index,
                    "t_start": t0 - start,
                    "completion_tokens": completion_tokens,
                    "ttft_s": first_at - t0,
                    "decode_tok_s": decode_tok_s,
                }
            )
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, OSError, RuntimeError) as error:
            errors.append(
                {
                    "index": index,
                    "prompt_index": prompt_index,
                    "t": t0 - start,
                    "error": f"{type(error).__name__}: {error}",
                }
            )
        index += 1

    elapsed = time.monotonic() - start
    sampler_alive_before_stop = sampler.is_alive()
    sampler.stop()
    sampler.join(timeout=5)
    health_prober.stop()
    health_prober.join(timeout=35)
    health_probes = health_prober.probes
    finished_at = utc_now()

    # --- windowed decode degradation ---
    window = WINDOW_SECONDS
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
    min_mem = min((sample["gib"] for sample in sampler.samples), default=None)

    windows_disjoint = elapsed >= 2 * WINDOW_SECONDS
    windows_populated = len(first_window) >= 5 and len(last_window) >= 5

    gates = {
        "zero_errors": len(errors) == 0,
        "enough_requests": len(reps) >= MIN_REQUESTS,
        "sampler_healthy": sampler.error is None and sampler_alive_before_stop,
        "mem_sample_density": len(sampler.samples) >= 0.8 * elapsed,
        "windows_disjoint": windows_disjoint,
        "windows_populated": windows_populated,
        "degradation_within_threshold": (
            windows_disjoint
            and windows_populated
            and degradation is not None
            and degradation <= DEG_THRESHOLD
        ),
        "memory_above_floor": (min_mem is not None and min_mem >= MEM_FLOOR_GIB),
        "health_all_ok": (
            len(health_probes) >= MIN_HEALTH_PROBES
            and all(p["status"] == 200 for p in health_probes)
        ),
        "duration_met": elapsed >= 0.95 * DURATION,
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
        "duration_seconds_requested": DURATION,
        "duration_seconds_actual": elapsed,
        "n_requests": len(reps),
        "n_errors": len(errors),
        "max_tokens": MAX_TOKENS,
        "extra_body": extra_body,
        "gates": gates,
        "failed_gates": failed_gates,
        "degradation_threshold": DEG_THRESHOLD,
        "degradation_fraction": degradation,
        "decode_first_window_median_tok_s": first_median,
        "decode_last_window_median_tok_s": last_median,
        "decode_overall_median_tok_s": overall_median,
        "window_seconds": window,
        "n_first_window": len(first_window),
        "n_last_window": len(last_window),
        "mem_floor_gib": MEM_FLOOR_GIB,
        "mem_available_baseline_gib": round(baseline_mem, 3),
        "mem_available_min_gib": min_mem,
        "n_mem_samples": len(sampler.samples),
        "memory_sampler_error": sampler.error,
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
