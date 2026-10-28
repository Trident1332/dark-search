import AppKit
import WebKit
import XCTest
@testable import Search

@available(macOS 15.4, *)
@MainActor
final class ExtensionClosedSessionTests: XCTestCase {
    private var browser: Browser!
    private var folder: URL!
    private var context: WKWebExtensionContext!
    private var previousLazyTabs = false

    override class func setUp() {
        setenv("SEARCH_PROBE", "extension-closed-session-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Proxy.shared.automaticTarget = nil
        Proxy.shared.take(ProxySetup())
        browser = Browser(record: WindowRecord())
        previousLazyTabs = browser.prefs.lazyTabs
        browser.prefs.lazyTabs = true
        Browsers.register(browser)
        let id = "closed-session-\(UUID().uuidString.lowercased())"
        folder = Extensions.folder(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Closed sessions fixture", "version": "1", "permissions": ["sessions"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try ExtensionShims.prepare(folder, fresh: true)
        context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        context.uniqueIdentifier = id
        try await super.setUp()
    }

    override func tearDown() async throws {
        if let browser {
            browser.prefs.lazyTabs = previousLazyTabs
            Browsers.discard(browser)
        }
        browser = nil
        context = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
        try await super.tearDown()
    }

    @discardableResult
    private func close(_ address: String, tor: Bool) throws -> Browser.Ghost {
        let tab = makeOrdinaryTab()
        tab.restore(url: try XCTUnwrap(URL(string: address)), title: tor ? "Private Tor destination" : "Ordinary destination", tor: tor)
        XCTAssertFalse(tab.shy, "Reproduce conversion of an ordinary tab to Tor")
        XCTAssertEqual(tab.usesTor, tor)
        browser.closeTab(tab)
        return try XCTUnwrap(browser.ghosts.last)
    }

    private func makeOrdinaryTab() -> Tab {
        browser.open(URL(string: "about:blank#fixture-\(UUID().uuidString)")!, foreground: false, atEnd: true, mayWait: true)
    }

    private func answer(_ api: String, _ args: [Any] = []) async throws -> [String: Any] {
        let result = try await ExtensionShims.answer(["api": api, "args": args], from: context, owner: Extensions.shared)
        return try XCTUnwrap(result as? [String: Any])
    }

    func testRecentlyClosedNeverDisclosesTorEvenAfterClearnetRedirect() async throws {
        let normal = try close("about:blank#ordinary", tor: false)
        let tor = try close("https://private.example.invalid/after-redirect", tor: true)
        XCTAssertTrue(tor.tor)
        let reply = try await answer("sessions.getRecentlyClosed", [["maxResults": 1]])
        let sessions = try XCTUnwrap(reply["value"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 1)
        let tab = try XCTUnwrap(sessions.first?["tab"] as? [String: Any])
        XCTAssertEqual(tab["sessionId"] as? String, normal.id.uuidString)
        XCTAssertFalse(String(describing: reply).contains("private.example.invalid"))
    }

    func testExplicitTorOrUnknownSessionCannotFallBackToAnotherTab() async throws {
        _ = try close("about:blank#ordinary", tor: false)
        let tor = try close("https://private.example.invalid/", tor: true)
        let before = browser.tabs.map(\.id)
        let ghosts = browser.ghosts
        for id in [tor.id.uuidString, UUID().uuidString] {
            let reply = try await answer("sessions.restore", [id])
            XCTAssertNotNil(reply["error"])
            XCTAssertEqual(browser.tabs.map(\.id), before)
            XCTAssertEqual(browser.ghosts, ghosts)
        }
    }

    func testDefaultRestoreSkipsTheNewestTorSession() async throws {
        let normal = try close("about:blank#ordinary", tor: false)
        let tor = try close("https://private.example.invalid/", tor: true)
        let reply = try await answer("sessions.restore")
        XCTAssertNil(reply["error"])
        let value = try XCTUnwrap(reply["value"] as? [String: Any])
        let tab = try XCTUnwrap(value["tab"] as? [String: Any])
        XCTAssertEqual(tab["url"] as? String, normal.url.absoluteString)
        XCTAssertFalse(browser.ghosts.contains { $0.id == normal.id })
        XCTAssertTrue(browser.ghosts.contains { $0.id == tor.id }, "An extension cannot consume or reopen a Tor session")
        XCTAssertFalse(browser.tabs.contains(where: \.usesTor))
    }

    func testOnlyTorSessionsMeansNothingAccessibleToRestore() async throws {
        _ = try close("https://private.example.invalid/", tor: true)
        let recent = try await answer("sessions.getRecentlyClosed")
        XCTAssertEqual((recent["value"] as? [[String: Any]])?.count, 0)
        let restore = try await answer("sessions.restore")
        XCTAssertNotNil(restore["error"])
    }

    func testAnOrdinarySessionInAMixedBatchCannotRestoreTorSiblings() async throws {
        let anchor = try XCTUnwrap(browser.tabs.first)
        for tor in [false, true] {
            let tab = makeOrdinaryTab()
            tab.restore(url: URL(string: tor ? "https://private.example.invalid/" : "about:blank#ordinary")!,
                        title: tor ? "Private" : "Ordinary", tor: tor)
        }
        browser.closeTabsBelow(anchor)
        let normal = try XCTUnwrap(browser.ghosts.first { !$0.tor })
        let tor = try XCTUnwrap(browser.ghosts.first { $0.tor })
        XCTAssertNotNil(normal.batch)
        XCTAssertEqual(normal.batch, tor.batch)
        let reply = try await answer("sessions.restore", [normal.id.uuidString])
        XCTAssertNil(reply["error"])
        XCTAssertTrue(browser.ghosts.contains { $0.id == tor.id })
        XCTAssertFalse(browser.tabs.contains(where: \.usesTor), "Extension restore must not invoke native bulk undo for a mixed batch")
    }
}
