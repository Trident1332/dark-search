import AppKit
import WebKit

/// In-process tools for the tab the person chose. No debugging listener,
/// separate browser, copied cookies, or browser-wide automation permission.
@MainActor
final class AIBrowserTools {
    private weak var tab: Tab?
    private weak var web: WKWebView?
    private let tabID: UUID
    private var navigationRevision = 0
    private var navigationObserver: NSKeyValueObservation?

    init(tab: Tab) {
        self.tab = tab; self.web = tab.built; self.tabID = tab.id
        navigationObserver = tab.built?.observe(\.isLoading,options:[.new]) { [weak self] _,change in
            guard change.newValue == true else { return }
            MainActor.assumeIsolated { self?.navigationRevision += 1 }
        }
    }

    static let definitions: [[String: Any]] = {
        let ref: [String: Any] = ["type":"string", "description":"Exact ref from the latest browser_snapshot. Never invent a ref."]
        func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], _ required: [String] = []) -> [String: Any] {
            ["name":name, "description":description, "parameters":["type":"object", "properties":properties, "required":required, "additionalProperties":false]]
        }
        let condition: [String: Any] = ["ref":ref, "condition":["type":"string", "enum":["visible","hidden","enabled","disabled","text","value","url"]], "expected":["type":"string"]]
        return [
            tool("browser_snapshot", "Read this existing tab's current document, visible text and stable element refs. Refs expire on navigation or removal. Main document only; use inspection contexts for frames. No new browser or login."),
            tool("browser_evaluate", "Run an async JavaScript function body in this existing tab's main page world, with the page's own session and globals. Use return for a JSON-safe result; Promises are awaited. Can read or change page state. No native app, file, other-tab or Inspector/network-capture access is granted. Execution is page JavaScript, not proof of trusted input or UI success. Code and results are bounded; timed-out or cancelled scripts may still have changed the page.", ["code":["type":"string","maxLength":16000],"timeoutMs":["type":"integer","minimum":100,"maximum":10000]], ["code"]),
            tool("browser_click", "Click a visible unobscured element using native mouse events delivered to this tab. Returns fresh state. Native dialogs and other tabs are outside this tool.", ["ref":ref], ["ref"]),
            tool("browser_fill", "Replace text in a writable input or textarea using native text key events after DOM focus and selection. Maximum 2048 characters. Returns fresh state.", ["ref":ref,"text":["type":"string","maxLength":2048]], ["ref","text"]),
            tool("browser_select", "Set one select option by its exact value, then dispatch DOM input/change events. This is a DOM action, not a trusted physical selection.", ["ref":ref,"value":["type":"string","maxLength":2048]], ["ref","value"]),
            tool("browser_press", "Send a named native key to a referenced element in this tab. Supported: Enter, Tab, Escape, Backspace, Delete, ArrowUp/Down/Left/Right, Home, End, Space. No browser or system shortcuts.", ["ref":ref,"key":["type":"string"]], ["ref","key"]),
            tool("browser_scroll", "Scroll this document or a referenced element by bounded CSS pixels using DOM scrollBy. Returns fresh state.", ["ref":ref,"x":["type":"integer","minimum":-4000,"maximum":4000],"y":["type":"integer","minimum":-4000,"maximum":4000]]),
            tool("browser_wait", "Poll a document/ref condition until satisfied, cancelled, navigation invalidates the ref, or timeout (maximum 10000 ms). Text and URL use substring matching; value is exact.", condition.merging(["timeoutMs":["type":"integer","minimum":0,"maximum":10000]]) { _,new in new }, ["condition"]),
            tool("browser_assert", "Check a document/ref condition once and return passed plus fresh state. Text/URL use substring matching; value is exact. Does not infer success from an HTTP status.", condition, ["condition"]),
            tool("browser_request", "Make an explicit same-origin HTTP request inside this existing tab's WebKit session using fetch and same-origin credentials. Cookies including HttpOnly are handled by WebKit, never copied. This tests an endpoint, not the UI flow. CORS, proxy and browser policy still apply. Bounded response body; timeout aborts fetch. Do not retry a mutation without checking its outcome.", ["url":["type":"string","maxLength":4096],"method":["type":"string","enum":["GET","HEAD","POST","PUT","PATCH","DELETE","OPTIONS"]],"headers":["type":"object","additionalProperties":["type":"string"]],"body":["type":"string","maxLength":32768],"timeoutMs":["type":"integer","minimum":100,"maximum":10000]], ["url"])
        ]
    }()

    func call(_ name: String, arguments: [String: Any], isPermitted: @escaping @MainActor () -> Bool = { true }) async -> String {
        do {
            guard Self.definitions.contains(where: { $0["name"] as? String == name }) else { throw Failure("Unknown browser tool") }
            guard JSONSerialization.isValidJSONObject(arguments), (try JSONSerialization.data(withJSONObject: arguments)).count <= 65536 else { throw Failure("Browser tool arguments are too large") }
            try Task.checkCancellation()
            guard isPermitted() else { throw Failure("Browser tool access changed before dispatch") }
            let view = try ownedView()
            var result: [String: Any]
            switch name {
            case "browser_snapshot": result = try await run("snapshot", arguments, in: view)
            case "browser_evaluate": return try await evaluate(arguments, in:view,isPermitted:isPermitted)
            case "browser_click":
                let revision = navigationRevision
                let target = try await run("point", arguments, in: view)
                try Task.checkCancellation(); _ = try ownedView()
                guard navigationRevision == revision, !view.isLoading else { throw Failure("The document navigated before native input. Read browser_snapshot again.") }
                try mouse(target, in: view)
                result = ["ok":true,"mode":"native mouse events", "completion":"Input dispatched. Use browser_wait or browser_assert to verify event handlers and navigation; a snapshot alone does not prove completion."]
            case "browser_fill":
                guard let text = arguments["text"] as? String, text.count <= 2048, !text.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\n" }) else { throw Failure("Fill needs at most 2048 text characters without control keys") }
                let revision = navigationRevision
                _ = try await run("focusText", arguments, in: view)
                try Task.checkCancellation(); _ = try ownedView()
                guard navigationRevision == revision, !view.isLoading else { throw Failure("The document navigated before native input. Read browser_snapshot again.") }
                try requireWindow(view)
                // WebKit handles these as input, including beforeinput/input and
                // framework listeners. The caret was selected in the isolated world.
                for character in text {
                    try Task.checkCancellation()
                    try key(String(character), code: Self.characterCode(character), in: view)
                }
                if text.isEmpty { try key("\u{8}", code:51, in:view) }
                result = ["ok":true,"mode":"DOM focus and selection; native text key events"]
            case "browser_press":
                guard let name = arguments["key"] as? String, let key = Self.keys[name] else { throw Failure("Unsupported key; browser and system shortcuts are not available") }
                let revision = navigationRevision
                _ = try await run("focus", arguments, in:view)
                try Task.checkCancellation(); _ = try ownedView()
                guard navigationRevision == revision, !view.isLoading else { throw Failure("The document navigated before native input. Read browser_snapshot again.") }
                try self.key(key.0, code:key.1, in:view)
                result = ["ok":true,"mode":"native key events after DOM focus"]
            case "browser_select": result = try await run("select", arguments, in:view)
            case "browser_scroll":
                for field in ["x","y"] { if let value = arguments[field], !(value is NSNumber) || abs((value as? NSNumber)?.doubleValue ?? .infinity) > 4000 { throw Failure("Scroll distance must be between -4000 and 4000") } }
                result = try await run("scroll", arguments, in:view)
            case "browser_wait", "browser_assert":
                guard let condition = arguments["condition"] as? String, ["visible","hidden","enabled","disabled","text","value","url"].contains(condition) else { throw Failure("Unknown browser condition") }
                if ["text","value","url"].contains(condition), arguments["expected"] as? String == nil { throw Failure("This condition needs an expected string") }
                let timeout = name == "browser_wait" ? min(10000,max(0,(arguments["timeoutMs"] as? Int) ?? 5000)) : 0
                let deadline = ContinuousClock.now + .milliseconds(timeout)
                repeat {
                    try Task.checkCancellation(); _ = try ownedView()
                    result = try await run("condition",arguments,in:view)
                    if result["passed"] as? Bool == true || ContinuousClock.now >= deadline { break }
                    try await Task.sleep(for:.milliseconds(100))
                } while true
                result["timedOut"] = name == "browser_wait" && result["passed"] as? Bool != true
            case "browser_request": result = try await run("request",arguments,in:view,timeout:12)
            default: throw Failure("Unknown browser tool")
            }
            try Task.checkCancellation(); _ = try ownedView()
            if name != "browser_snapshot" { result["snapshot"] = try await run("snapshot",[:],in:view) }
            result["tab"] = tabID.uuidString
            return Self.json(result)
        } catch is CancellationError {
            var error:[String:Any] = ["error":"Browser action cancelled. Already dispatched input, scripts or requests may have taken effect; inspect fresh state before retrying."]
            if name == "browser_evaluate" { error["execution"] = "pageJavaScript" }
            return Self.json(error)
        } catch {
            var output:[String:Any] = ["error":String(error.localizedDescription.prefix(500))]
            if name == "browser_evaluate" { output["execution"] = "pageJavaScript" }
            return Self.json(output)
        }
    }

    private func evaluate(_ arguments:[String:Any],in view:WKWebView,isPermitted:@escaping @MainActor () -> Bool) async throws -> String {
        guard view.configuration.defaultWebpagePreferences.allowsContentJavaScript else { throw Failure("Page JavaScript is disabled for this web view; browser_evaluate will not override that policy") }
        guard let code=arguments["code"] as? String,!code.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              code.count<=16000,code.utf8.count<=32768 else { throw Failure("Page JavaScript needs non-empty code of at most 16000 characters and 32768 UTF-8 bytes") }
        let timeout=min(10000,max(100,(arguments["timeoutMs"] as? Int) ?? 5000))
        let revision=navigationRevision
        guard !view.isLoading else { throw Failure("The document is navigating. Wait for it to load before running page JavaScript.") }
        let before=try await run("snapshot",[:],in:view)
        let document=before["document"] as? String
        func current() throws {
            try Task.checkCancellation()
            guard isPermitted() else { throw Failure("Browser tool access changed while page JavaScript was pending. Its result was discarded.") }
            guard try ownedView() === view,navigationRevision == revision,!view.isLoading else {
                throw Failure("The document changed while page JavaScript was running. Its result was discarded; read browser_snapshot again.")
            }
        }
        try current()
        let reply=Evaluation()
        let value:Any
        do {
            value = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    reply.bind(continuation)
                    guard !reply.finished else { return }
                    view.callAsyncJavaScript(Self.pageScript(code),arguments:[:],in:nil,in:.page,completionHandler:{ reply.finish($0) })
                    DispatchQueue.main.asyncAfter(deadline:.now()+Double(timeout)/1000) {
                        reply.finish(.failure(Failure("Page JavaScript timed out. It may still be running or may have changed the page; inspect fresh state before retrying.")))
                    }
                }
            },onCancel:{ reply.finish(.failure(CancellationError())) })
        } catch {
            // Navigation can reject WebKit's callback before our normal final
            // validation. Never present that old document's value as fresh.
            try current()
            throw error
        }
        try current()
        guard let result=value as? [String:Any] else { throw Failure("Page JavaScript returned an invalid result envelope") }
        if let error=result["error"] as? String { throw Failure("Page JavaScript: " + String(error.prefix(400)) + ". The script may have changed the page.") }
        guard let encoded=result["json"] as? String,encoded.utf8.count<=65536,
              let bytes=encoded.data(using:.utf8) else { throw Failure("Page JavaScript result exceeded its 65536-byte limit or was not JSON-safe") }
        let decoded:Any
        do { decoded=try JSONSerialization.jsonObject(with:bytes,options:[.fragmentsAllowed]) }
        catch { throw Failure("Page JavaScript returned an invalid JSON result") }
        let after=try await run("snapshot",[:],in:view)
        try current()
        guard let document,after["document"] as? String == document else { throw Failure("The document changed while page JavaScript was running. Its result was discarded; read browser_snapshot again.") }
        return Self.json(["ok":true,"execution":"pageJavaScript","result":decoded,"resultBytes":bytes.count,
            "completion":"JavaScript completed in the current main document. This does not prove trusted input or UI flow success.","snapshot":after,"tab":tabID.uuidString])
    }

    private static func pageScript(_ code:String) -> String {
        #"""
        try {
          const __searchEvaluation_value=await (async()=>{
        \#(code)
          })();
          const __searchEvaluation_ancestors=new WeakSet();let __searchEvaluation_nodes=0,__searchEvaluation_characters=0;
          const __searchEvaluation_copy=(__searchEvaluation_item,__searchEvaluation_depth)=>{
            if(++__searchEvaluation_nodes>2000||__searchEvaluation_depth>20)throw Error('Result exceeds the 2000-value or 20-level limit');
            if(__searchEvaluation_item===undefined)throw Error('Result contains undefined; use return with explicit JSON-safe values');
            if(__searchEvaluation_item===null||typeof __searchEvaluation_item==='boolean')return __searchEvaluation_item;
            if(typeof __searchEvaluation_item==='number'){if(!Number.isFinite(__searchEvaluation_item))throw Error('Result contains a non-finite number');return __searchEvaluation_item}
            if(typeof __searchEvaluation_item==='string'){__searchEvaluation_characters+=__searchEvaluation_item.length;if(__searchEvaluation_characters>32768)throw Error('Result exceeds the string limit');return __searchEvaluation_item}
            if(typeof __searchEvaluation_item!=='object')throw Error('Result contains a non-JSON value: '+typeof __searchEvaluation_item);
            if(__searchEvaluation_ancestors.has(__searchEvaluation_item))throw Error('Result contains a circular reference');
            const __searchEvaluation_array=Array.isArray(__searchEvaluation_item),__searchEvaluation_prototype=Object.getPrototypeOf(__searchEvaluation_item);
            if(!__searchEvaluation_array&&__searchEvaluation_prototype!==Object.prototype&&__searchEvaluation_prototype!==null)throw Error('Return plain JSON objects; convert DOM nodes, Dates, Maps and Sets explicitly');
            __searchEvaluation_ancestors.add(__searchEvaluation_item);let __searchEvaluation_result;
            if(__searchEvaluation_array){if(__searchEvaluation_item.length>2000)throw Error('Result array is too large');__searchEvaluation_result=[];for(let i=0;i<__searchEvaluation_item.length;i++)__searchEvaluation_result.push(__searchEvaluation_copy(__searchEvaluation_item[i],__searchEvaluation_depth+1))}
            else {__searchEvaluation_result=Object.create(null);for(const __searchEvaluation_key in __searchEvaluation_item){if(!Object.prototype.hasOwnProperty.call(__searchEvaluation_item,__searchEvaluation_key))continue;__searchEvaluation_characters+=__searchEvaluation_key.length;if(__searchEvaluation_characters>32768)throw Error('Result exceeds the string limit');__searchEvaluation_result[__searchEvaluation_key]=__searchEvaluation_copy(__searchEvaluation_item[__searchEvaluation_key],__searchEvaluation_depth+1)}}
            __searchEvaluation_ancestors.delete(__searchEvaluation_item);return __searchEvaluation_result;
          };
          const __searchEvaluation_json=JSON.stringify(__searchEvaluation_copy(__searchEvaluation_value,0));
          if(new TextEncoder().encode(__searchEvaluation_json).length>65536)throw Error('Result exceeds the 65536-byte limit');
          return {json:__searchEvaluation_json};
        }catch(__searchEvaluation_error){return {error:String(__searchEvaluation_error?.message||__searchEvaluation_error).slice(0,400)}}
        """#
    }

    private func ownedView() throws -> WKWebView {
        guard let tab, tab.id == tabID, tab.isWeb, let web, tab.built === web else { throw Failure("The original browser tab is no longer available") }
        guard ["http","https"].contains(tab.pageAddress?.scheme?.lowercased() ?? ""), ["http","https"].contains(web.url?.scheme?.lowercased() ?? "") else { throw Failure("Browser tools only work on HTTP or HTTPS documents") }
        guard !tab.proxyPaused else { throw Failure("The tab is blocked while its protected connection changes") }
        return web
    }
    private func requireWindow(_ view: WKWebView) throws {
        guard let window = view.window, (Store.testing || (window.isVisible && !window.isMiniaturized)), !view.isHiddenOrHasHiddenAncestor, window.attachedSheet == nil, NSApp.modalWindow == nil else { throw Failure("The original tab must be visible in a browser window, without a modal dialog, for native input") }
        window.makeFirstResponder(view)
    }
    private func mouse(_ target: [String:Any], in view: WKWebView) throws {
        try requireWindow(view)
        guard let cssX = target["x"] as? Double, let cssY = target["y"] as? Double,
              let viewportWidth = target["viewportWidth"] as? Double, viewportWidth > 0,
              let viewportHeight = target["viewportHeight"] as? Double, viewportHeight > 0 else { throw Failure("WebKit did not return a usable viewport") }
        let x = (cssX - ((target["viewportX"] as? Double) ?? 0)) * view.bounds.width / viewportWidth
        let y = (cssY - ((target["viewportY"] as? Double) ?? 0)) * view.bounds.height / viewportHeight
        guard view.bounds.width > x, view.bounds.height > y, x >= 0, y >= 0 else { throw Failure("The element is outside this tab's visible viewport") }
        let point = view.convert(NSPoint(x:x,y:view.isFlipped ? y : view.bounds.height-y),to:nil)
        for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:view.window!.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:type == .leftMouseDown ? 1 : 0) else { throw Failure("Native mouse input could not be created") }
            if type == .leftMouseDown { view.mouseDown(with:event) } else { view.mouseUp(with:event) }
        }
    }
    private func key(_ text: String, code: UInt16, in view: WKWebView) throws {
        try requireWindow(view)
        for type in [NSEvent.EventType.keyDown,.keyUp] {
            guard let event = NSEvent.keyEvent(with:type,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:view.window!.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code) else { throw Failure("Native keyboard input could not be created") }
            if type == .keyDown { view.keyDown(with:event) } else { view.keyUp(with:event) }
        }
    }
    private static let keys: [String:(String,UInt16)] = ["Enter":("\r",36),"Tab":("\t",48),"Escape":("\u{1b}",53),"Backspace":("\u{8}",51),"Delete":("\u{f728}",117),"ArrowUp":("\u{f700}",126),"ArrowDown":("\u{f701}",125),"ArrowLeft":("\u{f702}",123),"ArrowRight":("\u{f703}",124),"Home":("\u{f729}",115),"End":("\u{f72b}",119),"Space":(" ",49)]
    private static func characterCode(_ character: Character) -> UInt16 {
        if character == "\n" { return 36 }; if character == "\t" { return 48 }
        let codes: [Character:UInt16] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"o":31,"u":32,"i":34,"p":35,"l":37,"j":38,"k":40,"n":45,"m":46]
        return character.lowercased().first.flatMap { codes[$0] } ?? 49
    }
    private struct Failure: LocalizedError { let errorDescription: String?; init(_ message:String) { errorDescription = message } }
    private static func json(_ value:[String:Any]) -> String { (try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])).flatMap { String(data:$0,encoding:.utf8) } ?? "{\"error\":\"Unserializable browser result\"}" }

    private func run(_ operation:String,_ arguments:[String:Any],in view:WKWebView,timeout:Double = 8) async throws -> [String:Any] {
        let reply = Evaluation()
        let value: Any = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                reply.bind(continuation)
                guard !reply.finished else { return }
                view.callAsyncJavaScript(Self.script,arguments:["operation":operation,"args":arguments],in:nil,in:Web.world,completionHandler:{ reply.finish($0) })
                DispatchQueue.main.asyncAfter(deadline:.now()+timeout) { reply.finish(.failure(Failure("Browser operation timed out. Already dispatched work may still be running; inspect state before retrying."))) }
            }
        },onCancel:{ reply.finish(.failure(CancellationError())) })
        guard let output = value as? [String:Any] else { throw Failure("WebKit returned no browser result") }
        if let error = output["error"] as? String { throw Failure(error) }
        return output
    }
    private final class Evaluation: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Any,Error>?
        private var result: Result<Any,Error>?
        var finished: Bool { lock.withLock { result != nil } }
        func bind(_ value:CheckedContinuation<Any,Error>) { lock.lock(); if let result { lock.unlock(); value.resume(with:result) } else { continuation=value; lock.unlock() } }
        func finish(_ value:Result<Any,Error>) { lock.lock(); guard result == nil else { lock.unlock(); return }; result=value; let next=continuation; continuation=nil; lock.unlock(); next?.resume(with:value) }
    }

    private static let script = #"""
    const slot='__searchAIBrowserToolsV1';
    let state=window[slot];
    if(!state || state.document!==document) state=window[slot]={document,token:typeof crypto.randomUUID==='function'?crypto.randomUUID():Array.from(crypto.getRandomValues(new Uint8Array(16)),b=>b.toString(16).padStart(2,'0')).join(''),next:0,refs:new Map(),ids:new WeakMap()};
    const cut=(v,n=500)=>String(v??'').slice(0,n);
    const visible=e=>{const r=e.getBoundingClientRect(),s=getComputedStyle(e);return e.isConnected&&r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none'&&!e.closest('[hidden],[inert]')};
    const reference=e=>{let id=state.ids.get(e);if(!id){if(state.refs.size>=2000)throw Error('Element reference limit reached; reload the document to start a new reference session');id=state.token+':'+(++state.next);state.ids.set(e,id);state.refs.set(id,e)}return id};
    const element=()=>{if(typeof args.ref!=='string'||!args.ref.startsWith(state.token+':'))throw Error('Stale or missing element ref. Read browser_snapshot again.');const e=state.refs.get(args.ref);if(!e||!e.isConnected||e.ownerDocument!==document)throw Error('Element ref is detached. Read browser_snapshot again.');return e};
    const writable=e=>{if(!visible(e)||e.disabled||e.readOnly)throw Error('Element is hidden, disabled or read-only')};
    try{
      if(operation==='snapshot'){
        const elements=[];let eligible=0;
        for(const e of document.querySelectorAll('a[href],button,input,textarea,select,summary,[role="button"],[role="link"],[tabindex],[contenteditable="true"]')){
          if(!visible(e))continue;eligible++;if(elements.length>=300)continue;
          elements.push({ref:reference(e),tag:e.tagName.toLowerCase(),role:e.getAttribute('role')||'',type:e.getAttribute('type')||'',name:cut(e.getAttribute('aria-label')||e.labels?.[0]?.innerText||e.innerText||e.getAttribute('placeholder')||e.getAttribute('name')||e.id),disabled:!!e.disabled,value:e.type==='password'?'[password omitted]':cut(e.value??'',1000)});
        }
        const text=document.body?.innerText||'';
        return {document:state.token,url:location.href,title:cut(document.title),text:cut(text,12000),elements,truncated:eligible>elements.length||text.length>12000,textTruncated:text.length>12000,elementsTruncated:eligible>elements.length,scope:'current tab main document; screenshots, frames and native dialogs are not represented'};
      }
      if(operation==='request'){
        if(typeof args.url!=='string'||args.url.length>4096)throw Error('Request needs a URL of at most 4096 characters');
        const url=new URL(args.url,location.href);if(!['http:','https:'].includes(url.protocol)||url.origin!==location.origin||url.username||url.password)throw Error('Browser requests must stay on this page origin without embedded credentials');
        const method=String(args.method||'GET').toUpperCase();if(!['GET','HEAD','POST','PUT','PATCH','DELETE','OPTIONS'].includes(method))throw Error('Unsupported HTTP method');
        if(typeof args.body!=='undefined'&&(typeof args.body!=='string'||args.body.length>32768||['GET','HEAD'].includes(method)))throw Error('Body must be at most 32768 characters and is not available with GET/HEAD');
        const headers=new Headers(args.headers||{});for(const [name] of headers)if(/^(cookie|host|origin|referer|proxy-|sec-)/i.test(name))throw Error('Browser-controlled headers cannot be supplied');
        const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),Math.min(10000,Math.max(100,Number(args.timeoutMs)||5000)));
        try{const response=await fetch(url.href,{method,headers,body:args.body,credentials:'same-origin',redirect:'error',signal:controller.signal});
          const reader=response.body?.getReader();let size=0,chunks=[],truncated=false;
          if(reader){while(true){const {done,value}=await reader.read();if(done)break;const remaining=131072-size;chunks.push(value.slice(0,remaining));size+=Math.min(remaining,value.length);if(value.length>remaining||size>=131072){truncated=true;await reader.cancel();break}}}
          const body=new Uint8Array(size);let offset=0;for(const chunk of chunks){body.set(chunk,offset);offset+=chunk.length}
          return {ok:response.ok,status:response.status,url:response.url,headers:Object.fromEntries(response.headers),body:new TextDecoder().decode(body),truncated,mode:'same-origin WebKit fetch with existing session; endpoint test, not UI validation'};
        }finally{clearTimeout(timer)}
      }
      if(operation==='condition'){
        const condition=args.condition;let e=args.ref?element():null,passed=false;
        if(condition==='url')passed=location.href.includes(String(args.expected??''));
        else if(condition==='text')passed=String(e?.innerText??document.body?.innerText??'').includes(String(args.expected??''));
        else if(!e)throw Error('This condition needs an element ref');
        else if(condition==='visible')passed=visible(e);else if(condition==='hidden')passed=!visible(e);else if(condition==='enabled')passed=!e.disabled;else if(condition==='disabled')passed=!!e.disabled;else if(condition==='value')passed=String(e.value??'')===String(args.expected??'');
        return {passed,condition,expected:cut(args.expected,2000)};
      }
      if(operation==='scroll'){const e=args.ref?element():window;e.scrollBy({left:Number(args.x)||0,top:Number(args.y)||0,behavior:'instant'});return {ok:true,mode:'DOM scrollBy'}}
      const e=element();writable(e);
      if(operation==='point'){
        e.scrollIntoView({block:'center',inline:'center',behavior:'instant'});const r=e.getBoundingClientRect(),x=r.left+r.width/2,y=r.top+r.height/2,hit=document.elementFromPoint(x,y);
        if(!hit||!(e===hit||e.contains(hit)))throw Error('Element is covered or outside the viewport');
        const viewport=window.visualViewport;
        return {x,y,viewportWidth:viewport?.width||innerWidth,viewportHeight:viewport?.height||innerHeight,viewportX:viewport?.offsetLeft||0,viewportY:viewport?.offsetTop||0,document:state.token};
      }
      if(operation==='focusText'){
        if(!(e instanceof HTMLInputElement||e instanceof HTMLTextAreaElement)||(['checkbox','radio','button','submit','file','range','color','hidden'].includes(e.type)))throw Error('Fill requires a text input or textarea');
        if(e instanceof HTMLInputElement&&args.text.includes('\n'))throw Error('Newlines are only allowed in a textarea');
        e.focus();if(document.activeElement!==e)throw Error('Element could not receive focus');
        try{e.setSelectionRange(0,e.value.length)}catch{throw Error('This input does not support text selection')};return {ok:true};
      }
      if(operation==='focus'){e.focus();if(document.activeElement!==e)throw Error('Element could not receive focus');return {ok:true}}
      if(operation==='select'){
        if(!(e instanceof HTMLSelectElement)||e.multiple)throw Error('Select requires a single-value select element');
        const option=Array.from(e.options).find(o=>o.value===args.value);if(!option||option.disabled||option.parentElement?.disabled)throw Error('No enabled option has that value');
        e.value=args.value;e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));return {ok:true,mode:'DOM selection and synthetic input/change events'};
      }
      throw Error('Unknown browser operation');
    }catch(error){return {error:cut(error.message||error,500)}}
    """#
}
