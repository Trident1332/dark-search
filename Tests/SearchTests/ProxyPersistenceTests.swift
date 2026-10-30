import AppKit
import Foundation
import Network
import WebKit
import XCTest
@testable import Search

/// The health server and destinations are synthetic. Nothing is sent to an
/// Internet IP lookup, and every credential belongs only to this fixture.
@MainActor
final class ProxyPersistenceTests: XCTestCase {
    private static let world = "proxy-persistence-tests-\(getpid())"
    private let target = URL(string: "http://persistent-proxy.invalid/health")!

    override class func setUp() {
        setenv("SEARCH_PROBE", world, 1)
        super.setUp()
    }

    override class func tearDown() {
        Disk.drain()
        if Store.world == world {
            try? FileManager.default.removeItem(at: Store.folder)
            let domain = "com.officecommun.search.test.\(world)"
            UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        }
        super.tearDown()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        _ = Shared.prefs
        Proxy.shared.automaticTarget = nil
        Proxy.shared.take(ProxySetup())
        try await super.setUp()
    }

    override func tearDown() async throws {
        Proxy.shared.automaticTarget = nil
        Proxy.shared.take(ProxySetup())
        // Off completes its process/worker transition before another suite
        // creates contexts on the same cached native pools.
        for _ in 0..<100 where Proxy.shared.changingContent {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(Proxy.shared.changingContent)
        try await super.tearDown()
    }

    private func route(_ port: UInt16) -> ProxySetup {
        ProxySetup(on: true, kind: .http, host: "127.0.0.1", port: port)
    }

    private func until(timeout: TimeInterval = 4, _ condition: @escaping @MainActor () -> Bool,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<Int(timeout / 0.02) {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for the local persistent proxy", file: file, line: line)
        throw URLError(.timedOut)
    }

    func testAutomaticCheckUsesSavedCredentialsBeforeOpeningGate() async throws {
        let server = try PersistentProxyFixture(held: true, user: "fixture-user", password: "fixture-password")
        let port = try await server.start()
        defer { server.stop() }
        var setup = route(port)
        setup.signsIn = true
        setup.user = "fixture-user"
        XCTAssertTrue(ProxyPassword.save("fixture-password", for: setup))
        defer { ProxyPassword.forget(setup) }
        let proxy = Proxy.shared
        proxy.automaticTarget = target
        proxy.take(setup)
        XCTAssertTrue(proxy.waiting, "Startup must close the route synchronously")
        try await until { server.requests > 0 }
        XCTAssertTrue(proxy.waiting, "A listening port alone is not a successful health check")
        XCTAssertGreaterThan(server.authorized, 0)
        server.release()
        try await until { !proxy.waiting }
        XCTAssertEqual(proxy.timeZoneID, "Europe/Berlin")
        XCTAssertEqual(proxy.countryFlag, "🇩🇪")
        XCTAssertFalse(proxy.refused)
        guard case .reached = proxy.check else { return XCTFail("The verified route should be healthy") }
    }

    func testUpdaterDefersUntilRealProxyHealthCheckOpensRouteAndAutomaticallyRetries() async throws {
        let server = try PersistentProxyFixture(held: true)
        let port = try await server.start()
        defer { server.stop() }
        let proxy = Proxy.shared
        proxy.automaticTarget = target
        proxy.take(route(port))
        XCTAssertTrue(proxy.waiting, "The real startup path must close the route before an updater can fetch")

        let previousInstallPolicy = Store.settings.object(forKey: Updater.installKey)
        Store.settings.set(false, forKey: Updater.installKey)
        defer {
            if let previousInstallPolicy { Store.settings.set(previousInstallPolicy, forKey: Updater.installKey) }
            else { Store.settings.removeObject(forKey: Updater.installKey) }
        }
        let current = Updater.Release(version: "proxy-readiness-fixture", build: Updater.build,
            archive: URL(string: "https://release-fixture.invalid/Search.zip")!,
            dmg: URL(string: "https://release-fixture.invalid/Search.dmg")!, sha256: nil, notes: nil,
            minimumSystemVersion: nil)
        var loads = 0
        let updater = Updater(fetchFeed: {
            loads += 1
            XCTAssertFalse(proxy.waiting, "No feed request may use the startup placeholder route")
            XCTAssertFalse(proxy.changingContent, "Recovery must complete before the deferred check resumes")
            return current
        })
        var initialResult: Updater.CheckResult?
        updater.check { initialResult = $0 }
        try await until(timeout: 1) { initialResult != nil }
        guard case .deferred(let reason)? = initialResult else {
            return XCTFail("A proxy startup wait must return a deferred result, not a DNS failure or a hung check")
        }
        XCTAssertTrue(reason.hasPrefix("Waiting for your proxy connection"))
        XCTAssertTrue(updater.waitingForConnection)
        XCTAssertFalse(updater.checking)
        XCTAssertNil(updater.lastCheckFailure)
        XCTAssertNil(updater.lastChecked)
        XCTAssertEqual(loads, 0)

        // A held real local health response proves that opening the TCP
        // listener alone cannot make the updater cross the privacy gate.
        try await until { server.requests > 0 }
        XCTAssertTrue(proxy.waiting)
        XCTAssertEqual(loads, 0)
        server.release()
        try await until { !proxy.waiting && updater.lastChecked != nil }
        XCTAssertEqual(loads, 1, "Real proxy recovery must retry the deferred check exactly once")
        XCTAssertFalse(updater.waitingForConnection)
        XCTAssertFalse(updater.checking)
        XCTAssertNil(updater.lastCheckFailure)
        XCTAssertEqual(updater.stage, .none)
        guard case .reached = proxy.check else { return XCTFail("The local health response must establish the route") }
    }

    func testMissingTimeZoneKeepsPersistentRouteClosed() async throws {
        let server = try PersistentProxyFixture(timeZone: nil)
        let port = try await server.start()
        defer { server.stop() }
        let proxy = Proxy.shared
        proxy.automaticTarget = target
        proxy.take(route(port))
        try await until { if case .failed = proxy.check { return true }; return false }
        XCTAssertTrue(proxy.waiting, "Location metadata must be known before exposing local Date/Intl")
        XCTAssertNil(proxy.timeZoneID)
        XCTAssertFalse(proxy.configuration().allowFailover)
    }

    func testRejectedSavedCredentialsStayBlockedUntilCorrectCredentialsAreVerified() async throws {
        let server = try PersistentProxyFixture(user: "fixture-user", password: "fixture-password")
        let port = try await server.start()
        defer { server.stop() }
        var setup = route(port)
        setup.signsIn = true
        setup.user = "fixture-user"
        XCTAssertTrue(ProxyPassword.save("wrong-fixture-password", for: setup))
        defer { ProxyPassword.forget(setup) }
        let proxy = Proxy.shared
        proxy.automaticTarget = target
        proxy.take(setup)
        try await until { if case .failed = proxy.check { return true }; return false }
        XCTAssertTrue(proxy.waiting)
        XCTAssertTrue(proxy.refused)
        XCTAssertEqual(server.authorized, 0)
        XCTAssertFalse(proxy.configuration().allowFailover)
        XCTAssertTrue(ProxyPassword.save("fixture-password", for: setup))
        proxy.passwordChanged()
        XCTAssertTrue(proxy.waiting, "Saving credentials must not skip reauthentication")
        try await until { !proxy.waiting }
        XCTAssertGreaterThan(server.authorized, 0)
        XCTAssertFalse(proxy.refused)
    }

    func testPersistentRouteOverridesProfileBypassesAndPeerCalls() throws {
        let proxy = Proxy.shared
        var setup = route(9)
        setup.profiles = [UUID()]
        setup.bypass = ["public-bypass.invalid"]
        setup.hidesCalls = false
        proxy.take(setup)
        XCTAssertTrue(proxy.routes(for: Profile.personalID))
        XCTAssertTrue(proxy.routes(for: UUID()))
        let store = WKWebsiteDataStore.nonPersistent()
        proxy.apply(to: store, profile: Profile.personalID)
        XCTAssertEqual(store.proxyConfigurations.count, 2)
        var exclusions: [String] = []
        nw_proxy_config_enumerate_excluded_domains(proxy.configuration()._nw) { exclusions.append(String(cString: $0)) }
        XCTAssertFalse(exclusions.contains("public-bypass.invalid"))
        XCTAssertFalse(proxy.configuration().allowFailover)
        let preferences = WKPreferences()
        proxy.follow(preferences, profile: Profile.personalID)
        let getter = NSSelectorFromString("_peerConnectionEnabled")
        guard preferences.responds(to: getter) else { throw XCTSkip("This WebKit has no peer-connection switch") }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let peerCalls = unsafeBitCast(preferences.method(for: getter), to: Getter.self)(preferences, getter)
        XCTAssertFalse(peerCalls, "Persistent mode must not let a saved call preference reveal a direct address")
    }

    func testTurningOffEitherSwitchReleasesPersistentGate() {
        let proxy = Proxy.shared
        var setup = route(9)
        setup.matchesTimeZone = false
        proxy.take(setup)
        XCTAssertTrue(proxy.waiting)
        setup.blocks = false
        proxy.take(setup)
        XCTAssertFalse(proxy.waiting)
        XCTAssertTrue(proxy.configuration().allowFailover)
        setup.blocks = true
        proxy.take(setup)
        XCTAssertTrue(proxy.waiting)
        let store = WKWebsiteDataStore.nonPersistent()
        proxy.apply(to: store, profile: Profile.personalID)
        setup.on = false
        proxy.take(setup)
        XCTAssertFalse(proxy.waiting)
        XCTAssertFalse(proxy.routes(for: Profile.personalID))
        XCTAssertEqual(store.proxyConfigurations.count, 1, "Only the onion-specific guard remains")
    }

    func testScopedProfileKeepsPeerProtectionWhenRouteIsRebuilt() throws {
        let proxy = Proxy.shared
        let profile = UUID()
        var setup = route(9)
        setup.blocks = false
        setup.matchesTimeZone = false
        setup.hidesCalls = true
        setup.profiles = [profile]
        proxy.take(setup)
        let protected = WKWebViewConfiguration()
        protected.websiteDataStore = .nonPersistent()
        proxy.apply(to: protected.websiteDataStore, profile: profile)
        proxy.prepare(protected)
        let personal = WKWebViewConfiguration()
        personal.websiteDataStore = .nonPersistent()
        proxy.apply(to: personal.websiteDataStore, profile: Profile.personalID)
        proxy.prepare(personal)
        let getter = NSSelectorFromString("_peerConnectionEnabled")
        guard protected.preferences.responds(to: getter), personal.preferences.responds(to: getter) else {
            throw XCTSkip("This WebKit has no peer-connection switch")
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        func peerCalls(_ preferences: WKPreferences) -> Bool {
            unsafeBitCast(preferences.method(for: getter), to: Getter.self)(preferences, getter)
        }
        XCTAssertFalse(peerCalls(protected.preferences))
        XCTAssertTrue(peerCalls(personal.preferences))
        proxy.passwordChanged()
        XCTAssertFalse(peerCalls(protected.preferences), "Rebuilding a scoped route must keep its profile's peer protection")
        XCTAssertTrue(peerCalls(personal.preferences), "The unrelated Personal profile should keep its own call preference")
    }

    func testClosedGateCannotReachAnOtherwiseReachableDirectOrigin() async throws {
        let origin = try PersistentProxyFixture()
        let port = try await origin.start()
        defer { origin.stop() }
        // Network exempts local IP literals. The Mac's DNS name gives the
        // same reachable listener a hostname to which proxy policy applies.
        let url = URL(string: "http://\(ProcessInfo.processInfo.hostName):\(port)/direct-origin")!
        let control = URLSession(configuration: .ephemeral)
        defer { control.invalidateAndCancel() }
        _ = try await control.data(from: url)
        XCTAssertEqual(origin.requests, 1)
        var setup = route(port)
        setup.matchesTimeZone = false
        setup.bypass = [ProcessInfo.processInfo.hostName]
        Proxy.shared.take(setup)
        XCTAssertTrue(Proxy.shared.waiting)
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        do {
            _ = try await Proxy.fetches.proxyData(for: request)
            XCTFail("An unverified persistent route must not reach the origin")
        } catch { }
        XCTAssertEqual(origin.requests, 1, "Neither the direct origin nor the unverified proxy should receive this page request")
    }

    func testPasswordChangeRearmsAnAlreadyVerifiedPersistentRoute() async throws {
        let server = try PersistentProxyFixture()
        let port = try await server.start()
        defer { server.stop() }
        let proxy = Proxy.shared
        proxy.take(route(port))
        proxy.test(target: target)
        try await until { !proxy.waiting }
        proxy.passwordChanged()
        XCTAssertTrue(proxy.waiting, "Credentials change invalidates the previous proof of a working connection")
        XCTAssertFalse(proxy.configuration().allowFailover)
    }

    func testUnreachablePageDoesNotSuspendAHealthyProxyOrEnterRecoveryQueue() async throws {
        let server = try PersistentProxyFixture()
        let port = try await server.start()
        defer { server.stop() }
        let proxy = Proxy.shared
        proxy.automaticTarget = target
        proxy.take(route(port))
        try await until { !proxy.waiting }
        let revision = proxy.revision
        let health = proxy.check
        let healthRequests = server.requests
        let connections = server.connectionCount
        let tab = Tab(bench: true)
        defer { tab.close() }
        tab.restore(url: URL(string: "http://unavailable-destination.invalid/page")!, title: "Unavailable")
        let localFailure = "The site could not be reached"
        tab.failure = localFailure

        for code in [URLError.Code.cannotFindHost, .timedOut, .cannotConnectToHost] {
            proxy.failed(URLError(code), profile: Profile.personalID, tab: tab)
        }
        XCTAssertFalse(proxy.waiting, "An origin failure is not proof that the proxy failed")
        try await until { server.connectionCount > connections }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(proxy.ready)
        XCTAssertFalse(proxy.dropped)
        XCTAssertFalse(proxy.changingContent)
        XCTAssertEqual(proxy.revision, revision, "The healthy route must not be torn down or rebuilt")
        XCTAssertEqual(proxy.check, health)
        XCTAssertEqual(server.requests, healthRequests, "Destination errors must not trigger a new location lookup")
        XCTAssertEqual(tab.failure, localFailure)

        // A later successful manual health check must not reload the same
        // broken destination and start another global suspend/recover cycle.
        proxy.test(target: target)
        try await until { proxy.check != .testing }
        XCTAssertEqual(tab.failure, localFailure)
        XCTAssertTrue(proxy.ready)
    }

    func testBackgroundDestinationFailureDoesNotSuspendAHealthyProxy() async throws {
        let server = try PersistentProxyFixture()
        let port = try await server.start()
        defer { server.stop() }
        let proxy = Proxy.shared
        proxy.automaticTarget = target
        proxy.take(route(port))
        try await until { !proxy.waiting }
        let revision = proxy.revision
        let connections = server.connectionCount
        let healthRequests = server.requests
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnreachableDestinationProtocol.self]
        let session = Proxy.makeSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.proxyData(from: URL(string: "http://unavailable-destination.invalid/icon")!)
            XCTFail("The fixture must fail the optional destination request")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotFindHost)
        }
        try await until { server.connectionCount > connections }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(proxy.ready)
        XCTAssertFalse(proxy.waiting)
        XCTAssertFalse(proxy.dropped)
        XCTAssertFalse(proxy.changingContent)
        XCTAssertEqual(proxy.revision, revision)
        XCTAssertEqual(server.requests, healthRequests)
    }

