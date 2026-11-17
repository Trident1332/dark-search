#!/usr/bin/env python3
"""Loopback-only call-authorized Numero selector; account tokens stay on this host."""
from __future__ import annotations
from dataclasses import dataclass
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import logging
from pathlib import Path
import re
import secrets
import subprocess
import threading
import urllib.parse
import uuid as uuid_module

from line_selection import LINE_GATEWAYS, Provider, SelectionError, load_session, private_bytes, select_line

ADDRESS = ("127.0.0.1", 18082)
AUTH_FILE = Path("/root/telicall/fs/scripts/search-numero-selector.wgetrc")


def report_failure(error):
    # Only literal diagnostic tags may reach the journal. Never log arbitrary
    # exception text, provider bodies, account identities, numbers or tokens.
    allowed = {"session_expired", "provider_rejected", "provider_unavailable",
               "provider_response_invalid", "gateway_unavailable",
               "selection_not_verified", "owned_line_missing_or_ambiguous",
               "session_binding_invalid", "calling_server_unavailable"}
    code = error.args[0] if isinstance(error, SelectionError) and len(error.args) == 1 else None
    code = code if isinstance(code, str) and code in allowed else "selection_unavailable"
    logging.getLogger("numero_selector").warning("selection_failed reason=%s", code)
    return code


class Busy(SelectionError):
    pass


def call_arguments(uuid, line, destination):
    if not isinstance(uuid, str) or not isinstance(line, str) or not isinstance(destination, str):
        raise SelectionError("invalid_call")
    try:
        canonical = str(uuid_module.UUID(uuid))
    except ValueError:
        raise SelectionError("invalid_call") from None
    if canonical != uuid or line not in ("us", "ca") or not re.fullmatch(r"[1-9][0-9]{5,14}", destination):
        raise SelectionError("invalid_call")


class FreeSWITCH:
    def api(self, command):
        result = subprocess.run(["docker", "exec", "freeswitch", "fs_cli", "-x", command],
            capture_output=True, text=True, timeout=3)
        if result.returncode or len(result.stdout) > 262144:
            raise SelectionError("calling_server_unavailable")
        return result.stdout.strip()

    def exists(self, uuid):
        value = self.api("uuid_exists " + uuid)
        if value not in ("true", "false"):
            raise SelectionError("calling_server_unavailable")
        return value == "true"

    def require_call(self, uuid, line, destination):
        call_arguments(uuid, line, destination)
        if not self.exists(uuid):
            raise SelectionError("call_ended")
        expected = {"sip_authorized": "true", "sip_auth_username": "1001",
                    "destination_number": f"numero-{line}-{destination}"}
        for name, value in expected.items():
            if self.api("uuid_getvar " + uuid + " " + name) != value:
                raise SelectionError("call_not_authorized")

    def require_gateway(self, gateway):
        if gateway not in LINE_GATEWAYS.values():
            raise SelectionError("gateway_invalid")
        status = self.api("sofia status gateway " + gateway)
        if not re.search(r"^State\s+REGED\s*$", status, re.M) or not re.search(r"^Status\s+UP\s*$", status, re.M):
            raise SelectionError("gateway_unavailable")

    def another_numero_call(self, uuid, session):
        def same_or_unknown(gateway):
            account = (session.gateway_accounts or {}).get(gateway)
            return account is None or account == session.account_key
        try:
            response = json.loads(self.api("show channels as json"))
            if not isinstance(response, dict):
                raise ValueError()
            # FS 1.10.12 omits rows entirely for its actual empty response.
            # Missing rows never means empty without an exact integer zero.
            rows = response.get("rows")
            count = response.get("row_count")
            if "rows" not in response and type(count) is int and count == 0:
                rows = []
            if not isinstance(rows, list) or len(rows) > 256 or any(not isinstance(row, dict) for row in rows) or ("row_count" in response and (
                    type(count) is not int or count != len(rows))):
                raise ValueError()
            for row in rows:
                if row.get("uuid") == uuid or row.get("call_uuid") == uuid:
                    continue
                destinations = (str(row.get("dest", "")), str(row.get("initial_destination", "")))
                for destination in destinations:
                    if destination.startswith("numero-"):
                        match = re.match(r"numero-(us|ca)-", destination)
                        if not match or same_or_unknown((session.line_gateways or {}).get(match[1])):
                            return True
                if "@numeroesimapp.com" in str(row.get("name", "")):
                    other_uuid = row.get("uuid", "")
                    if not isinstance(other_uuid, str) or str(uuid_module.UUID(other_uuid)) != other_uuid:
                        raise ValueError()
                    gateway = self.api("uuid_getvar " + other_uuid + " search_numero_gateway")
                    if gateway not in LINE_GATEWAYS.values():
                        gateway = self.api("uuid_getvar " + other_uuid + " sip_gateway_name")
                    if gateway not in LINE_GATEWAYS.values() or same_or_unknown(gateway):
                        return True
            return False
        except (KeyError, TypeError, ValueError):
            raise SelectionError("calling_server_unavailable") from None


@dataclass(repr=False)
class Lease:
    uuid: str
    token: str
    inflight: bool = True


