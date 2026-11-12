#!/usr/bin/env python3
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class MockBackend(BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        return

    def _respond(self, status, payload):
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self._respond(200, {"status": "ok"})
            return
        self._respond(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self._respond(404, {"error": "not found"})
            return
        if "x-api-key" in self.headers or "authorization" in self.headers:
            self._respond(400, {"error": "client credential header reached mock backend"})
            return
        try:
            request = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        except (ValueError, json.JSONDecodeError):
            self._respond(400, {"error": "invalid JSON request"})
            return
        if request.get("model") != "fixture-model" or request.get("stream", False):
            self._respond(400, {"error": "unexpected model or streaming request"})
            return
        self._respond(
            200,
            {
                "id": "chatcmpl-demo-fixture",
                "object": "chat.completion",
                "created": 1762927200,
                "model": "fixture-model",
                "choices": [
                    {
                        "index": 0,
                        "message": {
                            "role": "assistant",
                            "content": "Deterministic local fixture response.",
                        },
                        "finish_reason": "stop",
                    }
                ],
                "usage": {
                    "prompt_tokens": 40,
                    "completion_tokens": 20,
                    "total_tokens": 60,
                },
            },
        )


ThreadingHTTPServer(("0.0.0.0", 8080), MockBackend).serve_forever()
