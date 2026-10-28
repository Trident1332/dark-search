import Foundation
import AppKit
import WebKit
import XCTest
@testable import Search

/// Route markers survive saving ordinary destinations from a Tor tab.
/// These checks use serialized synthetic state, never a live browser store.
final class OnionSessionStateTests: XCTestCase {
    private let destination = "https://clearnet.example.test/a?q=one#part"

    func testTorSessionEntryKeepsItsRouteAfterAClearnetRedirect() throws {
        let entry = Session.Entry(url: destination, title: "Synthetic Tor destination", pin: nil, name: nil, home: nil, tor: true)
        let data = try JSONEncoder().encode(entry)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["tor"] as? Bool, true)
        let restored = try JSONDecoder().decode(Session.Entry.self, from: data)
        XCTAssertTrue(restored.tor)
        XCTAssertEqual(restored.url, destination)
    }

    func testSessionBeforeTorSupportRemainsAnOrdinaryTab() throws {
        let data = try JSONSerialization.data(withJSONObject: ["url": destination, "title": "Legacy ordinary tab"])
        let restored = try JSONDecoder().decode(Session.Entry.self, from: data)
        XCTAssertFalse(restored.tor)
        XCTAssertEqual(restored.url, destination)
    }

    func testOrdinarySessionEntryDoesNotWriteANewRouteMarker() throws {
        let entry = Session.Entry(url: destination, title: "Ordinary", pin: nil, name: nil, home: nil)
        let data = try JSONEncoder().encode(entry)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["tor"])
        XCTAssertFalse(try JSONDecoder().decode(Session.Entry.self, from: data).tor)
    }

    func testFreshSessionKeepsTorMarkerOnNamedAndPinnedEntries() {
        let named = Session.Entry(url: destination, title: "Named", pin: nil, name: "Kept Tor tab", home: nil, tor: true)
        let pin = Session.Entry(url: destination, title: "Pinned", pin: "T", name: nil, home: destination, tor: true)
        let ordinary = Session.Entry(url: destination, title: "Unkept", pin: nil, name: nil, home: nil)
        let kept = Session.fresh(Session.Shape(tabs: [named, pin, ordinary], active: 0))
        XCTAssertEqual(kept.tabs.count, 2)
        XCTAssertTrue(kept.tabs.allSatisfy(\.tor))
    }

    func testTorPinKeepsItsRouteWhenHomeIsAnOrdinaryWebsite() throws {
        let original = PinDef(id: UUID(), letter: "T", home: destination, title: "Tor pin", name: nil, tor: true)
        let data = try JSONEncoder().encode(original)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["tor"] as? Bool, true)
        let restored = try JSONDecoder().decode(PinDef.self, from: data)
        XCTAssertEqual(restored, original)
        XCTAssertTrue(restored.tor)
    }

    func testPinBeforeTorSupportDefaultsToAnOrdinaryRoute() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString, "letter": "N", "home": destination, "title": "Legacy pin"
        ])
        let restored = try JSONDecoder().decode(PinDef.self, from: data)
        XCTAssertFalse(restored.tor)
        XCTAssertEqual(restored.home, destination)
        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any]
        XCTAssertNil(reencoded?["tor"])
    }

    func testTorPinRouteSurvivesOwnAndSharedPinFiles() throws {
        let pin = PinDef(id: UUID(), letter: "T", home: destination, title: "Synthetic Tor pin", name: nil, tor: true)
        let space = UUID(), profile = UUID()
        let data = try XCTUnwrap(Pins.encode(bySpace: [space: [pin]], shared: [pin], others: [profile: [pin]]))
        let restored = try XCTUnwrap(Pins.decode(data))
        XCTAssertEqual(restored.bySpace[space]?.first?.tor, true)
        XCTAssertEqual(restored.shared.first?.tor, true)
        XCTAssertEqual(Pins.sharedLists(data)[profile]?.first?.tor, true)
    }

    func testTorMarkersDoNotBypassCredentialScrubbing() throws {
        let secret = "https://synthetic-user:synthetic-password@clearnet.example.test/a"
        let entry = Session.Entry(url: secret, title: "Synthetic Tor tab", pin: "T", name: nil, home: secret, tor: true)
        let pin = PinDef(id: UUID(), letter: "T", home: secret, title: "Synthetic Tor pin", name: nil, tor: true)
        let entryData = try JSONEncoder().encode(entry), pinData = try JSONEncoder().encode(pin)
        XCTAssertFalse(String(decoding: entryData, as: UTF8.self).contains("synthetic-password"))
        XCTAssertFalse(String(decoding: pinData, as: UTF8.self).contains("synthetic-password"))
        XCTAssertTrue(try JSONDecoder().decode(Session.Entry.self, from: entryData).tor)
        XCTAssertTrue(try JSONDecoder().decode(PinDef.self, from: pinData).tor)
    }

    func testMalformedPinRouteIsRejectedInsteadOfDowngraded() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString, "letter": "T", "home": destination, "title": "Malformed route", "tor": "true"
        ])
        XCTAssertThrowsError(try JSONDecoder().decode(PinDef.self, from: data))
    }

    func testMalformedSessionRouteIsRejectedInsteadOfDowngraded() throws {
        let data = try JSONSerialization.data(withJSONObject: ["url": destination, "title": "Malformed route", "tor": "true"])
        XCTAssertThrowsError(try JSONDecoder().decode(Session.Entry.self, from: data))
    }
}

