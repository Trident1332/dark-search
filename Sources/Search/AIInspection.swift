import SwiftUI
import AppKit
import WebKit

/// Opt-in, per-tab access to WebKit's inspector. Network capture does not
/// patch site JavaScript or replay requests. Console actions explicitly run
/// in the inspected page or worker's execution context.
@MainActor
final class AIInspection: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var connecting = false
    @Published private(set) var requestCount = 0
    @Published private(set) var bodyCount = 0
    @Published private(set) var problem: String?
    private weak var page: WKWebView?
    private weak var owner: Tab?
    struct Action: Identifiable {
        let id = UUID()
        let at = Date()
        let expression: String
        var result: String?
    }
    @Published private(set) var actions: [Action] = []
    private var inspector: NSObject?
    private var frontend: WKWebView?
    private var ownedConnection = false
    private var poller: Task<Void, Never>?
    private var generation = UUID()
    private var origin: String?
    private(set) var lastStopReason = ""

    static func origin(_ url: URL?) -> String? {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = ""; parts.query = nil; parts.fragment = nil
        return parts.string
    }
    private func object(_ owner: NSObject, _ name: String) -> NSObject? {
        let selector = NSSelectorFromString(name)
        guard owner.responds(to: selector) else { return nil }
        return owner.perform(selector)?.takeUnretainedValue() as? NSObject
    }
    private func flag(_ owner: NSObject, _ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard owner.responds(to: selector) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(owner.method(for: selector), to: Getter.self)(owner, selector)
    }
    func start(in tab: Tab) async {
        guard !recording, !connecting, tab.isWeb, let page = tab.built else { return }
        stop()
        let token = generation
        connecting = true
        defer { if Task.isCancelled, token == generation { stop() } }
        self.page = page
        self.owner = tab
        origin = Self.origin(tab.pageAddress)
        guard let inspector = object(page, "_inspector"),
              inspector.responds(to: NSSelectorFromString("connect")),
              inspector.responds(to: NSSelectorFromString("extensionHostWebView")) else {
            connecting = false; problem = "This WebKit version does not expose network inspection."; return
        }
        self.inspector = inspector
        ownedConnection = !flag(inspector, "isConnected")
        inspector.perform(NSSelectorFromString("connect"))
        for _ in 0..<80 {
            guard !Task.isCancelled, token == generation else { return }
            if let frontend = object(inspector, "extensionHostWebView") as? WKWebView {
                let ready = (try? await frontend.evaluateJavaScript("typeof WI === 'object' && !!WI.networkManager && !!WI.mainTarget && typeof InspectorBackend === 'object'")) as? Bool ?? false
                if ready {
                    self.frontend = frontend
                    do {
                        _ = try await frontend.evaluateJavaScript(Self.recorder)
                        guard !Task.isCancelled, token == generation else { return }
                        recording = true; connecting = false; problem = nil
                        poller = Task { [weak self] in
                            while !Task.isCancelled {
                                guard self != nil else { return }
                                await self?.updateCounts()
                                try? await Task.sleep(for: .seconds(1))
                            }
                        }
                        return
                    } catch { problem = Self.describe(error, in: "inspector's recorder"); break }
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        connecting = false
        if problem == nil { problem = "WebKit's network inspector did not become ready. Try again." }
    }
    func navigated(to url: URL?) {
        if recording || connecting, !["http", "https"].contains(url?.scheme?.lowercased() ?? "") { stop() }
    }
    func stop(reason: String = #function) {
        lastStopReason = reason
        generation = UUID(); poller?.cancel(); poller = nil
        if let frontend { frontend.evaluateJavaScript("window.__searchAIInspection?.stop(); delete window.__searchAIInspection; for (const t of WI.targets || []) t.RuntimeAgent?.releaseObjectGroup?.invoke({objectGroup:'SearchAIInspection'}).catch(()=>{});", completionHandler: nil) }
        if let inspector, ownedConnection, !flag(inspector, "isVisible"), inspector.responds(to: NSSelectorFromString("close")) {
            inspector.perform(NSSelectorFromString("close"))
        }
        recording = false; connecting = false; requestCount = 0; bodyCount = 0
        frontend = nil; inspector = nil; page = nil; owner = nil; problem = nil; ownedConnection = false
        actions.removeAll()
    }
    private func updateCounts() async {
        guard let frontend, recording else { return }
        let token = generation
        if let state = try? await frontend.evaluateJavaScript("window.__searchAIInspection?.summary()") as? [String: Any], recording, token == generation {
            requestCount = state["requests"] as? Int ?? 0
            bodyCount = state["bodies"] as? Int ?? 0
            problem = state["problem"] as? String
        }
    }
    /// WebKit says only "A JavaScript exception occurred" of a script that
    /// threw. The exception's own message and line travel in the error's
    /// user info: say those, and which script it was.
    static func describe(_ error: Error, in script: String) -> String {
        let failure = error as NSError
        guard failure.domain == WKErrorDomain, failure.code == WKError.javaScriptExceptionOccurred.rawValue else {
            return error.localizedDescription
        }
        var text = "The \(script) script threw"
        if let message = failure.userInfo["WKJavaScriptExceptionMessage"] as? String, !message.isEmpty {
            text += ": " + message
        } else {
            text += " an exception"
        }
        if let line = failure.userInfo["WKJavaScriptExceptionLineNumber"] as? Int, line > 0 { text += " (line \(line))" }
        return text
    }

    func snapshot() async throws -> AIInspectionSnapshot {
        guard recording, let frontend, let page else { throw AIError.unreachable("Start Inspect page first.") }
        let token = generation
        let captured: Any?
        do { captured = try await frontend.callAsyncJavaScript("return await window.__searchAIInspection.snapshot()", arguments: [:], in: nil, contentWorld: .page) }
        catch { throw AIError.unreachable(Self.describe(error, in: "network capture")) }
        let dom: Any?
        do { dom = try await page.evaluateJavaScript(Self.pageSnapshot, in: nil, contentWorld: Web.world) }
        catch { throw AIError.unreachable(Self.describe(error, in: "page snapshot")) }
        guard recording, token == generation else { throw AIError.unreachable("Inspection stopped while capturing. Start it again.") }
        guard let json = captured as? String else { throw AIError.unreachable("WebKit did not return a network snapshot (\(type(of: captured))).") }
        guard let pageJSON = dom as? String else { throw AIError.unreachable("WebKit did not return a page snapshot (\(type(of: dom))).") }
        return try AIInspectionSnapshot(networkJSON: json, pageJSON: pageJSON)
    }

    func tool(_ name: String, arguments: [String: Any]) async -> String {
        guard !Task.isCancelled, recording, let owner, owner.isWeb, owner.built === page,
              let frontend else { return AIInspectionSnapshot.json(["error":"The inspected tab is no longer available"]) }
        do {
            switch name {
            case "run_console":
                let expression = arguments["expression"] as? String ?? ""
                let action = Action(expression: expression)
                actions.append(action)
                let result = try await frontend.callAsyncJavaScript(Self.consoleScript, arguments: ["expression":expression,"targetID":arguments["target"] as? String ?? "","contextID":arguments["context"] as? Int ?? -1], in:nil, contentWorld:.page)
                let text = result as? String ?? "{}"
                if let index = actions.firstIndex(where: { $0.id == action.id }) { actions[index].result = text }
                return text
            case "inspect_object":
                return try await frontend.callAsyncJavaScript(Self.objectScript, arguments: ["objectID":arguments["objectId"] as? String ?? "","targetID":arguments["target"] as? String ?? ""], in:nil, contentWorld:.page) as? String ?? "{}"
            case "read_inspection":
                let part = arguments["part"] as? String ?? "index"
                let offset = max(0, arguments["offset"] as? Int ?? 0)
                let count = min(12000,max(1,arguments["count"] as? Int ?? 12000))
                if part == "dom" || part == "state" {
                    guard let page else { throw AIError.unreadable }
                    let captured = try await page.evaluateJavaScript(Self.pageSnapshot, in:nil,contentWorld:Web.world) as? String ?? "{}"
                    let snapshot = try AIInspectionSnapshot(networkJSON:"{\"records\":[]}",pageJSON:captured)
                    return snapshot.read(part:part,offset:offset,count:count)
                }
                return try await frontend.callAsyncJavaScript("return await window.__searchAIInspection.read(part,id,offset,count)",arguments:["part":part,"id":arguments["id"] as? String ?? "","offset":offset,"count":count],in:nil,contentWorld:.page) as? String ?? "{}"
            default: return AIInspectionSnapshot.json(["error":"Unknown inspector tool"])
            }
        } catch {
            let script = ["run_console": "console", "inspect_object": "object", "read_inspection": "inspection read"][name] ?? name
            return AIInspectionSnapshot.json(["error": Self.describe(error, in: script)])
        }
    }
    static let consoleScript = #"""
    const target = targetID ? WI.targets.find(t=>t.identifier===targetID) : (WI.pageTarget||WI.mainTarget);
    if(!target?.RuntimeAgent) return JSON.stringify({error:'Execution target no longer exists'});
    const evaluate = async()=>{
      const params={expression,objectGroup:'SearchAIInspection',includeCommandLineAPI:true,returnByValue:false,generatePreview:true,emulateUserGesture:true};
      if(contextID>=0)params.contextId=contextID;
      let response=await target.RuntimeAgent.evaluate.invoke(params);
      if(!response.wasThrown && (response.result?.subtype==='promise'||response.result?.className==='Promise') && target.RuntimeAgent.awaitPromise)
        response=await target.RuntimeAgent.awaitPromise.invoke({promiseObjectId:response.result.objectId,returnByValue:false,generatePreview:true});
      return JSON.stringify({target:target.identifier,...response});
    };
    return await Promise.race([evaluate().catch(e=>JSON.stringify({error:String(e)})),new Promise(r=>setTimeout(()=>r(JSON.stringify({error:'Console result is still pending after 30 seconds. Code already dispatched may still be running.'})),30000))]);
    """#
    static let objectScript = #"""
    const target = targetID ? WI.targets.find(t=>t.identifier===targetID) : (WI.pageTarget||WI.mainTarget);
    if(!target?.RuntimeAgent)return JSON.stringify({error:'Target no longer exists'});
    try{return JSON.stringify({target:target.identifier,...await target.RuntimeAgent.getProperties.invoke({objectId:objectID,ownProperties:true,generatePreview:true})})}catch(e){return JSON.stringify({error:String(e)})}
    """#

    /// Raw values are intentional: Inspect page's explicit no-redaction mode.
    static let pageSnapshot = #"""
    JSON.stringify({url:location.href,title:document.title,dom:document.documentElement.outerHTML,
      fields:Array.from(document.querySelectorAll('input,textarea,select')).map(e=>({tag:e.tagName,type:e.type,name:e.name,id:e.id,value:e.value,checked:e.checked})),
      scripts:Array.from(document.scripts).map(e=>({src:e.src,type:e.type,inline:e.src?'':e.textContent})),
      styles:Array.from(document.styleSheets).map(s=>{try{return {href:s.href,rules:Array.from(s.cssRules).map(r=>r.cssText)}}catch(e){return {href:s.href,unavailable:String(e)}}})})
    """#

    static let recorder = #"""
    (()=>{
      if(window.__searchAIInspection)return true;
      const records=new Map(), consoleMessages=[], socketEvents=[];
      const previous=InspectorBackend.dispatch;
      let serial=0, bytes=0, stopped=false, problem=null;
      const budget=128*1024*1024, startedAt=new Date().toISOString();
      function register(resource, key, raw={}) {
        if(records.has(key))return records.get(key);
        if(records.size>=5000){problem='5000 request capture limit reached. Clear capture to continue.';throw new Error(problem)}
        const item={id:String(++serial),key,url:resource?.url||raw.request?.url||'',resource,
          target:resource?.target?.identifier,request:raw.request||{url:resource?.url,method:resource?.requestMethod,headers:resource?.requestHeaders,postData:resource?.requestData},
          response:resource?{url:resource.url,status:resource.statusCode,headers:resource.responseHeaders,mimeType:resource.mimeType,source:resource.responseSource}:null,
          body:null,base64Encoded:false,bodyState:'pending',events:[],pending:null};
        records.set(key,item);return item;
      }
      function getBody(item) {
        if(item.pending||item.bodyState==='available'||stopped)return;
        const resource=item.resource;
        if(!resource&&!item.requestID){item.bodyState='unavailable';item.bodyError='WebKit did not expose this resource';return}
        item.pending=(async()=>{
          try {
            let value;
            const target=WI.targets.find(t=>t.identifier===item.wireTarget)||WI.networkManager.networkTargetForCommand?.(resource?.target,'Network.getResponseBody')||WI.pageTarget||WI.mainTarget;
            if((item.requestID||resource?.requestIdentifier)&&target?.NetworkAgent?.getResponseBody)
              value=await target.NetworkAgent.getResponseBody(item.requestID||resource.requestIdentifier);
            else value=await resource.requestContentFromBackend();
            if(stopped)return;
            const body=value.body??value.content;
            if(typeof body!=='string')throw new Error('WebKit returned no body');
            if(bytes+body.length*2>budget){item.bodyState='unavailable';item.bodyError='Capture memory limit reached';problem='128 MB capture limit reached. Some bodies are unavailable; clear capture to continue.';return}
            item.body=body;item.base64Encoded=!!value.base64Encoded;item.bodyState='available';bytes+=body.length*2;
          }catch(e){if(!stopped){item.bodyState='unavailable';item.bodyError=String(e)}}
        })();
      }
      function message(value,target='main') {
        if(stopped)return;
        if(typeof value==='string'){try{value=JSON.parse(value)}catch{return}}
        const name=value.method,p=value.params||{};
        if(name==='Target.dispatchMessageFromTarget'||name==='Worker.dispatchMessageFromWorker'){
          message(p.message,p.targetId||p.workerId||target);return;
        }
        if(name==='Console.messageAdded'){if(consoleMessages.length<500)consoleMessages.push(p.message);else problem='Console capture limit reached; later messages were not retained';return}
        if(!name?.startsWith('Network.'))return;
        if(name.includes('webSocket')||name.includes('WebSocket')||name.includes('eventSource')){
          if(socketEvents.length<2000)socketEvents.push({method:name,params:p,target});else problem='Socket event capture limit reached; later frames were not retained';return;
        }
        const requestId=p.requestId;
        if(!requestId)return;
        const key=target+':'+requestId;
        const resource=WI.networkManager.resourceForRequestIdentifier(requestId)||(p.resource?.url ? Array.from(WI.networkManager.resourcesForURL(p.resource.url)).at(-1) : null);
        let item=records.get(key);
        if(name==='Network.requestWillBeSent'){
          // Redirect responses and the final response have separate bodies/availability.
          if(item&&p.redirectResponse){item.response=p.redirectResponse;item.bodyState='unavailable';item.bodyError='Redirect body is not retained by WebKit';records.set(key+':redirect:'+serial,item);records.delete(key);item=null}
          item=item||register(resource,key,p);item.request=p.request;item.url=p.request.url;
        }
        item=item||register(resource,key,p);
        if(resource)item.resource=resource;
        item.wireTarget=target;item.requestID=requestId;
        if(p.resource){item.url=p.resource.url;item.response=p.resource.response;item.cacheEvent=true}
        if(name!=='Network.dataReceived')item.events.push({method:name,params:p});
        if(p.response)item.response=p.response;
        if(p.metrics)item.metrics=p.metrics;
        if(name==='Network.loadingFailed'){item.bodyState='unavailable';item.bodyError=p.errorText||'Request failed'}
        if(name==='Network.loadingFinished'||name==='Network.requestServedFromMemoryCache')getBody(item);
      }
      function dispatch(value) {
        // Keep the resource handle before WebKit's frontend removes completed IDs.
        let parsed=value;
        if(typeof parsed==='string'){try{parsed=JSON.parse(parsed)}catch{}}
        function remember(v,target='main'){
          if(typeof v==='string'){try{v=JSON.parse(v)}catch{return}}
          if(v.method==='Target.dispatchMessageFromTarget'||v.method==='Worker.dispatchMessageFromWorker'){remember(v.params.message,v.params.targetId||v.params.workerId||target);return}
          if(v.method?.startsWith('Network.')&&v.params?.requestId){
            const r=WI.networkManager.resourceForRequestIdentifier(v.params.requestId);
            if(r){const item=records.get(target+':'+v.params.requestId);if(item)item.resource=r}
          }
        }
        remember(parsed);
        const result=previous.call(this,value);
        try{message(parsed)}catch(e){problem='Some inspector events could not be recorded: '+String(e)}
        return result;
      }
      InspectorBackend.dispatch=dispatch;
      // Recover already loaded resources from WebKit's existing cache. This is
      // not a replay; old request headers/bodies may no longer be available.
      for(const frame of WI.networkManager.frames||[]){
        const resources=[frame.mainResource,...(frame.resourceCollection?.items||[])];
        for(const r of resources)if(r){const item=register(r,'cached:'+frame.id+':'+r.url);item.recoveredFromCache=true;getBody(item)}
      }
      window.__searchAIInspection={
        summary(){return {requests:records.size,bodies:Array.from(records.values()).filter(r=>r.bodyState==='available').length,problem}},
        async read(part,id,offset,count){
          let value;
          const values=Array.from(records.values());
          if(part==='index')value={startedAt,problem,scope:'Live, unredacted capture of this tab. Missing bodies are explicitly marked.',
            records:values.map(({resource,pending,body,events,...r})=>({...r,bodyLength:body?.length||0})),
            targets:WI.targets.map(t=>({id:t.identifier,type:t.type,name:t.displayName}))};
          else if(part==='targets')value={targets:WI.targets.map(t=>({id:t.identifier,type:t.type,name:t.displayName})),frames:(WI.networkManager.frames||[]).map(f=>({id:f.id,url:f.url,context:f.pageExecutionContext?.id,target:f.pageExecutionContext?.target?.identifier}))};
          else if(part==='console')value=consoleMessages;
          else if(part==='sockets')value=socketEvents;
          else {
            const item=values.find(r=>r.id===id);
            if(!item)return JSON.stringify({error:'Unknown request ID'});
            if(part==='body'){
              if(item.pending)await Promise.race([item.pending,new Promise(r=>setTimeout(r,2000))]);
              if(item.body===null)return JSON.stringify({error:item.bodyError||'Response body is still pending',state:item.bodyState});
              value=item.body;
            }else if(['request','response','events'].includes(part))value=item[part];
            else return JSON.stringify({error:'Unknown inspection section'});
          }
          const text=typeof value==='string'?value:JSON.stringify(value);
          let start=Math.min(Math.max(0,offset),text.length),end=Math.min(text.length,start+Math.min(12000,Math.max(1,count)));
          const low=i=>text.charCodeAt(i)>=0xDC00&&text.charCodeAt(i)<=0xDFFF;
          if(start>0&&low(start))start--;
          if(end<text.length&&low(end))end++;
          return JSON.stringify({part,id,offset:start,nextOffset:end,length:text.length,more:end<text.length,data:text.slice(start,end)});
        },
        async snapshot(){
          await Promise.race([Promise.all(Array.from(records.values()).map(r=>r.pending).filter(Boolean)),new Promise(r=>setTimeout(r,2500))]);
          return JSON.stringify({startedAt,problem,scope:'This tab only. Bodies are captured from WebKit, not refetched. Past requests and unfinished streams may be unavailable.',
            records:Array.from(records.values()).map(({resource,pending,...r})=>r),console:consoleMessages,sockets:socketEvents,targets:WI.targets.map(t=>({id:t.identifier,type:t.type})),frames:(WI.networkManager.frames||[]).map(f=>({id:f.id,url:f.url,context:f.pageExecutionContext?.id,target:f.pageExecutionContext?.target?.identifier}))});
        },
        stop(){stopped=true;if(InspectorBackend.dispatch===dispatch)InspectorBackend.dispatch=previous;records.clear();consoleMessages.length=0;socketEvents.length=0;bytes=0}
      };
      return true;
    })()
    """#
}

/// An immutable, exportable snapshot for preview and the initial prompt.
/// Interactive tools separately read the live capture and execute console code.
final class AIInspectionSnapshot: @unchecked Sendable {
    let network: [String: Any]
    let page: [String: Any]
    let index: String
    init(networkJSON: String, pageJSON: String) throws {
        guard let network = try JSONSerialization.jsonObject(with: Data(networkJSON.utf8)) as? [String: Any],
              let page = try JSONSerialization.jsonObject(with: Data(pageJSON.utf8)) as? [String: Any] else { throw AIError.unreadable }
        self.network = network; self.page = page
        let records = network["records"] as? [[String: Any]] ?? []
        index = Self.json(["url":page["url"] ?? "", "title":page["title"] ?? "", "startedAt":network["startedAt"] ?? "", "scope":network["scope"] ?? "", "problem":network["problem"] ?? NSNull(),
            "records":records.map { row in ["id":row["id"] ?? "", "url":row["url"] ?? "", "request":row["request"] ?? [:], "response":row["response"] ?? [:], "bodyState":row["bodyState"] ?? "", "bodyError":row["bodyError"] ?? "", "bodyLength":(row["body"] as? String)?.utf16.count ?? 0, "base64Encoded":row["base64Encoded"] ?? false] }])
    }
    static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
    func read(part: String, id: String = "", offset: Int = 0, count: Int = 12000) -> String {
        let text: String
        switch part {
        case "index": text = index
        case "targets": text = Self.json(["targets":network["targets"] ?? [],"frames":network["frames"] ?? []])
        case "dom": text = page["dom"] as? String ?? ""
        case "state": text = Self.json(page.filter { $0.key != "dom" })
        case "console": text = Self.json(network["console"] ?? [])
        case "sockets": text = Self.json(network["sockets"] ?? [])
        case "request", "response", "body", "events":
            guard let row = (network["records"] as? [[String: Any]])?.first(where: { $0["id"] as? String == id }) else { return Self.json(["error":"No captured request with that ID"]) }
            if part == "body" {
                guard let body = row["body"] as? String else { return Self.json(["error":row["bodyError"] ?? "Body is not yet available", "state":row["bodyState"] ?? "unknown"]) }
                text = body
            } else { text = Self.json(row[part] ?? [:]) }
        default: return Self.json(["error":"Unknown inspection section"])
        }
        // UTF-16 offsets are explicit. Avoid splitting surrogate pairs while
        // keeping every captured value intact across tool-read chunks.
        let string = text as NSString
        var start = min(max(0, offset), string.length)
        if start > 0, start < string.length, (0xDC00...0xDFFF).contains(string.character(at: start)) { start -= 1 }
        var end = min(string.length, start + min(12000, max(1, count)))
        if end > 0, end < string.length, (0xDC00...0xDFFF).contains(string.character(at: end)) { end += 1 }
        return Self.json(["part":part,"id":id,"offset":start,"nextOffset":end,"length":string.length,"more":end < string.length,"data":string.substring(with: NSRange(location:start,length:end-start))])
    }
}

struct InspectionControls: View {
    @ObservedObject var assistant: Assistant
    @State private var reviewing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Toggle("Inspect page", isOn: Binding(get: { assistant.inspectEnabled }, set: assistant.setInspection))
                    .toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: 11.5))
                    .disabled(!assistant.inspectEnabled && (assistant.busy || assistant.notice != nil))
                Spacer(minLength: 0)
                if assistant.inspectionBusy { ProgressView().controlSize(.mini) }
                if assistant.inspectEnabled {
                    Button("View data") { reviewing = true }.buttonStyle(.plain)
                        .font(.system(size: 11.5)).foregroundStyle(Color.accentColor)
                    Button { assistant.refreshInspection() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).disabled(assistant.busy).help("Refresh inspection snapshot")
                }
            }
            if assistant.inspectEnabled {
                Text("Live console, page source and network bodies · no redaction")
                    .font(.system(size: 10.5)).foregroundStyle(Palette.muted)
            }
            if assistant.inspectEnabled, let inspection = assistant.inspection { InspectionActivity(inspection: inspection) }
            if let problem = assistant.inspectionProblem {
                Text(problem).font(.system(size: 11)).foregroundStyle(Palette.failed).fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $reviewing) {
            if let inspection = assistant.inspection { InspectionPreview(assistant: assistant, inspection: inspection) }
        }
    }
}

private struct InspectionPreview: View {
    @ObservedObject var assistant: Assistant
    @ObservedObject var inspection: AIInspection
    @Environment(\.dismiss) private var dismiss
    @State private var part = "index"
    @State private var requestID = ""
    @State private var offset = 0
    @State private var consoleInput = ""
    @State private var consoleResult = ""
    @State private var executing = false
    @State private var exportError: String?
    private let sections = ["index", "targets", "dom", "state", "console", "sockets", "request", "response", "body", "events"]
    private var response: [String: Any] {
        guard let snapshot = assistant.inspectionSnapshot,
              let data = snapshot.read(part: part, id: requestID, offset: offset, count: 24000).data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Inspection data").font(.system(size: 18, weight: .semibold))
                    Text("Unredacted capture from this tab. AI can read live data and execute console code. Actions and results are recorded below.")
                        .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Picker("Section", selection: $part) { ForEach(sections, id: \.self) { Text($0.capitalized).tag($0) } }.frame(width: 180)
                if ["request", "response", "body", "events"].contains(part) {
                    TextField("Request ID from index", text: $requestID).frame(width: 170)
                }
                Spacer()
                Button("Refresh") { assistant.refreshInspection() }.disabled(assistant.busy)
                Button("Export capture…", action: export)
            }
            if part == "console" {
                HStack {
                    TextField("Console JavaScript", text: $consoleInput, axis: .vertical)
                        .font(.system(size: 11, design: .monospaced)).lineLimit(1...4)
                    Button(executing ? "Running…" : "Run") {
                        let expression = consoleInput
                        executing = true
                        Task {
                            consoleResult = await inspection.tool("run_console", arguments:["expression":expression])
                            executing = false
                        }
                    }.disabled(executing || consoleInput.isEmpty || !inspection.recording)
                }
            }
            ScrollView([.horizontal, .vertical]) {
                Text(part == "console" && !consoleResult.isEmpty ? consoleResult : response["data"] as? String ?? "No snapshot yet.")
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
            }
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("Start") { offset = 0 }.disabled(offset == 0)
                Text("UTF-16 offset \(offset) · \(response["length"] as? Int ?? 0) total")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer()
                Button("Next chunk") { offset = response["nextOffset"] as? Int ?? 0 }.disabled(response["more"] as? Bool != true)
            }
        }
        .padding(22).frame(width: 740, height: 540).background(Palette.ground)
        .onChange(of: part) { _, _ in offset = 0 }
        .onChange(of: requestID) { _, _ in offset = 0 }
        .alert("Capture could not be saved", isPresented: Binding(get:{exportError != nil},set:{if !$0 {exportError=nil}})) {
            Button("OK") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }
    private func export() {
        guard let snapshot = assistant.inspectionSnapshot else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "page-inspection.json"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                let data = try JSONSerialization.data(withJSONObject: ["page":snapshot.page,"network":snapshot.network,"consoleActions":inspection.actions.map { ["expression":$0.expression,"result":$0.result ?? "Running"] }], options: [.prettyPrinted, .sortedKeys])
                try data.write(to: url, options: .atomic)
            } catch { exportError = error.localizedDescription }
        }
    }
}

private struct InspectionActivity: View {
    @ObservedObject var inspection: AIInspection
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(inspection.recording ? Color.accentColor : Palette.muted).frame(width: 5,height: 5)
                Text("\(inspection.requestCount) requests · \(inspection.bodyCount) response bodies")
                    .font(.system(size: 10.5)).foregroundStyle(Palette.muted)
            }
            if let problem = inspection.problem {
                Text(problem).font(.system(size: 10.5)).foregroundStyle(Palette.failed)
            }
            if !inspection.actions.isEmpty {
                DisclosureGroup("Console activity (\(inspection.actions.count))") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(inspection.actions) { action in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(action.expression).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                                    Text(action.result ?? "Running…").font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Palette.muted).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(.top, 6)
                    }.frame(maxHeight: 160)
                }.font(.system(size: 11))
            }
        }
    }
}
