import AppKit
import Network
import WebKit
import XCTest
@testable import Search

/// Real WebKit documents and a disposable loopback server; no user cookies,
/// external accounts, AI provider or Bench listener are involved.
@MainActor
final class AIBrowserToolsTests: XCTestCase {
    private var tab: Tab!
    private var tools: AIBrowserTools!
    private var window: NSWindow!
    private var server: BrowserToolHTTPServer!
    private var origin: URL!

    override class func setUp() { setenv("SEARCH_PROBE","ai-browser-tools-\(getpid())",1); super.setUp() }
    override func setUp() async throws {
        _ = NSApplication.shared
        _ = Shared.prefs
        Proxy.shared.automaticTarget = nil
        Proxy.shared.take(ProxySetup())
        for _ in 0..<100 where Proxy.shared.changingContent { try await Task.sleep(for:.milliseconds(20)) }
        server = try BrowserToolHTTPServer()
        origin = URL(string:"http://127.0.0.1:\(try await server.start())")!
        tab = Tab(configuration:Web.configuration(shy:true))
        tab.setAddressOptimistically(origin.appendingPathComponent("fixture"))
        tab.web.frame = NSRect(x:0,y:0,width:800,height:600)
        window = NSWindow(contentRect:NSRect(x:-12000,y:-12000,width:800,height:600),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.contentView = tab.web
        window.orderBack(nil)
        tab.web.load(URLRequest(url:origin.appendingPathComponent("fixture")))
        try await loaded()
        tools = AIBrowserTools(tab:tab)
    }
    override func tearDown() async throws {
        tools = nil; tab?.built?.stopLoading(); window?.contentView=nil; window?.close(); window=nil; tab=nil
        server?.stop(); server=nil
    }

    func testSnapshotRefsAreStableAndPasswordsAreOmitted() async throws {
        let first = try await call("browser_snapshot")
        let second = try await call("browser_snapshot")
        XCTAssertEqual(try ref("Name",first),try ref("Name",second))
        XCTAssertEqual(first["document"] as? String,second["document"] as? String)
        let password = try XCTUnwrap((first["elements"] as? [[String:Any]])?.first { $0["type"] as? String == "password" })
        XCTAssertEqual(password["value"] as? String,"[password omitted]")
        XCTAssertFalse(String(describing:first).contains("synthetic-password"))
    }
    func testNativeClickRunsTrustedPageHandlerAndReturnsFreshState() async throws {
        let snapshot = try await call("browser_snapshot")
        let clicked = try await call("browser_click",["ref":try ref("Click fixture",snapshot)])
        XCTAssertNil(clicked["error"])
        try await until { (try? await self.tab.web.evaluateJavaScript("window.clicked===true && window.trusted===true") as? Bool) == true }
        let verified = try await call("browser_wait",["condition":"text","expected":"Clicked fixture","timeoutMs":2000])
        let state = try XCTUnwrap(verified["snapshot"] as? [String:Any])
        XCTAssertTrue((state["text"] as? String ?? "").contains("Clicked fixture"))
    }
    func testNativeClickUsesZoomedViewportCoordinates() async throws {
        tab.web.pageZoom = 1.5
        let reference = try ref("Click fixture",await call("browser_snapshot"))
        let clicked = try await call("browser_click",["ref":reference])
        XCTAssertNil(clicked["error"],String(describing:clicked))
        let verified = try await call("browser_wait",["condition":"text","expected":"Clicked fixture","timeoutMs":2000])
        let geometry = try await tab.web.evaluateJavaScript("JSON.stringify({innerWidth,innerHeight,vp:{width:visualViewport.width,height:visualViewport.height,scale:visualViewport.scale,x:visualViewport.offsetLeft,y:visualViewport.offsetTop},button:document.querySelector('#click').getBoundingClientRect().toJSON(),clicked:window.clicked,trusted:window.trusted})") as? String
        XCTAssertEqual(verified["passed"] as? Bool,true,"\(String(describing:geometry)); bounds=\(tab.web.bounds); zoom=\(tab.web.pageZoom); result=\(clicked)")
    }
    func testNativeFillAndPressReachInputHandlers() async throws {
        let reference = try ref("Name",await call("browser_snapshot"))
        let filled = try await call("browser_fill",["ref":reference,"text":"Edited value"])
        XCTAssertNil(filled["error"],String(describing:filled))
        try await until { (try? await self.tab.web.evaluateJavaScript("document.querySelector('#name').value==='Edited value' && window.inputTrusted===true") as? Bool) == true }
        let pressed = try await call("browser_press",["ref":reference,"key":"Enter"])
        XCTAssertNil(pressed["error"])
        try await until { (try? await self.tab.web.evaluateJavaScript("window.entered===true") as? Bool) == true }
    }
    func testSelectIsExplicitlyDOMAndAssertionsCheckTheResult() async throws {
        let reference = try ref("Country",await call("browser_snapshot"))
        let selected = try await call("browser_select",["ref":reference,"value":"ca"])
        XCTAssertNil(selected["error"])
        XCTAssertTrue((selected["mode"] as? String ?? "").contains("DOM"))
        let check = try await call("browser_assert",["ref":reference,"condition":"value","expected":"ca"])
        XCTAssertEqual(check["passed"] as? Bool,true)
        let synthetic = try await tab.web.evaluateJavaScript("window.selectionTrusted===false") as? Bool
        XCTAssertEqual(synthetic,true)
    }
    func testDetachedAndPreviousDocumentRefsCannotAct() async throws {
        let old = try ref("Click fixture",await call("browser_snapshot"))
        _ = try await tab.web.evaluateJavaScript("document.querySelector('#click').remove();true")
        let detached = try await call("browser_click",["ref":old])
        XCTAssertTrue((detached["error"] as? String ?? "").contains("detached"))
        tab.web.load(URLRequest(url:origin.appendingPathComponent("fixture")))
        try await loaded()
        let stale = try await call("browser_click",["ref":old])
        XCTAssertTrue((stale["error"] as? String ?? "").contains("Stale"))
    }
    func testWaitObservesChangesTimesOutAndCancels() async throws {
        _ = try await tab.web.evaluateJavaScript("setTimeout(()=>document.querySelector('#result').textContent='Eventually ready',150);true")
        let success = try await call("browser_wait",["condition":"text","expected":"Eventually ready","timeoutMs":2000])
        XCTAssertEqual(success["passed"] as? Bool,true)
        let timeout = try await call("browser_wait",["condition":"text","expected":"Never appears","timeoutMs":120])
        XCTAssertEqual(timeout["timedOut"] as? Bool,true)
        let task = Task { await self.tools.call("browser_wait",arguments:["condition":"text","expected":"Never appears","timeoutMs":10000]) }
        try await Task.sleep(for:.milliseconds(80)); task.cancel()
        let cancelled = try json(await task.value)
        XCTAssertTrue((cancelled["error"] as? String ?? "").contains("cancelled"))
    }
    func testRequestUsesExistingHttpOnlySessionAndKeepsEndpointEvidenceSeparate() async throws {
        let cookies = try await tab.web.evaluateJavaScript("document.cookie") as? String
        XCTAssertFalse((cookies ?? "").contains("toolSession"))
        let response = try await call("browser_request",["url":"/api","method":"POST","body":"fixture-payload"])
        XCTAssertNil(response["error"],String(describing:response))
        XCTAssertEqual(response["status"] as? Int,200)
        let body = try json(response["body"] as? String ?? "")
        XCTAssertTrue((body["cookie"] as? String ?? "").contains("toolSession=existing-session"))
        XCTAssertEqual(body["body"] as? String,"fixture-payload")
        XCTAssertTrue((response["mode"] as? String ?? "").contains("not UI validation"))
        XCTAssertNotNil(response["snapshot"])
    }
    func testRequestCannotChangeOriginOrSupplyBrowserControlledHeadersAndBodyIsBounded() async throws {
        let foreign = try await call("browser_request",["url":"https://example.invalid/api"])
        XCTAssertTrue((foreign["error"] as? String ?? "").contains("page origin"))
        let cookie = try await call("browser_request",["url":"/api","headers":["Cookie":"injected"]])
        XCTAssertTrue((cookie["error"] as? String ?? "").contains("Browser-controlled"))
        let large = try await call("browser_request",["url":"/large"])
        XCTAssertEqual(large["truncated"] as? Bool,true)
        XCTAssertEqual((large["body"] as? String)?.utf8.count,131072)
    }
    func testUnknownToolsAndOversizeInputsFailWithoutActing() async throws {
        let unknown = try await call("browser_launch")
        let large = try await call("browser_fill",["ref":"missing","text":String(repeating:"x",count:2049)])
        let shortcut = try await call("browser_press",["ref":"missing","key":"Command+Q"])
        XCTAssertNotNil(unknown["error"])
        XCTAssertNotNil(large["error"])
        XCTAssertNotNil(shortcut["error"])
    }
    func testCoveredClickAndControlCharactersAreRejected() async throws {
        let snapshot = try await call("browser_snapshot")
        let button = try ref("Click fixture",snapshot), field = try ref("Name",snapshot)
        let tabbed = try await call("browser_fill",["ref":field,"text":"wrong\tfield"])
        let newline = try await call("browser_fill",["ref":field,"text":"wrong\nsubmit"])
        XCTAssertNotNil(tabbed["error"]); XCTAssertNotNil(newline["error"])
        _ = try await tab.web.evaluateJavaScript("const cover=document.createElement('div');cover.style='position:fixed;inset:0;z-index:999999';document.body.append(cover);true")
        let covered = try await call("browser_click",["ref":button])
        XCTAssertTrue((covered["error"] as? String ?? "").contains("covered"))
        let untouched = try await tab.web.evaluateJavaScript("document.querySelector('#name').value==='Initial value' && !window.clicked") as? Bool
        XCTAssertEqual(untouched,true)
    }
    func testSleepingOriginalTabCannotBeUsedOrWokenByOldTools() async throws {
        _ = try await call("browser_snapshot")
        tab.sleep(picture:nil)
        XCTAssertNil(tab.built)
        let stopped = try await call("browser_snapshot")
        XCTAssertTrue((stopped["error"] as? String ?? "").contains("no longer available"))
        XCTAssertNil(tab.built,"A stale tool must never wake or rebuild its old tab")
    }
    func testEvaluateUsesPageGlobalsAwaitsPromisesAndDoesNotStartInspection() async throws {
        XCTAssertTrue(AIBrowserTools.definitions.contains { $0["name"] as? String == "browser_evaluate" })
        XCTAssertFalse(tab.aiInspection.recording)
        let output = try await call("browser_evaluate",["code":"window.fixtureGame.score += 41; document.querySelector('#result').textContent='Evaluated fixture'; return {score:window.fixtureGame.score, lexical:pageLexicalFixture};"])
        XCTAssertNil(output["error"],String(describing:output))
        XCTAssertEqual(output["execution"] as? String,"pageJavaScript")
        let result = try XCTUnwrap(output["result"] as? [String:Any])
        XCTAssertEqual(result["score"] as? Int,42)
        XCTAssertEqual(result["lexical"] as? Int,7)
        XCTAssertTrue(((output["snapshot"] as? [String:Any])?["text"] as? String)?.contains("Evaluated fixture") == true)
        let promised = try await call("browser_evaluate",["code":"return await new Promise(resolve=>setTimeout(()=>resolve(window.fixtureGame.score),25));"])
        XCTAssertEqual(promised["result"] as? Int,42)
        let null = try await call("browser_evaluate",["code":"return null;"])
        XCTAssertTrue(null["result"] is NSNull)
        XCTAssertFalse(tab.aiInspection.recording,"Executing page JavaScript must not enable raw Inspector/network capture")
    }

    func testEvaluateReportsErrorsNonJSONValuesAndResultLimitsExplicitly() async throws {
        for (code,expected) in [
            ("return undefined;","undefined"),
            ("const value={};value.self=value;return value;","circular"),
            ("throw Error('fixture-evaluation-error');","fixture-evaluation-error"),
            ("return 7n;","non-JSON"),
            ("return NaN;","non-finite"),
            ("return document.body;","plain JSON"),
            ("return 'X'.repeat(100000);","limit")
        ] {
            let output = try await call("browser_evaluate",["code":code])
            XCTAssertTrue((output["error"] as? String ?? "").contains(expected),"\(code): \(output)")
            XCTAssertEqual(output["execution"] as? String,"pageJavaScript")
            XCTAssertNil(output["snapshot"],"Errors must not be presented as a successful fresh evaluation")
        }
        let oversized = try await call("browser_evaluate",["code":String(repeating:" ",count:16001)+"window.shouldNeverRun=true;return true;"])
        XCTAssertNotNil(oversized["error"])
        let untouched = try await tab.web.evaluateJavaScript("typeof window.shouldNeverRun==='undefined'") as? Bool
        XCTAssertEqual(untouched,true)
    }

    func testEvaluateTimeoutAndCancellationDiscardLateResults() async throws {
        let timeout = try await call("browser_evaluate",["code":"return new Promise(()=>{});","timeoutMs":100])
        XCTAssertTrue((timeout["error"] as? String ?? "").contains("timed out"))
        XCTAssertNil(timeout["result"]);XCTAssertNil(timeout["snapshot"])
        let pending = Task { await self.tools.call("browser_evaluate",arguments:["code":"window.evaluationStarted=true;return new Promise(resolve=>setTimeout(()=>resolve('late fixture result'),300));","timeoutMs":2000]) }
        try await until { (try? await self.tab.web.evaluateJavaScript("window.evaluationStarted===true") as? Bool) == true }
        pending.cancel()
        let cancelled = try json(await pending.value)
        XCTAssertTrue((cancelled["error"] as? String ?? "").contains("cancelled"))
        XCTAssertNil(cancelled["result"]);XCTAssertNil(cancelled["snapshot"])
        try await Task.sleep(for:.milliseconds(350))
        let fresh = try await call("browser_evaluate",["code":"return window.fixtureGame.score;"])
        XCTAssertEqual(fresh["result"] as? Int,1,"A late completion cannot corrupt or complete another evaluation")
        var permitted=true
        let revoked = Task { await self.tools.call("browser_evaluate",arguments:["code":"window.revocationStarted=true;return new Promise(resolve=>setTimeout(()=>resolve('revoked result'),100));"],isPermitted:{ permitted }) }
        try await until { (try? await self.tab.web.evaluateJavaScript("window.revocationStarted===true") as? Bool) == true }
        permitted=false
        let rejected = try json(await revoked.value)
        XCTAssertTrue((rejected["error"] as? String ?? "").contains("access changed"))
        XCTAssertNil(rejected["result"]);XCTAssertNil(rejected["snapshot"])
    }

    func testEvaluateNavigationDiscardsThePreviousDocumentResult() async throws {
        let pending = Task { await self.tools.call("browser_evaluate",arguments:["code":"window.evaluationStarted=true;return new Promise(resolve=>setTimeout(()=>resolve('old document value'),500));","timeoutMs":2000]) }
        try await until { (try? await self.tab.web.evaluateJavaScript("window.evaluationStarted===true") as? Bool) == true }
        tab.web.load(URLRequest(url:origin.appendingPathComponent("fixture")))
        try await loaded()
        let stale = try json(await pending.value)
        XCTAssertTrue((stale["error"] as? String ?? "").contains("document changed"),String(describing:stale))
        XCTAssertNil(stale["result"]);XCTAssertNil(stale["snapshot"])
        let fresh = try await call("browser_evaluate",["code":"return {score:window.fixtureGame.score,started:window.evaluationStarted===true};"])
        XCTAssertEqual((fresh["result"] as? [String:Any])?["score"] as? Int,1)
        XCTAssertEqual((fresh["result"] as? [String:Any])?["started"] as? Bool,false)
    }

    func testEvaluateHonorsJavaScriptDisabledAndHTTPDocumentPolicies() async throws {
        tab.web.configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let disabled = try await call("browser_evaluate",["code":"window.shouldNeverRun=true;return true;"])
        XCTAssertTrue((disabled["error"] as? String ?? "").contains("disabled"))
        tab.web.configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let untouched = try await tab.web.evaluateJavaScript("typeof window.shouldNeverRun==='undefined'") as? Bool
        XCTAssertEqual(untouched,true)
        tab.setAddressOptimistically(URL(fileURLWithPath:"/private/tmp/internal-fixture"))
        let unsupported = try await call("browser_evaluate",["code":"return window.fixtureGame.score;"])
        XCTAssertTrue((unsupported["error"] as? String ?? "").contains("HTTP"))
        let insecure=URL(string:"http://insecure-browser-tools.invalid/fixture")!
        tab.setAddressOptimistically(insecure)
        tab.web.loadHTMLString("<!doctype html><title>Browser tools fixture</title><p>Plain HTTP fixture</p>",baseURL:insecure)
        try await loaded()
        let allowed = try await call("browser_evaluate",["code":"return {secure:isSecureContext,title:document.title};"])
        XCTAssertNil(allowed["error"],String(describing:allowed))
        XCTAssertEqual((allowed["result"] as? [String:Any])?["secure"] as? Bool,false)
        XCTAssertEqual((allowed["result"] as? [String:Any])?["title"] as? String,"Browser tools fixture")
    }

    private func call(_ name:String,_ arguments:[String:Any] = [:]) async throws -> [String:Any] { try json(await tools.call(name,arguments:arguments)) }
    private func json(_ value:String) throws -> [String:Any] { try XCTUnwrap(JSONSerialization.jsonObject(with:Data(value.utf8)) as? [String:Any]) }
    private func ref(_ name:String,_ snapshot:[String:Any]) throws -> String { try XCTUnwrap((snapshot["elements"] as? [[String:Any]])?.first { $0["name"] as? String == name }?["ref"] as? String) }
    private func loaded() async throws {
        try await until {
            guard !self.tab.web.isLoading else { return false }
            return (try? await self.tab.web.evaluateJavaScript("document.title") as? String) == "Browser tools fixture"
        }
    }
    private func until(_ predicate:@escaping @MainActor () async throws -> Bool) async throws {
        let deadline=ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline { if try await predicate() { return }; try await Task.sleep(for:.milliseconds(25)) }
        throw URLError(.timedOut)
    }
}

private final class BrowserToolHTTPServer: @unchecked Sendable {
    private let listener:NWListener
    private let queue=DispatchQueue(label:"AIBrowserToolsTests.http")
    private let lock=NSLock()
    private var connections:[NWConnection]=[]
    private var starting=true
    init() throws { let params=NWParameters.tcp; params.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any); listener=try NWListener(using:params) }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: if self.lock.withLock({ let first=self.starting;self.starting=false;return first }) { continuation.resume(returning:self.listener.port!.rawValue) }
                case .failed(let error): if self.lock.withLock({ let first=self.starting;self.starting=false;return first }) { continuation.resume(throwing:error) }
                default:break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in guard let self else { return connection.cancel() }; self.lock.withLock { self.connections.append(connection) };connection.start(queue:self.queue);self.read(connection) }
            listener.start(queue:queue)
        }
    }
    func stop() { listener.cancel();for connection in lock.withLock({connections}) { connection.cancel() } }
    private func read(_ connection:NWConnection,_ previous:Data = Data()) {
        connection.receive(minimumIncompleteLength:1,maximumLength:65536) { [weak self] incoming,_,complete,error in
            guard let self else { return connection.cancel() };var data=previous;if let incoming { data.append(incoming) }
            guard let end=data.range(of:Data("\r\n\r\n".utf8)) else { if error == nil && !complete && data.count<65536 { self.read(connection,data) } else { connection.cancel() };return }
            let lines=String(decoding:data[..<end.lowerBound],as:UTF8.self).components(separatedBy:"\r\n")
            let path=lines[0].split(separator:" ").dropFirst().first.map(String.init) ?? "/"
            let headers=Dictionary(lines.dropFirst().compactMap { line -> (String,String)? in guard let colon=line.firstIndex(of:":") else { return nil };return (String(line[..<colon]).lowercased(),line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces)) },uniquingKeysWith: { _,new in new })
            let length=Int(headers["content-length"] ?? "0") ?? 0
            guard data.count>=end.upperBound+length else { if !complete && error == nil && data.count<131072 { self.read(connection,data) } else { connection.cancel() };return }
            let body:String,type:String,cookie:String
            if path == "/fixture" { body=Self.html;type="text/html";cookie="Set-Cookie: toolSession=existing-session; Path=/; HttpOnly; SameSite=Lax\r\n" }
            else if path == "/large" { body=String(repeating:"L",count:200000);type="text/plain";cookie="" }
            else { body=String(data:try! JSONSerialization.data(withJSONObject:["cookie":headers["cookie"] ?? "","body":String(decoding:data[end.upperBound..<(end.upperBound+length)],as:UTF8.self)]),encoding:.utf8)!;type="application/json";cookie="" }
            let response=Data("HTTP/1.1 200 OK\r\nContent-Type: \(type); charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\n\(cookie)Cache-Control: no-store\r\nConnection: close\r\n\r\n\(body)".utf8)
            connection.send(content:response,contentContext:.finalMessage,isComplete:true,completion:.contentProcessed { _ in connection.cancel() })
        }
    }
    private static let html = #"""
    <!doctype html><html><head><title>Browser tools fixture</title></head><body>
    <label>Name<input id="name" value="Initial value"></label><input type="password" value="synthetic-password">
    <label>Country<select id="country" aria-label="Country"><option value="us">US</option><option value="ca">Canada</option></select></label>
    <button id="click">Click fixture</button><p id="result">Waiting fixture</p>
    <script>
    window.fixtureGame={score:1};let pageLexicalFixture=7;
    document.querySelector('#click').addEventListener('click',e=>{window.clicked=true;window.trusted=e.isTrusted;document.querySelector('#result').textContent='Clicked fixture'});
    document.querySelector('#name').addEventListener('input',e=>window.inputTrusted=e.isTrusted);
    document.querySelector('#name').addEventListener('keydown',e=>{if(e.key==='Enter')window.entered=e.isTrusted});
    document.querySelector('#country').addEventListener('change',e=>window.selectionTrusted=e.isTrusted);
    </script></body></html>
    """#
}
