#!/usr/bin/env python3
"""Tiny stand-in for the device-api Edge Function, for testing the watch
before the real Supabase backend exists. Plain HTTP on your local network.

Usage:
    python3 mock_device_api.py <device-token>

Then type `start` or `stop` + Enter to queue a command. The watch picks it up
on its next poll, and each command is returned exactly once, like the real
poll marks delivered_at.

Response shapes match the plan's API section exactly.
"""
import json
import sys
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

PORT = 8787
TOKEN = sys.argv[1] if len(sys.argv) > 1 else "dev-token"

pending = []
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"  # keep-alive, like the real server

    def _authorized(self):
        return self.headers.get("Authorization") == f"Bearer {TOKEN}"

    def _send(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not self._authorized():
            return self._send(401, {"error": "unauthorized"})
        if urlparse(self.path).path != "/functions/v1/device-api/poll":
            return self._send(404, {"error": "not found"})
        with lock:
            cmds = pending[:]
            pending.clear()
        if cmds:
            print(f"  -> delivered {cmds}")
        self._send(200, {"commands": cmds, "profile": None})

    def do_POST(self):
        if not self._authorized():
            return self._send(401, {"error": "unauthorized"})
        length = int(self.headers.get("Content-Length", 0))
        payload = self.rfile.read(length).decode() if length else ""
        path = urlparse(self.path).path
        print(f"  <- POST {path} {payload}")
        if path == "/functions/v1/device-api/events":
            events = json.loads(payload or "{}").get("events", [])
            return self._send(200, {"saved": len(events)})
        if path == "/functions/v1/device-api/status":
            return self._send(200, {"ok": True})
        self._send(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        pass  # polls every 3 s would flood the terminal


def read_stdin():
    for line in sys.stdin:
        word = line.strip().lower()
        if word in ("start", "stop"):
            cmd = {"id": str(uuid.uuid4()), "type": f"{word}_calm"}
            with lock:
                pending.append(cmd)
            print(f"  queued {cmd['type']} ({cmd['id']})")
        elif word:
            print("  type 'start' or 'stop'")


if __name__ == "__main__":
    threading.Thread(target=read_stdin, daemon=True).start()
    print(f"Mock device-api on port {PORT}, token '{TOKEN}'. Type start / stop.")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