    func testPublicNumericDestinationsUseProxyInFoundationAndWebKitThenStayBlockedOnFailure() async throws {
        let server = try PersistentProxyFixture()
        let port = try await server.start()
        defer { server.stop() }
        let proxy = Proxy.shared
        proxy.automaticTarget = target
        proxy.take(route(port))
        try await until { !proxy.waiting }
        // TEST-NET-2 is reserved documentation space. The local proxy
        // answers the tunnel itself; no destination server is contacted.
        let destination = URL(string: "http://198.51.100.17/numeric-destination")!
        var request = URLRequest(url: destination)
        request.timeoutInterval = 2
        let (data, response) = try await Proxy.fetches.proxyData(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: String])?["ip"], "203.0.113.7")
        XCTAssertTrue(server.connectAuthorities.contains("198.51.100.17:80"), "Foundation must tunnel a numeric public destination")
        let beforeWebKit = server.connectAuthorities.filter { $0 == "198.51.100.17:80" }.count
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        proxy.apply(to: configuration.websiteDataStore, profile: Profile.personalID)
        proxy.prepare(configuration)
        let page = WKWebView(frame: .zero, configuration: configuration)
        proxy.track(page)
        defer { ProxyTimeZone.close(page) }
        let navigation = PersistentProxyNavigation()
        page.navigationDelegate = navigation
        page.load(request)
        try await until { navigation.finished }
        XCTAssertTrue(navigation.loaded, "WebKit should load the fixture's response through the tunnel")
        let peerUsable = try await page.evaluateJavaScript("""
            (() => {
              if (typeof RTCPeerConnection === 'undefined') return false;
              try { const peer = new RTCPeerConnection(); peer.close(); return true; }
              catch (_) { return false; }
            })()
            """) as? Bool
        XCTAssertEqual(peerUsable, false, "A page on the persistent route cannot create a direct peer connection")
        XCTAssertGreaterThan(server.connectAuthorities.filter { $0 == "198.51.100.17:80" }.count, beforeWebKit,
                             "WebKit must also tunnel a numeric public destination")

        let origin = try PersistentProxyFixture()
        let originPort = try await origin.start()
        defer { origin.stop() }
        let originURL = URL(string: "http://\(ProcessInfo.processInfo.hostName):\(originPort)/after-failure")!
        let control = URLSession(configuration: .ephemeral)
        defer { control.invalidateAndCancel() }
        _ = try await control.data(from: originURL)
        XCTAssertEqual(origin.requests, 1)
        proxy.automaticTarget = nil
        server.stop()
        try await until { server.stopped }
        proxy.failed(URLError(.cannotConnectToHost), profile: Profile.personalID, tab: nil)
        try await until { proxy.waiting }
        XCTAssertTrue(proxy.dropped, "A confirmed proxy-endpoint failure closes the persistent gate")
        var blocked = URLRequest(url: originURL)
        blocked.timeoutInterval = 1
        do {
            _ = try await Proxy.fetches.proxyData(for: blocked)
            XCTFail("Persistent mode must never retry this request directly")
        } catch { }
        XCTAssertEqual(origin.requests, 1)
    }
}

