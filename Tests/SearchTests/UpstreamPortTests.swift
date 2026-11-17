import AppKit
import WebKit
import XCTest
@testable import Search

final class ImageFetchTests: XCTestCase {
    func testLargeResponseAndBothSizeLimitPaths() async throws {
        let bytes = String(repeating: "x", count: 3_000_000)
        let server = try LocalPageServer(["/image": .init(type: "image/png", body: bytes), "/error": .init(status: "404 Not Found", type: "text/plain", body: "no")])
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let start = Date()
        let data = await ImageFetch(server.url("/image"), limit: 3_000_000).data(over: session)
        XCTAssertEqual(data, Data(bytes.utf8))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "3 MB should not use the old byte-at-a-time slow path")
        let oversized = await ImageFetch(server.url("/image"), limit: 100).data(over: session)
        XCTAssertNil(oversized)
        let rejected = await ImageFetch(server.url("/error"), limit: 100).data(over: session)
        XCTAssertNil(rejected)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkProtocol.self]
        let streaming = URLSession(configuration: configuration)
        defer { streaming.invalidateAndCancel() }
        let overflow = await ImageFetch(URL(string: "https://image.test/chunks")!, limit: 10).data(over: streaming)
        XCTAssertNil(overflow, "An unknown-length response must be bounded while streaming")
    }
    func testChunkDelegatePreservesTorRedirectFence() {
        let session = URLSession(configuration: .ephemeral, delegate: OnionRedirects.shared, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://example.org/image")!
        let fetch = ImageFetch(url, limit: 100)
        let task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: [:])!
        var called = false
        fetch.urlSession(session, task: task, willPerformHTTPRedirection: response,
                         newRequest: URLRequest(url: URL(string: "http://127.0.0.1/private")!)) { next in
            called = true
            XCTAssertNil(next, "Tor image redirects must retain the local-address fence")
        }
        XCTAssertTrue(called)
        var request = URLRequest(url: URL(string: "https://example.net/image")!)
        request.setValue("private-cookie", forHTTPHeaderField: "Cookie")
        request.setValue("private-token", forHTTPHeaderField: "Authorization")
        fetch.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { next in
            XCTAssertEqual(next?.url, request.url)
            XCTAssertNil(next?.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(next?.value(forHTTPHeaderField: "Authorization"))
        }
    }
    private final class ChunkProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 8))
            client?.urlProtocol(self, didLoad: Data(repeating: 2, count: 8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
}

@MainActor
final class WindowScriptPortTests: XCTestCase {
    override class func setUp() {
        if ProcessInfo.processInfo.environment["SEARCH_PROBE"] == nil { setenv("SEARCH_PROBE", "window-port-\(getpid())", 1) }
        super.setUp()
    }
    func testGeometryAndScriptingRespectOwningWindowAndPrivateFrontTab() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        Browsers.register(browser)
        defer { browser.closeAll(); Browsers.discard(browser); window.close() }
        let tab = try XCTUnwrap(browser.active)
        window.contentView = tab.web
        tab.web.loadHTMLString("<title>geometry</title>", baseURL: nil)
        for _ in 0..<100 {
            if (try? await tab.web.evaluateJavaScript("document.title")) as? String == "geometry" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let width = try await tab.web.evaluateJavaScript("window.outerWidth") as? Double
        XCTAssertEqual(width, window.frame.width)
        let detached = WKWebView()
        XCTAssertEqual(browser.windowFrame(for: detached), window.frame)
        XCTAssertNotNil(window.scriptSpace)
        XCTAssertNotNil(window.scriptProfile)
        let privateSource = Search.Tab(shy: true)
        _ = browser.open(URL(string: "about:blank")!, foreground: true, from: privateSource)
        XCTAssertNil(window.scriptCurrentTab)
        XCTAssertNil(window.scriptSpace)
        XCTAssertNil(window.scriptProfile)
    }
}

final class AIRegexPortTests: XCTestCase {
    func testCachedPatternsPreserveSourceComparisonAndLookalikeDetection() {
        let read = AIPage.Read(title: "Contact", url: URL(string: "https://example.org"), text: "Email help@example.org or call +1 212 555 0100.", links: ["https://example.org/help"], cut: false)
        XCTAssertTrue(AIPage.strays(in: "Contact help@example.org at https://example.org/help or +1 212 555 0100.", from: read).isEmpty)
        let stray = AIPage.strays(in: "Use support@evil.net at https://evil.net or +1 415 555 9999.", from: read)
        XCTAssertTrue(stray.contains { $0.contains("support@evil.net") })
        XCTAssertTrue(stray.contains { $0.contains("evil.net") })
        XCTAssertTrue(stray.contains { $0.filter(\.isNumber).contains("14155559999") })
    }
}
