import AppKit
import Foundation
import ImageIO
import WebKit
import XCTest
@testable import Search

/// A real WebKit document declares a synthetic icon. Native favicon
/// requests are answered in-process; no public site or personal cookies
/// are involved. The assertions inspect the image actually worn by a tab.
@MainActor
final class FaviconLoadingTests: XCTestCase {
    private var previousProtocols: [AnyClass] = []
    private var previousSetup = ProxySetup()
    private var previousTarget: URL?
    private var tabs: [Tab] = []
    private var navigations: [FaviconNavigation] = []

    override class func setUp() {
        setenv("SEARCH_PROBE", "favicon-loading-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        previousProtocols = Proxy.protocolClasses
        previousSetup = Proxy.shared.setup
        previousTarget = Proxy.shared.automaticTarget
        Proxy.shared.automaticTarget = nil
        Proxy.shared.take(ProxySetup())
        for _ in 0..<100 where Proxy.shared.changingContent { try await Task.sleep(for: .milliseconds(20)) }
        Proxy.protocolClasses = [FaviconProtocol.self]
        try await super.setUp()
    }

    override func tearDown() async throws {
        for tab in tabs {
            tab.built?.stopLoading()
            tab.built?.navigationDelegate = nil
        }
        tabs.removeAll()
        navigations.removeAll()
        FaviconProtocol.plan = nil
        Proxy.protocolClasses = previousProtocols
        Proxy.shared.automaticTarget = previousTarget
        Proxy.shared.take(previousSetup)
        for _ in 0..<100 where Proxy.shared.changingContent { try await Task.sleep(for: .milliseconds(20)) }
        try await super.tearDown()
    }

    func testChangedIconRetriesARejectedURLAndReplacesTheLetter() async throws {
        for status in [401, 503] {
            let plan = FaviconPlan(png: try png(), status: status)
            FaviconProtocol.plan = plan
            let (tab, icons) = try await page()
            icons.fetch(for: tab)
            try await until { plan.requestCount >= 2 }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertNil(tab.icon, "The rejected icon must first reproduce the letter fallback")

            plan.status = 200
            icons.fetch(for: tab, changed: true)
            try await until { tab.icon != nil && plan.logoCount > 1 }
            try assertRedIcon(try XCTUnwrap(tab.icon))
            XCTAssertGreaterThan(plan.logoCount, 1, "A changed declaration must retry the same previously rejected URL")
        }
    }

    func testIconRequestUsesItsOwnWebsiteStoreCookies() async throws {
        let plan = FaviconPlan(png: try png(), requiredCookie: "icon-session=synthetic")
        FaviconProtocol.plan = plan
        let (tab, icons) = try await page()
        let jar = tab.web.configuration.websiteDataStore.httpCookieStore
        let own = try XCTUnwrap(HTTPCookie(properties: [
            .name: "icon-session", .value: "synthetic", .domain: "favicon-fixture.invalid", .path: "/",
            .secure: "TRUE", .expires: Date().addingTimeInterval(3600),
        ]))
        let unrelated = try XCTUnwrap(HTTPCookie(properties: [
            .name: "unrelated", .value: "must-stay-private", .domain: "other-fixture.invalid", .path: "/",
            .secure: "TRUE", .expires: Date().addingTimeInterval(3600),
        ]))
        for cookie in [own, unrelated] {
            await withCheckedContinuation { done in jar.setCookie(cookie) { done.resume() } }
        }
        icons.fetch(for: tab)
        try await until { tab.icon != nil && plan.logoCount > 0 }
        try assertRedIcon(try XCTUnwrap(tab.icon))
        let header = plan.logoCookies.joined(separator: "; ")
        XCTAssertTrue(header.contains("icon-session=synthetic"))
        XCTAssertFalse(header.contains("unrelated"), "Another site's cookies must never be copied into this icon request")
    }

    func testInlineDeclaredPNGBecomesTheActualTabImage() async throws {
        let image = try png()
        let href = "data:image/png;base64," + image.base64EncodedString()
        let (tab, icons) = try await page(icon: href)
        icons.fetch(for: tab)
        try await until { tab.icon != nil }
        try assertRedIcon(try XCTUnwrap(tab.icon))
    }

    func testCrossOriginIconDoesNotReceivePageCookies() async throws {
        let plan = FaviconPlan(png: try png())
        FaviconProtocol.plan = plan
        let href = "https://cdn.favicon-fixture.invalid/\(UUID().uuidString)/logo.png"
        let (tab, icons) = try await page(icon: href)
        // This domain cookie is eligible for both hosts under ordinary
        // domain matching. An icon on a different origin must still not
        // inherit the page's authentication.
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "page-session", .value: "must-stay-private", .domain: ".favicon-fixture.invalid", .path: "/",
            .secure: "TRUE", .expires: Date().addingTimeInterval(3600),
        ]))
        await withCheckedContinuation { done in
            tab.web.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { done.resume() }
        }
        icons.fetch(for: tab)
        try await until { tab.icon != nil && plan.logoCount > 0 }
        try assertRedIcon(try XCTUnwrap(tab.icon))
        XCTAssertTrue(plan.logoCookies.allSatisfy(\.isEmpty), "A cross-origin icon must receive no page cookies")
    }

    func testDeclaredIconArrivesBeforeSlowPageFinishesLoading() async throws {
        let plan = FaviconPlan(png: try png())
        FaviconProtocol.plan = plan
        let identity = UUID().uuidString.lowercased()
        let url = URL(string: "http://favicon-fixture.invalid/\(identity)/page")!
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let held = FaviconHeldImage()
        configuration.setURLSchemeHandler(held, forURLScheme: "favicon-hold")
        Proxy.shared.apply(to: configuration.websiteDataStore, profile: Profile.personalID)
        let tab = Tab(configuration: configuration)
        tabs.append(tab)
        let web = tab.web
        let navigation = FaviconNavigation()
        navigation.committed = { [weak tab] in
            tab?.setAddressOptimistically(url)
            tab?.icon = nil
        }
        navigations.append(navigation)
        web.navigationDelegate = navigation
        let icons = Favicons.shared
        let previous = icons.arrived
        icons.arrived = { [weak tab] site in
            previous?(site)
            guard let tab, site == Favicons.site(url) else { return }
            tab.icon = icons.cached(for: tab.address, shy: tab.shy)
        }
        defer {
            web.stopLoading()
            held.finish()
            icons.arrived = previous
        }
        web.loadHTMLString("""
            <!doctype html><html><head><title>Slow favicon fixture</title>
            <link rel=icon href="logo.png"></head><body>
            <img src="favicon-hold://fixture/image"><p>The image is still loading.</p></body></html>
            """, baseURL: url)
        try await until { held.started && tab.icon != nil && plan.logoCount > 0 }
        try assertRedIcon(try XCTUnwrap(tab.icon))
        XCTAssertFalse(navigation.finished, "The icon must arrive before the page's outstanding resource completes")
        XCTAssertEqual(plan.logoCount, 1, "DocumentEnd, without a didFinish callback, must initiate the icon request")
    }

    func testProxyRecoveryRetriesExistingTabWithoutAnotherNavigation() async throws {
        let plan = FaviconPlan(png: try png())
        plan.transportFailure = true
        FaviconProtocol.plan = plan
        let browser = Browser(record: WindowRecord())
        let lazy = browser.prefs.lazyTabs
        browser.prefs.lazyTabs = true
        Browsers.register(browser)
        defer {
            browser.closeAll()
            Browsers.discard(browser)
            browser.prefs.lazyTabs = lazy
        }
        let (tab, icons) = try await page(browser: browser)
        XCTAssertFalse(tab.asleep, "Recovery must exercise an open document, not a lazy tab placeholder")
        icons.fetch(for: tab)
        // This page's unique icon, asked twice, establishes the loader's
        // network backoff. The shared root favicon can already be cached.
        try await until(timeout: 8) { plan.logoCount >= 2 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(tab.icon)
        let document = tab.web.url
        let requests = plan.logoCount
        plan.transportFailure = false
        NotificationCenter.default.post(name: Proxy.contentChanged, object: nil)
        try await until { tab.icon != nil && plan.logoCount > requests }
        try assertRedIcon(try XCTUnwrap(tab.icon))
        XCTAssertGreaterThan(plan.logoCount, requests)
        XCTAssertEqual(tab.web.url, document, "Recovering an icon must not navigate the user's existing document")
    }

    func testNonpersistentProxyTestRestoresIconWithoutManualNotificationOrNavigation() async throws {
        Proxy.shared.take(ProxySetup(on: true, host: "favicon-proxy.invalid", blocks: false, matchesTimeZone: false))
        for _ in 0..<100 where Proxy.shared.changingContent { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(Proxy.shared.setup.persistent)
        let plan = FaviconPlan(png: try png())
        plan.transportFailure = true
        FaviconProtocol.plan = plan
        let (tab, icons) = try await page()
        icons.fetch(for: tab)
        try await until(timeout: 8) { plan.logoCount >= 2 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(tab.icon)
        let document = tab.web.url
        let attempts = plan.logoCount

        plan.transportFailure = false
        // Exercise the real Poke completion path. Nonpersistent recovery
        // does not replace browser content, so it needs its own notification.
        Proxy.shared.test(target: URL(string: "https://favicon-fixture.invalid/health.json")!)
        try await until(timeout: 8) {
            guard case .reached = Proxy.shared.check else { return false }
            return tab.icon != nil && plan.logoCount > attempts
        }
        try assertRedIcon(try XCTUnwrap(tab.icon))
        XCTAssertGreaterThan(plan.logoCount, attempts)
        XCTAssertEqual(tab.web.url, document, "Poking the proxy must restore the favicon without reloading the page")
    }

    private func page(icon: String? = nil, browser: Browser? = nil) async throws -> (Tab, Favicons) {
        let identity = UUID().uuidString.lowercased()
        let url = URL(string: "https://favicon-fixture.invalid/\(identity)/page")!
        let tab: Tab
        if let browser {
            tab = browser.open(URL(string: "about:blank#\(identity)")!, foreground: true, atEnd: true, mayWait: false)
        } else {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            Proxy.shared.apply(to: configuration.websiteDataStore, profile: Profile.personalID)
            tab = Tab(configuration: configuration)
        }
        tabs.append(tab)
        let web = tab.web
        if browser != nil { try await until { !web.isLoading } }
        // These tests explicitly drive their own loader after the page
        // settles. Keep the production DocumentEnd relay for its separate
        // slow-resource regression above, not for these private instances.
        web.configuration.userContentController.removeScriptMessageHandler(forName: IconRelay.name, contentWorld: Web.world)
        let navigation = FaviconNavigation()
        navigations.append(navigation)
        web.navigationDelegate = navigation
        web.loadHTMLString("<!doctype html><title>Favicon fixture</title><link rel=icon href='\(icon ?? "logo.png")'><p>Fixture</p>", baseURL: url)
        try await until { navigation.finished }
        XCTAssertTrue(navigation.loaded)
        tab.setAddressOptimistically(url)
        let icons = browser == nil ? Favicons() : Favicons.shared
        if browser == nil {
            icons.arrived = { [weak icons, weak tab] _ in
                guard let icons, let tab else { return }
                tab.icon = icons.cached(for: tab.address, shy: tab.shy)
            }
        }
        // setAddressOptimistically may adopt another fixture page's cached
        // site image. Every loading regression starts from its own missing
        // icon so it cannot pass on that nearest-neighbour fallback.
        tab.icon = nil
        return (tab, icons)
    }

    private func png() throws -> Data {
        // Write known sRGB pixels directly. NSBitmapImageRep.setColor
        // cannot reliably resolve catalog NSColors in a headless process.
        let pixels = Data((0..<(32 * 32)).flatMap { _ in [UInt8(255), 0, 0, 255] })
        let image = try XCTUnwrap(CGImage(width: 32, height: 32, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 128, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: CGDataProvider(data: pixels as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(encoded, nil))
        try assertRedPixels(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        return encoded as Data
    }

    private func assertRedIcon(_ image: NSImage, file: StaticString = #filePath, line: UInt = #line) throws {
        let decoded = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil), file: file, line: line)
        try assertRedPixels(decoded, file: file, line: line)
    }

    private func assertRedPixels(_ image: CGImage, file: StaticString = #filePath, line: UInt = #line) throws {
        // Inspect explicit sRGB bytes instead of NSColor's device-space
        // conversion; also reject an accidentally transparent fixture.
        var pixel = [UInt8](repeating: 0, count: 4)
        let made = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        XCTAssertTrue(made, file: file, line: line)
        XCTAssertGreaterThan(pixel[0], 230, file: file, line: line)
        XCTAssertLessThan(pixel[1], 26, file: file, line: line)
        XCTAssertLessThan(pixel[2], 26, file: file, line: line)
        XCTAssertGreaterThan(pixel[3], 230, file: file, line: line)
    }

    private func until(timeout: TimeInterval = 6, _ predicate: @escaping @MainActor () -> Bool,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard predicate() else {
            XCTFail("The favicon fixture did not produce its expected tab image or response", file: file, line: line)
            throw URLError(.timedOut)
        }
    }
}

@MainActor
private final class FaviconNavigation: NSObject, WKNavigationDelegate {
    var finished = false
    var loaded = false
    var committed: (() -> Void)?
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { committed?() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true; finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finished = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finished = true }
}

@MainActor
private final class FaviconHeldImage: NSObject, WKURLSchemeHandler {
    private var tasks: [WKURLSchemeTask] = []
    var started = false
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        started = true
        tasks.append(urlSchemeTask)
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        tasks.removeAll { $0 === urlSchemeTask }
    }
    func finish() { tasks.removeAll() }
}

private final class FaviconPlan: @unchecked Sendable {
    let png: Data
    let requiredCookie: String?
    private let lock = NSLock()
    private var responseStatus: Int
    private var blocked = false
    private var requests = 0
    private var cookies: [String] = []
    var status: Int {
        get { lock.withLock { responseStatus } }
        set { lock.withLock { responseStatus = newValue } }
    }
    var requestCount: Int { lock.withLock { requests } }
    var transportFailure: Bool {
        get { lock.withLock { blocked } }
        set { lock.withLock { blocked = newValue } }
    }
    var logoCount: Int { lock.withLock { cookies.count } }
    var logoCookies: [String] { lock.withLock { cookies } }
    init(png: Data, status: Int = 200, requiredCookie: String? = nil) {
        self.png = png; responseStatus = status; self.requiredCookie = requiredCookie
    }
    func answer(_ request: URLRequest) -> (Int, Data) {
        lock.withLock {
            requests += 1
            if request.url?.lastPathComponent == "health.json" {
                return (200, Data(#"{"ip":"203.0.113.42","country":"United States","country_code":"US","city":"Fixture"}"#.utf8))
            }
            guard request.url?.lastPathComponent == "logo.png" else { return (404, Data()) }
            let header = request.value(forHTTPHeaderField: "Cookie") ?? ""
            cookies.append(header)
            guard requiredCookie.map({ header.contains($0) }) ?? true else { return (401, Data()) }
            return (responseStatus, responseStatus == 200 ? png : Data())
        }
    }
}

private final class FaviconProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var kept: FaviconPlan?
    static var plan: FaviconPlan? {
        get { lock.withLock { kept } }
        set { lock.withLock { kept = newValue } }
    }
    override class func canInit(with request: URLRequest) -> Bool {
        ["favicon-fixture.invalid", "cdn.favicon-fixture.invalid"].contains(request.url?.host ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let plan = Self.plan, let url = request.url else { return }
        let (status, data) = plan.answer(request)
        if plan.transportFailure {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let type = url.lastPathComponent == "health.json" ? "application/json" : "image/png"
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
