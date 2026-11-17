#!/usr/bin/env python3
"""Concurrent same-site extension ports stay bound to their own documents.

Build first, then python3 Tests/extension_port_isolation.py. Unlike the
aside lifecycle test, several content ports stay open together throughout:
ordinary tabs, a peek and a small window, then both kept into the row. A
targeted worker message must reach exactly its document, a content reply
must arrive on exactly that document's worker port, and closing one must
leave all surviving ports connected. All pages and extension files are
local fixtures in a hidden, isolated test world.

Also checks runtime.connect fanout to an open extension page alongside
the worker, same-origin iframe ports and two independent caller ports in
one document. Chrome's contract is documented at:
https://developer.chrome.com/docs/extensions/develop/concepts/messaging#port-lifetime
"""
import hashlib
import json
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("port-isolation")

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "Port isolation fixture", "version": "1.0",
        "permissions": ["tabs"], "host_permissions": ["http://127.0.0.1/*"],
        "background": {"service_worker": "background.js"},
        "content_scripts": [{"matches": ["http://127.0.0.1/*"], "js": ["content.js"],
                             "run_at": "document_idle", "all_frames": True}],
    }),
    "page.html": "<!doctype html><title>Port isolation inspector</title>",
    "content.js": """
if (location.pathname.startsWith('/port-')) {
  const page = location.href, connections = new Map();
  function connect(channel) {
    if (connections.has(channel)) return;
    const port = chrome.runtime.connect({name: channel});
    connections.set(channel, port);
    let localDisconnects = 0;
    port.onDisconnect.addListener(() => { localDisconnects++; });
    port.onMessage.addListener(message => {
      // Record every delivery, including wrong-document/connection ones.
      chrome.runtime.sendMessage({op:'delivery',page,channel,target:message.target,token:message.token});
      if (message.target !== page) return;
      if (message.kind === 'probe') {
        port.postMessage({kind:'reply',from:page,channel,token:message.token});
      } else if (message.kind === 'openSecond') {
        connect(message.newChannel);
      } else if (message.kind === 'disconnectSelf') {
        port.disconnect();
        setTimeout(() => chrome.runtime.sendMessage({op:'selfDisconnected',page,channel,localDisconnects}), 100);
      }
    });
    port.postMessage({kind:'hello',from:page,channel,token:'hello:' + channel});
    chrome.runtime.sendMessage({op:'ready',page,channel});
  }
  connect('isolation:' + page);
}
""",
    "background.js": """
const ports = [], incoming = [], delivered = [], disconnected = [], ready = [], selfDisconnected = [], ownSources = [];
let next = 0;
chrome.runtime.onConnect.addListener(port => {
  if (port.name.startsWith('own-source:')) {
    const record = {name:port.name,active:true,messages:[],disconnects:0,port};
    ownSources.push(record);
    port.onMessage.addListener(message => {
      record.messages.push(message);
      port.postMessage({kind:'ownReply',channel:port.name,token:message.token});
    });
    port.onDisconnect.addListener(() => { record.active=false;record.disconnects++; });
    return;
  }
  if (!port.name.startsWith('isolation:')) return;
  // These identify the port at creation. They must never be overwritten
  // by an incoming message's claimed source, including a misrouted one.
  const origin = port.sender && port.sender.url, frameId = port.sender && port.sender.frameId, channel = port.name, id = ++next;
  const record = {id,origin,frameId,channel,active:true,port};
  ports.push(record);
  port.onMessage.addListener(message => incoming.push({...message,id,origin,channel,claimedChannel:message.channel}));
  port.onDisconnect.addListener(() => {
    record.active = false;
    disconnected.push({id,origin,channel});
  });
});
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message.op === 'ready') { ready.push({page:message.page,channel:message.channel}); reply(true); return; }
  if (message.op === 'delivery') { delivered.push(message); reply(true); return; }
  if (message.op === 'selfDisconnected') { selfDisconnected.push(message); reply(true); return; }
  if (message.op === 'ownDisconnect') {
    const found=ownSources.find(p=>p.name===message.name);
    if(!found){reply({found:false});return;}
    found.active=false;found.port.disconnect();reply({found:true});return;
  }
  if (message.op === 'send') {
    const channel = message.channel || 'isolation:' + message.target;
    const found = ports.filter(p => p.active && p.origin === message.target && p.channel === channel);
    if (found.length !== 1) { reply({sent:false,count:found.length}); return; }
    try {
      found[0].port.postMessage({kind:message.kind || 'probe',target:message.target,token:message.token,newChannel:message.newChannel});
      reply({sent:true,id:found[0].id});
    } catch (error) { reply({sent:false,error:String(error)}); }
    return;
  }
  if (message.op === 'snapshot') {
    reply({ports:ports.map(({id,origin,frameId,channel,active})=>({id,origin,frameId,channel,active})),
           incoming,delivered,disconnected,ready,selfDisconnected,
           ownSources:ownSources.map(({name,active,messages,disconnects})=>({name,active,messages,disconnects}))});
  }
});
""",
}

