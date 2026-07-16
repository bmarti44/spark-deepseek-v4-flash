#!/usr/bin/env python3
"""Loopback-only bearer authentication endpoint for Caddy forward_auth."""

import hmac
import os
import signal
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


KEY_PATH = Path(os.environ["API_KEY_FILE"])
API_KEY = b""


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

        self.send_response(204 if accepted else 401)
        if not accepted:
            self.send_header("WWW-Authenticate", "Bearer")
        self.send_header("Content-Length", "0")
        self.end_headers()

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
