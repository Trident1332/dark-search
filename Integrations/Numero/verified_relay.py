#!/usr/bin/env python3
"""Loopback TCP to certificate-verified Numero TLS; no account credentials.

Only this upstream TLS context permits the provider's legacy TLS 1.0. The
browser's modern WSS endpoint and all other TLS configurations are untouched.
"""

from __future__ import annotations

import errno
import logging
import select
import signal
import socket
import ssl
import sys
import threading
import warnings


LISTEN = ("127.0.0.1", 5061)
UPSTREAM = ("52.59.42.210", 5061)
SERVER_NAME = "numeroesimapp.com"
MAX_CLIENTS = 16
LOG = logging.getLogger("search-numero-relay")


def make_context(cafile: str | None = None) -> ssl.SSLContext:
    context = ssl.create_default_context(cafile=cafile)
    context.check_hostname = True
    context.verify_mode = ssl.CERT_REQUIRED
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)
        context.minimum_version = ssl.TLSVersion.TLSv1
        context.maximum_version = ssl.TLSVersion.TLSv1
    context.set_ciphers("DEFAULT@SECLEVEL=0")
    return context


def connect_upstream(context: ssl.SSLContext, endpoint=UPSTREAM, hostname=SERVER_NAME) -> ssl.SSLSocket:
    raw = socket.create_connection(endpoint, timeout=12)
    try:
        channel = context.wrap_socket(raw, server_hostname=hostname)
        channel.settimeout(15)
        return channel
    except BaseException:
        raw.close()
        raise


def forward(client: socket.socket, upstream: ssl.SSLSocket, stop: threading.Event) -> None:
    """Carry both directions without logging or interpreting SIP messages."""
    client.settimeout(15)
    upstream.settimeout(15)
    while not stop.is_set():
        readable, _, _ = select.select([client, upstream], [], [], 1)
        # OpenSSL may already have decrypted bytes beyond the previous read.
        if upstream.pending() and upstream not in readable:
            readable.append(upstream)
        for source in readable:
            data = source.recv(65536)
            if not data:
                return
            (upstream if source is client else client).sendall(data)


def serve(stop: threading.Event | None = None) -> None:
    stop = stop or threading.Event()
    context = make_context()
    capacity = threading.BoundedSemaphore(MAX_CLIENTS)

    def handle(client: socket.socket) -> None:
        try:
            with client, connect_upstream(context) as upstream:
                forward(client, upstream, stop)
        except ssl.SSLCertVerificationError as error:
            LOG.error("upstream_certificate_rejected code=%d", error.verify_code)
        except ssl.SSLError:
            LOG.error("upstream_tls_failed")
        except OSError as error:
            if error.errno not in (errno.ECONNRESET, errno.EPIPE):
                LOG.warning("connection_closed error=%s", type(error).__name__)
        finally:
            capacity.release()

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(LISTEN)
        listener.listen(MAX_CLIENTS)
        listener.settimeout(1)
        LOG.info("listening_on_loopback")
        while not stop.is_set():
            try:
                client, _ = listener.accept()
            except socket.timeout:
                continue
            if not capacity.acquire(blocking=False):
                client.close()
                continue
            threading.Thread(target=handle, args=(client,), daemon=True).start()


def main() -> int:
    if len(sys.argv) != 1:
        print("This relay has fixed loopback and verified upstream endpoints.", file=sys.stderr)
        return 2
    logging.basicConfig(level=logging.INFO, format="%(name)s %(levelname)s %(message)s")
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    try:
        serve(stop)
    except OSError:
        LOG.error("could_not_start_listener")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
