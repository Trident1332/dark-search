/* Offline integration tests for the built-in dialer. Run: node --test Tests/dialer_lifecycle.test.js
 * The shipped scripts run unchanged in a VM. DOM, WebKit, SIP and media are mocks;
 * no socket, live preferences, keychain access or real phone call is possible. */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const files = path.join(__dirname, '..', 'Resources', 'Dialer');
const scripts = ['search.js', 'calls.js', 'dialer.js'].map(file => [file, fs.readFileSync(path.join(files, file), 'utf8')]);
function deferred() { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; }
async function settle() { for (let i = 0; i < 50; i++) await Promise.resolve(); }
function element(id = '') {
  const classes = new Set();
  return { id, textContent: '', hidden: true, className: '', paused: true, style: { setProperty() {} }, attrs: {}, listeners: {}, children: [],
    classList: { add(x) { classes.add(x); }, remove(x) { classes.delete(x); }, toggle(x, value) { if (value) classes.add(x); else classes.delete(x); }, contains(x) { return classes.has(x); } },
    addEventListener(type, f) { (this.listeners[type] ??= []).push(f); }, removeEventListener() {},
    setAttribute(k, v) { this.attrs[k] = v; }, getAttribute(k) { return this.attrs[k]; }, appendChild(c) { this.children.push(c); },
    querySelector() { return null; }, querySelectorAll(q) { return q === '.key' ? Array.from({ length: 12 }, () => element()) : []; },
    getBoundingClientRect() { return { bottom: 300, height: 40, top: 260 }; },
    play() { this.paused = false; return Promise.resolve(); }, pause() { this.paused = true; }, contains() { return false; },
    click() { if (!this.inert && !this.disabled) (this.listeners.click || []).forEach(f => f({})); }
  };
}
async function world(options = {}) {
  const elements = new Map(), $ = id => { if (!elements.has(id)) elements.set(id, element(id)); return elements.get(id); };
  $('hang').inert = true; // the initial dialer.html state
  const config = { wss: 'wss://old.invalid', domain: 'old.invalid', user: '1001', password: 'synthetic', autodial: true, region: 'GB', protectedRoute: { mode: 'direct' }, ...options.config };
  const document = { getElementById: $, querySelector: q => q.startsWith('.menu') ? null : $(q), addEventListener() {},
    createElement: element, createTextNode: text => ({ textContent: text }), body: element(), fonts: null };
  const users = [], calls = [], invites = [], answers = [], mediaRequests = [], events = {}, pageValues = {}, records = [], zeroTimers = [], nativeOps = [], peers = [], handlers = [], networkEvents = [];
  const timers = new Map(); const baseTime = Date.now(); let clockNow = 0, timerID = 0;
  class ClockDate extends Date { constructor(...args) { super(...(args.length ? args : [baseTime + clockNow])); } static now() { return baseTime + clockNow; } }
  const providerItems = [['numeroDefault', 'numero'], ['numeroUS', 'numero-us'], ['numeroCA', 'numero-ca'], ['telicallUK', 'telicall']];
  providerItems.forEach(([id, value]) => { $(id).setAttribute('data-provider', value); $(id).hidden = id === 'numeroUS' || id === 'numeroCA'; });
  $('providerMenu').querySelectorAll = q => q === '[data-provider]' ? providerItems.map(([id]) => $(id)) : [];
  let ready = false, started = false, pending = options.pending || null;
  const stream = () => { const track = { stopped: false, stop() { this.stopped = true; } }; return { getTracks: () => [track], track }; };
  const media = () => { mediaRequests.push({}); return options.media ? options.media() : Promise.resolve(stream()); };
  class SimpleUser {
    constructor(wss, opts) { this.wss = wss; this.opts = opts; users.push(this); }
    handler() {
      const handler = this.opts.userAgentOptions.sessionDescriptionHandlerFactory(this.session, this.opts.userAgentOptions.sessionDescriptionHandlerFactoryOptions);
      this.session.sessionDescriptionHandler = handler;
      return handler;
    }
    connect() { this.delegate.onServerConnect(); return Promise.resolve(); }
    register() { if (options.register !== false) this.delegate.onRegistered(); return Promise.resolve(); }
    async call(uri, inviteOptions) {
      this.session = {};
      try { await this.handler().getMedia({ audio: true }); }
      catch (error) { if (options.terminateOnMediaFailure) { this.session = null; this.delegate.onCallHangup(); } throw error; }
      calls.push(uri); invites.push({ uri, options: inviteOptions });
    }
    async answer() {
      answers.push(this);
      try { await this.handler().getMedia({ audio: true }); }
      catch (error) { if (options.terminateOnMediaFailure) { this.session = null; this.delegate.onCallHangup(); } throw error; }
      this.delegate.onCallAnswered();
    }
    disconnect() { this.disconnected = true; networkEvents.push('disconnect'); return Promise.resolve(); }
    hangup() {
      const finish = () => { if (this.session) { this.session = null; this.delegate.onCallHangup(); } };
      if (options.hangup) return options.hangup().then(finish);
      finish(); return Promise.resolve();
    }
    decline() { this.declines = (this.declines || 0) + 1; this.session = null; this.delegate.onCallHangup(); return Promise.resolve(); }
  }
  function deliver() {
    if (!ready || !started || !pending) return;
    const message = { ...pending, type: 'dialer:dial' };
    queueMicrotask(() => context.__searchDialer.deliver(message));
  }
  const context = { console: { log() {}, warn() {}, error() {} }, document, location: { search: '', href: 'file:///synthetic/Dialer/dialer.html' },
    URL: class extends URL { static createObjectURL() { return 'blob:synthetic'; } }, URLSearchParams, Blob, Int16Array, ArrayBuffer, DataView,
    Date: ClockDate, Math, Promise, DOMException, navigator: { permissions: { query: () => options.permission ? options.permission() : Promise.resolve({ state: 'granted' }) }, mediaDevices: { getUserMedia: media } },
    setTimeout(fn, ms) { const id = ++timerID; timers.set(id, { fn, due: clockNow + ms }); if (ms === 0) zeroTimers.push(id); return id; },
    clearTimeout(id) { timers.delete(id); }, setInterval() { return 1; }, clearInterval() {},
    MacVoice: { online: () => false, voices: () => [], onChange() {}, connect() {}, refresh() {}, stop() {} },
    SIP: { Web: { SimpleUser, defaultSessionDescriptionHandlerFactory: f => (_session, settings) => {
      // SIP.js shallow-merges its default RTC configuration before constructing a peer.
      const configured = Object.assign({ iceCandidatePoolSize: 0, iceTransportPolicy: 'all', iceServers: [{ urls: 'stun:stun.l.google.com:19302' }] }, settings?.peerConnectionConfiguration);
      const peer = { configuration: configured, closed: false, getConfiguration: () => options.enginePolicy ? { ...configured, iceTransportPolicy: options.enginePolicy } : configured };
      const handler = { peerConnection: peer, async getMedia(constraints) { this.stream = await f(constraints); return this.stream; }, close() {
        if (!peer.closed) networkEvents.push('peer-close'); peer.closed = true;
        this.stream?.getTracks().forEach(track => track.stop()); this.peerConnection = undefined;
      } };
      peers.push(peer); handlers.push(handler); networkEvents.push('peer-create');
      return handler;
    } } },
    webkit: { messageHandlers: { dialer: { postMessage(msg) {
      nativeOps.push(msg.op);
      if (msg.op === 'microphone.request') return options.nativePermission ? options.nativePermission() : Promise.resolve({ state: 'granted' });
      if (msg.op === 'microphone.recover') return options.recovery ? options.recovery() : Promise.resolve({ state: 'denied' });
      if (msg.op === 'microphone.status') return Promise.resolve({ state: 'granted' });
      if (msg.op === 'get') {
        const result = { values: Object.fromEntries((msg.keys || Object.keys(config)).filter(k => k in config || k in pageValues).map(k => [k, k in config ? config[k] : pageValues[k]])) };
        return options.configGate && msg.keys.includes('wss') ? options.configGate.then(() => result) : Promise.resolve(result);
      }
      if (msg.op === 'set') { Object.assign(pageValues, msg.values); return Promise.resolve({ ok: true }); }
      if (msg.op === 'message') { if (msg.msg.type === 'call-ended') records.push(msg.msg.record); return Promise.resolve({ reply: { ok: true } }); }
      if (msg.op === 'session.get') { started = true; const values = pending ? { pendingDial: pending } : {}; deliver(); return Promise.resolve({ values }); }
      if (msg.op === 'session.remove' && msg.keys.includes('pendingDial')) pending = null;
      if (msg.op === 'ready') { ready = true; context.__searchDialer.setVisible(options.visible !== false); deliver(); }
      return Promise.resolve({ ok: true });
    } } } }
  };
  context.window = context; context.addEventListener = (name, fn) => (events[name] ??= []).push(fn);
  vm.createContext(context);
  for (const [file, source] of scripts) vm.runInContext(source, context, { filename: file });
  (events.DOMContentLoaded || []).forEach(f => f());
  await settle();
  return { $, config, users, calls, invites, answers, mediaRequests, records, nativeOps, peers, handlers, networkEvents, storage: pageValues, stream, api: context.__searchDialer, Calls: context.OttoCalls,
    now: () => baseTime + clockNow,
    makeHandler(settings, user = users.at(-1)) { return user.opts.userAgentOptions.sessionDescriptionHandlerFactory({}, settings || user.opts.userAgentOptions.sessionDescriptionHandlerFactoryOptions); },
    dial(number = '+442079460958') { context.__searchDialer.deliver({ type: 'dialer:dial', number }); },
    pickProvider(value) {
      const item = providerItems.map(([id]) => $(id)).find(item => item.getAttribute('data-provider') === value);
      assert.ok(item && !item.disabled && !item.hidden, 'the selected menu item must be available');
      $('providerMenu').listeners.click.forEach(f => f({ target: { closest: q => q === 'button[data-provider]' ? item : null }, stopPropagation() {} }));
    },
    recent(index = 0) {
      $('recents').classList.add('open');
      $('rlist').listeners.click.forEach(f => f({ target: { closest: q => q === '.rrow' ? { getAttribute: () => String(index) } : null } }));
    },
    async flushRecords() { while (zeroTimers.length) { const id = zeroTimers.shift(), timer = timers.get(id); timers.delete(id); if (timer) timer.fn(); } await settle(); },
    async advance(ms) {
      const end = clockNow + ms;
      for (let i = 0; i < 1000; i++) {
        const next = Array.from(timers.entries()).filter(([, timer]) => timer.due <= end).sort((a, b) => a[1].due - b[1].due)[0];
        if (!next) break;
        clockNow = next[1].due; timers.delete(next[0]); next[1].fn(); await settle();
      }
      clockNow = end; await settle();
    },
    async incoming() { users.at(-1).session = {}; await users.at(-1).delegate.onCallReceived(); await settle(); },
    async settings(values) { Object.assign(config, values); context.__searchDialer.changed(Object.fromEntries(Object.entries(values).map(([k, newValue]) => [k, { newValue }])), 'local'); await settle(); }
  };
}

