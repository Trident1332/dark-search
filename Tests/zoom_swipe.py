#!/usr/bin/env python3
"""Pinched in, two fingers sideways move about the page; only at its edge do they go back.

Build first (`./build.sh`), then `python3 Tests/zoom_swipe.py`. Same harness
as the split suite: a probe started hidden, in a world of its own, driven
through the bench, nothing made or shown, everything removed afterwards.

A page whose root says `overflow-x: hidden` (many do) can't scroll sideways
itself, so Swipe.watch told the app every sideways swipe on it was free to
mean back or forward. Pinched in (WebKit's magnification), the same fingers
are moving the zoomed view across the page, and a small pan to the left in
the middle of it went back a page (Drice, 17 Oct 2026). Checked here, with
the bench's `magnify` (the pinch, as WebKit ends it) and `wheel` (a
trackpad's two-finger scroll): pinched in, a pan in the middle stays on the
page, and at the left edge a swipe still goes back, as in Safari; not
pinched in, and on a page with nothing hidden, the swipe is as before.
"""
import json
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("zoom-swipe")

PAGE = """<!doctype html><meta charset=utf-8><title>{name}</title>
<style>{style} body{{margin:0;font:14px system-ui}} main{{width:600px;margin:0 auto}} .p{{height:160px;border-bottom:1px solid #ddd}}</style>
<main><div class=p>{name}</div><div class=p></div><div class=p></div><div style="height:3000px"></div></main>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/").split("?")[0] or "start"
        style = "html{overflow-x:hidden}" if name == "hidden" else ""
        body = PAGE.format(name=name, style=style).encode()
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://localhost:{srv.server_port}"

t = sv.T()


def ev(id, js): return sv.cmd({"do": "eval", "id": id, "js": js}).get("value")
def where(id): return [x for x in sv.cmd({"do": "tabs"})["tabs"] if x["id"] == id][0]["url"].rsplit("/", 1)[-1]
def left(id): return ev(id, "visualViewport.pageLeft")
def wheel(id, dx):
    sv.cmd({"do": "wheel", "id": id, "dx": dx, "dy": 0, "steps": 10, "ms": 150}); time.sleep(1.2)


def at(name, zoom):
    """A tab on `name`, with a page to go back to, pinched in to `zoom`."""
    tab = sv.cmd({"do": "open", "url": f"{BASE}/start"})["id"]
    sv.cmd({"do": "wait", "id": tab, "seconds": 5})
    sv.cmd({"do": "go", "id": tab, "url": f"{BASE}/{name}"})
    sv.cmd({"do": "wait", "id": tab, "seconds": 5}); time.sleep(0.5)
    if zoom != 1:
        sv.cmd({"do": "magnify", "id": tab, "scale": zoom})
    return tab


def main():
    try:
        sv.setup(); sv.launch()
        sv.cmd({"do": "ui", "swipepages": True}); time.sleep(0.3)

        for name in ("hidden", "plain"):
            tab = at(name, 2.0)
            # Fingers to the left: the zoomed view goes right, to the middle.
            wheel(tab, -300)
            moved = left(tab)
            t.ok(f"{name}, pinched in: a pan to the right moves the view", (moved or 0) > 100, moved)
            # Back a little to the left, in the middle of the page.
            wheel(tab, 150)
            t.ok(f"{name}, pinched in: a pan to the left in the middle stays on the page",
                 where(tab) == name and 0 < (left(tab) or 0) < moved, (where(tab), left(tab)))
            # On to the left edge in the same way, then a swipe from there.
            wheel(tab, 600)
            t.ok(f"{name}, pinched in: panning on to the left edge stays on the page",
                 where(tab) == name and (left(tab) or 0) <= 1, (where(tab), left(tab)))
            before = where(tab)
            wheel(tab, 300)
            t.ok(f"{name}, pinched in: at the left edge, a swipe goes back",
                 before == name and where(tab) == "start", (before, where(tab)))

            # Mirror the boundary with a forward entry. Begin close enough to
            # the right edge that the next gesture's first event crosses it.
            tab = at(name, 1)
            sv.cmd({"do": "go", "id": tab, "url": f"{BASE}/finish"})
            sv.cmd({"do": "wait", "id": tab, "seconds": 5})
            ev(tab, "history.back(); true")
            until = time.monotonic() + 5
            while where(tab) != name and time.monotonic() < until:
                time.sleep(0.05)
            if where(tab) != name:
                raise RuntimeError("the forward-swipe fixture did not return to its page")
            sv.cmd({"do": "magnify", "id": tab, "scale": 2.0})
            wheel(tab, -150)
            edge = ev(tab, "document.documentElement.clientWidth - visualViewport.width")
            t.ok(f"{name}, pinched in: a pan towards the right edge stays inside the page",
                 where(tab) == name and 0 < (left(tab) or 0) < edge, (where(tab), left(tab), edge))
            wheel(tab, -600)
            t.ok(f"{name}, pinched in: panning on to the right edge stays on the page",
                 where(tab) == name and abs((left(tab) or 0) - edge) <= 1, (where(tab), left(tab), edge))
            before = where(tab)
            wheel(tab, -300)
            t.ok(f"{name}, pinched in: at the right edge, a swipe goes forward",
                 before == name and where(tab) == "finish", (before, where(tab)))

            tab = at(name, 1)
            wheel(tab, 300)
            t.ok(f"{name}, not pinched in: a swipe goes back", where(tab) == "start", where(tab))
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
