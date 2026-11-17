#!/usr/bin/env python3
"""Back-forward cache preserves manual scroll without overruling the page.

Build first, then run `python3 Tests/kept_scroll.py`. These local fixtures
exercise the upstream #814 reproductions in this checkout's hidden probe.
They check actual cache restoration, not just synthetic lifecycle events.
The probe and its own settings/stores are removed by split_view.finish().
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("kept-scroll")


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        query = parse_qs(urlparse(self.path).query)
        mode = "auto" if query.get("mode") == ["auto"] else "manual"
        own = query.get("own", [""])[0]
        body = """<!doctype html><meta charset=utf-8><title>Scroll fixture</title>
<script>
history.scrollRestoration = MODE;
window.shownFromCache = false;
window.fixtureToken = Math.random();
addEventListener('pageshow', function (event) {
  window.shownFromCache = event.persisted;
  if (OWN === 'reset' && event.persisted) scrollTo(0, 0);
  if (OWN === 'fresh' && !event.persisted) scrollTo(0, 300);
});
</script>
<style>html{scroll-behavior:auto}body{margin:0}main{height:18000px}</style>
<main>Local back-forward cache fixture</main>"""
        data = body.replace("MODE", json.dumps(mode)).replace("OWN", json.dumps(own)).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "max-age=3600")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


sv.srv.RequestHandlerClass = H
t = sv.T()


def ev(tab, js):
    return sv.cmd({"do": "eval", "id": tab, "js": js}).get("value")


def settle(tab, predicate, within=6):
    deadline = time.monotonic() + within
    while time.monotonic() < deadline:
        try:
            if ev(tab, predicate):
                return True
        except RuntimeError:
            pass  # A navigation may replace the JavaScript context in flight.
        time.sleep(0.05)
    return False


def scenario(mode, own="", swipe=False):
    url = f"{sv.BASE}/kept?mode={mode}&own={own}"
    tab = sv.cmd({"do": "open", "url": url})["id"]
    sv.cmd({"do": "wait", "id": tab, "seconds": 5})
    ev(tab, "scrollTo(0, 4800); true")
    if not settle(tab, "Math.abs(scrollY - 4800) < 2"):
        raise RuntimeError("the scroll fixture did not reach its starting position")
    before = ev(tab, "({token:fixtureToken, y:scrollY})")
    sv.cmd({"do": "go", "id": tab, "url": f"{sv.BASE}/away?mode=auto"})
    sv.cmd({"do": "wait", "id": tab, "seconds": 5})
    if swipe:
        sv.cmd({"do": "wheel", "id": tab, "dx": 300, "steps": 10, "ms": 180, "glide": 20})
    else:
        ev(tab, "history.back(); true")
    cached = settle(tab, "window.shownFromCache === true")
    time.sleep(0.3)
    after = ev(tab, "({token:fixtureToken, x:scrollX, y:scrollY, cached:shownFromCache})")
    label = f"{mode}, {own or 'no page override'}, {'swipe' if swipe else 'back'}"
    t.ok(f"{label}: the original document returned from cache",
         cached and after.get("token") == before.get("token"), after)
    expected = 0 if own == "reset" else before["y"]
    t.ok(f"{label}: the expected scroll position survives",
         abs(after["x"]) <= 1 and abs(after["y"] - expected) <= 2, (before, after))
    return tab


def main():
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ui", "swipepages": True})
        scenario("manual")
        scenario("manual", swipe=True)
        scenario("manual", own="reset")
        scenario("auto")

        tab = sv.cmd({"do": "open", "url": f"{sv.BASE}/fresh?own=fresh"})["id"]
        sv.cmd({"do": "wait", "id": tab, "seconds": 5})
        ev(tab, "scrollTo(0, 4800); true")
        if not settle(tab, "Math.abs(scrollY - 4800) < 2"):
            raise RuntimeError("the reload fixture did not reach its starting position")
        token = ev(tab, "fixtureToken")
        ev(tab, "location.reload(); true")
        reloaded = settle(tab, f"window.fixtureToken !== {json.dumps(token)} && window.shownFromCache === false")
        settle(tab, "Math.abs(scrollY - 300) < 2")
        after = ev(tab, "({x:scrollX, y:scrollY, cached:shownFromCache})")
        t.ok("reload: a fresh document's pageshow keeps control of its scroll",
             reloaded and not after["cached"] and abs(after["y"] - 300) <= 2, after)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