test('autodial off loads a warm request without calling; Call still works', async () => {
  const w = await world({ config: { autodial: false } });
  w.dial(); await settle();
  assert.equal(w.calls.length, 0);
  assert.equal(w.mediaRequests.length, 0);
  assert.match(w.api.state().number, /442079460958/);
  w.$('call').click(); await settle();
  assert.equal(w.calls.length, 1);
});
test('autodial off also holds a native startup delivery', async () => {
  const w = await world({ config: { autodial: false }, pending: { number: '+442079460958', at: Date.now() } });
  assert.equal(w.calls.length, 0);
  assert.equal(w.mediaRequests.length, 0);
});
test('an enabled startup dial survives loading its connection settings', async () => {
  const settings = deferred();
  const w = await world({ configGate: settings.promise, pending: { number: '+442079460958', at: Date.now() } });
  settings.resolve(); await settle();
  assert.equal(w.calls.length, 1);
});
test('closing the panel cancels a number queued for registration', async () => {
  const w = await world({ register: false });
  w.dial(); await settle(); await w.api.setVisible(false);
  w.users[0].delegate.onRegistered(); await settle();
  assert.equal(w.calls.length, 0);
  assert.equal(w.mediaRequests.length, 0);
});
test('closing the panel invalidates an asynchronous permission check', async () => {
  const w = await world();
  // search.js supplies granted for the native panel. Simulate its genuinely async promise
  // by closing synchronously before the dial() continuation can acquire media.
  w.dial(); await w.api.setVisible(false); await settle();
  assert.equal(w.calls.length, 0);
  assert.equal(w.mediaRequests.length, 0);
});
test('a microphone stream acquired after closing is stopped and never invited', async () => {
  const media = deferred();
  const w = await world({ media: () => media.promise });
  w.dial(); await settle();
  assert.equal(w.mediaRequests.length, 1);
  await w.api.setVisible(false);
  const stream = w.stream(); media.resolve(stream); await settle();
  assert.equal(stream.track.stopped, true);
  assert.equal(w.calls.length, 0);
});
test('reopening does not revive an older microphone request', async () => {
  const media = deferred();
  const w = await world({ media: () => media.promise });
  w.dial(); await settle(); await w.api.setVisible(false); w.api.setVisible(true);
  const stream = w.stream(); media.resolve(stream); await settle();
  assert.equal(stream.track.stopped, true);
  assert.equal(w.calls.length, 0);
});
test('closing and reopening before startup settings finish cannot revive a cached number', async () => {
  const settings = deferred();
  const w = await world({ configGate: settings.promise, pending: { number: '+442079460958', at: Date.now() } });
  assert.equal(w.users.length, 0);
  await w.api.setVisible(false); w.api.setVisible(true);
  settings.resolve(); await settle();
  assert.equal(w.users.length, 1);
  assert.equal(w.calls.length, 0);
  assert.equal(w.mediaRequests.length, 0);
});
test('closing before a delivered request continuation runs cancels it after reopening', async () => {
  const w = await world();
  w.dial(); w.api.setVisible(false); w.api.setVisible(true); await settle();
  assert.equal(w.calls.length, 0);
  assert.equal(w.mediaRequests.length, 0);
});
test('a newly hidden page ignores requests until native visibility is granted', async () => {
  const w = await world({ visible: false });
  w.dial(); await settle();
  assert.equal(w.calls.length, 0);
  w.api.setVisible(true); w.dial(); await settle();
  assert.equal(w.calls.length, 1);
});
test('an incoming call requires Answer before any microphone access', async () => {
  const w = await world(); await w.incoming();
  assert.equal(w.answers.length, 0);
  assert.equal(w.mediaRequests.length, 0);
  assert.equal(w.$('incoming').hidden, false);
  w.$('answer').click(); await settle();
  assert.equal(w.answers.length, 1);
  assert.equal(w.mediaRequests.length, 1);
  assert.equal(w.api.state().state, 'incall');
});
test('hidden and declined incoming calls never acquire the microphone', async () => {
  const hidden = await world(); await hidden.api.setVisible(false); await hidden.incoming();
  assert.equal(hidden.users[0].declines, 1);
  assert.equal(hidden.answers.length, 0);
  assert.equal(hidden.mediaRequests.length, 0);
  const visible = await world(); await visible.incoming(); visible.$('decline').click(); await settle();
  assert.equal(visible.users[0].declines, 1);
  assert.equal(visible.answers.length, 0);
});
test('connection settings saved during a call are applied after hangup', async () => {
  const w = await world(); w.dial(); await settle(); w.users[0].delegate.onCallAnswered();
  await w.settings({ wss: 'wss://new.invalid', domain: 'new.invalid', user: '1002' });
  assert.equal(w.users.length, 1);
  assert.match(w.api.state().note, /after this call/);
  await w.api.hangup(); await settle();
  assert.equal(w.users.length, 2);
  assert.equal(w.users[0].disconnected, true);
  assert.equal(w.users[1].wss, 'wss://new.invalid');
});
test('shutdown disconnects the client and ignores later visibility or calls', async () => {
  const w = await world(); await w.api.shutdown();
  assert.equal(w.users[0].disconnected, true);
  w.api.setVisible(true); w.dial(); await settle();
  assert.equal(w.calls.length, 0);
  assert.equal(w.mediaRequests.length, 0);
});
test('shutdown cancels and stops a late microphone stream', async () => {
  const media = deferred();
  const w = await world({ media: () => media.promise });
  w.dial(); await settle(); await w.api.shutdown();
  const stream = w.stream(); media.resolve(stream); await settle();
  assert.equal(stream.track.stopped, true);
  assert.equal(w.calls.length, 0);
  assert.equal(w.users[0].disconnected, true);
});

