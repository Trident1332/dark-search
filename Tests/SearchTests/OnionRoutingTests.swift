import AppKit
import Foundation
import Network
import WebKit
import XCTest
@testable import Search

/// Every destination is answered by a loopback fixture. The synthetic Tor
/// child announces that fixture; no relay, onion service or public DNS is used.
@MainActor
final class OnionRoutingTests: XCTestCase {
    private let host = String(repeating: "a", count: 56) + ".onion"
    private var runtime: TorRuntime?
    private var fake: RoutingTorProcess?
    private var views: [WKWebView] = []

    override class func setUp() {
        setenv("SEARCH_PROBE", "onion-routing-tests-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        _ = Shared.prefs
        Onion.shared.stop()
        Onion.shared.take(enabled: true)
        Proxy.shared.automaticTarget = nil
        Proxy.shared.take(ProxySetup())
        for _ in 0..<100 where Proxy.shared.changingContent { try await Task.sleep(for: .milliseconds(20)) }
        try await super.setUp()
    }

    override func tearDown() async throws {
        for view in views { ProxyTimeZone.close(view) }
        views.removeAll()
        Onion.shared.stop()
        Onion.shared.useRuntimeForTesting(nil)
        runtime?.stop()
        runtime = nil
        fake?.remove()
        fake = nil
        Proxy.shared.take(ProxySetup())
        for _ in 0..<100 where Proxy.shared.changingContent { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(Proxy.shared.changingContent)
        try await super.tearDown()
    }

    private func until(timeout: TimeInterval = 8, _ predicate: @escaping @MainActor () -> Bool,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        if !predicate() {
            XCTFail("The isolated onion route did not complete", file: file, line: line)
            throw URLError(.timedOut)
        }
    }

    private func ordinaryProxy(_ port: UInt16) {
        Proxy.shared.take(ProxySetup(on: true, kind: .http, host: "127.0.0.1", port: port,
                                    blocks: false, matchesTimeZone: false))
    }

    private func connect(_ server: RoutingServer, exits: Bool = false) async throws {
        let fake = try RoutingTorProcess(port: try XCTUnwrap(server.port), exits: exits)
        self.fake = fake
        let runtime = TorRuntime(executableURL: fake.executable, dataFolder: fake.folder.appendingPathComponent("data"), bootstrapTimeout: 3)
        self.runtime = runtime
        Onion.shared.useRuntimeForTesting(runtime)
        _ = try await Onion.shared.connect()
    }

    private func makeView(tor: Bool, source given: WKWebsiteDataStore? = nil) -> WKWebView {
        let source = given ?? .nonPersistent()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = tor ? Onion.shared.store(for: source) : source
        Proxy.shared.apply(to: configuration.websiteDataStore, profile: Profile.personalID)
        Proxy.shared.prepare(configuration)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        Proxy.shared.track(view)
        views.append(view)
        return view
    }

    private func refuseOrdinaryFetch(_ url: URL, file: StaticString = #filePath, line: UInt = #line) async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.7
        configuration.timeoutIntervalForResource = 1
        let session = Proxy.makeSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.7
        do {
            _ = try await session.proxyData(for: request)
            XCTFail("An ordinary client must not reach an onion service", file: file, line: line)
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotConnectToHost,
                           "The closed loopback SOCKS guard must fail before resolving the onion name", file: file, line: line)
        } catch {
            XCTFail("The onion guard returned an unexpected error: \(error)", file: file, line: line)
        }
    }

    func testOrdinaryFoundationOnionRequestsNeverFallThroughToNormalProxy() async throws {
        let ordinary = try RoutingServer(mode: .ordinary)
        let port = try await ordinary.start()
        defer { ordinary.stop() }
        ordinaryProxy(port)
        let control = Proxy.makeSession(configuration: .ephemeral)
        defer { control.invalidateAndCancel() }
        let (body, _) = try await control.proxyData(from: URL(string: "http://ordinary.example.invalid/control")!)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "ordinary fixture")
        let before = ordinary.connectionCount
        for authority in [host, "sub." + host, host.uppercased() + "."] {
            await refuseOrdinaryFetch(URL(string: "http://\(authority)/never-direct")!)
        }
        XCTAssertEqual(ordinary.connectionCount, before, "Neither HTTP CONNECT nor a direct fallback may disclose an onion name")
    }

