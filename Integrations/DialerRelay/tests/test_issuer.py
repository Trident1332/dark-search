import base64
import hashlib
import hmac
import importlib.util
import json
from pathlib import Path
import socket
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from issuer import Config, ENDPOINT, Issuer, MAX_BODY, RateLimit, Server, seat_password


def basic(user="1001", password="synthetic-seat-password"):
    return "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()


class IssuerTests(unittest.TestCase):
    def setUp(self):
        self.config = Config("1001", "synthetic-seat-password", b"synthetic-turn-secret-for-offline-testing-only")
        self.issuer = Issuer(self.config, clock=lambda: 2000000000, nonce=lambda: "synthetic-nonce")

    def test_hmac_contract_has_bounded_expiry_and_only_owned_tls_turn(self):
        status, result = self.issuer.handle("POST", basic(), b"{}", "192.0.2.1")
        self.assertEqual(status, 200)
        self.assertEqual(result["expiresAt"], 2000003600)
        self.assertEqual(result["ttl"], 3600)
        server = result["iceServers"][0]
        self.assertEqual(server["urls"], ["turns:sip.investigate.agency:5349?transport=tcp"])
        expected = base64.b64encode(hmac.new(self.config.secret, server["username"].encode(), hashlib.sha1).digest()).decode()
        self.assertEqual(server["credential"], expected)
        serialized = json.dumps(result)
        self.assertNotIn(self.config.password, serialized)
        self.assertNotIn(self.config.secret.decode(), serialized)
        self.assertNotIn("stun:", serialized)

    def test_bad_auth_never_receives_credential_or_echoed_input(self):
        for auth in [None, "", "Bearer synthetic", "Basic !!!", "Basic /w==", basic("other"), basic(password="wrong"), "Basic " + "a" * 8193]:
            with self.subTest(auth_kind=type(auth).__name__):
                status, result = self.issuer.handle("POST", auth, b"{}", "192.0.2.1")
                self.assertEqual((status, result), (401, {"error": "authentication_required"}))

    def test_only_empty_request_is_accepted(self):
        for body in [b'{"ttl":14400}', b'{"host":"other.invalid"}', b"null", b"[]", b"{", b"\xff"]:
            self.assertEqual(self.issuer.handle("POST", basic(), body, "192.0.2.1")[0], 400)
        self.assertEqual(self.issuer.handle("POST", basic(), b"", "192.0.2.1")[0], 200)

    def test_method_and_size_are_bounded(self):
        self.assertEqual(self.issuer.handle("GET", basic(), b"", "192.0.2.1")[0], 405)
        self.assertEqual(self.issuer.handle("POST", basic(), b"x" * (MAX_BODY + 1), "192.0.2.1")[0], 413)

    def test_authentication_is_rate_limited_including_failed_attempts(self):
        for _ in range(12):
            self.assertEqual(self.issuer.handle("POST", basic(password="wrong"), b"", "192.0.2.1")[0], 401)
        self.assertEqual(self.issuer.handle("POST", basic(), b"", "192.0.2.1")[0], 429)

    def test_rate_limiter_window_expires_and_memory_is_bounded(self):
        now = [100.0]
        limiter = RateLimit(limit=1, max_clients=2, clock=lambda: now[0])
        self.assertTrue(limiter.allow("a"))
        self.assertFalse(limiter.allow("a"))
        self.assertTrue(limiter.allow("b"))
        self.assertFalse(limiter.allow("c"))
        now[0] += 61
        self.assertTrue(limiter.allow("c"))
        self.assertEqual(len(limiter.clients), 1)

    def test_global_rate_limit_spans_source_addresses(self):
        limiter = RateLimit()
        for i in range(120):
            self.assertTrue(limiter.allow(str(i)))
        self.assertFalse(limiter.allow("new"))

    def test_nonces_make_independent_credentials(self):
        issuer = Issuer(self.config)
        first = issuer.handle("POST", basic(), b"", "192.0.2.1")[1]
        second = issuer.handle("POST", basic(), b"", "192.0.2.1")[1]
        self.assertNotEqual(first["iceServers"][0]["username"], second["iceServers"][0]["username"])

    def test_untrusted_host_and_lifetime_configuration_is_rejected(self):
        for change in [{"host": "x.invalid\nno-auth"}, {"host": "https://x.invalid"}, {"ttl": 1}, {"ttl": True}, {"ttl": 14401}, {"port": 0}, {"user": "1001\n"}, {"secret": b"short"}]:
            args = dict(user=self.config.user, password=self.config.password, secret=self.config.secret)
            args.update(change)
            with self.assertRaises(ValueError):
                Config(**args)

    def test_password_may_contain_colon_without_changing_account(self):
        config = Config("1001", "synthetic:password", self.config.secret)
        self.assertTrue(Issuer(config).authenticated(basic(password="synthetic:password")))

    def test_seat_loader_requires_one_literal_password_for_exact_seat(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "seat.xml"
            path.write_text('<include><user id="1001"><params><param name="password" value="synthetic"/></params></user></include>')
            self.assertEqual(seat_password(path, "1001"), "synthetic")
            for source in ['<include/>', '<include><user id="1002"><param name="password" value="synthetic"/></user></include>', '<user id="1001"><param name="password" value="$${default_password}"/></user>', '<user id="1001"><param name="password" value="a"/><param name="password" value="b"/></user>']:
                path.write_text(source)
                with self.assertRaises(ValueError):
                    seat_password(path, "1001")


class UnixHTTPTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = str(Path(self.tmp.name) / "issuer.sock")
        self.server = Server(self.path, Issuer(Config("1001", "synthetic-seat-password", b"synthetic-turn-secret-for-offline-testing-only")))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.tmp.cleanup()

    def request(self, headers="", body=b"", method="POST", path=ENDPOINT):
        with socket.socket(socket.AF_UNIX) as sock:
            sock.settimeout(2)
            sock.connect(self.path)
            sock.sendall(f"{method} {path} HTTP/1.1\r\nHost: synthetic.invalid\r\nX-Real-IP: 192.0.2.1\r\n{headers}\r\n".encode() + body)
            result = b""
            while data := sock.recv(4096):
                result += data
        header, data = result.split(b"\r\n\r\n", 1)
        return int(header.split()[1]), header, json.loads(data)

    def test_real_unix_http_auth_and_no_store(self):
        status, headers, body = self.request(f"Authorization: {basic()}\r\nContent-Length: 2\r\n", b"{}")
        self.assertEqual(status, 200)
        self.assertIn(b"Cache-Control: no-store", headers)
        self.assertIn(b"Connection: close", headers)
        self.assertNotIn(b"Access-Control-Allow-Origin", headers)
        self.assertIn("iceServers", body)
        self.assertEqual(Path(self.path).stat().st_mode & 0o777, 0o660)

    def test_unauthenticated_http_response_is_generic(self):
        status, headers, body = self.request()
        self.assertEqual(status, 401)
        self.assertIn(b"WWW-Authenticate: Basic", headers)
        self.assertEqual(body, {"error": "authentication_required"})

    def test_oversized_declared_body_is_rejected_without_waiting(self):
        self.assertEqual(self.request("Content-Length: 32769\r\n")[0], 413)

    def test_duplicate_auth_and_request_smuggling_framing_are_rejected(self):
        for headers in [f"Authorization: {basic()}\r\nAuthorization: {basic()}\r\n", "Content-Length: 0\r\nContent-Length: 0\r\n", "Transfer-Encoding: chunked\r\n", "Content-Length: -1\r\n"]:
            self.assertEqual(self.request(headers)[0], 400)

    def test_unknown_path_and_queries_never_issue_credentials(self):
        for path in ["/", ENDPOINT + "?host=other", ENDPOINT + "/"]:
            self.assertEqual(self.request(f"Authorization: {basic()}\r\n", path=path)[0], 404)


if __name__ == "__main__":
    unittest.main()