class Selector:
    def __init__(self, fs, session_loader=load_session, provider_factory=Provider):
        self.fs, self.session_loader, self.provider_factory = fs, session_loader, provider_factory
        self.operations = {}
        self.state = threading.Lock()
        self.leases = {}

    def reap(self):
        with self.state:
            candidates = [(key, lease) for key, lease in self.leases.items() if not lease.inflight]
        for key, lease in candidates:
            try:
                alive = self.fs.exists(lease.uuid)
            except Exception:
                continue  # An unavailable PBX is not proof that a call ended.
            if not alive:
                with self.state:
                    if self.leases.get(key) is lease and not lease.inflight:
                        del self.leases[key]

    def select(self, uuid, line, destination):
        call_arguments(uuid, line, destination)
        self.fs.require_call(uuid, line, destination)
        session = self.session_loader(line=line)
        if line not in session.owned or session.gateway != LINE_GATEWAYS[line]:
            raise SelectionError("session_binding_invalid")
        key = session.account_key
        with self.state:
            operation = self.operations.setdefault(key, threading.Lock())
        if not operation.acquire(blocking=False):
            raise Busy("account_busy")
        lease = None
        try:
            self.fs.require_call(uuid, line, destination)
            self.reap()
            with self.state:
                if key in self.leases:
                    raise Busy("account_busy")
                lease = Lease(uuid, secrets.token_urlsafe(24))
                self.leases[key] = lease
            # Also protects service restarts that lost the in-memory lease.
            if self.fs.another_numero_call(uuid, session):
                raise Busy("account_busy")
            self.fs.require_gateway(session.gateway)
            result = select_line(session, self.provider_factory(session), line,
                lambda: self.fs.require_call(uuid, line, destination))
            with self.state:
                lease.inflight = False
            return dict(result, ok=True, status=200, lease=lease.token)
        except Exception:
            with self.state:
                if lease is not None and self.leases.get(key) is lease:
                    del self.leases[key]
            raise
        finally:
            operation.release()

    def release(self, uuid, token):
        with self.state:
            leases = [value for value in self.leases.values() if value.uuid == uuid]
            if not leases:
                return
            if not any(hmac.compare_digest(lease.token, token) for lease in leases):
                raise SelectionError("lease_not_authorized")
        # A caller cannot release a live call's account lease prematurely.
        self.reap()


def bearer(path=AUTH_FILE):
    text = private_bytes(path).decode("ascii")
    values = re.findall(r"^header\s*=\s*Authorization:\s*Bearer\s+([A-Za-z0-9_-]{43,128})\s*$", text, re.M)
    if len(values) != 1:
        raise SelectionError("local_auth_configuration_invalid")
    return "Bearer " + values[0]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    server_version = "SearchNumeroSelector"
    sys_version = ""

    def log_message(self, *args):
        pass

    def setup(self):
        self.request.settimeout(5)
        super().setup()

    def respond(self, status, body):
        data = json.dumps(body, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        status, body = 503, {"ok": False, "status": 503, "error": "selection_unavailable"}
        try:
            auth = self.headers.get_all("Authorization", [])
            if len(auth) != 1 or not hmac.compare_digest(auth[0].encode(), self.server.bearer.encode()):
                return self.respond(401, {"ok": False, "status": 401, "error": "not_authorized"})
            sizes = self.headers.get_all("Content-Length", [])
            if len(sizes) != 1 or not re.fullmatch(r"[0-9]{1,4}", sizes[0]) or int(sizes[0]) > 2048 or self.headers.get("Transfer-Encoding"):
                raise SelectionError("request_invalid")
            data = self.rfile.read(int(sizes[0]))
            if len(data) != int(sizes[0]):
                raise SelectionError("request_invalid")
            fields = urllib.parse.parse_qs(data.decode("ascii"), keep_blank_values=True, strict_parsing=True)
            if any(len(value) != 1 for value in fields.values()):
                raise SelectionError("request_invalid")
            fields = {key: value[0] for key, value in fields.items()}
            if self.path == "/select" and set(fields) == {"uuid", "line", "destination"}:
                body = self.server.selector.select(fields["uuid"], fields["line"], fields["destination"])
            elif self.path == "/release" and set(fields) == {"uuid", "lease"}:
                if not re.fullmatch(r"[A-Za-z0-9_-]{32}", fields["lease"]):
                    raise SelectionError("request_invalid")
                self.server.selector.release(fields["uuid"], fields["lease"])
                body = {"ok": True, "status": 200}
            else:
                raise SelectionError("request_invalid")
            status = 200
        except Busy:
            status, body = 486, {"ok": False, "status": 486, "error": "account_busy"}
        except Exception as error:
            body["error"] = report_failure(error)
        self.respond(status, body)


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, selector, token):
        self.selector, self.bearer = selector, token
        self.slots = threading.BoundedSemaphore(8)
        super().__init__(ADDRESS, Handler)

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

    def handle_error(self, *args):
        pass


def main():
    selector = Selector(FreeSWITCH())
    stop = threading.Event()
    def reap():
        while not stop.wait(1):
            selector.reap()
    threading.Thread(target=reap, daemon=True).start()
    try:
        with Server(selector, bearer()) as server:
            server.serve_forever(poll_interval=0.5)
    finally:
        stop.set()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        raise SystemExit("numero_selector_unavailable") from None