    func testOrdinaryWebKitOnionRequestIsBlockedBeforeNormalProxy() async throws {
        let ordinary = try RoutingServer(mode: .ordinary)
        ordinaryProxy(try await ordinary.start())
        defer { ordinary.stop() }
        let view = makeView(tor: false)
        let navigation = OnionNavigation()
        view.navigationDelegate = navigation
        var request = URLRequest(url: URL(string: "http://\(host)/blocked")!)
        request.timeoutInterval = 1
        view.load(request)
        try await until { navigation.finished }
        XCTAssertFalse(navigation.loaded)
        XCTAssertEqual(ordinary.connectionCount, 0)
    }

    func testReadyTorDoesNotOpenOrdinarySessionsButExplicitTorSessionUsesRemoteDomain() async throws {
        let tor = try RoutingServer(mode: .socks)
        _ = try await tor.start()
        defer { tor.stop() }
        try await connect(tor)
        await refuseOrdinaryFetch(URL(string: "http://\(host)/ordinary-session")!)
        XCTAssertTrue(tor.socksRequests.isEmpty)
        let session = Proxy.makeSession(configuration: .ephemeral,
                                        route: OnionNetwork.configuration(port: Onion.shared.port),
                                        reportsAuthenticationFailures: false)
        defer { session.invalidateAndCancel() }
        let (body, response) = try await session.proxyData(from: URL(string: "http://\(host)/explicit-session")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "onion fixture")
        XCTAssertEqual(tor.socksRequests.map(\.host), [host])
        XCTAssertTrue(tor.socksRequests.allSatisfy { $0.addressType == 3 }, "The destination must be sent to SOCKS as a domain, without local resolution")
    }

    func testCircuitIsolationKeysFollowTorStoreAcrossWebKitAndNativeRequests() async throws {
        let tor = try RoutingServer(mode: .socks)
        let port = try await tor.start()
        defer { tor.stop() }
        try await connect(tor)
        let first = makeView(tor: true)
        let second = makeView(tor: true)

        func load(_ view: WKWebView, path: String) async throws -> RoutingServer.SOCKSRequest {
            let before = tor.socksRequests.count
            let navigation = OnionNavigation()
            view.navigationDelegate = navigation
            view.load(URLRequest(url: URL(string: "http://\(host)/\(path)")!))
            try await until { navigation.finished }
            XCTAssertTrue(navigation.loaded)
            let handshake = try XCTUnwrap(tor.socksRequests.dropFirst(before).first)
            XCTAssertEqual(handshake.username, OnionNetwork.Isolation.username)
            XCTAssertFalse(handshake.isolation?.isEmpty ?? true)
            return handshake
        }

        let firstPage = try await load(first, path: "isolation-first")
        let secondPage = try await load(second, path: "isolation-second")
        XCTAssertNotEqual(firstPage.isolation, secondPage.isolation, "Different Tor stores must not share a SOCKS isolation key")

        let auxiliary = try XCTUnwrap(OnionSession.make(for: first.configuration.websiteDataStore))
        defer { auxiliary.invalidateAndCancel() }
        let before = tor.socksRequests.count
        _ = try await auxiliary.proxyData(from: URL(string: "http://\(host)/isolation-auxiliary")!)
        let auxiliaryHandshake = try XCTUnwrap(tor.socksRequests.dropFirst(before).first)
        XCTAssertEqual(auxiliaryHandshake.username, firstPage.username)
        XCTAssertEqual(auxiliaryHandshake.isolation, firstPage.isolation, "An image fetch inherits its tab's circuit context")

        Proxy.shared.refreshOnionRoute(port: port)
        let rebuilt = try await load(first, path: "isolation-after-route-refresh")
        XCTAssertEqual(rebuilt.isolation, firstPage.isolation, "Rebuilding a listener route must preserve the active store's context")

        let guardedConfiguration = URLSessionConfiguration.ephemeral
        let guardSession = Proxy.makeSession(configuration: guardedConfiguration,
                                              route: OnionNetwork.configuration(port: port, suffixOnly: true),
                                              reportsAuthenticationFailures: false)
        defer { guardSession.invalidateAndCancel() }
        let guardBefore = tor.socksRequests.count
        _ = try await guardSession.proxyData(from: URL(string: "http://\(host)/isolation-suffix-guard")!)
        let guardHandshake = try XCTUnwrap(tor.socksRequests.dropFirst(guardBefore).first)
        XCTAssertEqual(guardHandshake.username, OnionNetwork.Isolation.username)
        XCTAssertNotEqual(guardHandshake.isolation, firstPage.isolation, "The ordinary suffix guard cannot join a private store's circuits")
        XCTAssertNotEqual(guardHandshake.isolation, secondPage.isolation)
    }

