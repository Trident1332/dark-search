from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from render_config import render


class ConfigTests(unittest.TestCase):
    def test_generated_config_is_authenticated_tls_only_and_peer_scoped(self):
        config = render("a" * 64)
        flags = set(config.splitlines())
        for flag in ["no-udp", "no-tcp", "no-dtls", "no-tcp-relay", "no-stun", "no-cli", "no-tlsv1", "no-tlsv1_1", "use-auth-secret", "user-quota=4", "total-quota=20", "allowed-peer-ip=185.56.45.246"]:
            self.assertIn(flag, flags)
        self.assertIn("denied-peer-ip=0.0.0.0-255.255.255.255", flags)
        self.assertIn("denied-peer-ip=::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", flags)
        self.assertNotIn("no-auth", flags)
        self.assertNotIn("no-udp-relay", flags)
        self.assertNotIn("no-tls", flags)

    def test_config_injection_and_private_peer_are_rejected(self):
        for secret, peer, host in [("a" * 64 + "\nno-auth", "185.56.45.246", "sip.investigate.agency"), ("short", "185.56.45.246", "sip.investigate.agency"), ("a" * 64, "127.0.0.1", "sip.investigate.agency"), ("a" * 64, "185.56.45.246", "sip.invalid\nno-auth")]:
            with self.assertRaises(ValueError):
                render(secret, peer, host)

    def test_issuer_unit_cannot_open_network_sockets_and_uses_scoped_credentials(self):
        service = (ROOT / "search-dialer-issuer.service").read_text()
        self.assertIn("RestrictAddressFamilies=AF_UNIX", service)
        self.assertIn("LoadCredential=seat.xml:/root/telicall/fs/conf/directory/default/1001.xml", service)
        self.assertIn("LoadCredential=turn-secret:", service)
        self.assertIn("ProtectSystem=strict", service)
        self.assertNotIn("User=root", service)

    def test_nginx_auth_response_is_not_logged_or_exposed_as_general_proxy(self):
        config = (ROOT / "nginx-search-dialer.conf").read_text()
        self.assertIn("location = /search-dialer/turn", config)
        self.assertIn("access_log off;", config)
        self.assertIn("location / { return 404; }", config)
        self.assertIn("client_max_body_size 32k;", config)
        self.assertIn("limit_req_status 429;", config)
        self.assertNotIn("Access-Control-Allow-Origin", config)

    def test_route_health_is_exact_get_only_non_cached_and_uses_connection_address(self):
        config = (ROOT / "nginx-search-dialer.conf").read_text()
        self.assertIn("location = /search-dialer/route-check", config)
        self.assertIn("if ($request_method != GET) { return 405; }", config)
        self.assertIn('return 200 \'{"ip":"$remote_addr"}\';', config)
        self.assertIn('add_header Cache-Control "no-store" always;', config)
        self.assertNotIn("$http_x_forwarded_for", config)


if __name__ == "__main__":
    unittest.main()