OWN_RECEIVER = """
window.portReceiver = {ports:[],incoming:[],disconnected:[],next:0,seenConnections:[],ownSources:[]};
chrome.runtime.onConnect.addListener(port => {
  portReceiver.seenConnections.push(port.name);
  if (!port.name.startsWith('isolation:')) return;
  const origin = port.sender && port.sender.url, channel = port.name;
  const record = {id:++portReceiver.next,origin,channel,active:true,port};
  portReceiver.ports.push(record);
  port.onMessage.addListener(message => portReceiver.incoming.push({...message,origin,channel,id:record.id,claimedChannel:message.channel}));
  port.onDisconnect.addListener(() => {
    record.active = false;
    portReceiver.disconnected.push({origin,channel,id:record.id});
  });
});
portReceiver.send = (target, channel, token) => {
  const found = portReceiver.ports.filter(p => p.active && p.origin === target && p.channel === channel);
  if (found.length !== 1) return {sent:false,count:found.length};
  try {
    found[0].port.postMessage({kind:'probe',target,token});
    return {sent:true};
  } catch (error) { return {sent:false,error:String(error)}; }
};
portReceiver.startOwn = name => {
  const port=chrome.runtime.connect({name});
  const record={name,port,senderAbsent:port.sender===undefined,replies:[],disconnects:0};
  portReceiver.ownSources.push(record);
  port.onMessage.addListener(message=>record.replies.push(message));
  port.onDisconnect.addListener(()=>{record.disconnects++;});
  // Deliberately sent synchronously before any allocation/ready callback.
  port.postMessage({kind:'ownHello',token:name+':immediate'});
  return {senderAbsent:record.senderAbsent};
};
portReceiver.postOwn = (name,token) => {
  const found=portReceiver.ownSources.find(p=>p.name===name);
  try { found.port.postMessage({kind:'ownHello',token});return {threw:false}; }
  catch(error){return {threw:true,error:String(error)};}
};
portReceiver.disconnectOwn = name => {
  const found=portReceiver.ownSources.find(p=>p.name===name);
  found.port.disconnect();
  return {disconnects:found.disconnects};
};
0
"""


def poll(read, ready, seconds=8, required=True):
    end = time.monotonic() + seconds
    while True:
        got = read()
        if ready(got):
            return got
        if time.monotonic() >= end:
            if required:
                raise RuntimeError(f"timed out waiting: {got}")
            return got
        time.sleep(0.1)


def command(inspector, request):
    sv.ev(inspector, "window.__portResult=null;chrome.runtime.sendMessage(" + json.dumps(request) + ").then("
          "value=>window.__portResult={ok:true,value},"
          "error=>window.__portResult={ok:false,error:String(error)});0")
    answer = poll(lambda: sv.ev(inspector, "window.__portResult"), lambda value: value is not None)
    if not answer["ok"]:
        raise RuntimeError(answer["error"])
    return answer["value"]


def snapshot(inspector):
    return command(inspector, {"op": "snapshot"})


