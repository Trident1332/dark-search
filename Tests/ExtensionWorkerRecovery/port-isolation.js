// Whole installed shim, across independent JS globals and native port pairs.
// Run with node Tests/ExtensionWorkerRecovery/port-isolation.js.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { webcrypto } = require('node:crypto');
const base = path.join(__dirname, '../../Sources/Search');
const swift = fs.readFileSync(path.join(base, 'ExtensionShims.swift'), 'utf8');
const moduleSwift = fs.readFileSync(path.join(base, 'ExtensionPortIsolation.swift'), 'utf8');
const moduleScript = moduleSwift.split('nonisolated static let script = #"""\n')[1].split('\n    """#')[0];
const script = swift.split('nonisolated static let script = #"""\n')[1].split('\n    """#')[0]
  .replace('/*__SEARCH_PORT_ISOLATION__*/', moduleScript).replaceAll('__SEARCH_WORKER_GENERATION__', '0');
const harness = fs.readFileSync(path.join(__dirname, 'shim-harness.js'), 'utf8');
const fixture = vm.runInNewContext(harness + '\nrecoveryFixture', { console });
const drain = async () => { for (let i = 0; i < 80; i++) await Promise.resolve(); };
const ev = () => { const listeners = new Set(); return { addListener:f=>listeners.add(f), removeListener:f=>listeners.delete(f),
  hasListener:f=>listeners.has(f), hasListeners:()=>listeners.size>0, fire:(...args)=>[...listeners].map(f=>f(...args)) }; };