// Reserved fictional NANP numbers; no owned numbers or credentials belong in tests.
const numeroNumbers = { numeroUS: '+12025550123', numeroCA: '+16135550123' };
test('owned Numero US and Canada choices send distinct explicit URI routes', async () => {
  for (const [line, prefix] of [['us', 'numero-us-'], ['ca', 'numero-ca-']]) {
    const w = await world({ config: { ...numeroNumbers, numeroLine: line } });
    w.dial('+442079460958'); await settle();
    assert.equal(w.calls[0], `sip:${prefix}442079460958@old.invalid`);
    assert.ok(w.invites[0].options.extraHeaders.includes(`X-Numero-Line: ${line}`));
    assert.ok(!w.invites[0].options.extraHeaders.some(h => /caller.?id|202555|613555/i.test(h)));
  }
});
test('the Number menu persists Canada and displays each configured number', async () => {
  const w = await world({ config: { ...numeroNumbers } });
  assert.match(w.$('numeroUS').textContent, /\+12025550123/);
  assert.equal(w.$('numeroUS').getAttribute('data-flag'), 'US');
  assert.match(w.$('numeroCA').textContent, /\+16135550123/);
  assert.equal(w.$('numeroCA').getAttribute('data-flag'), 'CA');
  assert.match(w.$('numeroCA').getAttribute('aria-label'), /^Numero Canada · \+16135550123/);
  assert.equal(w.$('numeroDefault').hidden, true);
  w.pickProvider('numero-ca');
  assert.equal(w.storage.provider, 'numero');
  assert.equal(w.storage.numeroLine, 'ca');
  assert.equal(w.$('providerLbl').textContent, 'Canada');
  w.dial(); await settle();
  assert.match(w.calls[0], /^sip:numero-ca-/);
});
test('an unavailable or invalid owned line cannot fall back to the US/default route', async () => {
  for (const config of [
    { numeroUS: numeroNumbers.numeroUS, numeroLine: 'ca' },
    { ...numeroNumbers, numeroLine: 'invalid' },
    { numeroUS: '+11235550123', numeroLine: 'us' },
    { numeroUS: '+12021550123', numeroLine: 'us' },
    { numeroUS: '+12025550123\r\nX-Caller-ID: arbitrary', numeroLine: 'us' }
  ]) {
    const w = await world({ config }); w.dial(); await settle();
    assert.equal(w.calls.length, 0);
    assert.equal(w.mediaRequests.length, 0);
    assert.match(w.api.state().note, /Choose an available Numero number/);
  }
});
test('a valid NANP toll-free number is allowed in either owned slot', async () => {
  const w = await world({ config: { numeroCA: '+18775550123', numeroLine: 'ca' } });
  w.dial(); await settle();
  assert.match(w.calls[0], /^sip:numero-ca-/);
  assert.equal(w.$('numeroCA').disabled, false);
});
test('a missing Canada number is disabled in the Number menu', async () => {
  const w = await world({ config: { numeroUS: numeroNumbers.numeroUS } });
  assert.equal(w.$('numeroUS').disabled, false);
  assert.equal(w.$('numeroCA').disabled, true);
  assert.throws(() => w.pickProvider('numero-ca'), /must be available/);
});
test('Numero service codes and legacy unconfigured users keep numeric routing', async () => {
  const service = await world({ config: { numeroUS: numeroNumbers.numeroUS, numeroLine: 'ca' } });
  service.dial('9199'); await settle();
  assert.equal(service.calls[0], 'sip:9199@old.invalid');
  assert.equal(service.invites[0].options.extraHeaders.length, 0);
  const legacy = await world(); legacy.dial(); await settle();
  assert.equal(legacy.calls[0], 'sip:%2B442079460958@old.invalid');
  assert.equal(legacy.invites[0].options.extraHeaders.length, 0);
});
test('Telicall stays separate from configured Numero line routing', async () => {
  const w = await world({ config: { ...numeroNumbers, provider: 'telicall', numeroLine: 'ca' } });
  w.dial(); await settle();
  assert.equal(w.calls[0], 'sip:%2B442079460958@old.invalid');
  assert.deepEqual(Array.from(w.invites[0].options.extraHeaders), ['X-Provider: telicall']);
});
test('the chosen line and caller number remain frozen through media setup and call records', async () => {
  const media = deferred();
  const w = await world({ config: { ...numeroNumbers, numeroLine: 'ca' }, media: () => media.promise });
  w.dial(); await settle();
  w.pickProvider('numero-us');
  await w.settings({ numeroCA: '+16135550124' });
  assert.equal(w.users.length, 1, 'number changes must not reconnect the SIP seat');
  media.resolve(w.stream()); await settle();
  assert.match(w.calls[0], /^sip:numero-ca-/);
  assert.ok(w.invites[0].options.extraHeaders.includes('X-Numero-Line: ca'));
  await w.api.hangup(); await w.flushRecords();
  assert.equal(w.storage.history[0].numeroLine, 'ca');
  assert.equal(w.storage.history[0].fromNumber, numeroNumbers.numeroCA);
  assert.equal(w.records[0].numeroLine, 'ca');
  assert.equal(w.records[0].fromNumber, numeroNumbers.numeroCA);
  const clean = w.Calls.clean(w.records[0]);
  assert.equal(clean.numeroLine, 'ca');
  assert.equal(clean.fromNumber, numeroNumbers.numeroCA);
});
test('Recents restores its original Numero line for redial', async () => {
  const w = await world({ config: { ...numeroNumbers, numeroLine: 'ca' } });
  w.dial(); await settle(); await w.api.hangup(); await w.flushRecords();
  w.pickProvider('numero-us'); w.recent(); await settle();
  assert.equal(w.calls.length, 2);
  assert.match(w.calls[1], /^sip:numero-ca-/);
  assert.equal(w.storage.numeroLine, 'ca');
});
test('Recents asks for a fresh choice if that owned number has changed', async () => {
  const w = await world({ config: { ...numeroNumbers, numeroLine: 'ca' } });
  w.dial(); await settle(); await w.api.hangup(); await w.flushRecords();
  await w.settings({ numeroCA: '+16135550124' });
  w.recent(); await settle();
  assert.equal(w.calls.length, 1);
  assert.match(w.api.state().note, /number changed/);
});
test('connection changes retain line binding and malformed metadata never becomes caller-ID signaling', async () => {
  const w = await world({ config: { ...numeroNumbers, numeroLine: 'ca' } });
  await w.settings({ password: 'synthetic-new' });
  w.dial(); await settle();
  assert.match(w.calls[0], /^sip:numero-ca-/);
  const clean = w.Calls.clean({ id: 'sample', number: '+442079460958', outcome: 'answered', startedAt: 1, endedAt: 2,
    numeroLine: 'ca\r\nX-Caller-ID: other', fromNumber: '+16135550123' });
  assert.equal(clean.numeroLine, undefined);
  assert.equal(clean.fromNumber, undefined);
});

