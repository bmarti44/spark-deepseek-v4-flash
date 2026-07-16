#!/usr/bin/env python3
"""Loopback-only bearer authentication endpoint for Caddy forward_auth."""

import hmac
import os
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


KEY_PATH = Path(os.environ["API_KEY_FILE"])
API_KEY = b""
MAX_IN_FLIGHT = 64
RATE_PER_SECOND = 120 / 60
RATE_BURST = 240
IN_FLIGHT = threading.BoundedSemaphore(MAX_IN_FLIGHT)
RATE_LOCK = threading.Lock()
RATE_TOKENS = float(RATE_BURST)
RATE_UPDATED = time.monotonic()


def consume_rate_token() -> bool:
    """Consume one global bucket token without ever blocking on request I/O."""
    global RATE_TOKENS, RATE_UPDATED
    with RATE_LOCK:
        now = time.monotonic()
        RATE_TOKENS = min(RATE_BURST, RATE_TOKENS + (now - RATE_UPDATED) * RATE_PER_SECOND)
        RATE_UPDATED = now
        if RATE_TOKENS < 1:
            return False
        RATE_TOKENS -= 1
        return True


def read_key() -> bytes:
    """Read one non-empty whitespace-free token, allowing a final newline."""
    value = KEY_PATH.read_bytes().rstrip(b"\r\n")
    if not value or any(char in value for char in b" \t\r\n"):
        raise ValueError("key file must contain one non-empty token")
    return value


def reload_key(_signum=None, _frame=None) -> None:
    """Atomically replace the in-memory key; retain the old key on failure."""
    global API_KEY
    try:
        replacement = read_key()
    except (OSError, ValueError):
        print("auth helper: key reload failed", file=sys.stderr, flush=True)
        return
    API_KEY = replacement


class AuthHandler(BaseHTTPRequestHandler):
    server_version = "dsv4-auth"
    sys_version = ""

    def authorize(self) -> None:
        if not consume_rate_token():
            self._empty_response(429)
            return
        if not IN_FLIGHT.acquire(blocking=False):
            self._empty_response(503)
            return
        try:
            self._authorize_bounded()
        finally:
            IN_FLIGHT.release()

    def _empty_response(self, status: int, authenticate: bool = False) -> None:
        self.send_response(status)
        if authenticate:
            self.send_header("WWW-Authenticate", "Bearer")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _authorize_bounded(self) -> None:
        # get_all is required: get()/mapping access can hide duplicate headers.
        headers = self.headers.get_all("Authorization", failobj=[])
        accepted = False
        if len(headers) == 1 and headers[0].startswith("Bearer "):
            candidate = headers[0][len("Bearer ") :]
            try:
                encoded = candidate.encode("ascii")
            except UnicodeEncodeError:
                encoded = b""
            if candidate and not any(char.isspace() for char in candidate):
                accepted = hmac.compare_digest(encoded, API_KEY)

        self._empty_response(204 if accepted else 401, authenticate=not accepted)

    do_GET = authorize
    do_HEAD = authorize
    do_POST = authorize
    do_PUT = authorize
    do_PATCH = authorize
    do_DELETE = authorize
    do_OPTIONS = authorize
    do_CONNECT = authorize
    do_TRACE = authorize

    def log_message(self, _format: str, *_args: object) -> None:
        # Do not emit request data; in particular, never log Authorization.
        return


if __name__ == "__main__":
    try:
        API_KEY = read_key()
    except (OSError, ValueError):
        print("auth helper: cannot load API key", file=sys.stderr)
        raise SystemExit(1)
    signal.signal(signal.SIGHUP, reload_key)
    server = ThreadingHTTPServer(("127.0.0.1", 8014), AuthHandler)
    server.daemon_threads = True
    server.serve_forever()
