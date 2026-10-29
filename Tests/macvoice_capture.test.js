/* Offline Mac voice capture cancellation checks. No sockets or real audio devices. */
const test = require('node:test'), assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '..', 'Resources', 'Dialer', 'macvoice.js'), 'utf8');
function deferred() { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; }
async function settle() { for (let i = 0; i < 30; i++) await Promise.resolve(); }
function world(options = {}) {
  const contexts = [], sockets = [], mediaRequests = [], nodes = [], timers = new Map(); let timerId = 0;
  const rawTrack = { stopped: false, stop() { this.stopped = true; } };
  const rawStream = { getTracks: () => [rawTrack] };
  const node = () => { const n = { connect() {}, port: { postMessage() {}, onmessage: null } }; nodes.push(n); return n; };
  class AudioContext {
    constructor() { this.closed = false; this.state = 'running'; this.audioWorklet = { addModule: () => options.module ? options.module : Promise.resolve() }; contexts.push(this); }
    close() { this.closed = true; return Promise.resolve(); }
    createMediaStreamSource() { return node(); }
    createGain() { const n = node(); n.gain = {}; return n; }
    createMediaStreamDestination() { const n = node(); n.stream = { getTracks: () => [] }; return n; }
  }
  class WebSocket { constructor() { this.readyState = 1; sockets.push(this); } send() {} }
  const context = { console, DOMException, AudioContext, WebSocket, AudioWorkletNode: class { constructor() { return node(); } },
    navigator: { mediaDevices: { getUserMedia() { mediaRequests.push({}); return options.media ? options.media : Promise.resolve(rawStream); } } },
    chrome: { runtime: { getURL: value => value } },
    setTimeout(fn, ms) { const id = ++timerId; timers.set(id, { fn, ms }); return id; }, clearTimeout(id) { timers.delete(id); },
    setInterval() { return 1; }, clearInterval() {}, ArrayBuffer, Int16Array };
  vm.createContext(context); vm.runInContext(source, context, { filename: 'macvoice.js' });
  context.MacVoice.connect(); sockets[0].onmessage({ data: JSON.stringify({ type: 'hello', voices: [{ name: 'Synthetic voice' }] }) });
  return { voice: context.MacVoice, contexts, mediaRequests, nodes, rawStream, rawTrack, timers };
}
test('cancellation while loading a worklet prevents opening the microphone', async () => {
  const module = deferred(); let current = true;
  const w = world({ module: module.promise });
  const result = w.voice.start('Synthetic voice', 12, () => current).catch(error => error);
  await settle(); current = false; module.resolve();
  const error = await result;
  assert.equal(error.name, 'AbortError');
  assert.equal(w.mediaRequests.length, 0);
  assert.equal(w.contexts[0].closed, true);
});
test('a late microphone grant after cancellation is stopped before any audio graph exists', async () => {
  const media = deferred(); let current = true;
  const w = world({ media: media.promise });
  const result = w.voice.start('Synthetic voice', 12, () => current).catch(error => error);
  await settle(); assert.equal(w.mediaRequests.length, 1);
  current = false; media.resolve(w.rawStream);
  const error = await result;
  assert.equal(error.name, 'AbortError');
  assert.equal(w.rawTrack.stopped, true);
  assert.equal(w.contexts[0].closed, true);
  assert.equal(w.nodes.length, 0);
});
test('stopping during voice startup rejects its own waiter and clears the service timer', async () => {
  const w = world();
  const result = w.voice.start('Synthetic voice', 12, () => true).catch(error => error);
  await settle();
  assert.equal(w.timers.size, 1);
  w.voice.stop();
  const error = await result;
  assert.equal(error.name, 'AbortError');
  assert.equal(w.rawTrack.stopped, true);
  assert.equal(w.contexts[0].closed, true);
  assert.equal(Array.from(w.timers.values()).some(timer => timer.ms === 15000), false);
});