def own_snapshot(inspector):
    return sv.ev(inspector, "({ports:portReceiver.ports.map(({id,origin,channel,active})=>({id,origin,channel,active})),"
                 "incoming:portReceiver.incoming,disconnected:portReceiver.disconnected,"
                 "seenConnections:portReceiver.seenConnections,"
                 "ownSources:portReceiver.ownSources.map(({name,senderAbsent,replies,disconnects})=>({name,senderAbsent,replies,disconnects}))})")


def own_send(inspector, page, channel, token):
    return sv.ev(inspector, "portReceiver.send(" + ",".join(json.dumps(x) for x in (page, channel, token)) + ")")


def wait_pages(inspector, pages):
    return poll(lambda: snapshot(inspector),
                lambda state: all(any(p["origin"] == page for p in state["ports"]) for page in pages),
                seconds=6, required=False)


def phase(t, inspector, label, pages, expected_closed):
    state = wait_pages(inspector, pages)
    active = {p["origin"] for p in state["ports"] if p["active"]}
    t.ok(label + ": all concurrent pages retain their own live port", active == set(pages), state["ports"])
    tokens = {page: label + ":" + page for page in pages}
    sent = {page: command(inspector, {"op": "send", "target": page, "token": token})
            for page, token in tokens.items()}
    t.ok(label + ": worker can send on each live port", all(x.get("sent") for x in sent.values()), sent)
    state = poll(lambda: snapshot(inspector),
                 lambda s: all(any(m.get("kind") == "reply" and m.get("token") == token for m in s["incoming"])
                               for token in tokens.values()), seconds=3, required=False)
    # Give incorrectly duplicated deliveries a chance to arrive as well.
    time.sleep(0.3)
    state = snapshot(inspector)
    delivered = [m for m in state["delivered"] if m.get("token") in tokens.values()]
    replies = [m for m in state["incoming"] if m.get("kind") == "reply" and m.get("token") in tokens.values()]
    correct_deliveries = all(len([m for m in delivered if m.get("token") == token and m.get("page") == page]) == 1
                             for page, token in tokens.items())
    t.ok(label + ": each targeted message reaches its document exactly once", correct_deliveries, delivered)
    t.ok(label + ": no worker message reaches a different document",
         all(m.get("page") == m.get("target") for m in delivered), delivered)
    correct_replies = all(len([m for m in replies if m.get("token") == token and m.get("origin") == page]) == 1
                          for page, token in tokens.items())
    t.ok(label + ": each document's reply returns on its own port", correct_replies, replies)
    t.ok(label + ": no content reply arrives on another document's port",
         all(m.get("origin") == m.get("from") and m.get("channel") == "isolation:" + m.get("from", "")
             for m in replies), replies)
    t.ok(label + ": only explicitly closed documents disconnected",
         {m["origin"] for m in state["disconnected"]} == set(expected_closed), state["disconnected"])
    own = poll(lambda: own_snapshot(inspector),
               lambda s: all(any(p["origin"] == page and p["active"] for p in s["ports"]) for page in pages),
               seconds=3, required=False)
    t.ok(label + ": own extension page receives onConnect for every live document",
         {p["origin"] for p in own["ports"] if p["active"]} == set(pages), own["ports"])
    own_replies = [m for m in own["incoming"] if m.get("kind") == "reply" and m.get("token") in tokens.values()]
    t.ok(label + ": caller replies fan out to the open extension page too",
         all(len([m for m in own_replies if m.get("token") == token and m.get("origin") == page]) == 1
             for page, token in tokens.items()), own_replies)
    t.ok(label + ": extension-page receiver has no cross-document replies",
         all(m.get("origin") == m.get("from") for m in own_replies), own_replies)
    own_tokens = {page: "own:" + token for page, token in tokens.items()}
    own_sent = {page: own_send(inspector, page, "isolation:" + page, token) for page, token in own_tokens.items()}
    t.ok(label + ": own extension page can send on each caller connection",
         all(result.get("sent") for result in own_sent.values()), own_sent)
    state = poll(lambda: snapshot(inspector),
                 lambda s: all(any(m.get("kind") == "reply" and m.get("token") == token for m in s["incoming"])
                               for token in own_tokens.values()), seconds=3, required=False)
    time.sleep(0.3)
    state = snapshot(inspector)
    own_delivered = [m for m in state["delivered"] if m.get("token") in own_tokens.values()]
    t.ok(label + ": extension-page messages reach only their intended document",
         len(own_delivered) == len(pages) and all(m.get("page") == m.get("target") for m in own_delivered), own_delivered)
    own = own_snapshot(inspector)
    fanout = [m for m in own["incoming"] if m.get("kind") == "reply" and m.get("token") in own_tokens.values()]
    t.ok(label + ": replies to the extension page also fan out to its worker",
         all(len([m for m in state["incoming"] if m.get("kind") == "reply" and m.get("token") == token and m.get("origin") == page]) == 1
             for page, token in own_tokens.items())
         and all(len([m for m in fanout if m.get("token") == token and m.get("origin") == page]) == 1
                 for page, token in own_tokens.items()), {"worker": state["incoming"], "own": fanout})
    t.ok(label + ": only closed documents disconnect their extension-page receivers",
         {m["origin"] for m in own["disconnected"]} == set(expected_closed), own["disconnected"])
    return state


