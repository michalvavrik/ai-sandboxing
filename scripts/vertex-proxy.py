#!/usr/bin/env python3
"""Proxy that adds Google auth to Vertex AI requests from Claude Code.

Claude Code sends Vertex-formatted requests to ANTHROPIC_VERTEX_BASE_URL.
This proxy adds the Google auth token and forwards to aiplatform.googleapis.com.
"""

import atexit
import http.client
import http.server
import json
import logging
import os
import signal
import ssl
import sys

import google.auth
import google.auth.transport.requests

REGION = os.environ.get("ANTHROPIC_VERTEX_REGION",
                        os.environ.get("CLOUD_ML_REGION", ""))
PROJECT_ID = os.environ.get("ANTHROPIC_VERTEX_PROJECT_ID", "")
PID_FILE = os.environ.get("DEV_PROXY_PID_FILE", "/run/user/1000/dev-proxy.pid")
PORT_FILE = os.environ.get("DEV_PROXY_PORT_FILE", "/run/user/1000/dev-proxy.port")

if not PROJECT_ID:
    print("Error: ANTHROPIC_VERTEX_PROJECT_ID must be set", file=sys.stderr)
    sys.exit(1)
if not REGION:
    print("Error: CLOUD_ML_REGION or ANTHROPIC_VERTEX_REGION must be set", file=sys.stderr)
    sys.exit(1)

if REGION == "global":
    UPSTREAM_HOST = "aiplatform.googleapis.com"
else:
    UPSTREAM_HOST = f"{REGION}-aiplatform.googleapis.com"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger("vertex-proxy")

credentials, _ = google.auth.default(
    scopes=["https://www.googleapis.com/auth/cloud-platform"]
)
_auth_request = google.auth.transport.requests.Request()


def _get_token():
    if not credentials.valid:
        credentials.refresh(_auth_request)
    return credentials.token


class _ProxyHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        raw_body = self.rfile.read(content_length)

        token = _get_token()
        upstream_headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": self.headers.get("Content-Type", "application/json"),
            "Content-Length": str(len(raw_body)),
        }

        try:
            conn = http.client.HTTPSConnection(UPSTREAM_HOST)
            upstream_path = self.path if self.path.startswith("/v1/") else f"/v1{self.path}"
            conn.request("POST", upstream_path, body=raw_body, headers=upstream_headers)
            upstream_resp = conn.getresponse()
        except Exception as exc:
            log.error("Upstream connection failed: %s", exc)
            self.send_error(502, f"Upstream error: {exc}")
            return

        status = upstream_resp.status
        content_type = upstream_resp.getheader("Content-Type", "application/json")

        self.send_response(status)
        self.send_header("Content-Type", content_type)

        is_stream = "streamRawPredict" in self.path

        if is_stream and 200 <= status < 300:
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                while True:
                    chunk = upstream_resp.read1(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            data = upstream_resp.read()
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        conn.close()
        log.info("POST %s status=%d stream=%s", self.path, status, is_stream)

    def log_message(self, fmt, *args):
        pass


def _write_file(path, content):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w") as fh:
        fh.write(content)


def _remove_runtime_files():
    for path in (PID_FILE, PORT_FILE):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


def _shutdown_handler(signum, _frame):
    log.info("Received signal %d, shutting down", signum)
    _remove_runtime_files()
    sys.exit(0)


def main():
    signal.signal(signal.SIGTERM, _shutdown_handler)
    signal.signal(signal.SIGINT, _shutdown_handler)

    server = http.server.HTTPServer(("0.0.0.0", 0), _ProxyHandler)
    port = server.server_address[1]

    _write_file(PID_FILE, str(os.getpid()))
    _write_file(PORT_FILE, str(port))
    atexit.register(_remove_runtime_files)

    log.info("Listening on 0.0.0.0:%d", port)
    log.info("Forwarding to %s", UPSTREAM_HOST)

    server.serve_forever()


if __name__ == "__main__":
    main()
