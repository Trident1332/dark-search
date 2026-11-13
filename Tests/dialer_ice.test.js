const test = require('node:test');
const assert = require('node:assert/strict');
const ICE = require('../Resources/Dialer/ice.js');
const empty = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nc=IN IP4 0.0.0.0\r\n';
const relay = empty + 'a=candidate:1 1 udp 2122260223 203.0.113.7 49162 typ relay raddr 192.168.4.2 rport 60000\r\n';
function handler(body = relay, state = 'complete') {
  const listeners = new Map();
  const peer = { iceGatheringState: state, connectionState: 'new', localDescription: { sdp: body },
    addEventListener(name, fn) { if (!listeners.has(name)) listeners.set(name,new Set()); listeners.get(name).add(fn); },
    removeEventListener(name, fn) { listeners.get(name)?.delete(fn); },
    emit(name) { for (const fn of listeners.get(name) || []) fn({}); }
  };
  const h = { peerConnection: peer, closed: false, settings: null,
    getDescription(settings) { this.settings = settings; return Promise.resolve({ body, contentType: 'application/sdp' }); },
    close() { this.closed = true; peer.connectionState = 'closed'; }
  };
  return h;
}
test('relay-only descriptions require a usable RTP candidate, not merely an audio m-line', () => {
  assert.equal(ICE.inspect(empty, true).usable, false);
  assert.equal(ICE.inspect(relay, true).usable, true);
  for (const body of [relay.replace(' typ relay',' typ host'), relay.replace(' typ relay',' typ srflx'), relay.replace('49162 typ','0 typ'), relay.replace('203.0.113.7','127.0.0.1'), relay.replace('203.0.113.7','machine.local'), relay.replace('c=IN IP4 0.0.0.0','c=IN IP4 192.168.4.2')]) {
    assert.equal(ICE.inspect(body, true).usable, false);
  }
});
test('inactive audio and RTCP-only candidates cannot start a call', () => {
  assert.equal(ICE.inspect(relay.replace('m=audio 9','m=audio 0'),true).usable,false);
  assert.equal(ICE.inspect(relay.replace('candidate:1 1 udp','candidate:1 2 udp'),true).usable,false);
});
test('IPv6 candidates are validated and malformed address strings are rejected', () => {
  assert.equal(ICE.inspect(relay.replaceAll('203.0.113.7','2001:db8::7'),true).usable,true);
  assert.equal(ICE.inspect(relay.replaceAll('203.0.113.7',':::bad'),true).usable,false);
});
test('protected SDP suppresses related interface metadata and overrides the short gathering budget', async () => {
  const h = handler(); ICE.guard(h,{relayOnly:true}); const d=await h.getDescription({iceGatheringTimeout:1});
  assert.equal(h.settings.iceGatheringTimeout,20000);
  assert.doesNotMatch(d.body,/192\.168\.4\.2|60000/);
  assert.match(d.body,/raddr 0\.0\.0\.0 rport 0/);
});
test('a zero-candidate complete offer fails before the caller can send it and closes the peer', async () => {
  const h=handler(empty); let failures=0; ICE.guard(h,{relayOnly:true,failed(){failures++;}});
  await assert.rejects(h.getDescription(),e=>e.name==='AudioRouteError');
  assert.equal(failures,1); assert.equal(h.closed,true);
});
test('late candidates replace a timed-out SIP description before it is released', async () => {
  const h=handler(empty,'gathering'); ICE.guard(h,{relayOnly:true,timeout:100});
  const d=h.getDescription(); await new Promise(r=>setImmediate(r));
  h.peerConnection.localDescription.sdp=relay; h.peerConnection.iceGatheringState='complete'; h.peerConnection.emit('icecandidate');
  assert.match((await d).body,/typ relay/);
});
test('a stalled peer has a bounded failure and no direct fallback', async () => {
  const h=handler(empty,'gathering'); ICE.guard(h,{relayOnly:true,timeout:15});
  await assert.rejects(h.getDescription(),e=>e.name==='AudioRouteError'); assert.equal(h.closed,true);
});
test('closing a handler cancels its pending description without reporting a network failure', async () => {
  const h=handler(empty,'gathering'); let failures=0; ICE.guard(h,{relayOnly:true,failed(){failures++;}});
  const pending=h.getDescription(); const result=assert.rejects(pending,e=>e.name==='AbortError');
  h.close(); await result; assert.equal(failures,0);
});
test('an invalidated route never returns a late ready description', async () => {
  const h=handler(empty,'gathering'); let current=true; ICE.guard(h,{relayOnly:true,current:()=>current,timeout:25});
  const pending=h.getDescription(); const result=assert.rejects(pending,e=>e.name==='AbortError'); await new Promise(r=>setImmediate(r));
  current=false; h.peerConnection.localDescription.sdp=relay; h.peerConnection.emit('icecandidate'); await result;
});
test('media permission errors retain their original type instead of being called relay failures', async () => {
  const h=handler(); const denied=new DOMException('synthetic denial','NotAllowedError'); h.getDescription=()=>Promise.reject(denied);
  let failures=0; ICE.guard(h,{relayOnly:true,failed(){failures++;}});
  await assert.rejects(h.getDescription(),e=>e===denied); assert.equal(failures,0);
});
test('errors never echo raw SDP or credentials', async () => {
  const h=handler(empty+'a=candidate:SECRET-DO-NOT-DISPLAY 1 udp 123 127.0.0.1 99 typ host\r\n'); ICE.guard(h,{relayOnly:true});
  await assert.rejects(h.getDescription(),e=>e.name==='AudioRouteError'&&!e.message.includes('SECRET'));
});
