"""Local TLS fixtures exercise verification and duplex forwarding, never SIP."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import unittest
import warnings


SOURCE = Path(__file__).resolve().parents[1] / "verified_relay.py"
SPEC = importlib.util.spec_from_file_location("numero_verified_relay", SOURCE)
RELAY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RELAY)


class NumeroRelayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        openssl = shutil.which("openssl")
        if not openssl:
            raise unittest.SkipTest("openssl is needed only to create the offline test certificate")
        cls.folder = tempfile.TemporaryDirectory()
        cls.root = Path(cls.folder.name)
        cls.cert, cls.key = cls.root / "test-cert.pem", cls.root / "test-key.pem"
        config = cls.root / "openssl.cnf"
        config.write_text("""[req]
distinguished_name=dn
x509_extensions=extensions
prompt=no
[dn]
CN=numeroesimapp.com
[extensions]
basicConstraints=critical,CA:TRUE
keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign
extendedKeyUsage=serverAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
subjectAltName=DNS:numeroesimapp.com
""", encoding="utf-8")
        subprocess.run([openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-config", str(config), "-keyout", str(cls.key), "-out", str(cls.cert)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    @classmethod
    def tearDownClass(cls):
        cls.folder.cleanup()

    def test_context_keeps_ca_and_hostname_verification_required(self):
        context = RELAY.make_context()
        self.assertTrue(context.check_hostname)
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        self.assertEqual(context.minimum_version, ssl.TLSVersion.TLSv1)
        self.assertEqual(context.maximum_version, ssl.TLSVersion.TLSv1)
        self.assertGreater(context.cert_store_stats()["x509_ca"], 0)
        ordinary = ssl.create_default_context()
        self.assertGreaterEqual(ordinary.minimum_version, ssl.TLSVersion.TLSv1_2)

    def test_production_listener_is_loopback_and_upstream_identity_is_fixed(self):
        self.assertEqual(RELAY.LISTEN, ("127.0.0.1", 5061))
        self.assertEqual(RELAY.UPSTREAM, ("52.59.42.210", 5061))
        self.assertEqual(RELAY.SERVER_NAME, "numeroesimapp.com")
        self.assertNotIn("CERT_NONE", SOURCE.read_text(encoding="utf-8"))
        unit = (SOURCE.parent / "search-numero-relay.service").read_text(encoding="utf-8")
        self.assertIn("DynamicUser=yes", unit)
        self.assertIn("NoNewPrivileges=yes", unit)
        self.assertIn("ProtectSystem=strict", unit)
        self.assertNotIn("Environment=", unit)

    def local_tls_server(self, callback):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", DeprecationWarning)
            context.minimum_version = ssl.TLSVersion.TLSv1
            context.maximum_version = ssl.TLSVersion.TLSv1
        context.set_ciphers("DEFAULT@SECLEVEL=0")
        context.load_cert_chain(str(self.cert), str(self.key))
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(4)
        errors = []

        def server():
            try:
                with listener:
                    client, _ = listener.accept()
                    with client, context.wrap_socket(client, server_side=True) as channel:
                        channel.settimeout(4)
                        callback(channel)
            except (ssl.SSLError, OSError) as error:
                errors.append(error)

        thread = threading.Thread(target=server, daemon=True)
        thread.start()
        return listener.getsockname(), thread, errors

    def test_verified_local_tls_forwards_both_directions_and_closes_on_eof(self):
        endpoint, server, errors = self.local_tls_server(lambda channel: channel.sendall(b"reply:" + channel.recv(1024)))
        context = RELAY.make_context(cafile=str(self.cert))
        with RELAY.connect_upstream(context, endpoint=endpoint) as upstream:
            client, peer = socket.socketpair()
            stop = threading.Event()
            forwarded = []

            def run():
                try:
                    RELAY.forward(client, upstream, stop)
                except OSError as error:
                    forwarded.append(error)
                finally:
                    client.close()

            thread = threading.Thread(target=run, daemon=True)
            thread.start()
            with peer:
                peer.settimeout(4)
                peer.sendall(b"offline-test")
                self.assertEqual(peer.recv(1024), b"reply:offline-test")
            thread.join(4)
            self.assertFalse(thread.is_alive())
            self.assertEqual(forwarded, [])
        server.join(4)
        self.assertEqual(errors, [])

    def test_untrusted_certificate_is_rejected(self):
        endpoint, thread, _ = self.local_tls_server(lambda _: None)
        with self.assertRaises(ssl.SSLCertVerificationError):
            RELAY.connect_upstream(RELAY.make_context(), endpoint=endpoint)
        thread.join(4)

    def test_wrong_hostname_is_rejected_even_with_trusted_ca(self):
        endpoint, thread, _ = self.local_tls_server(lambda _: None)
        with self.assertRaises(ssl.SSLCertVerificationError):
            RELAY.connect_upstream(RELAY.make_context(cafile=str(self.cert)), endpoint=endpoint, hostname="different.invalid")
        thread.join(4)


if __name__ == "__main__":
    unittest.main()