    func testReleasedTemporaryStoreDoesNotKeepItsCircuitContextAlive() async throws {
        let tor = try RoutingServer(mode: .socks)
        let port = try await tor.start()
        defer { tor.stop() }
        let source = WKWebsiteDataStore.nonPersistent()
        weak var released: WKWebsiteDataStore?
        var previous: ProxyConfiguration?
        autoreleasepool {
            let store = Onion.shared.store(for: source)
            released = store
            previous = Onion.shared.configuration(for: store, port: port)
        }
        // WebKit's asynchronous store initialization may own the wrapper
        // until its main-loop callback has finished. Poll only inside a
        // drained pool: observing a weak Objective-C reference must not
        // itself keep the wrapper alive through the following await.
        for _ in 0..<100 {
            if autoreleasepool(invoking: { released == nil }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(autoreleasepool(invoking: { released == nil }),
                      "Isolation bookkeeping must not retain a temporary Tor store after its owner closes")
        let next = Onion.shared.store(for: source)
        let fresh = Onion.shared.configuration(for: next, port: port)

        func fetch(_ route: ProxyConfiguration, path: String) async throws -> RoutingServer.SOCKSRequest {
            let session = Proxy.makeSession(configuration: .ephemeral, route: route, reportsAuthenticationFailures: false)
            defer { session.invalidateAndCancel() }
            let before = tor.socksRequests.count
            _ = try await session.proxyData(from: URL(string: "http://\(host)/\(path)")!)
            return try XCTUnwrap(tor.socksRequests.dropFirst(before).first)
        }
        let oldHandshake = try await fetch(try XCTUnwrap(previous), path: "retired-context")
        let newHandshake = try await fetch(fresh, path: "new-context")
        XCTAssertNotEqual(oldHandshake.isolation, newHandshake.isolation, "A new temporary store receives a fresh circuit context")
    }

    func testTorPageAssetsNativeClockAndPeerProtectionUseOneIsolatedRoute() async throws {
        try XCTSkipUnless(ProxyTimeZone.isSupported)
        let ordinary = try RoutingServer(mode: .ordinary)
        ordinaryProxy(try await ordinary.start())
        defer { ordinary.stop() }
        let local = try RoutingServer(mode: .ordinary)
        let localPort = try await local.start()
        defer { local.stop() }
        let control = URLSession(configuration: .ephemeral)
        defer { control.invalidateAndCancel() }
        _ = try await control.data(from: URL(string: "http://127.0.0.1:\(localPort)/reachable")!)
        XCTAssertEqual(local.httpRequests.count, 1)
        let tor = try RoutingServer(mode: .socks, localProbe: localPort)
        _ = try await tor.start()
        defer { tor.stop() }
        try await connect(tor)
        let view = makeView(tor: true)
        let navigation = OnionNavigation()
        view.navigationDelegate = navigation
        view.load(URLRequest(url: URL(string: "http://\(host)/page")!))
        try await until { navigation.finished }
        XCTAssertTrue(navigation.loaded)
        let observed = try await view.evaluateJavaScript("""
            (() => {
              let peer = false;
              try { const p = new RTCPeerConnection(); p.close(); peer = true; } catch (_) {}
              return {zone: Intl.DateTimeFormat().resolvedOptions().timeZone,
                asset: document.documentElement.dataset.assetLoaded || '', peer,
                utc: new Date(Date.UTC(2026,0,15,12)).toISOString()};
            })()
            """) as? [String: Any]
        XCTAssertEqual(observed?["zone"] as? String, "UTC")
        XCTAssertEqual(observed?["asset"] as? String, "yes", "Clearnet scripts embedded by the onion page must also travel through Tor")
        XCTAssertEqual(observed?["peer"] as? Bool, false)
        XCTAssertEqual(observed?["utc"] as? String, "2026-01-15T12:00:00.000Z")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(local.httpRequests.count, 1, "Numeric loopback subresources and sockets must be blocked before Network's local-address proxy exemption")
        XCTAssertEqual(ordinary.connectionCount, 0, "Onion page assets must not use the regular proxy")
        XCTAssertTrue(tor.socksRequests.map(\.host).contains(host))
        XCTAssertTrue(tor.socksRequests.map(\.host).contains("assets.example.invalid"))
        XCTAssertTrue(tor.socksRequests.allSatisfy { $0.addressType == 3 })
        XCTAssertTrue(Onion.shared.owns(view.configuration.websiteDataStore))
    }

    func testOnionRedirectToClearnetStaysInsideTorStore() async throws {
        let ordinary = try RoutingServer(mode: .ordinary)
        ordinaryProxy(try await ordinary.start())
        defer { ordinary.stop() }
        let tor = try RoutingServer(mode: .socks)
        _ = try await tor.start()
        defer { tor.stop() }
        try await connect(tor)
        let view = makeView(tor: true)
        let navigation = OnionNavigation()
        view.navigationDelegate = navigation
        view.load(URLRequest(url: URL(string: "http://\(host)/redirect")!))
        try await until { navigation.finished }
        XCTAssertTrue(navigation.loaded)
        XCTAssertEqual(view.url?.host(), "redirect.example.invalid")
        XCTAssertTrue(Onion.shared.owns(view.configuration.websiteDataStore))
        XCTAssertTrue(tor.socksRequests.map(\.host).contains("redirect.example.invalid"))
        XCTAssertEqual(ordinary.connectionCount, 0)
    }

    func testReadyTorRestorationWaitsForStageAttachmentBeforeLoading() async throws {
        let tor = try RoutingServer(mode: .socks)
        _ = try await tor.start()
        defer { tor.stop() }
        try await connect(tor)
        XCTAssertTrue(Onion.shared.ready)

        let tab = Tab(configuration: Web.configuration(shy: true, store: .nonPersistent()))
        tab.restore(url: URL(string: "http://\(host)/page")!, title: "Restored Tor fixture")
        XCTAssertTrue(tab.usesTor)
        XCTAssertTrue(tab.wake())
        try await until { tab.built != nil }
        let view = try XCTUnwrap(tab.built)
        views.append(view)
        let navigation = OnionNavigation()
        view.navigationDelegate = navigation
        XCTAssertNil(view.window)

        // A ready connection must not race the stage while the restored
        // view is still detached. The old path sent its request here.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(tor.socksRequests.isEmpty, "Restoring an onion page must wait for its stage before starting the request")

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
            ProxyTimeZone.close(view)
        }
        window.contentView = view
        XCTAssertFalse(window.isVisible, "The fixture attaches a stage without showing a test window")
        try await until { navigation.finished }
        XCTAssertTrue(navigation.loaded)
        let body = try await view.evaluateJavaScript("document.body.innerText") as? String
        XCTAssertTrue(body?.contains("Tor fixture") == true, "The restored page must finish loading after attachment")
        XCTAssertEqual(view.url?.host(), host)
        XCTAssertTrue(tor.socksRequests.map(\.host).contains(host))
    }

    func testRestoredOnionTabsUseSeparateTemporaryStoresWithoutCopyingCookies() async throws {
        let source = WKWebsiteDataStore.nonPersistent()
        let normal = Tab(configuration: Web.configuration(shy: true, store: source))
        let restored = Tab(configuration: Web.configuration(shy: true, store: source))
        restored.restore(url: URL(string: "http://\(host)/restored")!, title: "Restored onion")
        XCTAssertTrue(restored.usesTor)
        XCTAssertTrue(Onion.shared.owns(restored.store))
        XCTAssertFalse(normal.usesTor)
        XCTAssertTrue(normal.store === source)
        XCTAssertFalse(restored.store === source)
        XCTAssertFalse(restored.store.isPersistent)
        XCTAssertTrue(Onion.shared.store(for: source) === restored.store)
        XCTAssertTrue(Onion.shared.store(for: restored.store) === restored.store)
        XCTAssertFalse(Onion.shared.store(for: .nonPersistent()) === restored.store)
        XCTAssertNil(restored.built, "Restoration must not build a page or contact a relay")
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "normal-only", .value: "fixture", .domain: "example.invalid", .path: "/"]))
        await withCheckedContinuation { done in source.httpCookieStore.setCookie(cookie) { done.resume() } }
        let torCookies: [HTTPCookie] = await withCheckedContinuation { done in restored.store.httpCookieStore.getAllCookies { done.resume(returning: $0) } }
        XCTAssertFalse(torCookies.contains { $0.name == "normal-only" })
    }

    func testTorFailureAndDisabledSupportKeepOrdinaryOnionRouteClosed() async throws {
        let ordinary = try RoutingServer(mode: .ordinary)
        ordinaryProxy(try await ordinary.start())
        defer { ordinary.stop() }
        let tor = try RoutingServer(mode: .socks)
        _ = try await tor.start()
        defer { tor.stop() }
        do { try await connect(tor, exits: true); XCTFail("A failed synthetic Tor must not become ready") }
        catch { }
        XCTAssertFalse(Onion.shared.ready)
        await refuseOrdinaryFetch(URL(string: "http://\(host)/failed-tor")!)
        Onion.shared.take(enabled: false)
        do { _ = try await Onion.shared.connect(); XCTFail("Disabled support must remain disabled") }
        catch { }
        await refuseOrdinaryFetch(URL(string: "http://\(host)/disabled-tor")!)
        XCTAssertEqual(ordinary.connectionCount, 0)
        XCTAssertTrue(tor.socksRequests.isEmpty)
        Onion.shared.take(enabled: true)
    }
}

