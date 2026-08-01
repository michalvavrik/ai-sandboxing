#!/usr/bin/env python3
"""Dev sandbox proxy: Vertex AI auth + Git SSH bridge + MCP reverse proxy.

- Vertex AI: adds Google auth token to Claude Code's API requests
- Git: bridges HTTP smart protocol from containers to GitHub via SSH key
- MCP: reverse-proxies host MCP SSE servers (e.g. JetBrains) into containers
- Branch isolation: per-container ports restrict git push to allowed branches
"""

import atexit
import http.client
import http.server
import json
import logging
import os
import signal
import subprocess
import sys
import threading
from pathlib import Path
from urllib.parse import urlparse

import google.auth
import google.auth.transport.requests

REGION = os.environ.get("ANTHROPIC_VERTEX_REGION",
                        os.environ.get("CLOUD_ML_REGION", ""))
PROJECT_ID = os.environ.get("ANTHROPIC_VERTEX_PROJECT_ID", "")
PID_FILE = os.environ.get("DEV_PROXY_PID_FILE", "/run/user/1000/dev-proxy.pid")
PORT_FILE = os.environ.get("DEV_PROXY_PORT_FILE", "/run/user/1000/dev-proxy.port")
LISTEN_PORT = int(os.environ.get("DEV_PROXY_PORT", "9222"))
MAPPING_FILE = os.path.join(os.path.dirname(PID_FILE), "dev-proxy-ports.json")

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_KEYS_DIR = os.path.join(os.path.dirname(_SCRIPT_DIR), "keys")
SSH_KEY = os.path.join(_KEYS_DIR, "id_ed25519_dev_automation")

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
log = logging.getLogger("dev-proxy")

credentials, _ = google.auth.default(
    scopes=["https://www.googleapis.com/auth/cloud-platform"]
)
_auth_request = google.auth.transport.requests.Request()


# Only read-only MCP servers that don't reveal host information may be whitelisted.
MCP_WHITELIST = set()

MCP_SERVERS = {}

_port_mapping = {}
_port_mapping_lock = threading.Lock()
_container_servers = {}


def _load_mcp_servers():
    if not MCP_WHITELIST:
        return
    claude_json = Path.home() / ".claude.json"
    try:
        with open(claude_json) as f:
            config = json.load(f)
        for name, server in config.get("mcpServers", {}).items():
            if name not in MCP_WHITELIST:
                continue
            if server.get("type") == "sse":
                parsed = urlparse(server["url"])
                MCP_SERVERS[name] = (parsed.hostname, parsed.port)
                log.info("MCP server: %s -> %s:%d", name, parsed.hostname, parsed.port)
    except (FileNotFoundError, json.JSONDecodeError, KeyError) as exc:
        log.warning("Could not load MCP servers from %s: %s", claude_json, exc)


def _load_port_mapping():
    global _port_mapping
    try:
        with open(MAPPING_FILE) as f:
            new_mapping = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        new_mapping = {}

    with _port_mapping_lock:
        _port_mapping = new_mapping

    return new_mapping


def _get_branch_prefix(port):
    with _port_mapping_lock:
        entry = _port_mapping.get(str(port))
    if entry:
        return entry.get("branch", "")
    return None


def _extract_push_refs(body):
    """Extract ref names from a git-receive-pack pkt-line payload."""
    refs = []
    offset = 0
    while offset + 4 <= len(body):
        pkt_len_hex = body[offset:offset + 4]
        try:
            pkt_len = int(pkt_len_hex, 16)
        except ValueError:
            break
        if pkt_len == 0:
            break
        if pkt_len < 4:
            break
        pkt_data = body[offset + 4:offset + pkt_len]
        offset += pkt_len

        line = pkt_data.split(b"\x00", 1)[0]
        parts = line.split()
        if len(parts) >= 3:
            ref = parts[2].decode("utf-8", errors="replace")
            refs.append(ref)

    return refs


def _check_push_allowed(port, body):
    """Check if a git push is allowed on this port. Returns (allowed, reason)."""
    if port == LISTEN_PORT:
        return False, "git push not allowed on base proxy port"

    branch_prefix = _get_branch_prefix(port)
    if branch_prefix is None:
        return False, f"no container registered for port {port}"

    refs = _extract_push_refs(body)
    if not refs:
        return False, "could not extract refs from push payload"

    allowed_full = f"refs/heads/{branch_prefix}"
    allowed_sub = f"refs/heads/{branch_prefix}/"
    for ref in refs:
        if ref != allowed_full and not ref.startswith(allowed_sub):
            return False, f"ref {ref} not allowed (must match {allowed_full} or {allowed_sub}*)"

    return True, "ok"


