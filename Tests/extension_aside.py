#!/usr/bin/env python3
"""Extension CSS, messages and ports in windowless pages, in a hidden probe.

Build first, then python3 Tests/extension_aside.py. All pages are loopback
fixtures, extensions live only in this test world, and no window is shown.
ExtensionAsideTests covers private consent/store independence and Tor
rejection; this probe exercises the real content-script/background bridge.
Each lifecycle ends its content port before the next starts: upstream #818
documents pre-existing same-site cross-document port interference, which
this regression does not claim to repair.
"""
import json
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("extension-aside")

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "Windowless page fixture", "version": "1.0",
        "permissions": ["tabs"], "host_permissions": ["http://127.0.0.1/*"],
        "background": {"service_worker": "background.js"},
        "content_scripts": [{"matches": ["http://127.0.0.1/*"], "js": ["content.js"],
                             "css": ["style.css"], "run_at": "document_idle"}],
    }),
    "page.html": "<!doctype html><title>Windowless fixture inspector</title>",
    "style.css": "html { --aside-extension-fixture: applied; }",
    "content.js": """
if (location.pathname.startsWith('/aside-')) {
  const page = location.href;
  const css = getComputedStyle(document.documentElement).getPropertyValue('--aside-extension-fixture').trim();
  chrome.runtime.sendMessage({kind: 'hello', page, css}).then(reply =>
    chrome.runtime.sendMessage({kind: 'answered', page, mark: reply.mark})).catch(() => {});
  const port = chrome.runtime.connect({name: 'aside-fixture'});
  port.onMessage.addListener(reply => {
    if (reply.page === page) chrome.runtime.sendMessage({kind: reply.kind, page, mark: reply.mark});
  });
  port.postMessage({page});
}
""",
    "background.js": """
const messages = [], events = [], known = {};
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message.read) { reply({messages, events}); return; }
  messages.push({...message, windowId: sender.tab && sender.tab.windowId});
  reply({mark: 'worker replied'});
});
chrome.runtime.onConnect.addListener(port => {
  if (port.name !== 'aside-fixture') return;
  let page = '';
  // Keep the actual owner separate from a received message's page. WebKit
  // can cross-deliver same-site port messages (upstream #818), so a mutable
  // echo must never identify which document's port disconnected.
  const origin = port.sender && port.sender.url;
  port.onDisconnect.addListener(() => messages.push({kind: 'disconnected', page: origin || page, origin}));
  port.onMessage.addListener(message => {
    page = message.page;
    port.postMessage({kind: 'portAnswer', page, mark: 'worker replied'});
    setTimeout(() => {
      try { port.postMessage({kind: 'latePortAnswer', page, mark: 'worker replied'}); } catch (_) {}
    }, 3000);
  });
});
chrome.tabs.onCreated.addListener(tab => {
  known[tab.id] = tab.url;
  events.push({kind: 'created', page: tab.url, windowId: tab.windowId});
});
chrome.tabs.onRemoved.addListener((id, info) => {
  events.push({kind: 'removed', page: known[id] || '', windowId: info.windowId});
  delete known[id];
});
""",
}


def poll(read, ready, seconds=15):
    end = time.monotonic() + seconds
    while True:
        result = read()
        if ready(result):
            return result
        if time.monotonic() >= end:
            raise RuntimeError(f"timed out waiting: {result}")
        time.sleep(0.1)


def run(page, body):
    sv.ev(page, "window.__asideResult=null;(async()=>{" + body + "})().then("
          "value=>window.__asideResult={ok:true,value},"
          "error=>window.__asideResult={ok:false,error:String(error)});0")
    result = poll(lambda: sv.ev(page, "window.__asideResult"), lambda x: x is not None)
    if not result["ok"]:
        raise RuntimeError(result["error"])
    return result["value"]


def snapshot(page):
    return run(page, "return await chrome.runtime.sendMessage({read:true});")


def messages(page, url):
    return [m for m in snapshot(page)["messages"] if m.get("page") == url]