@MainActor
private final class OnionNavigation: NSObject, WKNavigationDelegate {
    var finished = false
    var loaded = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true; finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finished = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finished = true }
}

private struct RoutingTorProcess {
    let folder: URL
    let executable: URL
    init(port: UInt16, exits: Bool) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("onion-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        executable = folder.appendingPathComponent("fixture-tor.py")
        try """
        #!/usr/bin/python3
        import sys, time
        sys.stdin.buffer.read()
        if \(exits ? "True" : "False"):
            sys.exit(19)
        print('[notice] Socks listener listening on port \(port).', flush=True)
        print('[notice] Bootstrapped 100% (done): Done', flush=True)
        while True:
            time.sleep(1)
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
    func remove() { try? FileManager.default.removeItem(at: folder) }
}

private final class RoutingServer: @unchecked Sendable {
    enum Mode: Equatable { case ordinary, socks }
    struct SOCKSRequest {
        let host: String
        let addressType: UInt8
        let username: String?
        let isolation: String?
    }
    struct HTTPRequest { let host: String; let path: String }
    private let mode: Mode
    private let localProbe: UInt16?
    private let listener: NWListener
    private let queue = DispatchQueue(label: "OnionRoutingTests.loopback")
    private let lock = NSLock()
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var accepted = 0
    private var socks: [SOCKSRequest] = []
    private var requests: [HTTPRequest] = []
    var port: UInt16? { listener.port?.rawValue }
    var connectionCount: Int { lock.withLock { accepted } }
    var socksRequests: [SOCKSRequest] { lock.withLock { socks } }
    var httpRequests: [HTTPRequest] { lock.withLock { requests } }

    init(mode: Mode, localProbe: UInt16? = nil) throws {
        self.mode = mode
        self.localProbe = localProbe
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { done in
            let once = RoutingOnce()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard once.first() else { return }
                    if let port = self.port { done.resume(returning: port) }
                    else { done.resume(throwing: URLError(.cannotConnectToHost)) }
                case .failed(let error):
                    guard once.first() else { return }
                    done.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.lock.withLock { self.accepted += 1 }
                let peer = Peer(connection: connection, server: self, socks: self.mode == .socks)
                self.peers[ObjectIdentifier(connection)] = peer
                connection.start(queue: self.queue)
                peer.read()
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        queue.sync { peers.values.forEach { $0.connection.cancel() }; peers.removeAll() }
    }

    private func answer(host: String, path: String) -> Data {
        lock.withLock { requests.append(HTTPRequest(host: host, path: path)) }
        if mode == .ordinary { return response("ordinary fixture", type: "text/plain") }
        if path == "/redirect" {
            return Data("HTTP/1.1 302 Found\r\nLocation: http://redirect.example.invalid/landing\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        }
        if path == "/clock.js" { return response("document.documentElement.dataset.assetLoaded='yes';", type: "application/javascript") }
        if path == "/pixel" { return response("pixel", type: "text/plain") }
        if path == "/page" {
            let local = localProbe.map { port in
                """
                <img src="http://127.0.0.1:\(port)/must-not-load">
                <script>
                fetch('http://127.0.0.1:\(port)/must-not-fetch').catch(()=>{});
                try { new WebSocket('ws://127.0.0.1:\(port)/must-not-connect'); } catch (_) {}
                </script>
                """
            } ?? ""
            return response("""
                <!doctype html><title>Isolated onion fixture</title>
                <script src="http://assets.example.invalid/clock.js"></script>
                <img src="http://assets.example.invalid/pixel">
                \(local)<p>Tor fixture</p>
                """, type: "text/html")
        }
        return response("onion fixture", type: "text/plain")
    }

    private func response(_ text: String, type: String) -> Data {
        let body = Data(text.utf8)
        var bytes = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        bytes.append(body)
        return bytes
    }

    private final class Peer {
        enum Phase: Equatable { case greeting, authentication, request, http, done }
        let connection: NWConnection
        weak var server: RoutingServer?
        private var phase: Phase
        private var buffer = Data()
        private var destination = "ordinary.example.invalid"
        private var username: String?
        private var isolation: String?
        init(connection: NWConnection, server: RoutingServer, socks: Bool) {
            self.connection = connection
            self.server = server
            self.phase = socks ? .greeting : .http
        }

        func read() {
            guard phase != .done else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
                guard let self else { return }
                if let data { self.buffer.append(data) }
                while self.consume() { }
                if complete || error != nil { self.connection.cancel() }
                else if self.phase != .done { self.read() }
            }
        }

        private func drop(_ count: Int) { buffer = Data(buffer.dropFirst(count)) }

        private func consume() -> Bool {
            guard let server else { connection.cancel(); return false }
            switch phase {
            case .greeting:
                guard buffer.count >= 2 else { return false }
                let count = Int(buffer[1])
                guard buffer.count >= count + 2 else { return false }
                guard buffer[0] == 5 else { phase = .done; connection.cancel(); return false }
                let methods = buffer[2..<(count + 2)]
                let authenticate = methods.contains(2)
                guard authenticate || methods.contains(0) else { phase = .done; connection.cancel(); return false }
                drop(count + 2)
                connection.send(content: Data([5, authenticate ? 2 : 0]), completion: .contentProcessed { _ in })
                phase = authenticate ? .authentication : .request
                return true
            case .authentication:
                guard buffer.count >= 2 else { return false }
                let nameLength = Int(buffer[1])
                guard buffer.count >= nameLength + 3 else { return false }
                let keyLength = Int(buffer[nameLength + 2])
                let length = nameLength + keyLength + 3
                guard buffer.count >= length else { return false }
                guard buffer[0] == 1 else { phase = .done; connection.cancel(); return false }
                username = String(decoding: buffer[2..<(2 + nameLength)], as: UTF8.self)
                isolation = String(decoding: buffer[(nameLength + 3)..<length], as: UTF8.self)
                drop(length)
                connection.send(content: Data([1, 0]), completion: .contentProcessed { _ in })
                phase = .request
                return true
            case .request:
                guard buffer.count >= 5 else { return false }
                let type = buffer[3]
                guard buffer[0] == 5, buffer[1] == 1, type == 3 else { phase = .done; connection.cancel(); return false }
                let length = Int(buffer[4])
                guard buffer.count >= 7 + length else { return false }
                destination = String(decoding: buffer[5..<(5 + length)], as: UTF8.self).lowercased()
                server.lock.withLock { server.socks.append(SOCKSRequest(host: destination, addressType: type,
                                                                      username: username, isolation: isolation)) }
                drop(7 + length)
                connection.send(content: Data([5, 0, 0, 1, 127, 0, 0, 1, 0, 80]), completion: .contentProcessed { _ in })
                phase = .http
                return true
            case .http:
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return false }
                let header = String(decoding: buffer[..<end.upperBound], as: UTF8.self)
                drop(end.upperBound)
                let first = header.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
                guard first.count >= 2 else { phase = .done; connection.cancel(); return false }
                if first[0] == "CONNECT" {
                    destination = String(first[1])
                    connection.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                    return true
                }
                let raw = String(first[1])
                let path = raw.hasPrefix("http") ? (URL(string: raw)?.path ?? raw) : raw
                let response = server.answer(host: destination, path: path)
                phase = .done
                connection.send(content: response, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { [weak self] _ in self?.connection.cancel() })
                return false
            case .done: return false
            }
        }
    }
}

private final class RoutingOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func first() -> Bool {
        lock.withLock {
            guard !used else { return false }
            used = true
            return true
        }
    }
}
