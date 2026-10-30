import AppKit
import Foundation
import ImageIO
import WebKit
import XCTest
@testable import Search

/// Exercise the real page-to-icon path. The protocol sends large bodies
/// in chunks and records cancellation, rather than just checking a final
/// Data.count after the entire response has already been received.
@MainActor
final class FaviconBoundsTests: XCTestCase {
    private var previousProtocols: [AnyClass] = []
    private var previousSetup = ProxySetup()
    private var previousTarget: URL?
    private var tabs: [Tab] = []

    override class func setUp() {
        setenv("SEARCH_PROBE", "favicon-bounds-\(getpid())", 1)
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
        Proxy.protocolClasses = [BoundedIconProtocol.self]
        try await super.setUp()
    }

    override func tearDown() async throws {
        for tab in tabs { tab.built?.stopLoading(); tab.built?.navigationDelegate = nil }
        tabs.removeAll()
        BoundedIconProtocol.plan = nil
        Proxy.protocolClasses = previousProtocols
        Proxy.shared.automaticTarget = previousTarget
        Proxy.shared.take(previousSetup)
        for _ in 0..<100 where Proxy.shared.changingContent { try await Task.sleep(for: .milliseconds(20)) }
        try await super.tearDown()
    }

    func testChunkedOversizedIconIsCancelledBeforeWholeBodyAndFallbackStillLoads() async throws {
        let plan = BoundedIconBody(png: try png(), total: 3_000_000)
        let (tab, icons) = try await page(plan)
        icons.fetch(for: tab)
        try await until { plan.done && tab.icon != nil }
        XCTAssertGreaterThanOrEqual(plan.sent, 2_000_000, "Exercise the actual streaming cap, without a length header")
        XCTAssertLessThan(plan.sent, plan.total, "The oversized response must be cancelled before the entire body is received")
        XCTAssertLessThanOrEqual(plan.sent, 2_000_000 + 3 * 65_536, "Cancellation must happen promptly at the cap")
        XCTAssertEqual(plan.payloadRequests, 1, "An oversized icon is a content failure, not a network retry")
        XCTAssertEqual(plan.fallbackRequests, 1)
        XCTAssertEqual(try XCTUnwrap(tab.icon).size, NSSize(width: 64, height: 64))
        withExtendedLifetime(icons) { }
    }

    func testOversizedContentLengthRejectsBodyImmediately() async throws {
        let plan = BoundedIconBody(png: try png(), total: 3_000_000, declared: 3_000_000)
        let (tab, icons) = try await page(plan)
        icons.fetch(for: tab)
        try await until { plan.done && tab.icon != nil }
        // URLProtocol may emit an in-flight chunk before URLSession forwards
        // stopLoading. Header rejection must stop well before the body cap.
        XCTAssertLessThanOrEqual(plan.sent, 65_536, "A known oversized response must be rejected at its headers")
        XCTAssertEqual(plan.payloadRequests, 1)
        XCTAssertEqual(plan.fallbackRequests, 1)
        withExtendedLifetime(icons) { }
    }

    func testValidChunkedPNGStillBecomesTheTabIcon() async throws {
        let png = try png()
        let plan = BoundedIconBody(png: png, total: png.count, payload: png)
        let (tab, icons) = try await page(plan)
        icons.fetch(for: tab)
        try await until { plan.done && tab.icon != nil }
        XCTAssertEqual(plan.sent, png.count)
        XCTAssertEqual(plan.payloadRequests, 1)
        XCTAssertEqual(plan.fallbackRequests, 0, "The declared valid icon must succeed without a fallback")
        XCTAssertEqual(try XCTUnwrap(tab.icon).size, NSSize(width: 64, height: 64))
        withExtendedLifetime(icons) { }
    }

    private func page(_ plan: BoundedIconBody) async throws -> (Tab, Favicons) {
        BoundedIconProtocol.plan = plan
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let tab = Tab(shy: true, configuration: config)
        tabs.append(tab)
        let web = tab.web
        web.configuration.userContentController.removeScriptMessageHandler(forName: IconRelay.name, contentWorld: Web.world)
        let ready = BoundedIconNavigation()
        web.navigationDelegate = ready
        let url = URL(string: "https://\(UUID().uuidString.lowercased()).favicon-bounds.invalid/page")!
        web.loadHTMLString("<!doctype html><link rel=icon href='/payload.png'><p>Fixture</p>", baseURL: url)
        try await until { ready.loaded }
        tab.setAddressOptimistically(url)
        tab.icon = nil
        let icons = Favicons()
        icons.arrived = { [weak icons, weak tab] _ in
            guard let icons, let tab else { return }
            tab.icon = icons.cached(for: tab.address, shy: tab.shy)
        }
        return (tab, icons)
    }

    private func png() throws -> Data {
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
        return encoded as Data
    }

    private func until(_ predicate: @escaping @MainActor () -> Bool,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = Date().addingTimeInterval(6)
        while !predicate(), Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        guard predicate() else {
            XCTFail("Favicon fixture did not finish", file: file, line: line)
            throw URLError(.timedOut)
        }
    }
}

@MainActor
private final class BoundedIconNavigation: NSObject, WKNavigationDelegate {
    var loaded = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
}

private final class BoundedIconBody: @unchecked Sendable {
    let png: Data
    let total: Int
    let declared: Int?
    let payload: Data?
    private let lock = NSLock()
    private var received = 0
    private var ended = false
    private var requests = 0
    private var fallbacks = 0
    var sent: Int { lock.withLock { received } }
    var done: Bool { lock.withLock { ended } }
    var payloadRequests: Int { lock.withLock { requests } }
    var fallbackRequests: Int { lock.withLock { fallbacks } }
    init(png: Data, total: Int, declared: Int? = nil, payload: Data? = nil) {
        self.png = png; self.total = total; self.declared = declared; self.payload = payload
    }
    func add(_ count: Int) { lock.withLock { received += count } }
    func finish() { lock.withLock { ended = true } }
    func requested(payload: Bool) { lock.withLock { if payload { requests += 1 } else { fallbacks += 1 } } }
}

private final class BoundedIconProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: BoundedIconBody?
    static var plan: BoundedIconBody? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    private var body: BoundedIconBody?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".favicon-bounds.invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let plan = Self.plan else {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled)); return
        }
        let payload = url.path == "/payload.png"
        plan.requested(payload: payload)
        guard payload else {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: plan.png)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        body = plan
        var headers = ["Content-Type": "image/png"]
        if let declared = plan.declared { headers["Content-Length"] = String(declared) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        // Leave enough time for URLSession's header disposition before
        // emitting any body: a declared oversized body must never start.
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in self?.send(0, plan) }
    }
    private func send(_ offset: Int, _ plan: BoundedIconBody) {
        guard !plan.done else { return }
        guard offset < plan.total else {
            client?.urlProtocolDidFinishLoading(self)
            plan.finish()
            return
        }
        let size = min(65_536, plan.total - offset)
        plan.add(size)
        let data = plan.payload.map { $0.subdata(in: offset..<(offset + size)) } ?? Data(repeating: 65, count: size)
        client?.urlProtocol(self, didLoad: data)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(1)) { [weak self] in self?.send(offset + size, plan) }
    }
    override func stopLoading() { body?.finish() }
}
