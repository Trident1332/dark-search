import AppKit
import Foundation
import Network
import WebKit
import XCTest
@testable import Search

/// A disposable settings world, a local CONNECT proxy, and synthetic AI
/// responses. No request reaches ipinfo.io or an actual AI provider.
@MainActor
final class ProxyTests: XCTestCase {
    private static let world = "proxy-tests-\(getpid())"

    override class func setUp() {
        setenv("SEARCH_PROBE", world, 1)
        super.setUp()
    }

    override class func tearDown() {
        Disk.drain()
        if Store.world == world {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults(suiteName: "com.officecommun.search.test.\(world)")?.removePersistentDomain(forName: "com.officecommun.search.test.\(world)")
        }
        super.tearDown()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        _ = Shared.prefs
        Proxy.shared.take(ProxySetup())
        try await super.setUp()
    }

    override func tearDown() async throws {
        Proxy.shared.take(ProxySetup())
        AIProtocol.response = nil
        // Off completes its process/worker transition before another suite
        // creates contexts on the same cached native pools.
        for _ in 0..<100 where Proxy.shared.changingContent {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(Proxy.shared.changingContent)
        try await super.tearDown()
    }

    private var target: URL { URL(string: "http://proxy-review.invalid/check")! }

    private func setup(_ port: UInt16) -> ProxySetup {
        ProxySetup(on: true, kind: .http, host: "127.0.0.1", port: port, blocks: false, matchesTimeZone: false)
    }

    private func until(timeout: TimeInterval = 4, _ condition: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<Int(timeout / 0.02) {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for the proxy operation", file: file, line: line)
        throw URLError(.timedOut)
    }

    func testClearingEnabledHostDoesNotConnectDirectly() async throws {
        let origin = try LocalProxy()
        let port = try await origin.start()
        defer { origin.stop() }
        // Network exempts local IP literals. This Mac's DNS name gives the
        // same local listener a destination to which proxy policy applies.
        let url = URL(string: "http://\(ProcessInfo.processInfo.hostName):\(port)/direct")!
        let direct = URLSession(configuration: .ephemeral)
        defer { direct.invalidateAndCancel() }
        _ = try await direct.data(from: url)
        XCTAssertEqual(origin.requests.count, 1, "The local origin really is reachable directly")

        let proxy = Proxy.shared
        proxy.take(setup(port))
        let store = WKWebsiteDataStore.nonPersistent()
        proxy.apply(to: store, profile: Profile.personalID)
        var editing = proxy.setup
        editing.host = "  "
        // Even allowing ordinary proxy failover must not turn a missing
        // address into an instruction to send requests directly.
        editing.blocks = false
        proxy.take(editing)
        XCTAssertEqual(store.proxyConfigurations.count, 2)
        XCTAssertTrue(proxy.routes(for: Profile.personalID))
        XCTAssertFalse(proxy.configuration().allowFailover)
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        do {
            _ = try await Proxy.fetches.data(for: request)
            XCTFail("An enabled proxy with no server must not reach the origin directly")
        } catch { }
        XCTAssertEqual(origin.requests.count, 1)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let page = WKWebView(frame: .zero, configuration: configuration)
        let navigation = ProxyNavigation()
        page.navigationDelegate = navigation
        page.load(request)
        try await until { navigation.finished }
        XCTAssertFalse(navigation.loaded, "WebKit must also refuse the direct route")
        XCTAssertEqual(origin.requests.count, 1)
        page.stopLoading()
        proxy.take(ProxySetup())
        XCTAssertEqual(store.proxyConfigurations.count, 1, "Off restores clearnet routing while retaining the onion-only guard")
    }

    func testConnectionTestIgnoresBypassAndDisallowsFailover() async throws {
        let server = try LocalProxy()
        let port = try await server.start()
        defer { server.stop() }
        var route = setup(port)
        route.bypass = ["proxy-review.invalid", "ipinfo.io"]
        route.blocks = false
        Proxy.shared.take(route)
        let testRoute = Proxy.shared.configuration(forTest: true)
        var exclusions: [String] = []
        // Network's Swift getter returns matchDomains on some OS versions;
        // inspect the native configuration actually handed to URLSession.
        nw_proxy_config_enumerate_excluded_domains(testRoute._nw) { exclusions.append(String(cString: $0)) }
        XCTAssertTrue(exclusions.isEmpty)
        XCTAssertFalse(testRoute.allowFailover)
        Proxy.shared.test(target: target)
        try await until { Proxy.shared.check != .testing }
        guard case .reached(_, let address, _) = Proxy.shared.check else {
            return XCTFail("The local proxy was not reached: \(Proxy.shared.check)")
        }
        XCTAssertEqual(address, "203.0.113.7")
        XCTAssertEqual(server.requests.count, 1, "A bypassed destination still goes through the explicit test proxy")
    }

    func testConnectionUsesSavedProxyCredentials() async throws {
        let server = try LocalProxy(user: "proxy-test-user", password: "synthetic-test-password")
        let port = try await server.start()
        defer { server.stop() }
        var route = setup(port)
        route.signsIn = true
        route.user = "proxy-test-user"
        XCTAssertTrue(ProxyPassword.save("synthetic-test-password", for: route))
        defer { ProxyPassword.forget(route) }
        Proxy.shared.take(route)
        Proxy.shared.test(target: target)
        try await until { Proxy.shared.check != .testing }
        guard case .reached = Proxy.shared.check else { return XCTFail("Saved proxy authentication failed") }
        XCTAssertGreaterThan(server.authorized, 0)
        XCTAssertFalse(Proxy.shared.refused)
    }

    func testMissingSavedPasswordIsAnInlineErrorBeforeConnecting() async throws {
        let server = try LocalProxy(user: "proxy-test-user", password: "synthetic-test-password")
        let port = try await server.start()
        defer { server.stop() }
        var route = setup(port)
        route.signsIn = true
        route.user = "proxy-test-user"
        Proxy.shared.take(route)
        Proxy.shared.test(target: target)
        XCTAssertEqual(Proxy.shared.check, .failed(ProxyAuthentication.missing))
        XCTAssertTrue(Proxy.shared.refused)
        XCTAssertEqual(server.authAttempts, 0)
    }

    func testUnexpectedProxyPasswordChallengeCancelsWithInlineError() async throws {
        let server = try LocalProxy(user: "proxy-test-user", password: "synthetic-test-password")
        let port = try await server.start()
        defer { server.stop() }
        Proxy.shared.take(setup(port))
        Proxy.shared.test(target: target)
        try await until { Proxy.shared.check != .testing }
        XCTAssertEqual(Proxy.shared.check, .failed(ProxyAuthentication.missing))
        XCTAssertTrue(Proxy.shared.refused)
        XCTAssertGreaterThan(server.authAttempts, 0)
        XCTAssertLessThanOrEqual(server.authAttempts, 2)
    }

    func testRejectedSavedPasswordDoesNotPromptOrStayTesting() async throws {
        let server = try LocalProxy(user: "proxy-test-user", password: "synthetic-test-password")
        let port = try await server.start()
        defer { server.stop() }
        var route = setup(port)
        route.signsIn = true
        route.user = "proxy-test-user"
        XCTAssertTrue(ProxyPassword.save("synthetic-wrong-password", for: route))
        defer { ProxyPassword.forget(route) }
        Proxy.shared.take(route)
        Proxy.shared.test(target: target)
        try await until { Proxy.shared.check != .testing }
        XCTAssertEqual(Proxy.shared.check, .failed(ProxyAuthentication.rejected))
        XCTAssertTrue(Proxy.shared.refused)
        XCTAssertEqual(server.authorized, 0)
        XCTAssertLessThanOrEqual(server.authAttempts, 3, "A rejected credential is retried at most once by the delegate")
    }

    private func challenge(host: String = "127.0.0.1", port: Int = 12323, failures: Int = 0) -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(proxyHost: host, port: port, type: NSURLProtectionSpaceHTTPSProxy,
            realm: "Synthetic proxy", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        return URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: failures,
            failureResponse: nil, error: nil, sender: ProxyChallengeSender())
    }

    func testWebKitUsesSavedCredentialsAndCancelsRejectedChallenge() async throws {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        var route = setup(12323)
        route.signsIn = true
        route.user = "proxy-test-user"
        ProxyPassword.save("synthetic-test-password", for: route)
        defer { ProxyPassword.forget(route) }
        Proxy.shared.take(route)
        let page = WKWebView(frame: .zero, configuration: Web.configuration())
        var disposition: URLSession.AuthChallengeDisposition?
        browser.webView(page, didReceive: challenge()) { result, credential in
            disposition = result
            XCTAssertEqual(credential?.user, route.user)
            XCTAssertEqual(credential?.password, "synthetic-test-password")
            XCTAssertEqual(credential?.persistence, URLCredential.Persistence.none)
        }
        XCTAssertEqual(disposition, .useCredential, "HTTPS protection-space labels must still match an HTTP CONNECT endpoint")
        browser.webView(page, didReceive: challenge(failures: 1)) { result, credential in
            disposition = result
            XCTAssertNil(credential)
        }
        XCTAssertEqual(disposition, .cancelAuthenticationChallenge, "Never fall back to the macOS password dialog")
        try await until { Proxy.shared.refused }
        XCTAssertEqual(Proxy.shared.check, .failed(ProxyAuthentication.rejected))
    }

    func testWebKitRejectedPasswordIsInlineAndSavingCorrectPasswordRecovers() async throws {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let server = try LocalProxy(user: "proxy-test-user", password: "synthetic-test-password")
        let port = try await server.start()
        defer { server.stop() }
        var route = setup(port)
        route.signsIn = true
        route.user = "proxy-test-user"
        ProxyPassword.save("synthetic-wrong-password", for: route)
        defer { ProxyPassword.forget(route) }
        Proxy.shared.take(route)
        XCTAssertFalse(route.blocks, "Authentication remains protected when Persistent connection is off")
        XCTAssertFalse(Proxy.shared.configuration().allowFailover)
        let page = WKWebView(frame: .zero, configuration: Web.configuration())
        page.navigationDelegate = browser
        page.load(URLRequest(url: target))
        try await until { Proxy.shared.refused }
        XCTAssertEqual(Proxy.shared.check, .failed(ProxyAuthentication.rejected))
        XCTAssertEqual(server.authorized, 0)
        let attempts = server.authAttempts
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.authAttempts, attempts, "WebKit stops retrying after reporting the rejection")
        XCTAssertLessThan(server.authAttempts, 8)

        ProxyPassword.save("synthetic-test-password", for: route)
        Proxy.shared.passwordChanged()
        page.load(URLRequest(url: target))
        try await until { server.requests.count > 0 && !page.isLoading }
        XCTAssertGreaterThan(server.authorized, 0)
        XCTAssertFalse(Proxy.shared.refused)
        page.stopLoading()
    }

