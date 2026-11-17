const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../Sources/Search/AIInspection.swift'), 'utf8');
const recorder = source.match(/static let recorder = #"""\n([\s\S]*?)\n    """#/)[1];

function fixture({ budget = 32768, frames = [], body = 'response secret' } = {}) {
  let delivered = 0;
  const target = { identifier: 'main', NetworkAgent: { getResponseBody: async () => ({ body }) } };
  const world = { window: {}, setTimeout: (f, ms) => { const t = setTimeout(f, ms); t.unref(); return t; },
    WI: { targets: [target], pageTarget: target, networkManager: { frames, resourceForRequestIdentifier: () => null } },
    InspectorBackend: { dispatch: () => { delivered++; } } };
  vm.createContext(world);
  vm.runInContext(recorder.replace('budget=128*1024*1024', 'budget=' + budget), world);
  return { capture: world.window.__searchAIInspection, send: (method, params) => world.InspectorBackend.dispatch({ method, params }), delivered: () => delivered };
}

test('small console, socket, POST, headers and response bodies stay unredacted', async () => {
  const f = fixture();
  f.send('Console.messageAdded', { message: { text: 'console secret' } });
  f.send('Network.webSocketFrameReceived', { requestId: 's', response: { payloadData: 'socket secret' } });
  f.send('Network.requestWillBeSent', { requestId: '1', request: { url: 'https://fixture.invalid', postData: 'POST secret', headers: { Cookie: 'cookie secret' } } });
  f.send('Network.responseReceived', { requestId: '1', response: { status: 200 } });
  f.send('Network.loadingFinished', { requestId: '1' });
  const snapshot = await f.capture.snapshot();
  for (const secret of ['console secret', 'socket secret', 'POST secret', 'cookie secret', 'response secret']) assert.ok(snapshot.includes(secret));
  assert.equal(f.capture.summary().problem, null);
});

for (const section of ['console', 'socket', 'request', 'response', 'events', 'body']) {
  test(section + ' consumes the shared capture budget and leaves dispatch working', async () => {
    const huge = 'x'.repeat(20000);
    const f = fixture({ body: section === 'body' ? huge : 'response secret' });
    if (section === 'console') f.send('Console.messageAdded', { message: { text: huge } });
    if (section === 'socket') f.send('Network.webSocketFrameReceived', { requestId: '1', response: { payloadData: huge } });
    if (section === 'request') f.send('Network.requestWillBeSent', { requestId: '1', request: { url: 'https://fixture.invalid', postData: huge, headers: { Authorization: huge } } });
    if (['response', 'events', 'body'].includes(section)) {
      f.send('Network.requestWillBeSent', { requestId: '1', request: { url: 'https://fixture.invalid' } });
      if (section === 'response') f.send('Network.responseReceived', { requestId: '1', response: { headers: { 'Set-Cookie': huge } } });
      if (section === 'events') f.send('Network.someMetadata', { requestId: '1', metadata: huge });
      if (section === 'body') {
        f.send('Network.loadingFinished', { requestId: '1' });
      }
    }
    await f.capture.snapshot();
    const before = f.delivered();
    f.send('Console.messageAdded', { message: { text: 'after limit' } });
    assert.equal(f.delivered(), before + 1);
    const state = f.capture.summary();
    assert.ok(state.bytes <= state.budget);
    assert.ok(state.dropped > 0, JSON.stringify(state));
    assert.match(state.problem, /capture limit/);
    assert.ok(!(await f.capture.snapshot()).includes(huge));
    f.capture.stop();
    assert.equal(f.capture.summary().bytes, 0);
  });
}

test('the production 128 MB budget also stops accumulated socket payloads', () => {
  const f = fixture({ budget: 128 * 1024 * 1024 });
  const payload = 'x'.repeat(4 * 1024 * 1024);
  for (let i = 0; i < 20; i++) f.send('Network.webSocketFrameReceived', { requestId: 's', response: { payloadData: payload } });
  assert.ok(f.capture.summary().bytes <= 128 * 1024 * 1024);
  assert.ok(f.capture.summary().dropped > 0);
});

test('streaming data-received notifications do not repeatedly charge unchanged request IDs', () => {
  const f = fixture();
  f.send('Network.requestWillBeSent', { requestId: '1', request: { url: 'https://fixture.invalid/stream' } });
  const before = f.capture.summary().bytes;
  for (let i = 0; i < 10000; i++) f.send('Network.dataReceived', { requestId: '1', dataLength: 1024 });
  assert.equal(f.capture.summary().bytes, before);
  assert.equal(f.capture.summary().problem, null);
});

test('too many recovered resources reports the limit without breaking initialization', () => {
  const resources = Array.from({ length: 5002 }, (_, i) => ({ url: 'https://fixture.invalid/' + i }));
  const f = fixture({ budget: 128 * 1024 * 1024, frames: [{ id: 'f', resourceCollection: { items: resources } }] });
  assert.equal(f.capture.summary().requests, 5000);
  assert.match(f.capture.summary().problem, /5000/);
  f.capture.stop();
});
