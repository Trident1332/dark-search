/* Ottocaller — Mac voice: RVC voices converted on this Mac by the local voice service
 * (web-dialer/mac-voice/rvc_service.py, ws://127.0.0.1:8790).
 *
 * The panel keeps one WebSocket to the service while it is open (reconnecting quietly, so a
 * service started later is picked up) and reads the voice list from it. When a call starts
 * with a Mac voice selected, SIP.js asks us for the local media instead of opening the
 * microphone itself: we open the mic into a 16 kHz AudioContext, stream it to the service in
 * 20 ms int16 packets, queue the converted blocks into a player node and hand SIP.js the
 * player's MediaStream. The FreeSWITCH box only ever hears the converted voice. */
var MacVoice = (function () {
  "use strict";
  var URL = "ws://127.0.0.1:8790";
  var ws = null, hello = null, retry = null, backoff = 1000, waiting = null, active = null, listeners = [];

  function notify() { listeners.forEach(function (f) { try { f(); } catch (e) { console.error(e); } }); }
  function online() { return !!(ws && ws.readyState === 1 && hello); }
  function voices() { return hello ? hello.voices.map(function (v) { return v.name; }) : []; }

  function connect() {
    if (ws && (ws.readyState === 0 || ws.readyState === 1)) return;
    clearTimeout(retry); retry = null;
    var sock;
    try { sock = new WebSocket(URL); } catch (e) { schedule(); return; }
    sock.binaryType = "arraybuffer";
    sock.onopen = function () { backoff = 1000; };
    sock.onmessage = function (e) {
      if (e.data instanceof ArrayBuffer) { if (active) active.player.port.postMessage(e.data, [e.data]); return; }
      var m; try { m = JSON.parse(e.data); } catch (err) { return; }
      if (m.type === "hello") { hello = m; notify(); }
      else if (m.type === "voices") { if (hello) { hello.voices = m.voices; notify(); } }
      else if (m.type === "started" || m.type === "error") {
        if (m.type === "started" && active) { active.ready = true; active.player.port.postMessage("flush"); }   // only audio from now on counts
        if (waiting) { var w = waiting; waiting = null; clearTimeout(w.timer); m.type === "started" ? w.ok(m) : w.fail(new Error("Voice service: " + (m.message || "error"))); }
      }
    };
    sock.onclose = function () { if (ws === sock) { ws = null; var was = !!hello; hello = null; if (waiting) { var w = waiting; waiting = null; clearTimeout(w.timer); w.fail(new Error("voice service closed")); } if (was) notify(); schedule(); } };
    sock.onerror = function () { /* onclose follows */ };
    ws = sock;
  }
  function schedule() { if (retry) return; retry = setTimeout(function () { retry = null; connect(); }, backoff); backoff = Math.min(backoff * 2, 15000); }
  function refresh() { if (online()) ws.send(JSON.stringify({ type: "voices" })); else connect(); }

  /* Open the microphone and return the converted MediaStream for the call. */
  async function start(name, pitch, isCurrent) {
    var current = typeof isCurrent === "function" ? isCurrent : function () { return true; };
    function cancelled(mic, ctx) {
      if (current()) return;
      if (mic) mic.getTracks().forEach(function (track) { track.stop(); });
      if (ctx) ctx.close();
      throw new DOMException("Call cancelled", "AbortError");
    }
    cancelled();
    if (!online()) throw new Error("Mac voice service is off");
    if (active) stop();
    var ctx = new AudioContext({ sampleRate: 16000, latencyHint: "interactive" });
    await ctx.audioWorklet.addModule(chrome.runtime.getURL("voice-worklets.js")).catch(function (error) { ctx.close(); throw error; });
    cancelled(null, ctx);
    var mic = await navigator.mediaDevices.getUserMedia({ audio: true }).catch(function (error) { ctx.close(); throw error; });
    cancelled(mic, ctx);
    var src = ctx.createMediaStreamSource(mic);
    var cap = new AudioWorkletNode(ctx, "mac-capture", { numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [1] });
    var sink = ctx.createGain(); sink.gain.value = 0;          // keeps the capture node alive; it outputs silence anyway
    src.connect(cap); cap.connect(sink); sink.connect(ctx.destination);
    var player = new AudioWorkletNode(ctx, "mac-player", { numberOfInputs: 0, numberOfOutputs: 1, outputChannelCount: [1] });
    var dest = ctx.createMediaStreamDestination(); player.connect(dest);
    var PKT = 320, pkt = new Int16Array(PKT), fill = 0;       // 20 ms at 16 kHz
    cap.port.onmessage = function (e) {
      var f = e.data;
      for (var i = 0; i < f.length; i++) {
        var s = f[i]; pkt[fill++] = s <= -1 ? -32768 : s >= 1 ? 32767 : (s * 32767) | 0;
        if (fill === PKT) { if (active && active.ready && ws && ws.readyState === 1) ws.send(pkt.buffer.slice(0)); fill = 0; }   // nothing is sent while the voice is still loading: it would all be converted in one burst and sit in the player's queue as delay
      }
    };
    var mine = active = { ctx: ctx, mic: mic, player: player, stream: dest.stream, name: name, ready: false };
    active.statsTimer = setInterval(function () {   // queue figures every 10 s, into the service log (see rvc_service.py "player")
      if (!active) return;
      player.port.onmessage = function (e) { try { if (ws && ws.readyState === 1) ws.send(JSON.stringify({ type: "player", stats: e.data, ctx: ctx.state, latency_ms: Math.round(1000 * ((ctx.outputLatency || 0) + ctx.baseLatency)) })); } catch (err) { /* closed */ } };
      player.port.postMessage("stats");
    }, 10000);
    await new Promise(function (ok, fail) {
      var request = waiting = { ok: ok, fail: fail };
      ws.send(JSON.stringify({ type: "start", voice: name, pitch: pitch }));
      request.timer = setTimeout(function () { if (waiting === request) { waiting = null; request.fail(new Error("voice service did not answer")); } }, 15000);
    }).catch(function (e) { if (active === mine) stop(); throw e; });
    if (ctx.state !== "running") { try { await ctx.resume(); } catch (e) { /* no gesture */ } }
    cancelled(mic, ctx);
    return dest.stream;
  }
  function stop() {
    if (waiting) { var w = waiting; waiting = null; clearTimeout(w.timer); w.fail(new DOMException("Call cancelled", "AbortError")); }
    if (!active) return;
    var a = active; active = null;
    clearInterval(a.statsTimer);
    // Report the player's queue figures before stopping: the service logs them next to its own stats,
    // so a glitchy call can be told apart (browser side vs conversion side) from the log alone.
    try {
      a.player.port.onmessage = function (e) { try { if (ws && ws.readyState === 1) ws.send(JSON.stringify({ type: "player", stats: e.data })); } catch (err) { /* closed */ } finally { try { ws.send(JSON.stringify({ type: "stop" })); } catch (err) { /* closed */ } } };
      a.player.port.postMessage("stats");
      setTimeout(function () { try { if (ws && ws.readyState === 1) ws.send(JSON.stringify({ type: "stop" })); } catch (e) { /* closed */ } }, 300);
    } catch (e) { try { if (ws && ws.readyState === 1) ws.send(JSON.stringify({ type: "stop" })); } catch (err) { /* closed */ } }
    try { a.mic.getTracks().forEach(function (t) { t.stop(); }); } catch (e) { /* gone */ }
    try { a.ctx.close(); } catch (e) { /* closed */ }
  }
  function stats() {   // resolves with the player's queue figures (for the console / tests)
    return new Promise(function (ok) {
      if (!active) return ok(null);
      active.player.port.onmessage = function (e) { ok(e.data); };
      active.player.port.postMessage("stats");
      setTimeout(function () { ok(null); }, 500);
    });
  }

  return { connect: connect, refresh: refresh, online: online, voices: voices, info: function () { return hello; },
           onChange: function (f) { listeners.push(f); }, start: start, stop: stop, active: function () { return active ? active.name : null; },
           stats: stats, streams: function () { return active ? { mic: active.mic, out: active.stream } : null; } };   // streams: for tests
})();
