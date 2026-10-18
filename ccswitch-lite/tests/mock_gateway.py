#!/usr/bin/env python3
"""Minimal Anthropic-compatible mock gateway used to prove that Claude
Desktop's 3P profile actually routes inference traffic to the configured
baseUrl. Logs every request (headers + body) to MOCK_LOG.
"""
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = os.environ.get("MOCK_LOG", "/tmp/ccswitch-desktop/mock.log")


def log(entry):
    with open(LOG, "a", encoding="utf-8") as fh:
        fh.write(entry)
        fh.flush()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _log_request(self, body):
        parts = ["=== %s %s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), self.command, self.path)]
        for k, v in self.headers.items():
            parts.append("H %s: %s\n" % (k, v))
        parts.append("B " + body.decode("utf-8", "replace") + "\n\n")
        log("".join(parts))

    def _json(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._log_request(b"")
        if self.path.rstrip("/").endswith("/models"):
            self._json(200, {"data": [
                {"id": "claude-sonnet-4-6", "type": "model", "display_name": "Mock Sonnet"},
                {"id": "claude-opus-4-1", "type": "model", "display_name": "Mock Opus"},
            ], "has_more": False})
        else:
            self._json(404, {"type": "error", "error": {"type": "not_found_error", "message": "mock"}})

    def do_POST(self):
        body = self._read_body()
        self._log_request(body)
        try:
            req = json.loads(body or b"{}")
        except Exception:
            req = {}
        model = req.get("model", "claude-sonnet-4-6")
        text = "MOCK-OK: ccswitch-lite gateway reached"
        if req.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            events = [
                ("message_start", {"type": "message_start", "message": {
                    "id": "msg_mock", "type": "message", "role": "assistant", "model": model,
                    "content": [], "stop_reason": None, "stop_sequence": None,
                    "usage": {"input_tokens": 12, "output_tokens": 0}}}),
                ("content_block_start", {"type": "content_block_start", "index": 0,
                                         "content_block": {"type": "text", "text": ""}}),
                ("content_block_delta", {"type": "content_block_delta", "index": 0,
                                         "delta": {"type": "text_delta", "text": text}}),
                ("content_block_stop", {"type": "content_block_stop", "index": 0}),
                ("message_delta", {"type": "message_delta",
                                   "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                                   "usage": {"output_tokens": 8}}),
                ("message_stop", {"type": "message_stop"}),
            ]
            for name, payload in events:
                self.wfile.write(("event: %s\ndata: %s\n\n" % (name, json.dumps(payload))).encode())
                self.wfile.flush()
            self.close_connection = True
        else:
            self._json(200, {
                "id": "msg_mock", "type": "message", "role": "assistant", "model": model,
                "content": [{"type": "text", "text": text}],
                "stop_reason": "end_turn", "stop_sequence": None,
                "usage": {"input_tokens": 12, "output_tokens": 8},
            })


if __name__ == "__main__":
    port = int(os.environ.get("MOCK_PORT", "18080"))
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
