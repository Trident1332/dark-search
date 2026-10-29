#!/usr/bin/env python3
"""Issue expiring, seat-authenticated TURN credentials over an isolated Unix socket."""
from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import hmac
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import socketserver
import threading
import time
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler
import xml.etree.ElementTree as ET

ENDPOINT = "/search-dialer/turn"
MAX_BODY = 32768


def seat_password(path: Path, user: str) -> str:
    """Read only the designated seat; macros and ambiguous identities fail closed."""
    data = path.read_bytes()
    if len(data) > 1024 * 1024:
        raise ValueError("seat_configuration_invalid")
    root = ET.fromstring(data)
    users = [u for u in root.iter("user") if u.get("id") == user]
    values = [p.get("value", "") for u in users for p in u.iter("param") if p.get("name") == "password"]
    if len(users) != 1 or len(values) != 1 or not values[0] or "$" in values[0] or len(values[0]) > 4096:
        raise ValueError("seat_configuration_invalid")
    return values[0]


@dataclass(frozen=True, repr=False)
class Config:
    user: str
    password: str
    secret: bytes
    host: str = "sip.investigate.agency"
    port: int = 5349
    ttl: int = 3600

    def __post_init__(self):
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", self.user):
            raise ValueError("seat_configuration_invalid")
        if not self.password or len(self.password) > 4096 or len(self.secret) < 32:
            raise ValueError("credential_configuration_invalid")
        labels = self.host.split(".")
        if len(labels) < 2 or any(not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", x) for x in labels):
            raise ValueError("host_configuration_invalid")
        if type(self.port) is not int or not 1 <= self.port <= 65535 or type(self.ttl) is not int or not 60 <= self.ttl <= 14400:
            raise ValueError("lifetime_configuration_invalid")


class RateLimit:
    """A bounded sliding window, including failed authentication attempts."""
    def __init__(self, limit=12, window=60, max_clients=512, clock=time.monotonic):
        self.limit, self.window, self.max_clients, self.clock = limit, window, max_clients, clock
        self.lock = threading.Lock()
        self.clients: dict[str, list[float]] = {}
        self.global_times: list[float] = []

    def allow(self, client: str) -> bool:
        with self.lock:
            now = self.clock()
            self.clients = {k: [t for t in v if t > now - self.window] for k, v in self.clients.items() if v and v[-1] > now - self.window}
            self.global_times = [t for t in self.global_times if t > now - self.window]
            if len(self.global_times) >= 120 or (client not in self.clients and len(self.clients) >= self.max_clients):
                return False
            values = self.clients.setdefault(client, [])
            if len(values) >= self.limit:
                return False
            values.append(now)
            self.global_times.append(now)
            return True


class Issuer:
    def __init__(self, config: Config, *, clock=time.time, nonce=lambda: secrets.token_hex(12), limiter=None):
        self.config, self.clock, self.nonce = config, clock, nonce
        self.limiter = limiter or RateLimit()

    def authenticated(self, authorization: str | None) -> bool:
        try:
            scheme, token = (authorization or "").split(" ", 1)
            if scheme.lower() != "basic" or len(token) > 8192:
                return False
            raw = base64.b64decode(token, validate=True)
            user, password = raw.decode("utf-8").split(":", 1)
        except (ValueError, UnicodeError, binascii.Error):
            return False
        # Both comparisons run even when the username differs.
        user_ok = hmac.compare_digest(user.encode(), self.config.user.encode())
        password_ok = hmac.compare_digest(password.encode(), self.config.password.encode())
        return user_ok & password_ok

    def handle(self, method: str, authorization: str | None, body: bytes, client: str):
        if not self.limiter.allow(client):
            return 429, {"error": "rate_limited"}
        if method != "POST":
            return 405, {"error": "method_not_allowed"}
        if len(body) > MAX_BODY:
            return 413, {"error": "request_too_large"}
        if not self.authenticated(authorization):
            return 401, {"error": "authentication_required"}
        try:
            if body and json.loads(body) != {}:
                raise ValueError()
        except (ValueError, UnicodeError):
            return 400, {"error": "bad_request"}
        expires = int(self.clock()) + self.config.ttl
        username = f"{expires}:{self.config.user}:{self.nonce()}"
        credential = base64.b64encode(hmac.new(self.config.secret, username.encode(), hashlib.sha1).digest()).decode("ascii")
        return 200, {
            "iceServers": [{"urls": [f"turns:{self.config.host}:{self.config.port}?transport=tcp"],
                            "username": username, "credential": credential}],
            "expiresAt": expires, "ttl": self.config.ttl,
        }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "SearchDialerRelay"
    sys_version = ""

    def log_message(self, *args):
        pass  # No paths, headers, credentials, or response bodies enter logs.

    def setup(self):
        self.request.settimeout(5)
        super().setup()

    def respond(self, status, value):
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Pragma", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Connection", "close")
        if status == 401:
            self.send_header("WWW-Authenticate", 'Basic realm="Search Dialer Relay", charset="UTF-8"')
        if status == 405:
            self.send_header("Allow", "POST")
        if status == 429:
            self.send_header("Retry-After", "60")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def dispatch(self):
        if self.path != ENDPOINT:
            return self.respond(404, {"error": "not_found"})
        lengths = self.headers.get_all("Content-Length", [])
        auth = self.headers.get_all("Authorization", [])
        if len(lengths) > 1 or len(auth) > 1 or self.headers.get("Transfer-Encoding"):
            return self.respond(400, {"error": "bad_request"})
        try:
            raw_length = lengths[0] if lengths else "0"
            if not re.fullmatch(r"[0-9]{1,8}", raw_length):
                raise ValueError()
            length = int(raw_length)
        except ValueError:
            return self.respond(400, {"error": "bad_request"})
        if length > MAX_BODY:
            return self.respond(413, {"error": "request_too_large"})
        body = self.rfile.read(length)
        if len(body) != length:
            return self.respond(400, {"error": "bad_request"})
        try:
            client = str(ipaddress.ip_address(self.headers.get("X-Real-IP", "")))
        except ValueError:
            return self.respond(400, {"error": "bad_request"})
        status, value = self.server.issuer.handle(self.command, auth[0] if auth else None, body, client)
        self.respond(status, value)

    do_POST = dispatch
    do_GET = dispatch
    do_PUT = dispatch
    do_DELETE = dispatch
    do_OPTIONS = dispatch


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    request_queue_size = 16

    def __init__(self, path, issuer):
        self.issuer = issuer
        self.slots = threading.BoundedSemaphore(16)
        super().__init__(path, Handler)
        os.chmod(path, 0o660)

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            return self.shutdown_request(request)
        try:
            super().process_request(request, address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.slots.release()

    def handle_error(self, request, address):
        pass  # BaseServer's traceback can include request-local credential data.


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--user", default="1001")
    parser.add_argument("--host", default="sip.investigate.agency")
    parser.add_argument("--ttl", type=int, default=3600)
    args = parser.parse_args()
    try:
        directory = Path(os.environ["CREDENTIALS_DIRECTORY"])
        config = Config(args.user, seat_password(directory / "seat.xml", args.user),
                        (directory / "turn-secret").read_bytes().strip(), args.host, ttl=args.ttl)
        path = Path(args.socket)
        if path.exists():
            if not path.is_socket():
                raise ValueError("socket_configuration_invalid")
            path.unlink()
        with Server(str(path), Issuer(config)) as server:
            server.serve_forever(poll_interval=0.5)
    except Exception:
        raise SystemExit("relay_configuration_or_service_failed") from None


if __name__ == "__main__":
    main()