def close_tab(t, inspector, url, label):
    row = next(p for p in sv.sp("state")["tabs"] if p["url"] == url)
    sv.sp("select", id=row["id"])
    sv.cmd({"do": "press", "code": 13, "chars": "w", "mods": ["cmd"]})
    row_state = poll(lambda: sv.sp("state"),
                     lambda s: not any(p["url"] == url for p in s["tabs"]), seconds=3, required=False)
    t.ok(label + ": the closed document leaves the browser row",
         not any(p["url"] == url for p in row_state["tabs"]), row_state["tabs"])
    state = poll(lambda: snapshot(inspector),
                 lambda s: any(p["origin"] == url for p in s["disconnected"]), seconds=4, required=False)
    t.ok(label + ": closing this tab disconnects its own port",
         any(p["origin"] == url for p in state["disconnected"]), state["disconnected"])


def probe_channel(t, inspector, label, page, channel, receiver):
    token = label + ":" + receiver
    sent = (command(inspector, {"op": "send", "target": page, "channel": channel, "token": token})
            if receiver == "worker" else own_send(inspector, page, channel, token))
    t.ok(label + ": " + receiver + " sends on the selected logical port", sent.get("sent"), sent)
    state = poll(lambda: snapshot(inspector),
                 lambda s: any(m.get("kind") == "reply" and m.get("token") == token for m in s["incoming"]),
                 seconds=3, required=False)
    time.sleep(0.3)
    state, own = snapshot(inspector), own_snapshot(inspector)
    deliveries = [m for m in state["delivered"] if m.get("token") == token]
    replies = [m for m in state["incoming"] if m.get("kind") == "reply" and m.get("token") == token]
    own_replies = [m for m in own["incoming"] if m.get("kind") == "reply" and m.get("token") == token]
    t.ok(label + ": the other same-document caller port receives nothing",
         len(deliveries) == 1 and deliveries[0].get("page") == page and deliveries[0].get("channel") == channel,
         deliveries)
    t.ok(label + ": worker receives only that logical port's reply",
         len(replies) == 1 and replies[0].get("origin") == page and replies[0].get("channel") == channel, replies)
    t.ok(label + ": extension page receives the same logical port's reply",
         len(own_replies) == 1 and own_replies[0].get("origin") == page and own_replies[0].get("channel") == channel,
         own_replies)


