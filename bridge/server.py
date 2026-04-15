#!/usr/bin/env python3
"""openclaw-bridge — narrow HTTP bridge to three hardened scripts.

Design constraints:
- Three fixed routes, no dynamic dispatch.
- Bearer token auth; no token env -> refuse to start.
- JSON body only; one optional string field per route; hard size cap.
- Per-route subprocess timeout; output returned as JSON, never streamed to a shell.
- Bounded concurrency; excess requests fail fast with 503.
- One JSON audit line per request to stderr; no request body content is logged.
"""
import hashlib
import hmac
import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("BRIDGE_TOKEN", "").strip()
if not TOKEN or len(TOKEN) < 32:
    print("FATAL: BRIDGE_TOKEN missing or too short", file=sys.stderr)
    sys.exit(1)

MAX_BODY = 8192
MAX_CONCURRENCY = int(os.environ.get("BRIDGE_MAX_CONCURRENCY", "4"))

_slots = threading.BoundedSemaphore(MAX_CONCURRENCY)

ROUTES = {
    "/run-codex":      {"script": "/scripts/run-codex.sh",      "field": "prompt", "timeout": 600},
    "/deploy-staging": {"script": "/scripts/deploy-staging.sh", "field": None,     "timeout": 900},
    "/query-readonly": {"script": "/scripts/query-readonly.sh", "field": "query",  "timeout": 30},
}


def _audit(record):
    """Emit one JSON line to stderr. Never contains request body content."""
    sys.stderr.write(json.dumps(record, separators=(",", ":")) + "\n")
    sys.stderr.flush()


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
        started = time.monotonic()
        route = ROUTES.get(self.path)
        if not route:
            self._json(404, {"ok": False, "error": "unknown endpoint"})
            _audit({
                "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "route": self.path, "status": 404, "reason": "unknown_route",
                "duration_ms": int((time.monotonic() - started) * 1000),
                "peer": self.address_string(),
            })
            return

        if not _slots.acquire(blocking=False):
            self._json(503, {"ok": False, "error": "busy"})
            _audit({
                "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "route": self.path, "status": 503, "reason": "busy",
                "duration_ms": int((time.monotonic() - started) * 1000),
                "peer": self.address_string(),
            })
            return
        try:
            status, extra = self._do_post_locked(route)
            _audit({
                "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "route": self.path, "status": status,
                "duration_ms": int((time.monotonic() - started) * 1000),
                "peer": self.address_string(),
                **extra,
            })
        finally:
            _slots.release()

    def _do_post_locked(self, route):
        """Returns (http_status, extra_fields_for_audit)."""
        auth = self.headers.get("Authorization", "").encode("utf-8", "replace")
        expected = ("Bearer " + TOKEN).encode("utf-8")
        if not hmac.compare_digest(auth, expected):
            self._json(401, {"ok": False, "error": "unauthorized"})
            return 401, {"reason": "unauthorized"}

        try:
            length = int(self.headers.get("Content-Length", "0") or 0)
        except ValueError:
            self._json(400, {"ok": False, "error": "bad content-length"})
            return 400, {"reason": "bad_content_length"}
        if length > MAX_BODY:
            self._json(413, {"ok": False, "error": "body too large"})
            return 413, {"reason": "body_too_large", "body_bytes": length}
        raw = self.rfile.read(length) if length > 0 else b""
        try:
            body = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            self._json(400, {"ok": False, "error": "invalid json"})
            return 400, {"reason": "invalid_json", "body_bytes": length}
        if not isinstance(body, dict):
            self._json(400, {"ok": False, "error": "body must be object"})
            return 400, {"reason": "body_not_object", "body_bytes": length}

        args = [route["script"]]
        field = route["field"]
        if field:
            val = body.get(field, "")
            if not isinstance(val, str):
                self._json(400, {"ok": False, "error": f"{field} must be string"})
                return 400, {"reason": f"{field}_not_string"}
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
            return 504, {"reason": "script_timeout"}
        except Exception as e:
            self._json(500, {"ok": False, "error": f"exec failed: {e}"})
            return 500, {"reason": "exec_failed"}

        stdout = p.stdout
        stderr = p.stderr
        self._json(200, {
            "ok": p.returncode == 0,
            "exit_code": p.returncode,
            "stdout": stdout.decode("utf-8", "replace"),
            "stderr": stderr.decode("utf-8", "replace"),
        })
        return 200, {
            "exit_code": p.returncode,
            "body_bytes": length,
            "stdout_bytes": len(stdout),
            "stderr_bytes": len(stderr),
            "stdout_sha256": hashlib.sha256(stdout).hexdigest()[:16],
        }

    def log_message(self, fmt, *args):
        # Silence default per-request access log; the audit logger above
        # is the authoritative record. Preserve error lines from the base
        # class by still writing them.
        if fmt and args and ("error" in fmt.lower() or "exception" in fmt.lower()):
            sys.stderr.write("[bridge] %s - %s\n" % (self.address_string(), fmt % args))


def main():
    addr = ("0.0.0.0", 8005)
    httpd = ThreadingHTTPServer(addr, Handler)
    print(f"[bridge] listening on {addr[0]}:{addr[1]}", file=sys.stderr)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
