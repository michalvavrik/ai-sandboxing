#!/usr/bin/env python3
"""Proxy that translates Anthropic API requests to Google Vertex AI endpoints.

Listens on localhost on a dynamically assigned port and forwards
POST /v1/messages requests to the Vertex AI rawPredict / streamRawPredict
endpoint, injecting Google ADC credentials.
"""

import atexit
import http.client
import http.server
import json
import logging
import os
import signal
import sys

import google.auth
import google.auth.transport.requests

REGION = os.environ.get("ANTHROPIC_VERTEX_REGION",
                        os.environ.get("CLOUD_ML_REGION", ""))
PROJECT_ID = os.environ.get("ANTHROPIC_VERTEX_PROJECT_ID", "")

if not PROJECT_ID:
    print("Error: ANTHROPIC_VERTEX_PROJECT_ID must be set", file=sys.stderr)
    sys.exit(1)
if not REGION:
    print("Error: CLOUD_ML_REGION or ANTHROPIC_VERTEX_REGION must be set", file=sys.stderr)
    sys.exit(1)
PID_FILE = os.environ.get("DEV_PROXY_PID_FILE", "/run/user/1000/dev-proxy.pid")
PORT_FILE = os.environ.get("DEV_PROXY_PORT_FILE", "/run/user/1000/dev-proxy.port")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger("vertex-proxy")

MODEL_MAP = {
    "claude-opus-4-20250514": "claude-opus-4-0@20250514",
    "claude-opus-4-6-20250918": "claude-opus-4-6",
    "claude-sonnet-4-20250514": "claude-sonnet-4-0@20250514",
    "claude-sonnet-4-5-20250929": "claude-sonnet-4-5@20250929",
    "claude-haiku-4-5-20251001": "claude-haiku-4-5@20251001",
    "claude-sonnet-5": "claude-sonnet-4-5@20250929",
}


def _to_vertex_model(model):
    """Map Anthropic API model name to Vertex AI model name.

    Strips [1m] context suffix, then checks the explicit map,
    then passes through as-is (many names work unchanged on Vertex).
    """
    model = model.split("[")[0]
    if "@" in model:
        return model
    if model in MODEL_MAP:
        return MODEL_MAP[model]
    return model


credentials, _ = google.auth.default(
    scopes=["https://www.googleapis.com/auth/cloud-platform"]
)
_auth_request = google.auth.transport.requests.Request()


def _get_token():
    """Return a valid access token, refreshing if expired."""
    if not credentials.valid:
        credentials.refresh(_auth_request)
    return credentials.token


class _ProxyHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        if self.path != "/v1/messages":
            self.send_error(404)
            return

        content_length = int(self.headers.get("Content-Length", 0))
        raw_body = self.rfile.read(content_length)

        try:
            payload = json.loads(raw_body)
        except (json.JSONDecodeError, ValueError):
            self.send_error(400, "Invalid JSON body")
            return

        model = payload.get("model", "unknown")
        vertex_model = _to_vertex_model(model)
        is_stream = payload.get("stream", False)

        payload["anthropic_version"] = "vertex-2023-10-16"
        payload.pop("model", None)
        raw_body = json.dumps(payload).encode()

        endpoint = "streamRawPredict" if is_stream else "rawPredict"
        if REGION == "global":
            host = "aiplatform.googleapis.com"
        else:
            host = f"{REGION}-aiplatform.googleapis.com"
        path = (
            f"/v1/projects/{PROJECT_ID}/locations/{REGION}/"
            f"publishers/anthropic/models/{vertex_model}:{endpoint}"
        )

        token = _get_token()
        upstream_headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Content-Length": str(len(raw_body)),
        }
        upstream_headers["anthropic-version"] = "vertex-2023-10-16"

        try:
            conn = http.client.HTTPSConnection(host)
            conn.request("POST", path, body=raw_body, headers=upstream_headers)
            upstream_resp = conn.getresponse()
        except Exception as exc:
            log.error("Upstream connection failed: %s", exc)
            self.send_error(502, f"Upstream error: {exc}")
            return

        status = upstream_resp.status
        content_type = upstream_resp.getheader("Content-Type", "application/json")

        self.send_response(status)
        self.send_header("Content-Type", content_type)

        if is_stream and 200 <= status < 300:
            # Stream SSE bytes through as they arrive. Connection: close
            # tells the client the response ends when the connection drops,
            # avoiding the need for Content-Length or chunked framing.
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
        log.info(
            "POST %s model=%s status=%d stream=%s",
            self.path, model, status, is_stream,
        )

    def log_message(self, fmt, *args):
        # Suppress the default per-request access log; we log our own.
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
    log.info("PID file: %s  Port file: %s", PID_FILE, PORT_FILE)
    log.info("Vertex AI: project=%s region=%s", PROJECT_ID, REGION)

    server.serve_forever()


if __name__ == "__main__":
    main()