@available(macOS 15.4, *)
@MainActor
final class OnionExtensionIsolationTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "onion-extension-isolation-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        Proxy.shared.take(ProxySetup())
        for _ in 0..<100 where Proxy.shared.changingContent { try await Task.sleep(for: .milliseconds(20)) }
        try await super.setUp()
    }

    private func context() async throws -> WKWebExtensionContext {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tor-extension-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Synthetic Tor access test", "version": "1",
                                       "permissions": ["tabs", "scripting"], "host_permissions": ["<all_urls>"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        context.hasAccessToPrivateData = true
        return context
    }

    private func tabs() -> (normal: Tab, tor: Tab) {
        let ordinary = WKWebsiteDataStore.nonPersistent()
        let normalConfiguration = WKWebViewConfiguration()
        normalConfiguration.websiteDataStore = ordinary
        let torConfiguration = WKWebViewConfiguration()
        torConfiguration.websiteDataStore = Onion.shared.store(for: ordinary)
        let normal = Tab(configuration: normalConfiguration), tor = Tab(configuration: torConfiguration)
        tor.setAddressOptimistically(URL(string: "https://clearnet.example.test/private-tor-destination")!)
        tor.restore(url: URL(string: "https://example.invalid/tor-page")!, title: "Synthetic Tor title", tor: true)
        return (normal, tor)
    }

    func testPrivateAccessDoesNotRevealTorTabMetadata() async throws {
        let context = try await context()
        let (normal, tor) = tabs()
        let owner = Extensions.shared
        XCTAssertTrue(owner.seen(normal, for: context))
        XCTAssertFalse(owner.seen(tor, for: context))
        let adapter = owner.adapter(for: tor)
        XCTAssertNil(adapter.title(for: context))
        XCTAssertNil(adapter.url(for: context))
        XCTAssertNil(adapter.webView(for: context))
        XCTAssertNil(adapter.window(for: context))
        XCTAssertEqual(adapter.indexInWindow(for: context), NSNotFound)
        XCTAssertFalse(adapter.shouldGrantPermissionsOnUserGesture(for: context))
    }

    func testRetainedAdapterCannotActOnATorTab() async throws {
        let context = try await context()
        let (_, tor) = tabs()
        let adapter = ExtensionTab(tab: tor, owner: .shared)
        do {
            try await adapter.loadURL(URL(string: "https://ordinary.example.test/")!, for: context)
            XCTFail("A retained extension adapter must not navigate a Tor tab")
        } catch { XCTAssertTrue(error.localizedDescription.contains("No tab")) }
        do {
            try await adapter.close(for: context)
            XCTFail("A retained extension adapter must not close a Tor tab")
        } catch { XCTAssertTrue(error.localizedDescription.contains("No tab")) }
        XCTAssertNil(tor.built, "Refused actions must not build a page or start Tor")
    }

    func testTorConfigurationCannotAcquireAnExtensionController() {
        let (_, tor) = tabs()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = tor.store
        Extensions.attach(config)
        XCTAssertNil(config.webExtensionController)
    }

    func testExtensionDownloadDoesNotBorrowTorStore() {
        let (normal, tor) = tabs()
        let torView = tor.web, ordinaryView = normal.web
        defer { ProxyTimeZone.close(torView); ProxyTimeZone.close(ordinaryView) }
        XCTAssertNil(ExtensionShims.downloadPage(active: tor, tabs: [tor]))
        XCTAssertTrue(ExtensionShims.downloadPage(active: tor, tabs: [tor, normal]) === ordinaryView)
    }
}
