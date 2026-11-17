#!/usr/bin/env python3
"""Swipe navigation keeps scroll position through momentum and same-page history.

Build first, then run `python3 Tests/swipe.py`. These local fixtures reproduce
upstream #811/#816 through the existing wheel/glide bench verb in a hidden,
isolated probe. zoom_swipe.py covers the accompanying zoom-edge regression.
"""
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("swipe-scroll")


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"""<!doctype html><meta charset=utf-8><title>Swipe fixture</title>
<style>html{scroll-behavior:auto}body{margin:0}main{height:18000px}</style>
<main>Local swipe fixture</main>
<script>window.shownFromCache=false;
addEventListener('pageshow', e => window.shownFromCache=e.persisted);</script>"""
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "max-age=3600")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


sv.srv.RequestHandlerClass = H
t = sv.T()


def ev(tab, js):
    return sv.cmd({"do": "eval", "id": tab, "js": js}).get("value")


def settle(tab, condition, within=6):
    deadline = time.monotonic() + within
    while time.monotonic() < deadline:
        try:
            if ev(tab, condition):
                return True
        except RuntimeError:
            pass
        time.sleep(0.05)
    return False


def position(tab):
    return ev(tab, "({x:scrollX, y:scrollY, path:location.pathname, hash:location.hash})")


def scrolled_page(name, y):
    tab = sv.cmd({"do": "open", "url": f"{sv.BASE}/{name}"})["id"]
    sv.cmd({"do": "wait", "id": tab, "seconds": 5})
    ev(tab, f"scrollTo(0, {y}); true")
    if not settle(tab, f"Math.abs(scrollY - {y}) < 2"):
        raise RuntimeError("the swipe fixture did not reach its starting position")
    return tab


def wheel(tab, dx, dy=0, glide=20):
    sv.cmd({"do": "wheel", "id": tab, "dx": dx, "dy": dy, "steps": 10, "ms": 180, "glide": glide})
    time.sleep(0.6)


def main():
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ui", "swipepages": True})

        tab = scrolled_page("first", 4800)
        sv.cmd({"do": "go", "id": tab, "url": f"{sv.BASE}/second"})
        sv.cmd({"do": "wait", "id": tab, "seconds": 5})
        ev(tab, "scrollTo(0, 3200); true")
        if not settle(tab, "Math.abs(scrollY - 3200) < 2"):
            raise RuntimeError("the forward fixture did not reach its starting position")
        wheel(tab, 300, 70)
        settle(tab, "location.pathname === '/first'")
        back = position(tab)
        t.ok("back with a glide restores the first page without sideways drift",
             back["path"] == "/first" and abs(back["x"]) <= 1 and abs(back["y"] - 4800) <= 2, back)

        wheel(tab, -300, 70)
        settle(tab, "location.pathname === '/second'")
        forward = position(tab)
        t.ok("the next gesture can go forward and preserves that page's place",
             forward["path"] == "/second" and abs(forward["x"]) <= 1 and abs(forward["y"] - 3200) <= 2, forward)

        wheel(tab, 0, -250)
        after = position(tab)
        t.ok("a fresh vertical gesture still scrolls normally after navigation",
             after["path"] == "/second" and after["y"] > forward["y"] + 100, (forward, after))

        same = scrolled_page("same-document", 4800)
        ev(same, "history.pushState({section:true}, '', '#section'); scrollTo(0, 9000); true")
        if not settle(same, "Math.abs(scrollY - 9000) < 2"):
            raise RuntimeError("the same-document fixture did not reach its next position")
        wheel(same, 300)
        settle(same, "location.hash === ''")
        restored = position(same)
        t.ok("same-document back restores its old place without a blank strip",
             restored["hash"] == "" and abs(restored["x"]) <= 1 and abs(restored["y"] - 4800) <= 2, restored)

        # At the first history entry, a sideways pull has nowhere to go.
        # A following real scroll must not be mistaken for navigation glide.
        plain = scrolled_page("no-back-entry", 1800)
        wheel(plain, 300)
        before = position(plain)
        wheel(plain, 0, -250)
        after = position(plain)
        t.ok("a refused back gesture does not suppress later scrolling",
             after["path"] == "/no-back-entry" and after["y"] > before["y"] + 100, (before, after))
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
