import AppKit
import WebKit
import XCTest
@testable import Search

@available(macOS 15.4, *)
@MainActor
final class ExtensionFetchTransportTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "extension-fetch-route-\(getpid())", 1)
        super.setUp()
    }

    func testExtensionFetchUsesManagedProxyWithoutASharedCookieOrCredentialJar() {
        _ = NSApplication.shared
        let previous = Proxy.shared.setup
        defer { Proxy.shared.take(previous) }
        Proxy.shared.take(ProxySetup(on: false))
        let direct = ExtensionFetch.networkSession()
        defer { direct.invalidateAndCancel() }
        let directRoutes = direct.configuration.proxyConfigurations.count
        Proxy.shared.take(ProxySetup(on: true, kind: .http, host: "127.0.0.1", port: 9))
        let routed = ExtensionFetch.networkSession()
        defer { routed.invalidateAndCancel() }
        XCTAssertGreaterThan(routed.configuration.proxyConfigurations.count, directRoutes)
        XCTAssertNil(routed.configuration.httpCookieStorage)
        XCTAssertNil(routed.configuration.urlCredentialStorage)
        XCTAssertNil(routed.configuration.urlCache)
        XCTAssertFalse(routed.configuration.httpShouldSetCookies)
        XCTAssertEqual(routed.configuration.httpCookieAcceptPolicy, .never)
    }

    func testFloatingFieldDraftDoesNotCrossPrivateTabBoundary() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let saved = browser.prefs.floatingNewTab
        browser.prefs.floatingNewTab = true
        defer { browser.closeAll(); browser.prefs.floatingNewTab = saved }
        let ordinary = browser.active!
        ordinary.restore(url: URL(string: "https://ordinary.test/")!, title: "ordinary")
        browser.newShyTab()
        let hidden = browser.active!
        hidden.restore(url: URL(string: "https://private.test/")!, title: "private")
        browser.activeID = ordinary.id
        browser.launch(); browser.typed = "ordinary draft"; browser.dismiss()
        browser.launch()
        XCTAssertEqual(browser.typed, "ordinary draft", "ordinary drafts still resume")
        browser.dismiss()
        browser.activeID = hidden.id
        browser.launch()
        XCTAssertEqual(browser.typed, "", "a private field does not inherit an ordinary draft")
        browser.typed = "private query"; browser.dismiss()
        browser.activeID = ordinary.id
        browser.launch()
        XCTAssertEqual(browser.typed, "", "the dismissed private query is not offered outside its tab")
    }

    func testClosedWindowHistoryStaysInMemoryAndTorFlagStillPersists() throws {
        var entry = Session.Entry(url: "https://example.test/", title: "page")
        entry.tor = true
        entry.keepsake = Browser.Keepsake(state: "synthetic-page-form-state")
        let data = try JSONEncoder().encode(entry)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(encoded.contains("synthetic-page-form-state"))
        XCTAssertFalse(encoded.contains("keepsake"))
        let restored = try JSONDecoder().decode(Session.Entry.self, from: data)
        XCTAssertTrue(restored.tor)
        XCTAssertNil(restored.keepsake)
    }
}