def independent_caller_ports(t, inspector, page):
    primary, secondary = "isolation:" + page, "isolation:" + page + ":second"
    sent = command(inspector, {"op": "send", "target": page, "kind": "openSecond",
                               "newChannel": secondary, "token": "open-second"})
    t.ok("same document: request a second independent caller port", sent.get("sent"), sent)
    state = poll(lambda: snapshot(inspector),
                 lambda s: any(p["origin"] == page and p["channel"] == secondary and p["active"] for p in s["ports"]),
                 seconds=4, required=False)
    own = poll(lambda: own_snapshot(inspector),
               lambda s: any(p["origin"] == page and p["channel"] == secondary and p["active"] for p in s["ports"]),
               seconds=3, required=False)
    t.ok("same document: worker has both independent caller ports",
         {p["channel"] for p in state["ports"] if p["origin"] == page and p["active"]} == {primary, secondary}, state["ports"])
    t.ok("same document: both caller ports fan out to the extension page",
         {p["channel"] for p in own["ports"] if p["origin"] == page and p["active"]} == {primary, secondary}, own["ports"])
    probe_channel(t, inspector, "second logical port before disconnect", page, secondary, "worker")
    probe_channel(t, inspector, "second logical port before disconnect", page, secondary, "own page")

    sent = command(inspector, {"op": "send", "target": page, "channel": primary,
                               "kind": "disconnectSelf", "token": "disconnect-primary"})
    t.ok("explicit disconnect: command reaches the first caller port", sent.get("sent"), sent)
    state = poll(lambda: snapshot(inspector),
                 lambda s: any(m["page"] == page and m["channel"] == primary for m in s["selfDisconnected"]),
                 seconds=4, required=False)
    caller = [m for m in state["selfDisconnected"] if m["page"] == page and m["channel"] == primary]
    t.ok("explicit disconnect: disconnect() is silent at the calling end",
         len(caller) == 1 and caller[0]["localDisconnects"] == 0, caller)
    state = poll(lambda: snapshot(inspector),
                 lambda s: any(p["origin"] == page and p["channel"] == primary for p in s["disconnected"]),
                 seconds=4, required=False)
    own = poll(lambda: own_snapshot(inspector),
               lambda s: any(p["origin"] == page and p["channel"] == primary for p in s["disconnected"]),
               seconds=3, required=False)
    t.ok("explicit disconnect: worker's matching receiver is disconnected",
         len([p for p in state["disconnected"] if p["origin"] == page and p["channel"] == primary]) == 1, state["disconnected"])
    t.ok("explicit disconnect: extension page's matching receiver is disconnected",
         len([p for p in own["disconnected"] if p["origin"] == page and p["channel"] == primary]) == 1, own["disconnected"])
    t.ok("explicit disconnect: same-document sibling remains connected at both receivers",
         any(p["origin"] == page and p["channel"] == secondary and p["active"] for p in state["ports"])
         and any(p["origin"] == page and p["channel"] == secondary and p["active"] for p in own["ports"])
         and not any(p["origin"] == page and p["channel"] == secondary for p in state["disconnected"] + own["disconnected"]))
    probe_channel(t, inspector, "surviving logical port after sibling disconnect", page, secondary, "worker")
    probe_channel(t, inspector, "surviving logical port after sibling disconnect", page, secondary, "own page")