test('a stalled microphone startup times out without waiting for the remote party', async () => {
  const media = deferred();
  const w = await world({ media: () => media.promise, terminateOnMediaFailure: true });
  w.dial('9196'); await settle();
  assert.equal(w.api.state().state, 'calling');
  assert.match(w.api.state().note, /Starting microphone/);
  await w.advance(14999);
  assert.equal(w.api.state().state, 'calling');
  await w.advance(1);
  assert.equal(w.api.state().state, 'idle');
  assert.match(w.api.state().status, /Microphone didn't start/);
  assert.match(w.api.state().note, /System Settings/);
  assert.equal(w.calls.length, 0);
  assert.equal(w.nativeOps.includes('microphone'), false, 'a timeout must not open an explanation alert');
  const late = w.stream(); media.resolve(late); await settle();
  assert.equal(late.track.stopped, true);
  assert.equal(w.calls.length, 0);
});
test('successful microphone startup clears its timer and never imposes a call-duration limit', async () => {
  const w = await world(); w.dial(); await settle();
  assert.equal(w.calls.length, 1);
  w.users[0].delegate.onCallAnswered();
  await w.advance(60000);
  assert.equal(w.api.state().state, 'incall');
  assert.equal(w.users[0].session !== null, true);
  assert.doesNotMatch(w.api.state().note, /didn't start/);
});
test('an explicit incoming Answer has the same bounded microphone-start failure', async () => {
  const media = deferred();
  const w = await world({ media: () => media.promise, terminateOnMediaFailure: true });
  await w.incoming(); w.$('answer').click(); await settle();
  await w.advance(15000);
  assert.equal(w.api.state().state, 'idle');
  assert.match(w.api.state().note, /microphone didn't start/);
  const late = w.stream(); media.resolve(late); await settle();
  assert.equal(late.track.stopped, true);
  assert.equal(w.calls.length, 0);
});
test('a timed-out attempt can retry without an old stream replacing the new one', async () => {
  const old = deferred(); let acquisitions = 0;
  const w = await world({ media: () => ++acquisitions === 1 ? old.promise : Promise.resolve(w.stream()) });
  w.dial('9196'); await settle(); await w.advance(15000);
  w.$('call').click(); await settle();
  assert.equal(w.calls.length, 1);
  const late = w.stream(); old.resolve(late); await settle();
  assert.equal(late.track.stopped, true);
  assert.equal(w.calls.length, 1);
});
test('SIP logging of configuration and transport payloads is disabled', async () => {
  const w = await world();
  assert.equal(w.users[0].opts.userAgentOptions.logConfiguration, false);
  assert.equal(w.users[0].opts.userAgentOptions.logBuiltinEnabled, false);
});

test('native microphone permission is requested only for an explicit call', async () => {
  const w = await world();
  assert.equal(w.nativeOps.includes('microphone.request'), false);
  w.dial('9196'); await settle();
  assert.equal(w.nativeOps.filter(op => op === 'microphone.request').length, 1);
  assert.equal(w.calls.length, 1);
});
test('native microphone denial is inline and leaves no number to auto-redial', async () => {
  let granted = false;
  const w = await world({ nativePermission: () => Promise.resolve({ state: granted ? 'granted' : 'denied' }) });
  w.dial('9196'); await settle();
  assert.equal(w.calls.length, 0);
  assert.equal(w.mediaRequests.length, 0);
  assert.match(w.api.state().note, /Microphone blocked/);
  assert.equal(w.nativeOps.includes('microphone'), false);
  granted = true; w.users[0].delegate.onRegistered(); await settle();
  assert.equal(w.calls.length, 0);
  w.$('call').click(); await settle();
  assert.equal(w.calls.length, 1);
});
test('hiding during native permission cancels the request before any capture or INVITE', async () => {
  const permission = deferred();
  const w = await world({ nativePermission: () => permission.promise });
  w.dial('9196'); await settle();
  assert.match(w.api.state().note, /Allow Search/);
  await w.api.setVisible(false); permission.resolve({ state: 'granted' }); await settle();
  await w.advance(20000);
  assert.equal(w.calls.length, 0);
  assert.equal(w.mediaRequests.length, 0);
  assert.doesNotMatch(w.api.state().note, /didn't start/);
});
test('explicit incoming Answer requests native permission and respects denial', async () => {
  const w = await world({ nativePermission: () => Promise.resolve({ state: 'denied' }) });
  await w.incoming();
  assert.equal(w.nativeOps.includes('microphone.request'), false);
  w.$('answer').click(); await settle();
  assert.equal(w.nativeOps.filter(op => op === 'microphone.request').length, 1);
  assert.equal(w.answers.length, 0);
  assert.equal(w.mediaRequests.length, 0);
  assert.match(w.api.state().note, /Microphone blocked/);
});

test('a media timeout offers recovery once; Cancel sends no INVITE', async () => {
  const media = deferred();
  const w = await world({ media: () => media.promise, recovery: () => Promise.resolve({ state: 'denied' }) });
  w.dial('9196'); await settle(); await w.advance(15000);
  assert.equal(w.nativeOps.filter(op => op === 'microphone.recover').length, 1);
  assert.equal(w.calls.length, 0);
  assert.equal(w.api.state().state, 'idle');
  const late = w.stream(); media.resolve(late); await settle();
  assert.equal(late.track.stopped, true);
  assert.equal(w.calls.length, 0);
});
test('Allow retries the same frozen Numero destination and line once', async () => {
  const first = deferred(); let acquisitions = 0;
  const w = await world({ config: { ...numeroNumbers, numeroLine: 'ca' },
    media: () => ++acquisitions === 1 ? first.promise : Promise.resolve(w.stream()), recovery: () => Promise.resolve({ state: 'granted' }) });
  w.dial('+442079460958'); await settle(); await w.advance(15000);
  assert.equal(w.nativeOps.filter(op => op === 'microphone.recover').length, 1);
  assert.equal(w.mediaRequests.length, 2);
  assert.equal(w.calls.length, 1);
  assert.equal(w.calls[0], 'sip:numero-ca-442079460958@old.invalid');
  assert.ok(w.invites[0].options.extraHeaders.includes('X-Numero-Line: ca'));
  const late = w.stream(); first.resolve(late); await settle();
  assert.equal(late.track.stopped, true);
  assert.equal(w.calls.length, 1);
});
test('a second media failure never starts a recovery prompt loop', async () => {
  const w = await world({ media: () => new Promise(() => {}), recovery: () => Promise.resolve({ state: 'granted' }) });
  w.dial('9196'); await settle(); await w.advance(30000);
  assert.equal(w.nativeOps.filter(op => op === 'microphone.recover').length, 1);
  assert.equal(w.mediaRequests.length, 2);
  assert.equal(w.calls.length, 0);
  assert.equal(w.api.state().state, 'idle');
});
test('a denied preflight can recover only after explicit Allow', async () => {
  let allowed = false;
  const w = await world({ nativePermission: () => Promise.resolve({ state: allowed ? 'granted' : 'denied' }),
    recovery: () => { allowed = true; return Promise.resolve({ state: 'granted' }); } });
  w.dial('9196'); await settle();
  assert.equal(w.nativeOps.filter(op => op === 'microphone.recover').length, 1);
  assert.equal(w.nativeOps.filter(op => op === 'microphone.request').length, 2);
  assert.equal(w.calls[0], 'sip:9196@old.invalid');
});
test('NotAllowed media failure also offers one approved retry', async () => {
  let acquisitions = 0;
  const w = await world({ terminateOnMediaFailure: true,
    media: () => ++acquisitions === 1 ? Promise.reject(new DOMException('not allowed', 'NotAllowedError')) : Promise.resolve(w.stream()),
    recovery: () => Promise.resolve({ state: 'granted' }) });
  w.dial('9196'); await settle();
  assert.equal(w.nativeOps.filter(op => op === 'microphone.recover').length, 1);
  assert.equal(w.calls[0], 'sip:9196@old.invalid');
});
test('hiding while a recovery decision is pending never retries the call', async () => {
  const choice = deferred();
  const w = await world({ media: () => new Promise(() => {}), recovery: () => choice.promise });
  w.dial('9196'); await settle(); await w.advance(15000);
  await w.api.setVisible(false); choice.resolve({ state: 'granted' }); await settle();
  assert.equal(w.calls.length, 0);
  assert.equal(w.mediaRequests.length, 1);
});
test('Hang up while a recovery decision is pending invalidates its later Allow', async () => {
  const choice = deferred();
  const w = await world({ media: () => new Promise(() => {}), recovery: () => choice.promise });
  w.dial('9196'); await settle(); await w.advance(15000);
  await w.api.hangup(); choice.resolve({ state: 'granted' }); await settle();
  assert.equal(w.calls.length, 0);
  assert.equal(w.mediaRequests.length, 1);
});
test('changing the selected Numero line cancels a pending approved retry', async () => {
  const choice = deferred();
  const w = await world({ config: { ...numeroNumbers, numeroLine: 'ca' }, media: () => new Promise(() => {}), recovery: () => choice.promise });
  w.dial(); await settle(); await w.advance(15000);
  w.pickProvider('numero-us'); choice.resolve({ state: 'granted' }); await settle();
  assert.equal(w.calls.length, 0);
  assert.equal(w.mediaRequests.length, 1);
});
test('reconfiguring the seat cancels a pending approved retry', async () => {
  const choice = deferred();
  const w = await world({ media: () => new Promise(() => {}), recovery: () => choice.promise });
  w.dial('9196'); await settle(); await w.advance(15000);
  await w.settings({ domain: 'changed.invalid' }); choice.resolve({ state: 'granted' }); await settle();
  assert.equal(w.calls.length, 0);
  assert.equal(w.mediaRequests.length, 1);
});
test('an approved retry waits for the failed SIP session to finish closing', async () => {
  const cleanup = deferred(), first = deferred(); let acquisitions = 0;
  const w = await world({ hangup: () => cleanup.promise,
    media: () => ++acquisitions === 1 ? first.promise : Promise.resolve(w.stream()), recovery: () => Promise.resolve({ state: 'granted' }) });
  w.dial('9196'); await settle(); await w.advance(15000);
  assert.equal(w.mediaRequests.length, 1);
  assert.equal(w.calls.length, 0);
  assert.match(w.api.state().note, /Finishing the previous call/);
  cleanup.resolve(); await settle();
  assert.equal(w.mediaRequests.length, 2);
  assert.equal(w.calls[0], 'sip:9196@old.invalid');
});
test('stalled SIP cleanup refuses a retry rather than overlapping sessions', async () => {
  const cleanup = deferred();
  const w = await world({ hangup: () => cleanup.promise, media: () => new Promise(() => {}), recovery: () => Promise.resolve({ state: 'granted' }) });
  w.dial('9196'); await settle(); await w.advance(20000);
  assert.equal(w.mediaRequests.length, 1);
  assert.equal(w.calls.length, 0);
  assert.match(w.api.state().note, /previous call is still closing/);
  cleanup.resolve(); await settle();
  assert.equal(w.mediaRequests.length, 1);
});
test('incoming preflight recovery answers only its original still-owned call', async () => {
  let allowed = false;
  const w = await world({ nativePermission: () => Promise.resolve({ state: allowed ? 'granted' : 'denied' }),
    recovery: () => { allowed = true; return Promise.resolve({ state: 'granted' }); } });
  await w.incoming(); w.$('answer').click(); await settle();
  assert.equal(w.nativeOps.filter(op => op === 'microphone.recover').length, 1);
  assert.equal(w.answers.length, 1);
  assert.equal(w.api.state().state, 'incall');
});
test('an old incoming recovery approval never answers a replacement call', async () => {
  const choice = deferred();
  const w = await world({ terminateOnMediaFailure: true, media: () => Promise.reject(new DOMException('not allowed', 'NotAllowedError')), recovery: () => choice.promise });
  await w.incoming(); w.$('answer').click(); await settle();
  assert.equal(w.answers.length, 1);
  await w.incoming(); choice.resolve({ state: 'granted' }); await settle();
  assert.equal(w.answers.length, 1);
  assert.equal(w.api.state().state, 'incoming');
});

// Ofcom's reserved mobile drama range; this is not an owned or live number.
const telicallNumber = '+447700900123';
test('the configured UK choice stays on Telicall numeric routing', async () => {
  const w = await world({ config: { ...numeroNumbers, telicallUK: telicallNumber } });
  assert.match(w.$('telicallUK').textContent, /\+447700900123/);
  assert.equal(w.$('telicallUK').getAttribute('data-flag'), 'GB');
  assert.match(w.$('telicallUK').getAttribute('aria-label'), /^Telicall UK · \+447700900123/);
  w.pickProvider('telicall');
  assert.equal(w.$('providerLbl').textContent, 'UK');
  assert.equal(w.storage.provider, 'telicall');
  w.dial('+442079460958'); await settle();
  assert.equal(w.calls[0], 'sip:%2B442079460958@old.invalid');
  assert.deepEqual(Array.from(w.invites[0].options.extraHeaders), ['X-Provider: telicall']);
  await w.api.hangup(); await w.flushRecords();
  assert.equal(w.storage.history[0].telicallLine, 'uk');
  assert.equal(w.storage.history[0].fromNumber, telicallNumber);
  assert.equal(w.records[0].telicallLine, 'uk');
  assert.equal(w.records[0].fromNumber, telicallNumber);
  assert.equal(w.records[0].numeroLine, undefined);
});
test('a configured Telicall UK number stays frozen through media startup', async () => {
  const media = deferred();
  const w = await world({ config: { provider: 'telicall', telicallUK: telicallNumber }, media: () => media.promise });
  w.dial(); await settle();
  await w.settings({ telicallUK: '+447700900124' });
  assert.equal(w.users.length, 1, 'a UK label change must not reconnect the SIP seat');
  media.resolve(w.stream()); await settle();
  assert.equal(w.calls[0], 'sip:%2B442079460958@old.invalid');
  await w.api.hangup(); await w.flushRecords();
  assert.equal(w.records[0].telicallLine, 'uk');
  assert.equal(w.records[0].fromNumber, telicallNumber);
});
test('UK Recents restores the Telicall provider without becoming Numero', async () => {
  const w = await world({ config: { ...numeroNumbers, provider: 'telicall', telicallUK: telicallNumber } });
  w.dial(); await settle(); await w.api.hangup(); await w.flushRecords();
  w.pickProvider('numero-ca'); w.recent(); await settle();
  assert.equal(w.calls.length, 2);
  assert.equal(w.calls[1], 'sip:%2B442079460958@old.invalid');
  assert.deepEqual(Array.from(w.invites[1].options.extraHeaders), ['X-Provider: telicall']);
  assert.equal(w.storage.provider, 'telicall');
  assert.equal(w.$('providerLbl').textContent, 'UK');
});
test('UK Recents requires a fresh Call when the configured UK number changes', async () => {
  const w = await world({ config: { provider: 'telicall', telicallUK: telicallNumber } });
  w.dial(); await settle(); await w.api.hangup(); await w.flushRecords();
  await w.settings({ telicallUK: '+447700900124' });
  w.recent(); await settle();
  assert.equal(w.calls.length, 1);
  assert.match(w.api.state().note, /UK number changed/);
  w.$('call').click(); await settle();
  assert.equal(w.calls.length, 2);
});
test('an invalid nonempty UK number is disabled and cannot silently use a legacy line', async () => {
  for (const telicallUK of ['+12025550123', '+4407700900123', '+4477', '+447700900123\r\nX-Caller-ID: other']) {
    const w = await world({ config: { provider: 'telicall', telicallUK } });
    assert.equal(w.$('telicallUK').disabled, true);
    w.dial(); await settle();
    assert.equal(w.calls.length, 0);
    assert.equal(w.mediaRequests.length, 0);
    assert.match(w.api.state().note, /valid UK number/);
  }
});
test('UK number changes invalidate a pending microphone-recovery approval', async () => {
  const choice = deferred();
  const w = await world({ config: { provider: 'telicall', telicallUK: telicallNumber }, media: () => new Promise(() => {}), recovery: () => choice.promise });
  w.dial(); await settle(); await w.advance(15000);
  await w.settings({ telicallUK: '+447700900124' });
  choice.resolve({ state: 'granted' }); await settle();
  assert.equal(w.calls.length, 0);
  assert.equal(w.mediaRequests.length, 1);
});
test('a seat configuration refresh preserves the independent UK line field', async () => {
  const w = await world({ config: { ...numeroNumbers, provider: 'telicall', telicallUK: telicallNumber } });
  await w.settings({ password: 'synthetic-new' });
  w.dial(); await settle(); await w.api.hangup(); await w.flushRecords();
  assert.equal(w.calls[0], 'sip:%2B442079460958@old.invalid');
  assert.equal(w.records[0].telicallLine, 'uk');
  assert.equal(w.records[0].fromNumber, telicallNumber);
});
test('historical UK metadata is preserved and mixed-provider metadata is discarded', async () => {
  const w = await world({ config: { telicallUK: '+447700900124' } });
  const record = { id: 'old-uk-call', number: '+442079460958', outcome: 'answered', startedAt: 1, endedAt: 2,
    telicallLine: 'uk', fromNumber: telicallNumber };
  const clean = w.Calls.clean(record);
  assert.equal(clean.telicallLine, 'uk');
  assert.equal(clean.fromNumber, telicallNumber);
  assert.equal(clean.numeroLine, undefined);
  for (const bad of [{ ...record, numeroLine: 'us' }, { ...record, fromNumber: '+12025550123' }, { ...record, telicallLine: 'uk\r\nother' }]) {
    const clean = w.Calls.clean(bad);
    assert.equal(clean.fromNumber, undefined);
    assert.equal(clean.telicallLine, undefined);
    assert.equal(clean.numeroLine, undefined);
  }
});

function proxyCallRoute(overrides = {}) {
  return { mode: 'proxy', revision: 'synthetic-route-1', turnURL: 'turn:127.0.0.1:49152?transport=tcp',
    username: 'synthetic-turn-user', credential: 'synthetic-turn-password', expiresAt: Date.now() / 1000 + 3600, ...overrides };
}
test('explicit direct mode removes every default STUN server before peer construction', async () => {
  const w = await world(); w.dial('9196'); await settle();
  assert.equal(w.peers.length, 1);
  assert.equal(w.peers[0].configuration.iceTransportPolicy, 'all');
  assert.equal(w.peers[0].configuration.iceServers.length, 0);
  assert.equal(w.peers[0].configuration.iceCandidatePoolSize, 0);
});
test('proxy mode constructs a relay-only peer using only the native loopback TCP TURN route', async () => {
  const route = proxyCallRoute();
  const w = await world({ config: { protectedRoute: route } });
  const prePeer = w.users[0].opts.userAgentOptions.sessionDescriptionHandlerFactoryOptions.peerConnectionConfiguration;
  assert.equal(prePeer.iceTransportPolicy, 'relay');
  w.dial('9196'); await settle();
  const config = w.peers[0].configuration;
  assert.equal(config.iceTransportPolicy, 'relay');
  assert.equal(config.iceCandidatePoolSize, 0);
  assert.equal(config.iceServers.length, 1);
  assert.equal(config.iceServers[0].urls, route.turnURL);
  assert.equal(config.iceServers[0].username, route.username);
  assert.equal(config.iceServers[0].credential, route.credential);
});
test('missing, blocked, malformed and expired routes cannot start SIP, a peer, or microphone access', async () => {
  const invalid = [undefined, { mode: 'blocked', error: 'The proxy tunnel is unavailable' }, { mode: 'unknown' },
    proxyCallRoute({ turnURL: 'turn:localhost:49152?transport=tcp' }),
    proxyCallRoute({ turnURL: 'turn:owned-server.invalid:3478?transport=tcp' }),
    proxyCallRoute({ turnURL: 'turns:127.0.0.1:49152?transport=tcp' }),
    proxyCallRoute({ turnURL: 'turn:127.0.0.1:49152?transport=udp' }),
    proxyCallRoute({ turnURL: 'turn:127.0.0.1:0?transport=tcp' }),
    proxyCallRoute({ turnURL: 'turn:127.0.0.1:65536?transport=tcp' }),
    proxyCallRoute({ turnURL: ['turn:127.0.0.1:49152?transport=tcp', 'stun:outside.invalid'] }),
    proxyCallRoute({ revision: '' }), proxyCallRoute({ username: '' }), proxyCallRoute({ credential: '' }),
    proxyCallRoute({ expiresAt: Date.now() / 1000 - 1 }), proxyCallRoute({ expiresAt: 'tomorrow' })];
  for (const protectedRoute of invalid) {
    const w = await world({ config: { protectedRoute } }); w.dial('9196'); await settle();
    assert.equal(w.users.length, 0);
    assert.equal(w.peers.length, 0);
    assert.equal(w.mediaRequests.length, 0);
    assert.equal(w.nativeOps.includes('microphone.request'), false);
    assert.equal(w.api.state().status, 'Calls paused');
  }
});
test('incomplete SIP configuration still reports Not configured without making any connection', async () => {
  const w = await world({ config: { user: '', protectedRoute: { mode: 'blocked' } } });
  assert.equal(w.api.state().status, 'Not configured');
  assert.equal(w.users.length, 0);
  assert.equal(w.peers.length, 0);
});
test('caller-provided SDH options cannot introduce STUN, direct policy, or candidate prewarming', async () => {
  const route = proxyCallRoute();
  const w = await world({ config: { protectedRoute: route } });
  w.makeHandler({ peerConnectionConfiguration: { iceTransportPolicy: 'all', iceCandidatePoolSize: 8,
    iceServers: [{ urls: 'stun:outside.invalid' }, { urls: 'turn:outside.invalid' }] } });
  const config = w.peers[0].configuration;
  assert.equal(config.iceTransportPolicy, 'relay');
  assert.equal(config.iceCandidatePoolSize, 0);
  assert.equal(config.iceServers.length, 1);
  assert.equal(config.iceServers[0].urls, route.turnURL);
});
test('a WebRTC engine that fails to preserve relay-only policy is closed without fallback', async () => {
  const w = await world({ config: { protectedRoute: proxyCallRoute() }, enginePolicy: 'all' });
  w.dial('9196'); await settle();
  assert.equal(w.peers.length, 1);
  assert.equal(w.peers[0].closed, true);
  assert.equal(w.mediaRequests.length, 0);
  assert.equal(w.calls.length, 0);
  assert.equal(w.users.length, 1);
  assert.equal(w.users[0].disconnected, true);
  assert.equal(w.api.state().status, 'Calls paused');
});
test('protected route changes close every old peer before disconnecting SIP', async () => {
  const w = await world({ config: { protectedRoute: proxyCallRoute() } });
  w.dial('9196'); await settle(); w.users[0].delegate.onCallAnswered();
  w.makeHandler(); // models an additional provisional/early-media session handler
  await w.settings({ protectedRoute: { mode: 'blocked', error: 'The proxy tunnel stopped' } });
  assert.equal(w.peers.length, 2);
  assert.ok(w.peers.every(peer => peer.closed));
  assert.equal(w.users[0].disconnected, true);
  const disconnect = w.networkEvents.indexOf('disconnect');
  assert.ok(w.networkEvents.slice(0, disconnect).filter(event => event === 'peer-close').length === 2);
  assert.equal(w.users.length, 1);
  assert.match(w.api.state().note, /proxy tunnel stopped/);
});
test('an old factory cannot create a peer or tear down a newer valid route', async () => {
  const w = await world({ config: { protectedRoute: proxyCallRoute() } });
  const old = w.users[0];
  await w.settings({ protectedRoute: proxyCallRoute({ revision: 'synthetic-route-2', turnURL: 'turn:127.0.0.1:49153?transport=tcp' }) });
  assert.equal(w.users.length, 2);
  assert.throws(() => w.makeHandler(undefined, old), /route changed or expired/);
  assert.equal(w.peers.length, 0);
  assert.equal(w.users[1].disconnected, undefined);
  w.dial('9196'); await settle();
  assert.equal(w.calls.length, 1);
  assert.equal(w.peers[0].configuration.iceServers[0].urls, 'turn:127.0.0.1:49153?transport=tcp');
});
test('an expired idle lease disconnects and cannot start another call', async () => {
  const w = await world({ config: { protectedRoute: proxyCallRoute({ expiresAt: Date.now() / 1000 + 2 }) } });
  await w.advance(2500); w.dial('9196'); await settle();
  assert.equal(w.users[0].disconnected, true);
  assert.equal(w.peers.length, 0);
  assert.equal(w.calls.length, 0);
  assert.match(w.api.state().note, /expired/);
});
test('credential expiry preserves an established relay call but forbids new peers and closes at hangup', async () => {
  const w = await world({ config: { protectedRoute: proxyCallRoute({ expiresAt: Date.now() / 1000 + 80 }) } });
  w.dial('9196'); await settle(); w.users[0].delegate.onCallAnswered();
  await w.advance(80500);
  assert.equal(w.api.state().state, 'incall');
  assert.equal(w.peers[0].closed, false);
  assert.equal(w.users[0].disconnected, undefined);
  assert.throws(() => w.makeHandler(), /route changed or expired/);
  assert.equal(w.peers.length, 1);
  assert.equal(w.peers[0].closed, false);
  w.users[0].delegate.onRegistered();
  await w.settings({ numeroUS: numeroNumbers.numeroUS });
  assert.equal(w.api.state().state, 'incall');
  assert.equal(w.peers[0].closed, false);
  await w.api.hangup(); await settle();
  assert.equal(w.peers[0].closed, true);
  assert.equal(w.users[0].disconnected, true);
});
test('new dial requests and repeated incoming callbacks preserve an established call after credential expiry', async () => {
  const w = await world({ config: { protectedRoute: proxyCallRoute({ expiresAt: Date.now() / 1000 + 80 }) } });
  w.dial('9196'); await settle(); w.users[0].delegate.onCallAnswered();
  const session = w.users[0].session;
  await w.advance(80500);
  w.dial('+442079460958'); await settle();
  assert.equal(w.api.state().state, 'incall');
  assert.match(w.api.state().note, /Hang up to call/);
  assert.equal(w.calls.length, 1);
  assert.equal(w.peers.length, 1);
  assert.equal(w.peers[0].closed, false);
  await w.users[0].delegate.onCallReceived(); await settle();
  assert.equal(w.api.state().state, 'incall');
  assert.equal(w.users[0].session, session);
  assert.equal(w.users[0].declines, undefined);
  assert.equal(w.users[0].disconnected, undefined);
  assert.equal(w.peers[0].closed, false);
  assert.equal(w.answers.length, 0);
});
test('a route change invalidates a pending microphone-recovery approval', async () => {
  const choice = deferred();
  const w = await world({ config: { protectedRoute: proxyCallRoute() }, media: () => new Promise(() => {}), recovery: () => choice.promise });
  w.dial('9196'); await settle(); await w.advance(15000);
  await w.settings({ protectedRoute: proxyCallRoute({ revision: 'synthetic-route-2' }) });
  choice.resolve({ state: 'granted' }); await settle();
  assert.equal(w.calls.length, 0);
  assert.equal(w.mediaRequests.length, 1);
  assert.ok(w.peers.every(peer => peer.closed));
});
test('the shipped SIP.js factory replaces its Google default when an explicit ICE array is provided', () => {
  const made = [];
  const context = { console, MediaStream: class {}, RTCPeerConnection: class {
    constructor(config) { made.push(config); }
    getReceivers() { return []; } getSenders() { return []; } close() {}
  } };
  context.window = context; vm.createContext(context);
  vm.runInContext(fs.readFileSync(path.join(files, 'vendor', 'sip.min.js'), 'utf8'), context);
  const session = { userAgent: { getLogger: () => ({ debug() {} }) } };
  const factory = context.SIP.Web.defaultSessionDescriptionHandlerFactory(() => Promise.resolve());
  factory(session, { peerConnectionConfiguration: { iceTransportPolicy: 'relay', iceServers: [{ urls: 'turn:127.0.0.1:49152?transport=tcp' }] } }).close();
  factory(session, { peerConnectionConfiguration: { iceTransportPolicy: 'all', iceServers: [] } }).close();
  assert.equal(made[0].iceTransportPolicy, 'relay');
  assert.equal(made[0].iceServers.length, 1);
  assert.equal(made[0].iceServers[0].urls, 'turn:127.0.0.1:49152?transport=tcp');
  assert.equal(made[1].iceServers.length, 0);
});
test('new calls and peers require a sixty-second TURN credential margin', async () => {
  const w = await world({ config: { protectedRoute: proxyCallRoute({ expiresAt: Date.now() / 1000 + 30 }) } });
  assert.equal(w.users.length, 1);
  assert.throws(() => w.makeHandler(), /needs to refresh/);
  assert.equal(w.peers.length, 0);
  assert.match(w.api.state().note, /needs to refresh/);
  const call = await world({ config: { protectedRoute: proxyCallRoute({ expiresAt: Date.now() / 1000 + 30 }) } });
  call.dial('9196'); await settle();
  assert.equal(call.peers.length, 0);
  assert.equal(call.mediaRequests.length, 0);
  assert.equal(call.calls.length, 0);
  assert.match(call.api.state().note, /needs to refresh/);
});
