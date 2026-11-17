#!/usr/bin/env python3
"""Installed-app OSINT regression through its isolated test-world API.

No duplicate app, user profile, signed-in tab, or real credentials are used.
The fixture simulates primary sources; live availability is checked separately.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


class Sources(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlsplit(parse_qs(urlsplit(self.path).query).get("url", [""])[0])
        params = parse_qs(url.query)
        self.server.calls.append(url.geturl())
        body = None
        status = 200
        host, path = url.hostname, url.path
        if any("Slow Fixture" in value for values in params.values() for value in values):
            time.sleep(.5)
        if host == "search.fixture.example":
            body = {"results": [{"title": "Jane Example at Fixture Labs", "url": f"https://source{i}.example/bio", "content": "Public index lead"} for i in range(8)]}
        elif host == "rdap.org":
            body = {"ldhName": "FIXTURE.EXAMPLE", "name": "Fixture network", "startAddress": "1.1.1.0", "endAddress": "1.1.1.255", "country": "ZZ", "events": [{"eventAction": "registration", "eventDate": "2001-01-01T00:00:00Z"}]}
        elif host == "dns.google":
            body = {"Status": 0, "AD": True, "Answer": [{"data": "10 mail.fixture.example." if params.get("type") == ["MX"] else "fixture.example."}]}
        elif host == "crt.sh":
            body = [{"name_value": "www.fixture.example\ncontact.fixture.example\nwrong.example"}]
        elif host == "web.archive.org":
            body = [["timestamp", "original", "statuscode", "mimetype"], ["20240102123456", "https://fixture.example/about", "200", "text/html"]]
        elif host == "stat.ripe.net":
            body = {"data": {"asns": ["13335"], "prefix": "1.1.1.0/24", "holder": "Fixture Network Operator", "announced": True, "block": {"name": "RIPE NCC"}}}
        elif host == "www.wikidata.org":
            if "Special:EntityData" in path:
                body = {"entities": {"Q123": {"labels": {"en": {"value": "Fixture Labs"}}, "claims": {"P856": [{"mainsnak": {"datavalue": {"value": "https://fixture.example"}}}], "P571": [{"mainsnak": {"datavalue": {"value": {"time": "+2001-01-01T00:00:00Z"}}}}]}}}}
            else:
                body = {"search": [{"id": "Q123", "label": "Fixture Labs", "description": "Fictional research organization"}]}
        elif host == "api.gleif.org":
            body = {"data": [{"id": "FIXTURE-LEI", "attributes": {"lei": "FIXTURE-LEI", "entity": {"legalName": {"name": "Fixture Labs"}, "status": "ACTIVE", "jurisdiction": "ZZ", "legalAddress": {"city": "Fictional city", "country": "ZZ"}}, "registration": {"initialRegistrationDate": "2001-01-01"}}}]}
        elif host == "api.github.com":
            body = {"login": "fixture-research", "name": "Jane Example", "bio": "Fictional public research profile", "blog": "https://fixture.example", "email": "research@fixture.example", "company": "Fixture Labs", "created_at": "2010-01-01T00:00:00Z"}
        elif host == "gitlab.com":
            entry = {"id": 123, "username": "fixture-research", "name": "Jane Example", "bio": "Fictional developer", "website_url": "https://fixture.example"}
            body = [entry] if path.endswith("/users") else entry
        elif host == "hacker-news.firebaseio.com":
            body = {"id": "fixture-research", "created": 1262304000, "karma": 20, "about": "Fictional public research profile"}
        elif host == "raw.githubusercontent.com":
            body = {"Fixture": {"url": "https://profiles.example/{}", "errorType": "status_code"}, "Authentication": {"url": "https://auth.example/{}", "errorType": "status_code"}}
        elif host == "auth.example":
            status = 401
            body = "Authentication required"
        elif host == "profiles.example":
            body = "<title>Profiles</title><p>Generic profile landing page with no account information.</p>"
        else:
            body = '''<title>Fixture Labs · Jane Example</title>
            <meta name="description" content="Public fictional research organization and contact details.">
            <p>Jane Example works at Fixture Labs. Public research enquiries: +1 (416) 555-0100 and research@fixture.example.</p>
            <a href="/contact">Contact</a><a href="/about">About</a><a href="mailto:research@fixture.example">Email</a>
            <script type="application/ld+json">{"@type":"Organization","name":"Fixture Labs","url":"https://fixture.example","foundingDate":"2001-01-01","sameAs":["https://github.com/fixture-research"],"telephone":"+14165550100"}</script>'''
        payload = body.encode() if isinstance(body, str) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html" if isinstance(body, str) else "application/json")
        self.send_header("Content-Length", str(len(payload)))
        if status == 401:
            self.send_header("WWW-Authenticate", 'Basic realm="OSINT test source"')
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_args):
        pass


def main():
    args = argparse.ArgumentParser()
    args.add_argument("--app", default="/Applications/Search.app")
    args.add_argument("--executable", help="Optional freshly compiled executable for preflight before packaging")
    args.add_argument("--output", required=True)
    options = args.parse_args()
    world = "osint-advanced-" + uuid.uuid4().hex[:8]
    support = Path.home() / f"Library/Application Support/Search ({world})"
    suite = f"com.officecommun.search.test.{world}"
    sock = support / "bench.sock"
    server = ThreadingHTTPServer(("127.0.0.1", 0), Sources)
    server.calls = []
    threading.Thread(target=server.serve_forever, daemon=True).start()
    source = f"http://127.0.0.1:{server.server_port}"
    checks = []
    reports = {}
    proc = None
    def command(**request):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(20)
            client.connect(str(sock))
            client.sendall(json.dumps(request).encode()+b"\n")
            data = b""
            while b"\n" not in data:
                chunk = client.recv(65536)
                if not chunk:
                    break
                data += chunk
        result = json.loads(data.split(b"\n", 1)[0])
        assert "error" not in result, result
        return result
    def launch():
        nonlocal proc
        env = dict(os.environ, SEARCH_PROBE=world, SEARCH_OSINT_FIXTURE=source)
        log = open(Path(options.output).with_suffix(".process.log"), "ab")
        executable = options.executable or str(Path(options.app)/"Contents/MacOS/Search")
        proc = subprocess.Popen([executable], env=env, stdout=log, stderr=log)
        for _ in range(200):
            if sock.exists():
                try:
                    command(do="osint")
                    return
                except (OSError, ValueError):
                    pass
            assert proc.poll() is None, "Probe exited before starting"
            time.sleep(.05)
        raise AssertionError("Probe API did not start")
    def check(name, condition):
        checks.append({"check": name, "passed": bool(condition)})
        print(("PASS " if condition else "FAIL ")+name, flush=True)
        assert condition, name
    try:
        Path(options.output).parent.mkdir(parents=True, exist_ok=True)
        for key in ["bench", "welcomed"]:
            subprocess.run(["defaults", "write", suite, key, "-bool", "true"], check=True)
        launch()
        picture = support / "fixture.png"
        picture.write_bytes(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))
        image = command(do="osint", action="image", path=str(picture))
        deadline = time.monotonic()+20
        while image["running"] and time.monotonic()<deadline:
            time.sleep(.1)
            image = command(do="osint")
        check("image: original metadata extracted", not image["running"] and not image["problem"] and any(x.get("facts", {}).get("Dimensions") == "1 × 1" for x in image["report"]["findings"]))
        reports["image"] = image
        command(do="osint", action="open", kind="person", query="Slow Fixture", searx="https://search.fixture.example")
        deadline = time.monotonic()+2
        while not any("Slow" in url for url in server.calls) and time.monotonic()<deadline:
            time.sleep(.02)
        check("cancellation: requests actually started", any("Slow" in url for url in server.calls))
        command(do="osint", action="clear")
        time.sleep(.7)
        cleared = command(do="osint")
        check("cancellation: late callbacks cannot restore cleared evidence", not cleared["running"] and "report" not in cleared)
        cases = [("person", "Jane Example"), ("company", "Fixture Labs"), ("phone", "+14165550100"), ("email", "research@fixture.example"), ("username", "fixture-research"), ("social", "https://github.com/fixture-research"), ("domain", "fixture.example"), ("website", "https://fixture.example"), ("ip", "1.1.1.1"), ("asn", "AS13335")]
        for kind, query in cases:
            state = command(do="osint", action="open", kind=kind, query=query, searx="https://search.fixture.example")
            deadline = time.monotonic()+25
            while state["running"] and time.monotonic()<deadline:
                time.sleep(.1)
                state = command(do="osint")
            check(f"{kind}: completed", not state["running"] and not state["problem"])
            check(f"{kind}: actual source facts", state["retrieved"] > 0)
            reports[kind] = state
        check("phone: actual matching passage", any("Matched passage" in x.get("facts", {}) for x in reports["phone"]["report"]["findings"]))
        check("email: source-backed connections", reports["email"]["connections"] >= 2)
        check("domain: event timeline", reports["domain"]["timeline"] >= 2)
        check("username: soft 404 rejected", not any(x["title"] == "Fixture" and x["state"] == "possible" for x in reports["username"]["report"]["findings"]))
        check("username: origin authentication stays unavailable", any(x["title"] == "Authentication" and x["state"] == "unavailable" for x in reports["username"]["report"]["findings"]))
        saved = command(do="osint", action="save")
        check("evidence saved", saved["saved"] == 1)
        command(do="quit")
        proc.wait(timeout=10)
        for _ in range(40):
            if not sock.exists():
                break
            time.sleep(.05)
        launch()
        restored = command(do="osint", action="restore")
        check("restart restores facts", restored["retrieved"] > 0 and restored["report"]["context"]["text"] == "AS13335")
        check("restart restores connections", restored["connections"] == reports["asn"]["connections"])
        Path(options.output).write_text(json.dumps({"checks": checks, "reports": reports, "sourceRequests": server.calls, "fixture": True}, indent=2))
    finally:
        Path(options.output).write_text(json.dumps({"checks": checks, "reports": reports, "sourceRequests": server.calls, "fixture": True}, indent=2))
        if proc is not None and proc.poll() is None:
            try:
                command(do="quit")
                proc.wait(timeout=5)
            except Exception:
                proc.terminate()
                proc.wait(timeout=5)
        server.shutdown()
        shutil.rmtree(support, ignore_errors=True)
        subprocess.run(["defaults", "delete", suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