    func testWrappedProxyAuthenticationErrorsAreRecognized() {
        for underlying in [NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EAUTH.rawValue)),
                           NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENEEDAUTH.rawValue)),
                           NSError(domain: Proxy.cfNetwork, code: 307), NSError(domain: Proxy.cfNetwork, code: 122)] {
            let wrapper = NSError(domain: "SyntheticWrapper", code: 1, userInfo: [NSUnderlyingErrorKey: underlying])
            XCTAssertTrue(Proxy.isAuthenticationFailure(wrapper))
            XCTAssertEqual(Proxy.explain(wrapper), ProxyAuthentication.rejected)
        }
        XCTAssertFalse(Proxy.isAuthenticationFailure(URLError(.cannotConnectToHost)))
        XCTAssertFalse(Proxy.isAuthenticationFailure(URLError(.serverCertificateUntrusted)))
    }

    func testProxyCredentialsNeverAnswerOriginOrAnotherEndpoint() async throws {
        var route = setup(12323)
        route.signsIn = true
        route.user = "proxy-test-user"
        ProxyPassword.save("synthetic-test-password", for: route)
        defer { ProxyPassword.forget(route) }
        Proxy.shared.take(route)
        var called = false
        let origin = URLProtectionSpace(host: "page.invalid", port: 443, protocol: "https", realm: "Origin", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let originChallenge = URLAuthenticationChallenge(protectionSpace: origin, proposedCredential: nil, previousFailureCount: 0,
            failureResponse: nil, error: nil, sender: ProxyChallengeSender())
        XCTAssertFalse(Proxy.authenticate(originChallenge) { _, _ in called = true })
        XCTAssertFalse(called, "The page's own authentication remains with its original delegate")
        XCTAssertTrue(Proxy.authenticate(challenge(host: "other-proxy.invalid")) { disposition, credential in
            XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
            XCTAssertNil(credential)
        })
        XCTAssertTrue(Proxy.authenticate(challenge(port: 12324)) { disposition, credential in
            XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
            XCTAssertNil(credential)
        })
    }

    func testOldSessionCannotUseNewProxyCredentialsOrReportAStaleFailure() async throws {
        var route = setup(12323)
        route.signsIn = true
        route.user = "proxy-test-user"
        ProxyPassword.save("synthetic-test-password", for: route)
        defer { ProxyPassword.forget(route) }
        Proxy.shared.take(route)
        let session = Proxy.makeSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        route.port = 12324
        Proxy.shared.take(route)
        XCTAssertTrue(Proxy.authenticate(challenge(), in: session) { disposition, credential in
            XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
            XCTAssertNil(credential)
        })
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(Proxy.shared.check, .untried)
        XCTAssertFalse(Proxy.shared.refused)
    }

    func testOldExplicitTestAuthFailureCannotOverwriteANewerTestOnTheSameRoute() async throws {
        let server = try LocalProxy(held: true)
        let port = try await server.start()
        defer { server.stop() }
        Proxy.shared.take(setup(port))
        let previous = Proxy.makeSession(configuration: .ephemeral, reportsAuthenticationFailures: false)
        defer { previous.invalidateAndCancel() }
        Proxy.shared.test(target: target)
        try await until { server.requests.count == 1 }
        XCTAssertTrue(Proxy.authenticate(challenge(port: Int(port), failures: 1), in: previous) { result, credential in
            XCTAssertEqual(result, .cancelAuthenticationChallenge)
            XCTAssertNil(credential)
        })
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(Proxy.shared.check, .testing)
        XCTAssertFalse(Proxy.shared.refused)
        server.release()
        try await until { Proxy.shared.check != .testing }
        guard case .reached = Proxy.shared.check else { return XCTFail("The active Test must retain its own result") }
    }

    func testBackgroundRejectedCredentialsAreReportedInSettings() async throws {
        let server = try LocalProxy(user: "proxy-test-user", password: "synthetic-test-password")
        let port = try await server.start()
        defer { server.stop() }
        var route = setup(port)
        route.signsIn = true
        route.user = "proxy-test-user"
        ProxyPassword.save("synthetic-wrong-password", for: route)
        defer { ProxyPassword.forget(route) }
        Proxy.shared.take(route)
        XCTAssertFalse(route.blocks, "Authentication remains protected when Persistent connection is off")
        XCTAssertFalse(Proxy.shared.configuration().allowFailover)
        do {
            _ = try await Proxy.fetches.proxyData(from: target)
            XCTFail("Wrong credentials cannot connect")
        } catch { }
        try await until { Proxy.shared.refused }
        XCTAssertEqual(Proxy.shared.check, .failed(ProxyAuthentication.rejected))
    }

    func testAuthenticatedRouteNeverFallsBackDirectlyWhenPersistenceIsOff() {
        var route = setup(12323)
        Proxy.shared.take(route)
        XCTAssertTrue(Proxy.shared.configuration().allowFailover, "An unauthenticated route can still use ordinary failover")
        route.signsIn = true
        route.user = "proxy-test-user"
        Proxy.shared.take(route)
        XCTAssertFalse(Proxy.shared.configuration().allowFailover, "Missing or rejected authentication must remain visible")
        route.on = false
        Proxy.shared.take(route)
        XCTAssertEqual(Proxy.fetches.configuration.proxyConfigurations.count, 1, "Off releases the ordinary route; onion requests remain guarded")
    }

    func testCustomSessionDelegateReportsPreappliedCredentialFailures() async throws {
        let server = try LocalProxy(user: "proxy-test-user", password: "synthetic-test-password")
        let port = try await server.start()
        defer { server.stop() }
        var route = setup(port)
        route.signsIn = true
        route.user = "proxy-test-user"
        ProxyPassword.save("synthetic-wrong-password", for: route)
        defer { ProxyPassword.forget(route) }
        Proxy.shared.take(route)
        XCTAssertFalse(route.blocks, "Authentication remains protected when Persistent connection is off")
        XCTAssertFalse(Proxy.shared.configuration().allowFailover)
        let client = AIClient()
        do {
            _ = try await client.session.proxyData(from: target)
            XCTFail("Wrong credentials cannot connect")
        } catch { }
        try await until { Proxy.shared.refused }
        XCTAssertEqual(Proxy.shared.check, .failed(ProxyAuthentication.rejected))
    }

    func testOldConnectionTestCannotOverwriteNewRoute() async throws {
        let old = try LocalProxy(held: true, address: "203.0.113.8", country: "US")
        let oldPort = try await old.start()
        let fresh = try LocalProxy(address: "203.0.113.9", country: "GB")
        let freshPort = try await fresh.start()
        defer { old.stop(); fresh.stop() }
        let proxy = Proxy.shared
        proxy.take(setup(oldPort))
        proxy.test(target: target)
        try await until { old.requests.count == 1 }
        proxy.take(setup(freshPort))
        XCTAssertEqual(proxy.check, .untried)
        proxy.test(target: target)
        try await until { if case .reached = proxy.check { return true }; return false }
        let expected = proxy.check
        old.release()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(proxy.check, expected, "Neither cancellation nor a late reply may replace the new result")
        guard case .reached(_, let address, _) = proxy.check else { return XCTFail("Expected a connection result") }
        XCTAssertEqual(address, "203.0.113.9")
        XCTAssertEqual(proxy.countryCode, "GB")
        XCTAssertEqual(proxy.countryFlag, "🇬🇧", "An old Test must not replace the current route's flag")
        var another = proxy.setup
        another.host = "another-proxy.invalid"
        proxy.take(another)
        XCTAssertNil(proxy.countryFlag)
    }

    func testRouteChangeDiscardsAnOutstandingResultWithoutAnotherTest() async throws {
        let server = try LocalProxy(held: true)
        let port = try await server.start()
        defer { server.stop() }
        let proxy = Proxy.shared
        proxy.take(setup(port))
        proxy.test(target: target)
        try await until { server.requests.count == 1 }
        proxy.passwordChanged()
        server.release()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(proxy.check, .untried)
        XCTAssertNil(proxy.place)
    }

    func testBypassCommitDoesNotStopRecoveryAndTestReloadsFailedTabs() async throws {
        let proxy = Proxy.shared
        proxy.take(ProxySetup(on: true))
        let tab = Tab(bench: true)
        defer { tab.close() }
        tab.restore(url: target, title: "Waiting")
        tab.failure = "Synthetic connection failure"
        proxy.failed(URLError(.cannotConnectToHost), profile: Profile.personalID, tab: tab)
        try await until { proxy.dropped }

        // A delegate commit is also delivered for a bypassed or cached page.
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let bypass = WKWebView(frame: .zero, configuration: Web.configuration())
        browser.webView(bypass, didCommit: nil)
        XCTAssertTrue(proxy.dropped)
        XCTAssertNotNil(tab.failure)

        let server = try LocalProxy()
        let port = try await server.start()
        defer { server.stop() }
        proxy.take(setup(port))
        proxy.test(target: target)
        try await until { if case .reached = proxy.check { return true }; return false }
        XCTAssertFalse(proxy.dropped)
        XCTAssertNil(tab.failure, "Manual Test drains the same recovery queue as the background probe")
        try await until { server.requests.count >= 2 }
        XCTAssertNil(tab.pending, "The failed WebKit tab was actually woken and loaded through the recovered proxy")
    }

    func testAutomaticRecoveryReloadsFailedTabs() async throws {
        let proxy = Proxy.shared
        proxy.take(ProxySetup(on: true))
        let tab = Tab(bench: true)
        defer { tab.close() }
        tab.restore(url: target, title: "Waiting for automatic recovery")
        tab.failure = "Synthetic connection failure"
        proxy.failed(URLError(.cannotConnectToHost), profile: Profile.personalID, tab: tab)
        try await until { proxy.dropped }
        let server = try LocalProxy()
        let port = try await server.start()
        defer { server.stop() }
        proxy.take(setup(port))
        try await until(timeout: 20) { server.requests.count >= 1 }
        XCTAssertFalse(proxy.dropped)
        XCTAssertNil(tab.failure)
        XCTAssertNil(tab.pending)
    }

    func testDeletingOnlyRestrictedProfileRestoresRoutingForRemainingProfiles() {
        let prefs = Shared.prefs
        let previous = prefs.proxySetup
        defer {
            prefs.proxyProfiles = previous.profiles
            prefs.proxyOn = previous.on
            prefs.proxyHost = previous.host
            prefs.proxyBlocks = previous.blocks
        }
        let profile = Profiles.shared.add(named: "Proxy-only profile")
        prefs.proxyBlocks = false
        prefs.proxyHost = "proxy-review.invalid"
        prefs.proxyOn = true
        prefs.proxyProfiles = [profile.id]
        XCTAssertFalse(Proxy.shared.routes(for: Profile.personalID))
        Profiles.shared.delete(profile.id)
        XCTAssertTrue(prefs.proxyProfiles.isEmpty)
        XCTAssertEqual(Store.settings.stringArray(forKey: "proxy.profiles"), [])
        XCTAssertTrue(Proxy.shared.routes(for: Profile.personalID))
    }

    func testDeletingOneRestrictedProfilePreservesTheOthers() {
        let prefs = Shared.prefs
        let previous = prefs.proxyProfiles
        let first = Profiles.shared.add(named: "First proxy profile")
        let second = Profiles.shared.add(named: "Second proxy profile")
        defer { Profiles.shared.delete(second.id); prefs.proxyProfiles = previous }
        prefs.proxyProfiles = [first.id, second.id]
        Profiles.shared.delete(first.id)
        XCTAssertEqual(prefs.proxyProfiles, [second.id])
    }

    func testAIRequestsUseCurrentProxyAndRebuildAfterRouteChanges() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIProtocol.self]
        let client = AIClient(configuration: configuration)
        let response = AIResponse()
        AIProtocol.response = response
        Proxy.shared.take(ProxySetup(on: true))
        let first = client.session
        XCTAssertEqual(first.configuration.proxyConfigurations.count, 2)
        var answer = ""
        for try await piece in client.stream(.openAI, model: "synthetic", system: "Test", messages: [], key: "synthetic-test-key") { answer += piece }
        XCTAssertEqual(answer, "local test answer")
        XCTAssertEqual(response.count, 1)
        Proxy.shared.take(ProxySetup())
        let second = client.session
        XCTAssertFalse(first === second)
        XCTAssertEqual(second.configuration.proxyConfigurations.count, 1)
        Proxy.shared.take(ProxySetup(on: true))
        let third = client.session
        XCTAssertFalse(second === third)
        XCTAssertEqual(third.configuration.proxyConfigurations.count, 2)
    }

    func testChangingProxyCancelsAnAIStreamOnTheOldRoute() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIProtocol.self]
        let client = AIClient(configuration: configuration)
        let response = AIResponse(held: true)
        AIProtocol.response = response
        Proxy.shared.take(ProxySetup(on: true))
        let original = client.session
        let streaming = Task {
            for try await _ in client.stream(.openAI, model: "synthetic", system: "Test", messages: [], key: "synthetic-test-key") { }
        }
        defer { streaming.cancel() }
        try await until { response.count == 1 }
        var appearance = Proxy.shared.setup
        appearance.shows.toggle()
        Proxy.shared.take(appearance)
        XCTAssertTrue(client.session === original, "Changing the address-bar mark does not change the route")
        XCTAssertEqual(response.stopped, 0)
        Proxy.shared.take(ProxySetup())
        try await until { response.stopped > 0 }
        try await streaming.value
    }
}