def own_source_connections(t, inspector):
    names = ["own-source:alpha", "own-source:beta"]
    for name in names:
        created = sv.ev(inspector, "portReceiver.startOwn(" + json.dumps(name) + ")")
        # Own-page callers retain the native route. The unmodified installed
        # app also exposes sender here; record that platform difference rather
        # than claiming the content-port fix changes its API contract.
        print("  NATIVE", name, "outgoing sender absent:", created.get("senderAbsent"), flush=True)
    state = poll(lambda: snapshot(inspector),
                 lambda s: all(any(p["name"] == name and p["messages"] for p in s["ownSources"]) for name in names),
                 seconds=6, required=False)
    own = poll(lambda: own_snapshot(inspector),
               lambda s: len(s["ownSources"]) == 2 and all(p["replies"] for p in s["ownSources"]),
               seconds=4, required=False)
    t.ok("own sources: worker receives exactly one immediate queued hello per connection",
         all(len([p for p in state["ownSources"] if p["name"] == name]) == 1
             and len(next(p for p in state["ownSources"] if p["name"] == name)["messages"]) == 1
             and next(p for p in state["ownSources"] if p["name"] == name)["messages"][0]["token"] == name + ":immediate"
             for name in names), state["ownSources"])
    t.ok("own sources: caller's own onConnect listener is excluded",
         not any(name in own["seenConnections"] for name in names), own["seenConnections"])
    t.ok("own sources: each worker reply reaches exactly its source connection once",
         all(len(p["replies"]) == 1 and p["replies"][0].get("channel") == p["name"]
             and p["replies"][0].get("token") == p["name"] + ":immediate" for p in own["ownSources"]), own["ownSources"])

    closed = sv.ev(inspector, "portReceiver.disconnectOwn(" + json.dumps(names[0]) + ")")
    # Native WebKit fires one local disconnect in the unchanged app too.
    # Managed content callers must be silent (checked separately above).
    t.ok("native own source explicit disconnect has no duplicate notification", closed["disconnects"] <= 1, closed)
    state = poll(lambda: snapshot(inspector),
                 lambda s: any(p["name"] == names[0] and p["disconnects"] == 1 for p in s["ownSources"]),
                 seconds=4, required=False)
    one = next((p for p in state["ownSources"] if p["name"] == names[0]), None)
    two = next((p for p in state["ownSources"] if p["name"] == names[1]), None)
    t.ok("own source disconnect retires only its worker-side receiver",
         one is not None and not one["active"] and one["disconnects"] == 1
         and two is not None and two["active"] and two["disconnects"] == 0, state["ownSources"])
    result = sv.ev(inspector, "portReceiver.postOwn(" + json.dumps(names[0]) + ",'after-disconnect')")
    t.ok("disconnected own source rejects further postMessage", result.get("threw"), result)
    result = sv.ev(inspector, "portReceiver.postOwn(" + json.dumps(names[1]) + ",'sibling-still-open')")
    t.ok("sibling own source remains usable", not result.get("threw"), result)
    own = poll(lambda: own_snapshot(inspector),
               lambda s: any(p["name"] == names[1] and any(m.get("token") == "sibling-still-open" for m in p["replies"])
                             for p in s["ownSources"]), seconds=3, required=False)
    sibling = next((p for p in own["ownSources"] if p["name"] == names[1]), None)
    t.ok("sibling own source receives its own worker reply after peer disconnect",
         sibling is not None and len([m for m in sibling["replies"] if m.get("token") == "sibling-still-open"]) == 1,
         sibling)

    result = command(inspector, {"op": "ownDisconnect", "name": names[1]})
    t.ok("worker can disconnect the remaining own-source receiver", result.get("found"), result)
    own = poll(lambda: own_snapshot(inspector),
               lambda s: any(p["name"] == names[1] and p["disconnects"] == 1 for p in s["ownSources"]),
               seconds=4, required=False)
    sibling = next((p for p in own["ownSources"] if p["name"] == names[1]), None)
    t.ok("worker-side disconnect fires exactly once at its own-page source",
         sibling is not None and sibling["disconnects"] == 1, sibling)
    sv.ev(inspector, "portReceiver.disconnectOwn(" + json.dumps(names[1]) + ")")
    result = sv.ev(inspector, "portReceiver.postOwn(" + json.dumps(names[1]) + ",'after-terminal')")
    own = own_snapshot(inspector)
    sibling = next((p for p in own["ownSources"] if p["name"] == names[1]), None)
    t.ok("terminal own source stays disconnected without duplicate events",
         result.get("threw") and sibling is not None and sibling["disconnects"] == 1, {"post": result, "source": sibling})


