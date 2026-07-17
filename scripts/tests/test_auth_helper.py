#!/usr/bin/env python3
"""Integration tests for the stdlib streaming authentication proxy."""

import http.client
import os
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
HELPER = REPO_ROOT / "scripts" / "40_auth_helper.py"
API_KEY = "test-only-key"


def unused_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


class UpstreamState:
    def __init__(self) -> None:
        self.condition = threading.Condition()
        self.hold_count = 0
        self.hold_release = threading.Event()
        self.stream_first_sent = threading.Event()
        self.stream_continue = threading.Event()
        self.authorizations: list[list[str]] = []


class MockUpstreamHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    @property
    def state(self) -> UpstreamState:
        return self.server.state  # type: ignore[attr-defined]

    def do_GET(self) -> None:
        self.state.authorizations.append(self.headers.get_all("Authorization", failobj=[]))
        if self.path == "/stream":
            body = b"first\nsecond\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(b"first\n")
            self.wfile.flush()
            self.state.stream_first_sent.set()
            self.state.stream_continue.wait(10)
            self.wfile.write(b"second\n")
            self.wfile.flush()
            return
        if self.path == "/hold":
            with self.state.condition:
                self.state.hold_count += 1
                self.state.condition.notify_all()
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.state.hold_release.wait(15)
            self.wfile.write(b"ok")
            self.wfile.flush()
            return
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, _format: str, *_args: object) -> None:
        return


class MockUpstreamServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 128


class AuthHelperTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        key_path = Path(self.temporary.name) / "api-key"
        key_path.write_text(API_KEY + "\n", encoding="ascii")

        self.state = UpstreamState()
        self.upstream = MockUpstreamServer(("127.0.0.1", 0), MockUpstreamHandler)
        self.upstream.state = self.state  # type: ignore[attr-defined]
        self.upstream_thread = threading.Thread(target=self.upstream.serve_forever, daemon=True)
        self.upstream_thread.start()

        self.helper_port = unused_port()
        environment = os.environ.copy()
        environment.update(
            API_KEY_FILE=str(key_path),
            LISTEN_PORT=str(self.helper_port),
            UPSTREAM_HOST="127.0.0.1",
            UPSTREAM_PORT=str(self.upstream.server_port),
        )
        self.helper = subprocess.Popen(
            [str(HELPER)],
            env=environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self.helper.poll() is not None:
                stderr = self.helper.stderr.read() if self.helper.stderr else ""
                self.fail(f"helper exited during startup: {stderr}")
            try:
                with socket.create_connection(("127.0.0.1", self.helper_port), timeout=0.1):
                    break
            except OSError:
                time.sleep(0.02)
        else:
            self.fail("helper did not open its listener")

    def tearDown(self) -> None:
        self.state.hold_release.set()
        self.state.stream_continue.set()
        self.helper.terminate()
        try:
            self.helper.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.helper.kill()
            self.helper.wait(timeout=5)
        self.upstream.shutdown()
        self.upstream.server_close()
        self.upstream_thread.join(timeout=5)
        self.temporary.cleanup()

    def request(self, path: str, key: str = API_KEY) -> tuple[int, bytes]:
        connection = http.client.HTTPConnection("127.0.0.1", self.helper_port, timeout=10)
        headers = {"Authorization": f"Bearer {key}"}
        connection.request("GET", path, headers=headers)
        response = connection.getresponse()
        result = response.status, response.read()
        connection.close()
        return result

    def test_happy_path_streams_and_strips_authorization(self) -> None:
        observed: dict[str, object] = {}

        def consume_stream() -> None:
            connection = http.client.HTTPConnection("127.0.0.1", self.helper_port, timeout=10)
            connection.request("GET", "/stream", headers={"Authorization": f"Bearer {API_KEY}"})
            response = connection.getresponse()
            observed["status"] = response.status
            observed["first"] = response.read(6)
            observed["rest"] = response.read()
            connection.close()

        consumer = threading.Thread(target=consume_stream)
        consumer.start()
        self.assertTrue(self.state.stream_first_sent.wait(5))
        deadline = time.monotonic() + 5
        while "first" not in observed and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(observed.get("first"), b"first\n")
        self.state.stream_continue.set()
        consumer.join(timeout=5)
        self.assertFalse(consumer.is_alive())
        self.assertEqual(observed, {"status": 200, "first": b"first\n", "rest": b"second\n"})
        self.assertEqual(self.state.authorizations, [[]])

    def test_wrong_key_is_401(self) -> None:
        self.assertEqual(self.request("/ok", "wrong-key"), (401, b""))
        self.assertEqual(self.state.authorizations, [])

    def test_duplicate_authorization_headers_are_rejected(self) -> None:
        connection = http.client.HTTPConnection("127.0.0.1", self.helper_port, timeout=10)
        connection.putrequest("GET", "/ok")
        connection.putheader("Authorization", f"Bearer {API_KEY}")
        connection.putheader("Authorization", f"Bearer {API_KEY}")
        connection.endheaders()
        response = connection.getresponse()
        self.assertEqual((response.status, response.read()), (401, b""))
        connection.close()
        self.assertEqual(self.state.authorizations, [])

    def test_token_bucket_returns_429_after_burst(self) -> None:
        statuses = []
        for _ in range(300):
            status, _body = self.request("/ok", "wrong-key")
            statuses.append(status)
            if status == 429:
                break
        self.assertIn(429, statuses)

    def test_503_when_all_64_slots_are_held(self) -> None:
        results: list[int] = []

        def held_request() -> None:
            status, _body = self.request("/hold")
            results.append(status)

        clients = [threading.Thread(target=held_request) for _ in range(64)]
        for client in clients:
            client.start()
        with self.state.condition:
            reached = self.state.condition.wait_for(lambda: self.state.hold_count == 64, timeout=10)
        self.assertTrue(reached, f"only {self.state.hold_count} upstream requests reached hold")
        self.assertEqual(self.request("/ok"), (503, b""))
        self.state.hold_release.set()
        for client in clients:
            client.join(timeout=10)
        self.assertTrue(all(not client.is_alive() for client in clients))
        self.assertEqual(results, [200] * 64)

    def test_slot_is_released_after_each_completed_response(self) -> None:
        for _ in range(65):
            self.assertEqual(self.request("/ok"), (200, b"ok"))


if __name__ == "__main__":
    unittest.main()
