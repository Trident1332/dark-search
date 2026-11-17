#!/usr/bin/env python3
"""The isolated extension transport respects private consent and Tor fences.

Build first, then python3 Tests/extension_port_isolation_private.py. Reuses
the simultaneous-port fixture and hidden harness. Consent is changed only
for this world's fixture extension. Tor is disabled before launch, so a
Tor conversion exercises its controller/privacy boundary without starting
Tor, contacting a relay or resolving an onion service.
"""
import hashlib
import json
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import extension_port_isolation as ports  # noqa: E402

sv = ports.sv
sv.use("port-private")

CONTENT = """
if (location.pathname.startsWith('/port-')) {
  const page=location.href, state={attempts:[],received:[],disconnected:[],postErrors:[],controls:0};
  const keep=new Map();
  function publish() { document.documentElement.setAttribute('data-port-privacy',JSON.stringify(state)); }
  function connect(channel) {
    state.attempts.push(channel); publish();
    try {
      const port=chrome.runtime.connect({name:channel}); keep.set(channel,port);
      port.onDisconnect.addListener(() => { state.disconnected.push(channel); publish(); });
      port.onMessage.addListener(message => {
        state.received.push({token:message.token,target:message.target,channel});publish();
        chrome.runtime.sendMessage({op:'delivery',page,channel,target:message.target,token:message.token}).catch(()=>{});
        if(message.target===page && message.kind==='probe') port.postMessage({kind:'reply',from:page,channel,token:message.token});
      });
      port.postMessage({kind:'hello',from:page,channel,token:'hello:'+channel});
      chrome.runtime.sendMessage({op:'ready',page,channel}).catch(()=>{});
    } catch(error) { state.postErrors.push(String(error));publish(); }
  }
  window.addEventListener('message',event => {
    if(event.source!==window || !event.data || event.data.__portPrivacy!=='reconnect') return;
    state.controls++;publish();
    connect('isolation:'+page+':retry-'+state.controls);
  });
  connect('isolation:'+page);
}
"""


def state(tab):
    raw=sv.ev(tab, "document.documentElement && document.documentElement.getAttribute('data-port-privacy')")
    return json.loads(raw) if raw else None


def current_tab(tab):
    return next(row for row in sv.cmd({"do":"tabs"})["tabs"] if row["id"]==tab)


def active_for(inspector,url):
    return [p for p in ports.snapshot(inspector)["ports"] if p["origin"]==url and p["active"]]


def connected(inspector,url):
    return ports.poll(lambda: ports.snapshot(inspector),
                      lambda s:any(p["origin"]==url and p["active"] for p in s["ports"]),
                      seconds=6,required=False)


def pulse(t,inspector,tab,url,label):
    token=label+':'+url
    sent=ports.command(inspector,{"op":"send","target":url,"token":token})
    t.ok(label+': worker can send',sent.get('sent'),sent)
    got=ports.poll(lambda:state(tab),
                   lambda s:s is not None and any(m['token']==token for m in s['received']),
                   seconds=3,required=False)
    t.ok(label+': intended document receives exactly one message',
         got is not None and len([m for m in got['received'] if m['token']==token])==1,got)
    reply=ports.poll(lambda:ports.snapshot(inspector),
                     lambda s:any(m.get('token')==token and m.get('kind')=='reply' for m in s['incoming']),
                     seconds=3,required=False)
    responses=[m for m in reply['incoming'] if m.get('token')==token and m.get('kind')=='reply']
    t.ok(label+': reply returns only on its own worker port',
         len(responses)==1 and responses[0]['origin']==url and responses[0]['from']==url,responses)


