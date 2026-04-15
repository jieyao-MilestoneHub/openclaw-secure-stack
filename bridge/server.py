#!/usr/bin/env python3
"""openclaw-bridge — narrow HTTP bridge to three hardened scripts.

Design constraints:
- Three fixed routes, no dynamic dispatch.
- Bearer token auth; no token env -> refuse to start.
- JSON body only; one optional string field per route; hard size cap.
- Per-route subprocess timeout; output returned as JSON, never streamed to a shell.
"""
import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("BRIDGE_TOKEN", "").strip()
if not TOKEN or len(TOKEN) < 32:
    print("FATAL: BRIDGE_TOKEN missing or too short", file=sys.stderr)
    sys.exit(1)

MAX_BODY = 8192

ROUTES = {
    "/run-codex":      {"script": "/scripts/run-codex.sh",      "field": "prompt", "timeout": 600},
    "/deploy-staging": {"script": "/scripts/deploy-staging.sh", "field": None,     "timeout": 900},
    "/query-readonly": {"script": "/scripts/query-readonly.sh", "field": "query",  "timeout": 30},
}


class Handler(BaseHTTPRequestHandler):
    server_version = "openclaw-bridge/1.0"

    def _json(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/healthz":
            self._json(200, {"ok": True})
            return
        self._json(404, {"ok": False, "error": "not found"})

    def do_POST(self):
        route = ROUTES.get(self.path)
        if not route:
            self._json(404, {"ok": False, "error": "unknown endpoint"})
            return

        auth = self.headers.get("Authorization", "")
        expected = "Bearer " + TOKEN
        if len(auth) != len(expected) or auth != expected:
            self._json(401, {"ok": False, "error": "unauthorized"})
            return

        try:
            length = int(self.headers.get("Content-Length", "0") or 0)
        except ValueError:
            self._json(400, {"ok": False, "error": "bad content-length"}); return
        if length > MAX_BODY:
            self._json(413, {"ok": False, "error": "body too large"}); return
        raw = self.rfile.read(length) if length > 0 else b""
        try:
            body = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            self._json(400, {"ok": False, "error": "invalid json"}); return
        if not isinstance(body, dict):
            self._json(400, {"ok": False, "error": "body must be object"}); return

        args = [route["script"]]
        field = route["field"]
        if field:
            val = body.get(field, "")
            if not isinstance(val, str):
                self._json(400, {"ok": False, "error": f"{field} must be string"}); return
            args.append(val)

        try:
            p = subprocess.run(
                args,
                capture_output=True,
                timeout=route["timeout"],
                check=False,
            )
        except subprocess.TimeoutExpired:
            self._json(504, {"ok": False, "error": "script timeout"})
            return
        except Exception as e:
            self._json(500, {"ok": False, "error": f"exec failed: {e}"})
            return

        self._json(200, {
            "ok": p.returncode == 0,
            "exit_code": p.returncode,
            "stdout": p.stdout.decode("utf-8", "replace"),
            "stderr": p.stderr.decode("utf-8", "replace"),
        })

    def log_message(self, fmt, *args):
        sys.stderr.write("[bridge] %s - %s\n" % (self.address_string(), fmt % args))


def main():
    addr = ("0.0.0.0", 8005)
    httpd = ThreadingHTTPServer(addr, Handler)
    print(f"[bridge] listening on {addr[0]}:{addr[1]}", file=sys.stderr)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