def _get_token():
    if not credentials.valid:
        credentials.refresh(_auth_request)
    return credentials.token


def _git_ssh_cmd():
    return ["ssh", "-i", SSH_KEY, "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=accept-new", "git@github.com"]


def _read_pkt_lines(stream):
    """Read pkt-line data until a flush packet (0000). Returns raw bytes."""
    buf = bytearray()
    while True:
        pkt_len_hex = stream.read(4)
        if len(pkt_len_hex) < 4:
            break
        buf.extend(pkt_len_hex)
        pkt_len = int(pkt_len_hex, 16)
        if pkt_len == 0:
            break
        remaining = pkt_len - 4
        if remaining > 0:
            buf.extend(stream.read(remaining))
    return bytes(buf)


def _parse_git_path(request_path):
    """Parse /git/owner/repo.git/rest?query into (owner, repo.git, rest, query)."""
    path = request_path
    query = ""
    if "?" in path:
        path, query = path.split("?", 1)

    trimmed = path[len("/git/"):]
    git_idx = trimmed.find(".git/")
    if git_idx == -1:
        return None
    repo_part = trimmed[:git_idx + 4]
    rest = trimmed[git_idx + 5:]
    owner = repo_part.split("/")[0]
    return owner, repo_part, rest, query


class _ProxyHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _handle_git_refs(self, repo_path, service):
        """GET /info/refs?service=<service> — bridge to SSH."""
        proc = subprocess.Popen(
            [*_git_ssh_cmd(), f"{service} '{repo_path}'"],
            stdout=subprocess.PIPE, stdin=subprocess.PIPE, stderr=subprocess.PIPE,
        )

        ref_data = _read_pkt_lines(proc.stdout)

        proc.stdin.close()
        proc.terminate()

        service_line = f"# service={service}\n"
        service_pkt = f"{len(service_line) + 4:04x}{service_line}".encode()

        body = service_pkt + b"0000" + ref_data
        self.send_response(200)
        self.send_header("Content-Type", f"application/x-{service}-advertisement")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _handle_git_pack(self, repo_path, service):
        """POST /git-receive-pack or /git-upload-pack — bridge to SSH."""
        content_length = int(self.headers.get("Content-Length", 0))
        raw_body = self.rfile.read(content_length) if content_length > 0 else b""

        if service == "git-receive-pack":
            port = self.server.server_address[1]
            allowed, reason = _check_push_allowed(port, raw_body)
            if not allowed:
                log.warning("BLOCKED push on port %d: %s", port, reason)
                msg = f"Push rejected: {reason}\n".encode()
                self.send_response(403)
                self.send_header("Content-Length", str(len(msg)))
                self.end_headers()
                self.wfile.write(msg)
                return

        proc = subprocess.Popen(
            [*_git_ssh_cmd(), f"{service} '{repo_path}'"],
            stdout=subprocess.PIPE, stdin=subprocess.PIPE, stderr=subprocess.PIPE,
        )

        _read_pkt_lines(proc.stdout)

        proc.stdin.write(raw_body)
        proc.stdin.close()

        response_data = proc.stdout.read()
        proc.wait()

        self.send_response(200)
        self.send_header("Content-Type", f"application/x-{service}-result")
        self.send_header("Content-Length", str(len(response_data)))
        self.end_headers()
        self.wfile.write(response_data)
        log.info("GIT %s %s exit=%d", service, repo_path, proc.returncode)

    def _forward_git(self, method):
        """Route git HTTP smart protocol requests to SSH."""
        parsed = _parse_git_path(self.path)
        if not parsed:
            self.send_error(400, "Bad git path")
            return

        _, repo_part, rest, query = parsed
        repo_path = f"/{repo_part}"

        try:
            if rest == "info/refs":
                service = ""
                for param in query.split("&"):
                    if param.startswith("service="):
                        service = param[len("service="):]
                if service in ("git-receive-pack", "git-upload-pack"):
                    self._handle_git_refs(repo_path, service)
                else:
                    self.send_error(400, f"Unknown service: {service}")
            elif rest in ("git-receive-pack", "git-upload-pack") and method == "POST":
                self._handle_git_pack(repo_path, rest)
            else:
                self.send_error(404)
        except Exception as exc:
            log.error("Git SSH bridge failed: %s", exc)
            self.send_error(502, f"Git SSH error: {exc}")

    def _forward_vertex(self):
        """Forward Vertex AI requests with Google auth."""
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

    def _relay_sse(self, name):
        if name not in MCP_SERVERS:
            self.send_error(404, f"Unknown MCP server: {name}")
            return

        host, port = MCP_SERVERS[name]
        prefix = f"/mcp/{name}"

        try:
            conn = http.client.HTTPConnection(host, port, timeout=10)
            conn.request("GET", "/sse")
            upstream = conn.getresponse()
        except Exception as exc:
            log.error("MCP %s connect failed: %s", name, exc)
            self.send_error(503, f"MCP server '{name}' unavailable")
            return

        if upstream.status != 200:
            self.send_error(upstream.status)
            conn.close()
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "keep-alive")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

        try:
            while True:
                line = upstream.readline()
                if not line:
                    break
                text = line.decode("utf-8", errors="replace")
                if text.startswith("data: /"):
                    text = f"data: {prefix}{text[6:]}"
                    line = text.encode("utf-8")
                self.wfile.write(line)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            conn.close()
            log.info("MCP %s SSE session ended", name)

    def _forward_mcp_message(self, name, query):
        if name not in MCP_SERVERS:
            self.send_error(404, f"Unknown MCP server: {name}")
            return

        host, port = MCP_SERVERS[name]
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length) if content_length > 0 else b""

        upstream_path = f"/message?{query}" if query else "/message"

        try:
            conn = http.client.HTTPConnection(host, port, timeout=30)
            conn.request("POST", upstream_path, body=body, headers={
                "Content-Type": self.headers.get("Content-Type", "application/json"),
                "Content-Length": str(len(body)),
            })
            resp = conn.getresponse()
        except Exception as exc:
            log.error("MCP %s message failed: %s", name, exc)
            self.send_error(503, f"MCP server '{name}' unavailable")
            return

        resp_body = resp.read()
        self.send_response(resp.status)
        ct = resp.getheader("Content-Type")
        if ct:
            self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(len(resp_body)))
        self.end_headers()
        if resp_body:
            self.wfile.write(resp_body)
        conn.close()

    def _serve_mcp_config(self):
        body = json.dumps(list(MCP_SERVERS.keys())).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/git/"):
            self._forward_git("GET")
        elif MCP_SERVERS and self.path == "/mcp/config":
            self._serve_mcp_config()
        elif MCP_SERVERS and self.path.startswith("/mcp/"):
            parts = self.path.split("/", 4)
            if len(parts) >= 4 and parts[3].startswith("sse"):
                self._relay_sse(parts[2])
            else:
                self.send_error(404)
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path.startswith("/git/"):
            self._forward_git("POST")
        elif MCP_SERVERS and self.path.startswith("/mcp/"):
            path = self.path
            query = ""
            if "?" in path:
                path, query = path.split("?", 1)
            parts = path.split("/", 4)
            if len(parts) >= 4 and parts[3] == "message":
                self._forward_mcp_message(parts[2], query)
            else:
                self.send_error(404)
        else:
            self._forward_vertex()

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