def main():
    binary=Path(sv.APP)/'Contents/MacOS/Search'
    print('Binary SHA256:',hashlib.sha256(binary.read_bytes()).hexdigest(),flush=True)
    t=sv.T();inspector=None
    try:
        sv.setup(sidebar=True,**{'onion.on':False})
        sv.launch()
        sv.page('home')
        with tempfile.TemporaryDirectory(prefix='port-private-ext-') as folder:
            files=dict(ports.FILES)
            manifest=json.loads(files['manifest.json']);manifest['name']='Port privacy fixture'
            files['manifest.json']=json.dumps(manifest);files['content.js']=CONTENT
            for name,content in files.items():Path(folder,name).write_text(content)
            sv.cmd({'do':'ext-folder','path':folder,'yes':True})
            loaded=ports.poll(lambda:sv.cmd({'do':'extensions'})['extensions'],
                              lambda es:any(e['name']=='Port privacy fixture' and e['loaded'] for e in es))
            ext=next(e['id'] for e in loaded if e['name']=='Port privacy fixture')
            inspector=sv.cmd({'do':'ext-page','id':ext,'path':'page.html'})['id']
            sv.cmd({'do':'wait','id':inspector,'seconds':10});sv.ev(inspector,ports.OWN_RECEIVER)
            t.ok('fixture starts without private consent',not next(e['private'] for e in loaded if e['id']==ext))

            normal_url=sv.BASE+'/port-normal'
            normal=sv.cmd({'do':'open','url':normal_url,'private':False})['id']
            connected(inspector,normal_url)
            normal_ids=[p['id'] for p in active_for(inspector,normal_url)]
            pulse(t,inspector,normal,normal_url,'normal before private consent')

            denied_url=sv.BASE+'/port-private-denied'
            denied=sv.cmd({'do':'open','url':denied_url,'private':True})['id']
            sv.cmd({'do':'wait','id':denied,'seconds':10})
            t.ok('denied private document has no extension controller',
                 current_tab(denied)['shy'] and not current_tab(denied)['extensions'])
            t.ok('denied private document has no content transport bootstrap',state(denied) is None)
            t.ok('denied private document never opens a worker channel',
                 not any(p['origin']==denied_url for p in ports.snapshot(inspector)['ports']))

            t.ok('individual private consent is granted',sv.cmd({'do':'ext-private','id':ext,'on':True})['private'])
            allowed_url=sv.BASE+'/port-private-allowed'
            allowed=sv.cmd({'do':'open','url':allowed_url,'private':True})['id']
            connected(inspector,allowed_url)
            t.ok('new allowed private document carries the controller',
                 current_tab(allowed)['shy'] and current_tab(allowed)['extensions'])
            t.ok('allowed private document has one live worker connection',len(active_for(inspector,allowed_url))==1)
            pulse(t,inspector,allowed,allowed_url,'private with consent')
            own=ports.poll(lambda:ports.own_snapshot(inspector),
                           lambda s:any(p['origin']==allowed_url and p['active'] for p in s['ports']),
                           seconds=3,required=False)
            t.ok('allowed private connection also reaches its own extension page',
                 any(p['origin']==allowed_url and p['active'] for p in own['ports']),own['ports'])

            # A private Keep changes its native adapter while retaining the
            # exact page. A second private peek remains windowless at revoke.
            sv.sp('select',id=allowed)
            kept_url=sv.BASE+'/port-private-kept'
            sv.cmd({'do':'peek','url':kept_url})
            connected(inspector,kept_url)
            kept_ids=[p['id'] for p in active_for(inspector,kept_url)]
            t.ok('allowed private peek has one live connection',len(kept_ids)==1)
            sv.cmd({'do':'ui','peeklink':'keep'})
            kept=ports.poll(lambda:sv.sp('state')['tabs'],lambda tabs:any(p['url']==kept_url for p in tabs))
            kept_id=next(p['id'] for p in kept if p['url']==kept_url)
            t.ok('kept private peek retains its private store',current_tab(kept_id)['shy'])
            pulse(t,inspector,kept_id,kept_url,'private after Keep')
            t.ok('private Keep preserves the original connection identity',
                 [p['id'] for p in active_for(inspector,kept_url)]==kept_ids)
            aside_url=sv.BASE+'/port-private-unkept'
            sv.cmd({'do':'peek','url':aside_url})
            connected(inspector,aside_url)
            t.ok('a second allowed private peek has one live connection',len(active_for(inspector,aside_url))==1)

            t.ok('individual private consent is revoked',not sv.cmd({'do':'ext-private','id':ext,'on':False})['private'])
            closed=ports.poll(lambda:ports.snapshot(inspector),
                              lambda s:any(p['origin']==allowed_url for p in s['disconnected']),seconds=4,required=False)
            t.ok('revocation disconnects the existing private worker channel',
                 any(p['origin']==allowed_url for p in closed['disconnected']) and not active_for(inspector,allowed_url),closed['ports'])
            own=ports.poll(lambda:ports.own_snapshot(inspector),
                           lambda s:any(p['origin']==allowed_url for p in s['disconnected']),seconds=3,required=False)
            t.ok('revocation retires its open-extension-page receiver too',
                 any(p['origin']==allowed_url for p in own['disconnected'])
                 and not any(p['origin']==allowed_url and p['active'] for p in own['ports']),own)
            for page in [kept_url,aside_url]:
                retired=ports.poll(lambda:ports.snapshot(inspector),
                                   lambda s:any(p['origin']==page for p in s['disconnected']),seconds=4,required=False)
                t.ok('revocation retires private aside/kept connection: '+page,
                     any(p['origin']==page for p in retired['disconnected']) and not active_for(inspector,page))
                receivers=ports.poll(lambda:ports.own_snapshot(inspector),
                                     lambda s:any(p['origin']==page for p in s['disconnected']),seconds=3,required=False)
                t.ok('revocation retires its private aside/kept extension-page receiver: '+page,
                     any(p['origin']==page for p in receivers['disconnected'])
                     and not any(p['origin']==page and p['active'] for p in receivers['ports']))
            sv.cmd({'do':'peek','url':'close'})

            old_receiver=sv.ev(inspector,"""(function(){
              const found=portReceiver.ports.find(p=>p.origin==="""+json.dumps(allowed_url)+""");
              if(!found)return {missing:true};
              try{found.port.postMessage({kind:'probe',target:"""+json.dumps(allowed_url)+""",token:'after-revoke'});return {threw:false};}
              catch(error){return {threw:true,error:String(error)};}
            })()""")
            t.ok('cached old receiver cannot send after revocation',old_receiver.get('threw') is True,old_receiver)
            before=state(allowed)
            sv.ev(allowed,"window.postMessage({__portPrivacy:'reconnect'},location.origin);true")
            attempted=ports.poll(lambda:state(allowed),
                                 lambda s:s is not None and before is not None and s['controls']>before['controls'],
                                 seconds=2,required=False)
            time.sleep(0.4)
            after=ports.snapshot(inspector)
            t.ok('reconnect from the revoked private document creates no live worker channel',
                 not any(p['origin']==allowed_url and p['active'] for p in after['ports']),{'content':attempted,'ports':after['ports']})
            t.ok('revoked private document receives no further old-channel delivery',
                 not any(m.get('token')=='after-revoke' for m in (state(allowed) or {}).get('received',[])))
            t.ok('normal peer keeps the same live worker connection',
                 [p['id'] for p in active_for(inspector,normal_url)]==normal_ids)
            pulse(t,inspector,normal,normal_url,'normal after private revocation')

            fresh_url=sv.BASE+'/port-private-after-revoke'
            fresh=sv.cmd({'do':'open','url':fresh_url,'private':True})['id']
            sv.cmd({'do':'wait','id':fresh,'seconds':10})
            t.ok('a new private document after revocation gets no controller or bootstrap',
                 not current_tab(fresh)['extensions'] and state(fresh) is None)
            t.ok('no fresh private worker channel is opened',
                 not any(p['origin']==fresh_url for p in ports.snapshot(inspector)['ports']))

            # A real tab conversion, but no Tor network: onion.on was false
            # before launch, so connect() rejects before starting a child.
            tor_source=sv.BASE+'/port-before-tor'
            tor=sv.cmd({'do':'open','url':tor_source,'private':False})['id']
            connected(inspector,tor_source)
            t.ok('Tor-conversion fixture first has a normal live connection',len(active_for(inspector,tor_source))==1)
            onion='http://'+'a'*56+'.onion/port-never-connected'
            sv.cmd({'do':'go','id':tor,'url':onion})
            descriptor=ports.poll(lambda:current_tab(tor),lambda tab:tab['url']==onion and not tab['extensions'],seconds=4,required=False)
            t.ok('Tor-converted view has no extension controller',descriptor['url']==onion and not descriptor['extensions'],descriptor)
            closed=ports.poll(lambda:ports.snapshot(inspector),
                              lambda s:any(p['origin']==tor_source for p in s['disconnected']),seconds=4,required=False)
            t.ok('Tor conversion retires its previous normal worker channel',
                 any(p['origin']==tor_source for p in closed['disconnected']) and not active_for(inspector,tor_source),closed['ports'])
            t.ok('Tor document cannot allocate a new worker channel',
                 not any(p['origin']==onion for p in ports.snapshot(inspector)['ports']))
            pulse(t,inspector,normal,normal_url,'normal after Tor conversion')
            print('FINAL SNAPSHOT',json.dumps(ports.snapshot(inspector)),flush=True)
    except Exception as error:
        t.ok('private transport probe completes',False,str(error))
        if inspector:
            try:print('FAILURE SNAPSHOT',json.dumps(ports.snapshot(inspector)),flush=True)
            except Exception:pass
    finally:sv.finish()
    t.done()
    return 1 if t.failed else 0


if __name__=='__main__':
    sys.exit(main())