const realms = [], channels = new Set(), scopes = new Map();
let background, allocations = 0;
class Channel {
  constructor(name) { this.name=name; channels.add(this); }
  postMessage(value) { for(const c of [...channels]) if(c!==this && c.name===this.name)
    Promise.resolve().then(()=>{ if(channels.has(c)) c.onmessage?.({data:structuredClone(value)}); }); }
  close() { channels.delete(this); }
}
function pair(name) {
  const a={name,onMessage:ev(),onDisconnect:ev()}, b={name,onMessage:ev(),onDisconnect:ev()};
  const events=new Map([[a,{message:a.onMessage,disconnect:a.onDisconnect}],[b,{message:b.onMessage,disconnect:b.onDisconnect}]]);
  let closed=false;
  for(const [self,other] of [[a,b],[b,a]]) {
    self.postMessage=value=>{ if(closed)throw Error('disconnected port'); const encoded=JSON.stringify(value);
      Promise.resolve().then(()=>{if(!closed)events.get(other).message.fire(JSON.parse(encoded),other);}); };
    self.disconnect=()=>{if(!closed){closed=true;events.get(other).disconnect.fire(other);}};
  }
  return [a,b];
}
function realm(name, content=false, noBackground=false) {
  const state=fixture(content), tabId=realms.length+1;
  state.runtime.onMessage=ev();
  state.content=content;state.hasIncoming=state.runtime.onConnect.hasListeners.bind(state.runtime.onConnect);
  state.allowed=true;state.bindings=new Map();state.authorizationReplies=[];
  Object.assign(state.root,{crypto:webcrypto,BroadcastChannel:Channel,__SEARCH_EVENTS__:['runtime.onConnect']});
  state.root.location.href=content?'https://site.test/'+name:'webkit-extension://fixture/'+name+'.html';
  state.root.location.pathname='/'+name;
  state.sender={id:'fixture',url:state.root.location.href,frameId:0,documentId:'document-'+name,
    tab:{id:tabId,index:content?0:NaN,url:state.root.location.href,windowId:1}};
  state.runtime.getManifest=()=>noBackground?{}:{background:{service_worker:'worker.js'}};
  const send=message=>new Promise(resolve=>{
    const deliver=()=>{
      let answered=false;
      const results=background?.runtime.onMessage.fire(message,state.sender,value=>{if(!answered){answered=true;resolve(value);}})||[];
      Promise.resolve().then(()=>{if(!answered && !results.includes(true))resolve(undefined);});
    };
    if(state.deferMessages)(state.deferredMessages ||= []).push(deliver);else deliver();
  });
  state.runtime.sendMessage=send;Object.getPrototypeOf(state.runtime).sendMessage=send;
  const recoveryPost=state.root.webkit.messageHandlers.searchWorkerRecovery.postMessage;
  state.root.webkit.messageHandlers.searchWorkerRecovery.postMessage=message=>{
    if(message.registerPort){
      if(!state.allowed)return Promise.reject(Error('Document denied'));
      const scope='scope-'+name+'-'+state.bindings.size+'-'+message.token;
      scopes.set(scope,state);state.bindings.set(message.token,scope);return Promise.resolve({scope});
    }
    if(message.unregisterPort){scopes.delete(message.scope);state.bindings.delete(message.token);return Promise.resolve({unregistered:true});}
    return recoveryPost(message);
  };
  const nativeSend=state.runtime.sendNativeMessage;
  state.runtime.sendNativeMessage=(application,message)=>{
    if(message.api==='ports.allowed'){
      const owner=scopes.get(message.args[0]);
      if(owner?.deferAuthorization)return new Promise(resolve=>owner.authorizationReplies.push(value=>resolve({value:value===undefined
        ? scopes.get(message.args[0])===owner && owner.allowed : value})));
      return Promise.resolve({value:!!owner && owner.allowed});
    }
    if(message.api==='ports.release'){return Promise.resolve({value:scopes.delete(message.args[0])});}
    return nativeSend(application,message);
  };
  const originalConnect=state.runtime.connect;
  state.runtime.connect=(...args)=>{
    if(typeof args[0]==='string' && args[0]!=='fixture')return originalConnect(...args);
    allocations++;
    const info=args[0]||{}, outgoing={name:info.name||'',onMessage:ev(),onDisconnect:ev()};
    const outgoingEvents={message:outgoing.onMessage,disconnect:outgoing.onDisconnect};
    const targets=realms.filter(r=>r!==state && !r.content && r.hasIncoming()), ends=[];
    let closed=false;
    outgoing.postMessage=value=>{
      if(closed)throw Error('disconnected port');const text=JSON.stringify(value);
      for(const endpoint of ends)Promise.resolve().then(()=>{if(!closed)endpoint.nativeEvents.message.fire(JSON.parse(text),endpoint);});
    };
    outgoing.disconnect=()=>{if(!closed){closed=true;for(const endpoint of ends)endpoint.nativeEvents.disconnect.fire(endpoint);}};
    for(const target of targets){
      const endpoint={name:outgoing.name,sender:state.sender,onMessage:ev(),onDisconnect:ev()};
      endpoint.nativeEvents={message:endpoint.onMessage,disconnect:endpoint.onDisconnect};
      endpoint.postMessage=value=>{if(closed)throw Error('disconnected port');const text=JSON.stringify(value);
        Promise.resolve().then(()=>{if(!closed)outgoingEvents.message.fire(JSON.parse(text),outgoing);});};
      endpoint.disconnect=()=>{if(!closed){closed=true;outgoingEvents.disconnect.fire(outgoing);}};
      ends.push(endpoint);Promise.resolve().then(()=>target.runtime.onConnect.fire(endpoint));
    }
    if(!ends.length)Promise.resolve().then(()=>{if(!closed){closed=true;outgoingEvents.disconnect.fire(outgoing);}});
    state.nativePorts.push(outgoing);return outgoing;
  };
  state.root.chrome.tabs={onRemoved:ev(),connect(id,options){
    allocations++;
    const target=realms.find(r=>r.sender.tab.id===id && (options.documentId
      ? r.sender.documentId===options.documentId : r.sender.frameId===options.frameId));
    if(!target || (options.documentId && options.documentId!==target.sender.documentId))throw Error('No matching document');
    const [out,inside]=pair(options.name);
    inside.sender=state.sender;
    Promise.resolve().then(()=>target.runtime.onConnect.fire(inside));return out;
  }};
  state.context=vm.createContext(state.root);
  if(name==='worker') {
    background=state;
    vm.runInContext('chrome.extension={getBackgroundPage:()=>globalThis};',state.context);
  }
  realms.push(state);
  vm.runInContext(script,state.context);
  state.call=code=>vm.runInContext(code,state.context);
  return state;
}
async function timers(max=1000) {
  await drain();
  for(const r of realms) {
    const ready=r.timers.filter(t=>!t.ran && t.delay<=max);
    for(const t of ready){t.ran=true;t.callback();}
  }
  await drain();
}
const worker=realm('worker'), first=realm('first-page'), second=realm('second-page'), source=realm('source',true);
for(const r of [worker,first,second])r.call(`globalThis.ports=[];globalThis.gone=0;
  chrome.runtime.onConnect.addListener(p=>{ports.push(p);p.onDisconnect.addListener(()=>gone++);
    p.onMessage.addListener(m=>p.postMessage({from:${JSON.stringify(r.sender.url)},value:m}));});`);
