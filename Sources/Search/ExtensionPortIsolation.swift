import Foundation

/// Allocate physical runtime channels in the extension's background process.
/// WebKit's process-local identifiers otherwise collide in its shared router.
/// Native worker-origin runtime.connect retains native receiver discovery and
/// queueing; tabs.connect is the private return path to a content document.
enum ExtensionPortIsolation {
    nonisolated static let script = #"""
      (() => {
        if (!hasWorker || !runtime || typeof runtime.connect !== "function" || typeof runtime.sendMessage !== "function"
            || !runtime.onConnect || !root.crypto || typeof root.crypto.getRandomValues !== "function") return;
        const protocol = "search.port-isolation/2", prefix = "__search_port_isolation_2__:";
        const token = () => [...root.crypto.getRandomValues(new Uint32Array(4))].map(n => n.toString(16).padStart(8, "0")).join("");
        const peer = token(), epoch = background ? token() : null;
        const valid = s => typeof s === "string" && /^[a-f0-9]{32}$/.test(s);
        const validID = s => typeof s === "string" && /^[a-f0-9]{32}:[a-f0-9]{32}$/.test(s);
        const nativeConnect = runtime.connect.bind(runtime), send = runtime.sendMessage.bind(runtime);
        const incoming = runtime.onConnect, nativeAdd = incoming.addListener.bind(incoming), nativeRemove = incoming.removeListener.bind(incoming);
        const nativeHas = incoming.hasListener.bind(incoming);
        const listeners = new Set(), nativeListeners = new WeakMap(), managed = new WeakSet();
        const sources = new Map(), receivers = new Map(), records = new Map();
        let rawAttached = false, sequence = 0;
        const packet = (op, rest = {}) => ({ __searchPortIsolation: protocol, op, from: peer, sequence: ++sequence, ...rest });
        const control = m => !!m && typeof m === "object" && m.__searchPortIsolation === protocol;
        const read = (state, m) => {
          if (!control(m) || !valid(m.from) || !Number.isSafeInteger(m.sequence) || m.sequence < 1) return false;
          const previous = state.heard.get(m.from) || 0;
          if (m.sequence <= previous) return false;
          state.heard.set(m.from, m.sequence); return true;
        };
        portIsolation.isControl = control;
        portIsolation.owns = p => !!p && managed.has(p);
        const copy = value => { const text = JSON.stringify(value); return text === undefined ? "null" : text; };
        const plain = value => JSON.parse(copy(value));
        const event = () => ({ listeners: new Set(),
          addListener(f) { if (typeof f !== "function") throw new TypeError("Listener must be a function"); this.listeners.add(f); },
          removeListener(f) { this.listeners.delete(f); }, hasListener(f) { return this.listeners.has(f); },
          hasListeners() { return this.listeners.size > 0; } });
        const emit = (e, args, error) => {
          for (const f of [...e.listeners]) {
            try { error ? withLastError(new Error(error), () => f(...args)) : f(...args); }
            catch (e) { setTimeout(() => { throw e; }); }
          }
        };
        const release = state => {
          if (!state.scope) return;
          const scope = state.scope; state.scope = null;
          try { root.webkit?.messageHandlers?.searchWorkerRecovery?.postMessage({ unregisterPort: true, token: state.id, scope }).catch(() => {}); } catch (_) {}
        };
        const end = (state, notify, error) => {
          if (state.closed) return;
          state.closed = true; state.queue = [];
          (state.source ? sources : receivers).delete(state.id);
          if (state.source) release(state);
          // Recovery.track replaces public onDisconnect. Its original event
          // must run first so its observer is released and it notifies once.
          if (notify) emit(state.disconnected, [state.port], error);
          updateRawListener();
        };
        const endpoint = (id, source, sender, sendValue, disconnect) => {
          const state = { id, source, closed: false, ready: !source, queue: [], epoch: null, physical: null, scope: null, heard: new Map() };
          const port = { name: "", onMessage: event(), onDisconnect: event(),
            postMessage(value) {
              if (state.closed) throw new Error("Attempting to use a disconnected port object");
              const encoded = copy(value); // Validate and snapshot before queueing.
              if (!state.ready) state.queue.push(encoded); else sendValue(encoded);
            },
            disconnect() { if (!state.closed) { end(state, false); disconnect(); } }
          };
          if (sender !== undefined) port.sender = sender;
          state.port = port; state.messages = port.onMessage; state.disconnected = port.onDisconnect;
          managed.add(port); return state;
        };
        const sourcePacket = (state, op, rest = {}) => {
          const m = packet(op, { id: state.id, epoch: state.epoch, ...rest });
          if (background) coordinate(m);
          else if (state.physical) { try { state.physical.postMessage(m); } catch (_) { end(state, true); } }
        };
        const sourceReceive = m => {
          const state = sources.get(m.id);
          if (!state || state.closed || (state.epoch && state.epoch !== m.epoch) || !read(state, m)) return;
          state.epoch = m.epoch;
          if (m.op === "ready") {
            state.ready = true;
            const queued = state.queue; state.queue = [];
            for (const value of queued) sourcePacket(state, "sourceData", { value });
          } else if (m.op === "sourceMessage" && typeof m.value === "string") {
            emit(state.messages, [JSON.parse(m.value), state.port]);
          } else if (m.op === "sourceEnd") end(state, m.notify !== false, m.error);
        };
        const receiverReceive = (state, m) => {
          if (state.closed || m.id !== state.id || m.epoch !== state.epoch || !read(state, m)) return;
          if (m.op === "receiverEnd") end(state, m.notify !== false, m.error);
          else if (m.op === "receiverMessage" && typeof m.value === "string") emit(state.messages, [JSON.parse(m.value), state.port]);
        };
        const receive = (meta, physical) => {
          if (meta.sourcePeer === peer || !listeners.size || receivers.has(meta.id)) return;
          const post = m => background ? coordinate(m) : physical.postMessage(m);
          const state = endpoint(meta.id, false, meta.sender,
            value => post(packet("receiverData", { id: meta.id, epoch: meta.epoch, value })),
            () => post(packet("receiverClose", { id: meta.id, epoch: meta.epoch })));
          state.port.name = meta.name; state.epoch = meta.epoch; state.physical = physical;
          receivers.set(meta.id, state);
          if (physical) {
            physical.onMessage.addListener(m => receiverReceive(state, m));
            physical.onDisconnect.addListener(() => end(state, true));
          }
          post(packet("accept", { id: meta.id, epoch: meta.epoch }));
          for (const f of [...listeners]) { try { f(state.port); } catch (e) { setTimeout(() => { throw e; }); } }
        };
        const toSource = (record, op, rest = {}) => {
          const m = packet(op, { id: record.id, epoch, to: record.sourcePeer, ...rest });
          if (record.mode === "worker") sourceReceive(m);
          else if (record.physical) { try { record.physical.postMessage(m); } catch (_) {} }
        };
        const broadcast = (record, m) => {
          const local = receivers.get(record.id);
          if (local) receiverReceive(local, m);
          if (record.bus && record.remote) try { record.bus.postMessage(m); } catch (_) {}
        };
        const finish = (record, cause, error) => {
          if (!record || record.closed) return;
          record.closed = true; record.deferred = []; records.delete(record.id);
          try { native("ports.release", [record.scope]).catch(() => {}); } catch (_) {}
          broadcast(record, packet("receiverEnd", { id: record.id, epoch, notify: cause !== "receiver", error }));
          toSource(record, "sourceEnd", { notify: cause !== "source", error });
          setTimeout(() => {
            try { record.bus?.disconnect(); } catch (_) {}
            try { record.physical?.disconnect(); } catch (_) {}
          }, 0);
        };
        const start = record => {
          if (record.started || record.closed || record.authorizing) return;
          record.started = true;
          const meta = { id: record.id, epoch, sourcePeer: record.sourcePeer, name: record.name, sender: record.sender };
          if (record.mode !== "worker" && listeners.size) receive(meta, null);
          if (record.closed) return;
          try {
            // Name metadata initializes each receiver before WebKit releases
            // its queued messages. Native discovery includes busy frames.
            record.bus = nativeConnect({ name: prefix + "bus:" + JSON.stringify(meta) });
            record.remote = true;
            record.bus.onMessage.addListener(m => coordinate(m));
            record.bus.onDisconnect.addListener(() => {
              record.remote = false;
              if (!receivers.has(record.id)) finish(record, "empty", runtime.lastError?.message);
            });
          } catch (error) {
            record.remote = false;
            if (!receivers.has(record.id)) finish(record, "empty", String(error.message || error));
          }
        };
        const route = (record, m) => {
          if (record.closed) return;
          if (m.from === record.sourcePeer) {
            if (m.op === "bound") { record.bound = true; start(record); }
            else if (m.op === "sourceClose") finish(record, "source");
            else if (m.op === "sourceData") broadcast(record, packet("receiverMessage", { id: record.id, epoch, value: m.value }));
          } else if (m.op === "accept") {
            record.peers.add(m.from); toSource(record, "ready");
          } else if (record.peers.has(m.from)) {
            if (m.op === "receiverClose") finish(record, "receiver");
            else if (m.op === "receiverData") toSource(record, "sourceMessage", { value: m.value });
            // Natural receiver loss is silent while another receiver remains.
            else if (m.op === "receiverGone") record.peers.delete(m.from);
          }
        };
        const coordinate = m => {
          if (!background || !control(m)) return;
          const record = records.get(m.id);
          if (!record || record.closed || m.epoch !== epoch || !read(record, m)) return;
          if (m.op === "sourceData" || m.op === "receiverData") {
            if (typeof m.value !== "string") return;
            if (record.authorizing) { record.deferred.push(m); return; }
          }
          route(record, m);
        };
        const revalidate = record => {
          if (record.closed) return;
          record.authorizing = true;
          const revision = ++record.authorizationRevision;
          Promise.resolve(native("ports.allowed", [record.scope])).then(allowed => {
            if (record.closed || records.get(record.id) !== record || record.authorizationRevision !== revision) return;
            if (allowed !== true) { finish(record, "policy", "This document is no longer available to the extension."); return; }
            record.authorizing = false;
            if (record.bound) start(record);
            const pending = record.deferred; record.deferred = [];
            for (const m of pending) route(record, m);
          }, () => { if (!record.closed && record.authorizationRevision === revision) finish(record, "policy", "Couldn't authorize this document."); });
        };
        const sameSender = (a, b) => a && b && a.id === b.id
          && (a.documentId && b.documentId ? a.documentId === b.documentId
            : a.tab?.id === b.tab?.id && a.frameId === b.frameId && a.url === b.url);
        const open = (spec, sender, mode) => {
          if (records.has(spec.id)) throw new Error("This connection already exists.");
          const record = { id: spec.id, name: spec.name, sourcePeer: spec.from, sender: plain(untabbed(sender)),
            actualSender: sender, mode, peers: new Set(), heard: new Map(), physical: null, bus: null,
            started: false, bound: false, remote: false, closed: false, scope: spec.scope,
            authorizing: false, authorizationRevision: 0, deferred: [] };
          records.set(record.id, record);
          try {
            if (mode === "frame") {
              if (!sender.tab || !Number.isSafeInteger(sender.tab.id) || !Number.isSafeInteger(sender.frameId) || sender.frameId < 0)
                throw new Error("The sending document is no longer available.");
              const options = { name: prefix + "source:" + spec.id };
              // Chrome/WebKit accept one selector, never both. Prefer the
              // immutable document so a navigated frame cannot take its port.
              if (typeof sender.documentId === "string" && sender.documentId) options.documentId = sender.documentId;
              else options.frameId = sender.frameId;
              record.physical = chrome.tabs.connect(sender.tab.id, options);
              record.physical.onMessage.addListener(m => {
                if (control(m) && m.id === record.id && m.from === record.sourcePeer) {
                  // The reverse endpoint can arrive before sendMessage's
                  // acceptance reply. This native channel already binds it.
                  coordinate(m.op === "bound" && m.epoch == null ? { ...m, epoch } : m);
                }
              });
              record.physical.onDisconnect.addListener(() => finish(record, "gone"));
            } else start(record);
          } catch (error) { finish(record, "empty", String(error.message || error)); throw error; }
          return { accepted: true, epoch };
        };
        portIsolation.handleControl = (m, sender, respond) => {
          if (!control(m)) return;
          // Keep sibling pages silent until the background answers. WebKit
          // can otherwise settle the request with their empty response.
          if (!background) return true;
          if (!sender || sender.id !== runtime.id || !valid(m.from)) return;
          try {
            if (m.op === "connect" && validID(m.id) && m.id.startsWith(m.from + ":") && typeof m.name === "string") {
              if (m.mode !== "frame" || typeof m.scope !== "string" || !m.scope) throw new Error("Invalid content document binding.");
              Promise.resolve(native("ports.allowed", [m.scope])).then(allowed => {
                if (allowed !== true) { respond({ error: "This document is no longer available to the extension." }); return; }
                try { respond(open(m, sender, "frame")); } catch (error) { respond({ error: String(error.message || error) }); }
              }, error => respond({ error: String(error.message || error) }));
              return true;
            }
            if (m.op === "cancel") {
              const record = records.get(m.id);
              if (record && record.sourcePeer === m.from && sameSender(record.actualSender, sender)) finish(record, "source");
              respond({ cancelled: true }); return;
            }
          } catch (error) { respond({ error: String(error.message || error) }); return; }
          respond({ error: "Invalid private connection request." });
        };
        const rawConnect = port => {
          const name = port && port.name;
          if (typeof name !== "string" || !name.startsWith(prefix)) return;
          // A reserved name is not authority: a content script can call the
          // native prototype itself. Only the actual extension-origin end
          // may introduce a worker-owned transport or its sender metadata.
          const sender = port.sender;
          if (!sender || sender.id !== runtime.id
              || !(String(sender.url || "") + "/").startsWith(runtime.getURL(""))) return;
          if (name.startsWith(prefix + "bus:")) {
            let meta; try { meta = JSON.parse(name.slice((prefix + "bus:").length)); } catch (_) { return; }
            if (validID(meta.id) && valid(meta.sourcePeer) && typeof meta.name === "string" && valid(meta.epoch)) receive(meta, port);
            return;
          }
          const id = name.slice((prefix + "source:").length), state = sources.get(id);
          if (!name.startsWith(prefix + "source:") || !state || state.closed || !inContent) { try { port.disconnect(); } catch (_) {} return; }
          state.physical = port;
          port.onMessage.addListener(m => { if (control(m) && m.id === id) sourceReceive(m); });
          port.onDisconnect.addListener(() => end(state, true));
          // Tell the background the source endpoint is ready before it starts
          // native fanout; temporary source-only native listeners can go away.
          updateRawListener();
          sourcePacket(state, "bound");
        };
        const updateRawListener = () => {
          const wanted = inContent || listeners.size > 0;
          if (wanted && !rawAttached) { nativeAdd(rawConnect); rawAttached = true; }
          else if (!wanted && rawAttached) { nativeRemove(rawConnect); rawAttached = false; }
        };
        const request = (m, state) => {
          Promise.resolve().then(() => send(m)).then(reply => {
            if (state?.closed) return;
            if (!reply || reply.error || reply.accepted !== true) {
              if (state) end(state, true, reply?.error || "Could not establish connection. Receiving end does not exist.");
              return;
            }
            if (state) state.epoch = reply.epoch;
          }, error => { if (state) end(state, true, String(error.message || error)); });
        };
        put(incoming, "addListener", (listener, ...rest) => {
          if (typeof listener !== "function") return nativeAdd(listener, ...rest);
          listeners.add(listener);
          let wrapped = nativeListeners.get(listener);
          if (!wrapped) { wrapped = port => { if (!String(port?.name || "").startsWith(prefix)) listener(port); }; nativeListeners.set(listener, wrapped); }
          updateRawListener(); return nativeAdd(wrapped, ...rest);
        });
        put(incoming, "removeListener", listener => { listeners.delete(listener); nativeRemove(nativeListeners.get(listener) || listener); updateRawListener(); });
        put(incoming, "hasListener", listener => listeners.has(listener) || nativeHas(nativeListeners.get(listener) || listener));
        put(incoming, "hasListeners", () => listeners.size > 0);
        put(runtime, "connect", (...args) => {
          if (typeof args[0] === "string" && args[0] && args[0] !== runtime.id) return nativeConnect(...args);
          // All extension-page callers retain native source-frame exclusion
          // and their existing codec/recovery behavior. This repair is for
          // website content-script callers, including frames and asides.
          if (!inContent) return nativeConnect(...args);
          const info = (typeof args[0] === "string" ? args[1] : args[0]) ?? {};
          if (typeof info !== "object" || Array.isArray(info) || (info.name !== undefined && typeof info.name !== "string")) throw new TypeError("Invalid connectInfo");
          const id = peer + ":" + token();
          let state;
          state = endpoint(id, true, undefined, value => sourcePacket(state, "sourceData", { value }), () => {
            if ((state.ready || state.epoch) && state.physical) sourcePacket(state, "sourceClose");
            else if (background) { const record = records.get(id); if (record) finish(record, "source"); }
            else request(packet("cancel", { id }));
            if (state.physical) try { state.physical.disconnect(); } catch (_) {}
          });
          state.port.name = info.name || ""; sources.set(id, state); updateRawListener();
          Promise.resolve().then(() => {
            const bridge = root.webkit?.messageHandlers?.searchWorkerRecovery;
            if (!bridge) throw new Error("Couldn't bind this content document.");
            return bridge.postMessage({ registerPort: true, token: id });
          }).then(binding => {
            if (!binding || typeof binding.scope !== "string" || !binding.scope) throw new Error("Couldn't bind this content document.");
            state.scope = binding.scope;
            if (state.closed) { release(state); return; }
            request(packet("connect", { id, name: state.port.name, mode: "frame", scope: state.scope }), state);
          }).catch(error => end(state, true, String(error.message || error)));
          return state.port;
        });
        if (background && chrome.tabs?.onRemoved) chrome.tabs.onRemoved.addListener(() => {
          // A kept peek changes native adapters without changing its view.
          // Recheck authoritative scopes, never the retired native tab ID.
          for (const record of [...records.values()]) revalidate(record);
        });
        if (typeof document !== "undefined" && root.addEventListener) root.addEventListener("pagehide", e => {
          if (e.persisted) return;
          for (const state of [...sources.values()]) state.port.disconnect();
          for (const state of [...receivers.values()]) {
            const m = packet("receiverGone", { id: state.id, epoch: state.epoch });
            if (background) coordinate(m); else try { state.physical.postMessage(m); } catch (_) {}
            end(state, false);
          }
        });
        updateRawListener();
      })();
    """#
}