@MainActor
private final class PersistentProxyNavigation: NSObject, WKNavigationDelegate {
    var finished = false
    var loaded = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true; finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finished = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finished = true }
}

private final class PersistentProxyFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ProxyPersistenceTests.local")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var pending: [() -> Void] = []
    private var count = 0
    private var accepted = 0
    private var authorities: [String] = []
    private var starting = true
    private var held: Bool
    private let body: Data
    private let authorization: String?
    var requests: Int { lock.withLock { count } }
    var connectionCount: Int { lock.withLock { connections.count } }
    var stopped: Bool { if case .cancelled = listener.state { return true }; return false }
    var authorized: Int { lock.withLock { accepted } }
    var connectAuthorities: [String] { lock.withLock { authorities } }

    init(held: Bool = false, timeZone: String? = "Europe/Berlin", user: String? = nil, password: String? = nil) throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.held = held
        var location = ["ip": "203.0.113.7", "city": "Berlin", "country": "DE"]
        location["timezone"] = timeZone
        body = try JSONSerialization.data(withJSONObject: location)
        authorization = user.flatMap { user in password.map { "Basic " + Data("\(user):\($0)".utf8).base64EncodedString() } }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if self.lock.withLock({ let first = self.starting; self.starting = false; return first }) {
                        continuation.resume(returning: self.listener.port!.rawValue)
                    }
                case .failed(let error):
                    if self.lock.withLock({ let first = self.starting; self.starting = false; return first }) {
                        continuation.resume(throwing: error)
                    }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return connection.cancel() }
                self.lock.withLock { self.connections.append(connection) }
                connection.start(queue: self.queue)
                self.read(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        for connection in lock.withLock({ connections }) { connection.cancel() }
    }

    func release() {
        let replies = lock.withLock {
            held = false
            let replies = pending
            pending = []
            return replies
        }
        for reply in replies { queue.async(execute: DispatchWorkItem(block: reply)) }
    }

    private func read(_ connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if error == nil, !complete, buffer.count < 65_536 { self.read(connection, buffer: buffer) }
                else { connection.cancel() }
                return
            }
            let header = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            if header.hasPrefix("CONNECT ") {
                let words = header.components(separatedBy: "\r\n")[0].split(separator: " ")
                if words.count > 1 { self.lock.withLock { self.authorities.append(String(words[1])) } }
                if let authorization = self.authorization {
                    let valid = header.components(separatedBy: "\r\n").contains { line in
                        guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == "proxy-authorization" else { return false }
                        return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) == authorization
                    }
                    guard valid else {
                        connection.send(content: Data("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"Search persistence fixture\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                                        contentContext: .finalMessage, isComplete: true,
                                        completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
                    self.lock.withLock { self.accepted += 1 }
                }
                connection.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { error in
                    if error == nil { self.read(connection) } else { connection.cancel() }
                })
                return
            }
            self.lock.withLock { self.count += 1 }
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(self.body.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(self.body)
            let reply = { connection.send(content: response, contentContext: .finalMessage, isComplete: true,
                                          completion: .contentProcessed { _ in connection.cancel() }) }
            if self.lock.withLock({ if self.held { self.pending.append(reply); return true }; return false }) { return }
            reply()
        }
    }
}

private final class UnreachableDestinationProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "unavailable-destination.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost)) }
    override func stopLoading() {}
}