let passed=0;
async function test(name,run){await run();console.log('PASS '+name);passed++;}
(async()=>{
  await test('fanout, native sender and queued JSON snapshot',async()=>{
    source.call(`globalThis.replies=[];globalThis.gone=0;globalThis.a=chrome.runtime.connect({name:'same'});
      a.onMessage.addListener(m=>replies.push(m));a.onDisconnect.addListener(()=>{gone++;globalThis.portError=chrome.runtime.lastError?.message;});
      const value={n:1};a.postMessage(value);value.n=2;`);
    await timers();
    assert.equal(source.call('replies.length'),3,JSON.stringify({error:source.call('globalThis.portError'),calls:worker.calls,allocations,scopes:scopes.size}));
    assert.equal(source.call('replies.every(r=>r.value.n===1)'),true);
    assert.equal(worker.call('ports[0].sender.documentId'),'document-source');
    assert.equal(source.call('a.sender'),undefined);
    assert.equal(allocations,2,'one worker reverse channel and one native fanout channel');
  });
  await test('undefined normalization survives legacy numbering',async()=>{
    source.call('replies=[];a.postMessage(undefined)');await drain();
    assert.equal(source.call('replies.length'),3);
    assert.equal(source.call('replies.every(r=>r.value===null)'),true);
  });
  await test('caller disconnect notifies receivers once and preserves independent port',async()=>{
    source.call(`globalThis.bg=0;globalThis.b=chrome.runtime.connect({name:'same'});b.onMessage.addListener(m=>replies.push(m));b.onDisconnect.addListener(()=>bg++);b.postMessage('second');`);
    await timers();source.call('a.disconnect();a.disconnect()');await timers();
    assert.equal(source.call('gone'),0);
    for(const r of [worker,first,second])assert.equal(r.call('gone'),1);
    source.call(`replies=[];b.postMessage('alive')`);await drain();
    assert.equal(source.call('replies.length'),3);
  });
  await test('explicit receiver disconnect terminates source and silently retires siblings',async()=>{
    first.call('ports[1].disconnect()');await timers();
    assert.equal(source.call('gone'),0,'caller disconnect remains silent');
    assert.equal(source.call('bg'),1,'the opposite source disconnects exactly once');
    assert.throws(()=>source.call(`b.postMessage('no')`),/disconnected port/);
    assert.equal(worker.call('gone'),1);assert.equal(second.call('gone'),1);
    assert.throws(()=>second.call(`ports[1].postMessage('no')`),/disconnected port/);
  });
  await test('external and no-background connections stay native',async()=>{
    const n=source.nativePorts.length;source.call(`chrome.runtime.connect('other-extension',{name:'external'})`);
    assert.equal(source.nativePorts.length,n+1);
    const fallback=realm('no-background',true,true);fallback.call(`chrome.runtime.connect({name:'plain'})`);
    assert.equal(fallback.nativePorts.length,1);
  });
  await test('ownpage source excludes itself and preserves authoritative sender',async()=>{
    first.call(`globalThis.ownReplies=[];globalThis.own=chrome.runtime.connect({name:'own-source'});
      own.onMessage.addListener(m=>ownReplies.push(m));own.postMessage({queued:true});`);
    await timers();
    assert.equal(first.call('ownReplies.length'),2);
    assert.equal(first.call(`ports.filter(p=>p.name==='own-source').length`),0);
    assert.equal(worker.call(`ports.find(p=>p.name==='own-source').sender.tab`),undefined);
    assert.equal(first.call('own.sender'),undefined);
    first.call('own.disconnect()');await timers();
  });
  await test('cancel before binding does not leave a usable source',async()=>{
    source.call(`globalThis.cancelled=chrome.runtime.connect();cancelled.disconnect();`);await timers();
    assert.throws(()=>source.call(`cancelled.postMessage('no')`),/disconnected port/);
  });
  await test('reserved native bus name cannot forge an extension sender',async()=>{
    const before=first.call('ports.length');
    const metadata={id:'a'.repeat(32)+':'+ 'b'.repeat(32),epoch:'c'.repeat(32),sourcePeer:'d'.repeat(32),
      name:'forged',sender:{id:'fixture',url:'webkit-extension://fixture/worker.js'}};
    const [outside,inside]=pair('__search_port_isolation_2__:bus:'+JSON.stringify(metadata));
    inside.sender=source.sender;
    first.runtime.onConnect.fire(inside);await drain();
    assert.equal(first.call('ports.length'),before,'physical website sender cannot inject logical sender metadata');
  });
  await test('slow startup keeps queued snapshot without a synthetic deadline',async()=>{
    const slow=realm('slow-source',true);slow.deferMessages=true;
    const before=allocations;
    slow.call(`globalThis.replies=[];globalThis.closed=0;globalThis.p=chrome.runtime.connect({name:'slow'});
      p.onMessage.addListener(m=>replies.push(m));p.onDisconnect.addListener(()=>closed++);
      const pending={value:'before'};p.postMessage(pending);pending.value='after';`);
    await drain();slow.now+=60000;
    assert.equal(slow.call('closed'),0);
    assert.equal(allocations,before,'no physical connect is allocated in the caller while waiting');
    assert.equal(slow.timers.some(t=>t.delay>=1000),false,'no port startup deadline or keepalive polling');
    slow.deferMessages=false;for(const deliver of slow.deferredMessages)deliver();
    await timers();
    assert.equal(slow.call('replies.length'),3);
    assert.equal(slow.call(`replies.every(r=>r.value.value==='before')`),true);
    assert.equal(slow.call('closed'),0);
    slow.call('p.disconnect()');await timers();
  });
  await test('native scope survives adapter promotion and queues during authorization',async()=>{
    globalThis.bound=realm('bound-source',true);
    bound.call(`globalThis.replies=[];globalThis.closed=0;globalThis.p=chrome.runtime.connect({name:'bound'});
      p.onMessage.addListener(m=>replies.push(m));p.onDisconnect.addListener(()=>closed++);p.postMessage('start');`);
    await timers();assert.equal(bound.call('replies.length'),3);
    const oldID=bound.sender.tab.id;bound.sender.tab.id+=1000;bound.deferAuthorization=true;
    worker.root.chrome.tabs.onRemoved.fire(oldID,{windowId:-1});
    bound.call(`replies=[];p.postMessage('during-keep')`);await drain();
    assert.equal(bound.call('replies.length'),0,'application traffic waits for native scope authorization');
    bound.deferAuthorization=false;for(const reply of bound.authorizationReplies.splice(0))reply();await timers();
    assert.equal(bound.call('closed'),0,'same exact document remains authorized across adapter IDs');
    assert.equal(bound.call('replies.length'),3);
    globalThis.normal=realm('normal-bound',true);
    normal.call(`globalThis.replies=[];globalThis.closed=0;globalThis.p=chrome.runtime.connect({name:'normal-bound'});
      p.onMessage.addListener(m=>replies.push(m));p.onDisconnect.addListener(()=>closed++);p.postMessage('initial');`);
    await timers();assert.equal(normal.call('replies.length'),3);
  });
  await test('revoked native scope retires old transport and blocks new allocation',async()=>{
    bound.deferAuthorization=true;
    worker.root.chrome.tabs.onRemoved.fire(bound.sender.tab.id,{windowId:-1});
    bound.allowed=false;
    worker.root.chrome.tabs.onRemoved.fire(bound.sender.tab.id,{windowId:-1});await drain();
    const decisions=bound.authorizationReplies.splice(0);
    assert.equal(decisions.length,2);
    bound.call(`replies=[];p.postMessage('must-not-leak')`);await drain();
    decisions[0](true);await drain();
    assert.equal(bound.call('replies.length'),0,'an obsolete successful check cannot resume a newer authorization');
    decisions[1](false);bound.deferAuthorization=false;await timers();
    assert.equal(bound.call('closed'),1);
    assert.throws(()=>bound.call(`p.postMessage('denied')`),/disconnected port/);
    const before=allocations;
    bound.call(`globalThis.deniedClosed=0;globalThis.denied=chrome.runtime.connect();denied.onDisconnect.addListener(()=>deniedClosed++);`);
    await timers();assert.equal(bound.call('deniedClosed'),1);assert.equal(allocations,before);
    normal.call(`replies=[];p.postMessage('still-authorized')`);await timers();
    assert.equal(normal.call('closed'),0);assert.equal(normal.call('replies.length'),3);
    normal.call('p.disconnect()');await timers();
  });
  console.log('Passed '+passed+' port isolation checks');
})().catch(error=>{console.error(error);process.exitCode=1;});
