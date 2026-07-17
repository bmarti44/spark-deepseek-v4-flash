#!/usr/bin/env python3
"""Loopback-only bearer-authenticating streaming reverse proxy."""

import hmac
import http.client
import os
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


KEY_PATH = Path(os.environ["API_KEY_FILE"])
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8014"))
UPSTREAM_HOST = os.environ.get("UPSTREAM_HOST", "127.0.0.1")
UPSTREAM_PORT = int(os.environ["UPSTREAM_PORT"])
API_KEY = b""
MAX_IN_FLIGHT = 64
MAX_REQUEST_BYTES = 10 * 1024 * 1024
RATE_PER_SECOND = 120 / 60
RATE_BURST = 240
IN_FLIGHT = threading.BoundedSemaphore(MAX_IN_FLIGHT)
RATE_LOCK = threading.Lock()
RATE_TOKENS = float(RATE_BURST)
RATE_UPDATED = time.monotonic()
HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}


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


class ProxyHandler(BaseHTTPRequestHandler):
    server_version = "dsv4-auth"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    def handle_request(self) -> None:
        if not consume_rate_token():
            self._empty_response(429)
            return
        if not IN_FLIGHT.acquire(blocking=False):
            self._empty_response(503)
            return
        try:
            if not self._authorized():
                self._empty_response(401, authenticate=True)
                return
            self._proxy_bounded()
        finally:
            IN_FLIGHT.release()

    def _authorized(self) -> bool:
        # get_all is required: get()/mapping access can hide duplicate headers.
        headers = self.headers.get_all("Authorization", failobj=[])
        if len(headers) != 1 or not headers[0].startswith("Bearer "):
            return False
        candidate = headers[0][len("Bearer ") :]
        try:
            encoded = candidate.encode("ascii")
        except UnicodeEncodeError:
            encoded = b""
        return bool(candidate) and not any(char.isspace() for char in candidate) and hmac.compare_digest(
            encoded, API_KEY
        )

    def _empty_response(self, status: int, authenticate: bool = False) -> None:
        self.send_response(status)
        if authenticate:
            self.send_header("WWW-Authenticate", "Bearer")
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def _body_framing(self) -> tuple[int | None, bool]:
        content_lengths = self.headers.get_all("Content-Length", failobj=[])
        transfer_encodings = self.headers.get_all("Transfer-Encoding", failobj=[])
        if len(content_lengths) > 1 or len(transfer_encodings) > 1:
            raise ValueError("ambiguous request framing")
        if content_lengths and transfer_encodings:
            raise ValueError("conflicting request framing")
        if transfer_encodings:
            if transfer_encodings[0].strip().lower() != "chunked":
                raise ValueError("unsupported transfer encoding")
            return None, True
        if not content_lengths:
            return 0, False
        try:
            length = int(content_lengths[0])
        except ValueError as error:
            raise ValueError("invalid content length") from error
        if length < 0 or length > MAX_REQUEST_BYTES:
            raise ValueError("request body too large")
        return length, False

    def _iter_body(self, length: int | None, chunked: bool):
        consumed = 0
        if not chunked:
            remaining = length or 0
            while remaining:
                data = self.rfile.read(min(65536, remaining))
                if not data:
                    raise ConnectionError("request body ended early")
                remaining -= len(data)
                yield data
            return

        while True:
            line = self.rfile.readline(8193)
            if not line or len(line) > 8192 or not line.endswith(b"\n"):
                raise ValueError("invalid chunk framing")
            try:
                size = int(line.split(b";", 1)[0].strip(), 16)
            except ValueError as error:
                raise ValueError("invalid chunk size") from error
            if size < 0 or consumed + size > MAX_REQUEST_BYTES:
                raise ValueError("request body too large")
            if size == 0:
                while True:
                    trailer = self.rfile.readline(8193)
                    if not trailer or len(trailer) > 8192:
                        raise ValueError("invalid chunk trailer")
                    if trailer in (b"\r\n", b"\n"):
                        return
            data = self.rfile.read(size)
            ending = self.rfile.read(2)
            if len(data) != size or ending != b"\r\n":
                raise ValueError("invalid chunk body")
            consumed += size
            yield data

    def _proxy_bounded(self) -> None:
        upstream = http.client.HTTPConnection(UPSTREAM_HOST, UPSTREAM_PORT, timeout=600)
        response_started = False
        try:
            length, chunked = self._body_framing()
            connection_tokens = {
                token.strip().lower()
                for value in self.headers.get_all("Connection", failobj=[])
                for token in value.split(",")
            }
            upstream.putrequest(self.command, self.path, skip_host=True, skip_accept_encoding=True)
            upstream.putheader("Host", f"{UPSTREAM_HOST}:{UPSTREAM_PORT}")
            for name, value in self.headers.raw_items():
                lowered = name.lower()
                if lowered == "authorization" or lowered == "host" or lowered in HOP_BY_HOP:
                    continue
                if lowered in connection_tokens:
                    continue
                upstream.putheader(name, value)
            if chunked:
                upstream.putheader("Transfer-Encoding", "chunked")
            upstream.endheaders()
            for data in self._iter_body(length, chunked):
                if chunked:
                    upstream.send(f"{len(data):X}\r\n".encode("ascii"))
                    upstream.send(data)
                    upstream.send(b"\r\n")
                else:
                    upstream.send(data)
            if chunked:
                upstream.send(b"0\r\n\r\n")

            response = upstream.getresponse()
            response_started = True
            self.send_response(response.status, response.reason)
            response_connection_tokens = {
                token.strip().lower()
                for value in response.headers.get_all("Connection", failobj=[])
                for token in value.split(",")
            }
            has_length = response.headers.get("Content-Length") is not None
            for name, value in response.headers.raw_items():
                lowered = name.lower()
                if lowered in HOP_BY_HOP or lowered in response_connection_tokens:
                    continue
                self.send_header(name, value)
            if not has_length:
                self.send_header("Connection", "close")
                self.close_connection = True
            self.end_headers()
            if self.command != "HEAD":
                while True:
                    data = response.read1(65536)
                    if not data:
                        break
                    self.wfile.write(data)
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
        except (ConnectionError, OSError, ValueError, http.client.HTTPException) as error:
            if not response_started:
                self._empty_response(400 if isinstance(error, ValueError) else 502)
            self.close_connection = True
        finally:
            upstream.close()

    do_GET = handle_request
    do_HEAD = handle_request
    do_POST = handle_request
    do_PUT = handle_request
    do_PATCH = handle_request
    do_DELETE = handle_request
    do_OPTIONS = handle_request
    do_CONNECT = handle_request
    do_TRACE = handle_request

    def log_message(self, _format: str, *_args: object) -> None:
        # Do not emit request data; in particular, never log Authorization.
        return


class ProxyServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 128


if __name__ == "__main__":
    try:
        API_KEY = read_key()
        if UPSTREAM_HOST != "127.0.0.1" or not 1 <= UPSTREAM_PORT <= 65535 or not 1 <= LISTEN_PORT <= 65535:
            raise ValueError("invalid loopback proxy configuration")
    except (OSError, ValueError):
        print("auth helper: invalid configuration or API key", file=sys.stderr)
        raise SystemExit(1)
    signal.signal(signal.SIGHUP, reload_key)
    ProxyServer(("127.0.0.1", LISTEN_PORT), ProxyHandler).serve_forever()