def main():
    binary = Path(sv.APP) / "Contents/MacOS/Search"
    print("Binary SHA256:", hashlib.sha256(binary.read_bytes()).hexdigest(), flush=True)
    t = sv.T()
    inspector = None
    try:
        sv.setup(sidebar=True)
        sv.launch()
        sv.page("home")
        with tempfile.TemporaryDirectory(prefix="port-ext-") as folder:
            for name, content in FILES.items():
                Path(folder, name).write_text(content)
            sv.cmd({"do": "ext-folder", "path": folder, "yes": True})
            extensions = poll(lambda: sv.cmd({"do": "extensions"})["extensions"],
                              lambda rows: any(e["name"] == "Port isolation fixture" and e["loaded"] for e in rows))
            ext = next(e["id"] for e in extensions if e["name"] == "Port isolation fixture")
            inspector = sv.cmd({"do": "ext-page", "id": ext, "path": "page.html"})["id"]
            sv.cmd({"do": "wait", "id": inspector, "seconds": 10})
            sv.ev(inspector, OWN_RECEIVER)

            first = sv.page("port-first")
            second = sv.page("port-second")
            a, b = sv.BASE + "/port-first", sv.BASE + "/port-second"
            phase(t, inspector, "two ordinary tabs", [a, b], [])

            frame = sv.BASE + "/port-frame"
            sv.ev(first, "var frame=document.createElement('iframe');frame.id='port-frame';frame.src="
                  + json.dumps(frame) + ";document.body.appendChild(frame);true")
            phase(t, inspector, "plus same-origin iframe", [a, b, frame], [])
            frame_ports = [p for p in snapshot(inspector)["ports"] if p["origin"] == frame]
            t.ok("iframe sender metadata identifies a child frame",
                 len(frame_ports) == 1 and isinstance(frame_ports[0].get("frameId"), int)
                 and frame_ports[0]["frameId"] != 0, frame_ports)

            sv.sp("select", id=second)
            c = sv.BASE + "/port-peek"
            sv.cmd({"do": "peek", "url": c})
            phase(t, inspector, "plus peek", [a, b, frame, c], [])

            d = sv.BASE + "/port-little"
            sv.cmd({"do": "little", "what": d})
            phase(t, inspector, "plus small window", [a, b, frame, c, d], [])
            before = snapshot(inspector)["ports"]
            own_before = own_snapshot(inspector)["ports"]

            sv.cmd({"do": "ui", "peeklink": "keep"})
            sv.cmd({"do": "little", "what": "keep"})
            phase(t, inspector, "both kept", [a, b, frame, c, d], [])
            after = snapshot(inspector)["ports"]
            t.ok("keeping aside pages preserves original port identities", before == after, {"before": before, "after": after})
            t.ok("keeping aside pages preserves extension-page receiver identities",
                 own_before == own_snapshot(inspector)["ports"])

            sv.ev(first, "document.getElementById('port-frame').remove();true")
            frame_state = poll(lambda: snapshot(inspector),
                               lambda s: any(p["origin"] == frame for p in s["disconnected"]),
                               seconds=4, required=False)
            t.ok("removing the iframe disconnects its own caller connection",
                 any(p["origin"] == frame for p in frame_state["disconnected"]), frame_state["disconnected"])
            phase(t, inspector, "after iframe removal", [a, b, c, d], [frame])

            close_tab(t, inspector, a, "first ordinary tab")
            phase(t, inspector, "after closing first", [b, c, d], [frame, a])
            close_tab(t, inspector, c, "kept peek")
            phase(t, inspector, "after closing kept peek", [b, d], [frame, a, c])
            close_tab(t, inspector, d, "kept small window")
            phase(t, inspector, "last survivor", [b], [frame, a, c, d])
            independent_caller_ports(t, inspector, b)
            own_source_connections(t, inspector)
            final = snapshot(inspector)
            hellos = [m for m in final["incoming"] if m.get("kind") == "hello"]
            t.ok("initial content messages also stay on their originating port",
                 all(m.get("origin") == m.get("from") for m in hellos), hellos)
            own_hellos = [m for m in own_snapshot(inspector)["incoming"] if m.get("kind") == "hello"]
            t.ok("initial content messages fan out to the extension page with their correct source",
                 len(own_hellos) == len(hellos) and all(m.get("origin") == m.get("from") for m in own_hellos), own_hellos)
            print("FINAL SNAPSHOT", json.dumps(final), flush=True)
    except Exception as error:
        t.ok("port isolation probe completes", False, str(error))
        if inspector:
            try:
                print("FAILURE SNAPSHOT", json.dumps(snapshot(inspector)), flush=True)
            except Exception:
                pass
    finally:
        sv.finish()
    t.done()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
