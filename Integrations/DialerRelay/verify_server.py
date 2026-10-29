#!/usr/bin/env python3
"""Owned-server health probe: no calls and no media payloads or credential output."""
from __future__ import annotations
import base64
import hashlib
import hmac
import ipaddress
import json
import os
from pathlib import Path
import secrets
import socket
import ssl
import struct
import urllib.error
import urllib.request

from issuer import seat_password

HOST = "sip.investigate.agency"
PEER = "185.56.45.246"
COOKIE = 0x2112A442


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def attr(kind, value):
    return struct.pack("!HH", kind, len(value)) + value + b"\0" * (-len(value) % 4)


def packet(kind, attributes, *, key=None):
    transaction = secrets.token_bytes(12)
    length = len(attributes) + (24 if key else 0)
    header = struct.pack("!HHI", kind, length, COOKIE) + transaction
    data = header + attributes
    if key:
        data += attr(0x0008, hmac.new(key, data, hashlib.sha1).digest())
    return data, transaction


def exact(sock, length):
    data = b""
    while len(data) < length:
        part = sock.recv(length - len(data))
        if not part:
            raise ValueError("turn_response_incomplete")
        data += part
    return data


def exchange(sock, request, transaction):
    sock.sendall(request)
    header = exact(sock, 20)
    kind, length, cookie = struct.unpack("!HHI", header[:8])
    if cookie != COOKIE or header[8:] != transaction or length > 32768 or length % 4:
        raise ValueError("turn_response_invalid")
    data = exact(sock, length)
    attributes = {}
    i = 0
    while i < len(data):
        if i + 4 > len(data):
            raise ValueError("turn_attribute_invalid")
        code, size = struct.unpack("!HH", data[i:i + 4])
        if i + 4 + size > len(data):
            raise ValueError("turn_attribute_invalid")
        attributes[code] = data[i + 4:i + 4 + size]
        i += 4 + size + (-size % 4)
    return kind, attributes


def peer_attribute(ip, port=20000):
    address = int(ipaddress.IPv4Address(ip)) ^ COOKIE
    return attr(0x0012, struct.pack("!BBHI", 0, 1, port ^ (COOKIE >> 16), address))


def verify():
    context = ssl.create_default_context()
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(), urllib.request.HTTPSHandler(context=context))
    url = f"https://{HOST}/search-dialer/turn"
    results = {}
    for method, expected in [("POST", 401), ("GET", 405)]:
        try:
            response = opener.open(urllib.request.Request(url, data=b"{}" if method == "POST" else None, method=method), timeout=10)
            status = response.status
            response.close()
        except urllib.error.HTTPError as error:
            status = error.code
            error.close()
        results[f"unauthenticated_{method.lower()}_status"] = status
        if status != expected:
            raise ValueError("issuer_refusal_check_failed")
    password = seat_password(Path("/root/telicall/fs/conf/directory/default/1001.xml"), "1001")
    authorization = "Basic " + base64.b64encode(("1001:" + password).encode()).decode()
    request = urllib.request.Request(url, data=b"{}", headers={"Authorization": authorization, "Content-Type": "application/json"}, method="POST")
    with opener.open(request, timeout=10) as response:
        body = response.read(32769)
        if len(body) > 32768 or response.headers.get("Cache-Control") != "no-store":
            raise ValueError("issuer_response_invalid")
    values = json.loads(body)
    server = values["iceServers"][0]
    if server["urls"] != [f"turns:{HOST}:5349?transport=tcp"] or values["ttl"] != 3600:
        raise ValueError("issuer_contract_invalid")
    username, credential = server["username"], server["credential"]
    secret = Path("/etc/search-dialer-relay/turn-secret").read_bytes().strip()
    expected = base64.b64encode(hmac.new(secret, username.encode(), hashlib.sha1).digest()).decode()
    if not hmac.compare_digest(credential, expected):
        raise ValueError("issuer_hmac_invalid")
    results["issuer_hmac_valid"] = True
    results["credential_ttl"] = values["ttl"]
    with socket.create_connection((HOST, 5349), timeout=10) as raw:
        with context.wrap_socket(raw, server_hostname=HOST) as sock:
            sock.settimeout(10)
            results["turn_tls_protocol"] = sock.version()
            allocate = attr(0x0019, b"\x11\0\0\0") + attr(0x000D, struct.pack("!I", 60))
            kind, challenge = exchange(sock, *packet(0x0003, allocate))
            if kind != 0x0113 or 0x0014 not in challenge or 0x0015 not in challenge:
                raise ValueError("turn_auth_challenge_missing")
            realm, nonce = challenge[0x0014], challenge[0x0015]
            if realm != HOST.encode():
                raise ValueError("turn_realm_invalid")
            key = hashlib.md5(username.encode() + b":" + realm + b":" + credential.encode()).digest()
            auth = attr(0x0006, username.encode()) + attr(0x0014, realm) + attr(0x0015, nonce)
            kind, answer = exchange(sock, *packet(0x0003, allocate + auth, key=key))
            if kind != 0x0103 or 0x0016 not in answer:
                raise ValueError("turn_allocation_failed")
            relay = answer[0x0016]
            _, family, port, ip = struct.unpack("!BBHI", relay)
            if family != 1 or str(ipaddress.IPv4Address(ip ^ COOKIE)) != PEER or not 49160 <= port ^ (COOKIE >> 16) <= 49200:
                raise ValueError("turn_relay_address_invalid")
            results["authenticated_allocate"] = True
            kind, _ = exchange(sock, *packet(0x0008, peer_attribute(PEER) + auth, key=key))
            results["owned_peer_permission"] = kind == 0x0108
            kind, denied = exchange(sock, *packet(0x0008, peer_attribute("192.0.2.99") + auth, key=key))
            error = denied.get(0x0009, b"")
            results["off_host_peer_denied"] = kind == 0x0118 and len(error) >= 4 and (error[2] & 7) * 100 + error[3] == 403
            kind, _ = exchange(sock, *packet(0x0004, attr(0x000D, struct.pack("!I", 0)) + auth, key=key))
            results["allocation_deleted"] = kind == 0x0104
            if not all(results[k] for k in ["owned_peer_permission", "off_host_peer_denied", "allocation_deleted"]):
                raise ValueError("turn_peer_or_cleanup_check_failed")
    return results


if __name__ == "__main__":
    try:
        print(json.dumps(verify(), sort_keys=True))
    except Exception:
        raise SystemExit("relay_health_check_failed") from None