@MainActor
private final class ProxyNavigation: NSObject, WKNavigationDelegate {
    var finished = false
    var loaded = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true; finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finished = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finished = true }
}

private final class LocalProxy: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ProxyTests.local")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var pending: [() -> Void] = []
    private var paths: [String] = []
    private var starting = true
    private let held: Bool
    private let body: String
    private let authorization: String?
    private var attempts = 0
    private var accepted = 0
    var requests: [String] { lock.withLock { paths } }
    var authAttempts: Int { lock.withLock { attempts } }
    var authorized: Int { lock.withLock { accepted } }

    init(held: Bool = false, address: String = "203.0.113.7", user: String? = nil, password: String? = nil, country: String = "ZZ") throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.held = held
        body = "{\"ip\":\"\(address)\",\"city\":\"Test City\",\"country\":\"\(country)\"}"
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
        let connections = lock.withLock { self.connections }
        for connection in connections { connection.cancel() }
    }

    func release() {
        let replies = lock.withLock { let replies = pending; pending = []; return replies }
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
                if let authorization = self.authorization {
                    self.lock.withLock { self.attempts += 1 }
                    let valid = header.components(separatedBy: "\r\n").contains { line in
                        guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == "proxy-authorization" else { return false }
                        return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) == authorization
                    }
                    guard valid else {
                        let rejected = Data("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"Search proxy test\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                        connection.send(content: rejected, contentContext: .finalMessage, isComplete: true,
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
            self.lock.withLock { self.paths.append(header.components(separatedBy: "\r\n")[0]) }
            let response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(self.body.utf8.count)\r\nConnection: close\r\n\r\n\(self.body)".utf8)
            let reply = {
                connection.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            }
            if self.held { self.lock.withLock { self.pending.append(reply) } } else { reply() }
        }
    }
}

private final class ProxyChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) { }
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) { }
    func cancel(_ challenge: URLAuthenticationChallenge) { }
}

private final class AIResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private let held: Bool
    var count: Int { lock.withLock { starts } }
    var stopped: Int { lock.withLock { stops } }
    init(held: Bool = false) { self.held = held }
    func receive(_ request: URLProtocol) {
        lock.withLock { starts += 1 }
        guard !held else { return }
        let response = HTTPURLResponse(url: request.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        request.client?.urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
        request.client?.urlProtocol(request, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"local test answer\"}}]}\n\ndata: [DONE]\n\n".utf8))
        request.client?.urlProtocolDidFinishLoading(request)
    }
    func stop() { lock.withLock { stops += 1 } }
}

private final class AIProtocol: URLProtocol {
    nonisolated(unsafe) static var response: AIResponse?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.openai.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.response?.receive(self) }
    override func stopLoading() { Self.response?.stop() }
}