def _start_listener(port):
    """Start a listener on a port in a daemon thread."""
    try:
        server = http.server.ThreadingHTTPServer(("0.0.0.0", port), _ProxyHandler)
    except OSError as exc:
        log.error("Could not bind port %d: %s", port, exc)
        return None
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    log.info("Listener started on port %d", port)
    return server


def _sync_listeners():
    """Start/stop per-container listeners to match the mapping file."""
    mapping = _load_port_mapping()
    mapped_ports = {int(p) for p in mapping}

    for port in list(_container_servers):
        if port not in mapped_ports:
            _container_servers[port].shutdown()
            del _container_servers[port]
            log.info("Listener stopped on port %d", port)

    for port in mapped_ports:
        if port not in _container_servers:
            server = _start_listener(port)
            if server:
                _container_servers[port] = server


def _sighup_handler(signum, _frame):
    log.info("SIGHUP received, reloading port mapping")
    threading.Thread(target=_sync_listeners, daemon=True).start()


def _shutdown_handler(signum, _frame):
    log.info("Received signal %d, shutting down", signum)
    for server in _container_servers.values():
        server.shutdown()
    _remove_runtime_files()
    sys.exit(0)


def main():
    signal.signal(signal.SIGTERM, _shutdown_handler)
    signal.signal(signal.SIGINT, _shutdown_handler)
    signal.signal(signal.SIGHUP, _sighup_handler)

    _load_mcp_servers()

    server = http.server.ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), _ProxyHandler)
    port = server.server_address[1]

    _write_file(PID_FILE, str(os.getpid()))
    _write_file(PORT_FILE, str(port))
    atexit.register(_remove_runtime_files)

    _sync_listeners()

    log.info("Listening on 0.0.0.0:%d (base)", port)
    log.info("Git SSH key: %s", SSH_KEY)
    log.info("Vertex AI: %s", UPSTREAM_HOST)
    log.info("MCP servers: %s", list(MCP_SERVERS.keys()) or "none")

    server.serve_forever()


if __name__ == "__main__":
    main()