def verified(t, inspector, url, label):
    got = poll(lambda: messages(inspector, url),
               lambda rows: all(any(m.get("kind") == kind for m in rows)
                                for kind in ("hello", "answered", "portAnswer")))
    hello = next(m for m in got if m["kind"] == "hello")
    t.ok(label + ": extension CSS is applied", hello.get("css") == "applied", got)
    t.ok(label + ": content script gets its worker's answer",
         any(m.get("kind") == "answered" and m.get("mark") == "worker replied" for m in got), got)
    t.ok(label + ": content script receives a port message",
         any(m.get("kind") == "portAnswer" and m.get("mark") == "worker replied" for m in got), got)
    t.ok(label + ": sender is windowless", hello.get("windowId") == -1, hello)


def queried(inspector, url):
    return run(inspector, "return (await chrome.tabs.query({})).filter(t=>t.url===" + json.dumps(url) + ");")


def main():
    t = sv.T()
    try:
        sv.setup(sidebar=True)
        sv.launch()
        home = sv.page("home")
        with tempfile.TemporaryDirectory(prefix="search-aside-extension-") as folder:
            for name, content in FILES.items():
                Path(folder, name).write_text(content)
            sv.cmd({"do": "ext-folder", "path": folder, "yes": True})
            found = poll(lambda: sv.cmd({"do": "extensions"})["extensions"],
                         lambda rows: any(x["name"] == "Windowless page fixture" and x["loaded"] for x in rows))
            ext = next(x["id"] for x in found if x["name"] == "Windowless page fixture")
            inspector = sv.cmd({"do": "ext-page", "id": ext, "path": "page.html"})["id"]
            sv.cmd({"do": "wait", "id": inspector, "seconds": 10})

            sv.sp("select", id=home)
            peek = sv.BASE + "/aside-kept-peek"
            sv.cmd({"do": "peek", "url": peek})
            verified(t, inspector, peek, "peek")
            t.ok("peek stays out of tabs.query", queried(inspector, peek) == [])
            sv.cmd({"do": "ui", "peeklink": "keep"})
            poll(lambda: queried(inspector, peek), lambda rows: len(rows) == 1)
            t.ok("kept peek appears once in tabs.query", len(queried(inspector, peek)) == 1)
            poll(lambda: messages(inspector, peek), lambda rows: any(m["kind"] == "latePortAnswer" for m in rows))
            t.ok("keeping a peek preserves its existing port", True)
            events = snapshot(inspector)["events"]
            t.ok("keeping the peek emits one normal tab creation",
                 len([e for e in events if e["kind"] == "created" and e.get("page") == peek]) == 1, events)

            kept = next(row["id"] for row in sv.sp("state")["tabs"] if row["url"] == peek)
            sv.sp("select", id=kept)
            sv.cmd({"do": "press", "code": 13, "chars": "w", "mods": ["cmd"]})
            poll(lambda: messages(inspector, peek),
                 lambda rows: any(m["kind"] == "disconnected" and m.get("origin") == peek for m in rows))
            t.ok("closing the kept tab disconnects its original port", True)

            sv.sp("select", id=home)
            closed_peek = sv.BASE + "/aside-closed-peek"
            sv.cmd({"do": "peek", "url": closed_peek})
            verified(t, inspector, closed_peek, "second peek")
            sv.cmd({"do": "peek", "url": "close"})
            poll(lambda: messages(inspector, closed_peek),
                 lambda rows: any(m["kind"] == "disconnected" and m.get("origin") == closed_peek for m in rows))
            t.ok("closing a peek disconnects its port", True)
            t.ok("closed peek never appears in tabs.query", queried(inspector, closed_peek) == [])

            little = sv.BASE + "/aside-little"
            sv.cmd({"do": "little", "what": little})
            verified(t, inspector, little, "small window")
            t.ok("small window stays out of tabs.query", queried(inspector, little) == [])
            sv.cmd({"do": "little", "what": "close"})
            poll(lambda: messages(inspector, little),
                 lambda rows: any(m["kind"] == "disconnected" and m.get("origin") == little for m in rows))
            t.ok("closing a small window disconnects its port", True)
            events = snapshot(inspector)["events"]
            t.ok("windowless pages emit no row creation/removal events",
                 not any(e.get("windowId") == -1 or e.get("page") in (closed_peek, little) for e in events), events)
    except Exception as error:
        t.ok("extension aside probe completes", False, str(error))
    finally:
        sv.finish()
    t.done()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
