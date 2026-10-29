#!/usr/bin/env python3
"""Render a private TLS-only coturn config; never print its shared secret."""
from __future__ import annotations
import argparse
import ipaddress
import os
from pathlib import Path
import re


def render(secret: str, peer: str = "185.56.45.246", host: str = "sip.investigate.agency") -> str:
    if not re.fullmatch(r"[A-Za-z0-9_-]{43,128}", secret):
        raise ValueError("invalid_secret")
    address = ipaddress.IPv4Address(peer)
    if not address.is_global:
        raise ValueError("invalid_peer")
    if not re.fullmatch(r"[a-z0-9.-]{1,253}", host) or ".." in host or host.startswith((".", "-")):
        raise ValueError("invalid_host")
    return f"""# Private generated file: contains the TURN REST signing secret.
listening-ip={address}
relay-ip={address}
tls-listening-port=5349
no-udp
no-tcp
no-dtls
no-tcp-relay
no-stun
no-cli
no-loopback-peers
no-multicast-peers
no-tlsv1
no-tlsv1_1
realm={host}
server-name={host}
use-auth-secret
static-auth-secret={secret}
cert=/etc/search-dialer-relay/tls/fullchain.pem
pkey=/etc/search-dialer-relay/tls/privkey.pem
min-port=49160
max-port=49200
user-quota=4
total-quota=20
max-bps=262144
bps-capacity=5242880
max-allocate-lifetime=3600
denied-peer-ip=0.0.0.0-255.255.255.255
denied-peer-ip=::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
allowed-peer-ip={address}
no-stdout-log
log-file=/dev/null
pidfile=/run/search-dialer-turn/turnserver.pid
"""


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--secret-file", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--peer", default="185.56.45.246")
    p.add_argument("--host", default="sip.investigate.agency")
    args = p.parse_args()
    try:
        config = render(args.secret_file.read_text().strip(), args.peer, args.host)
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as file:
            file.write(config)
    except Exception:
        raise SystemExit("relay_configuration_failed") from None


if __name__ == "__main__":
    main()
