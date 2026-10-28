import AppKit
import Foundation
import WebKit
import XCTest
@testable import Search

/// Only ephemeral stores containing synthetic cookies are modified.
@MainActor
final class ExtensionBrowsingDataTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "extension-removal-\(getpid())", 1)
        super.setUp()
    }

    private func store() -> WKWebsiteDataStore {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        return .nonPersistent()
    }

    private func put(_ name: String, domain: String, in store: WKWebsiteDataStore) async throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: name, .value: "synthetic", .domain: domain, .path: "/", .expires: Date().addingTimeInterval(3600),
        ]))
        await withCheckedContinuation { done in store.httpCookieStore.setCookie(cookie) { done.resume() } }
    }

    private func names(in store: WKWebsiteDataStore) async -> Set<String> {
        let cookies: [HTTPCookie] = await withCheckedContinuation { done in
            store.httpCookieStore.getAllCookies { done.resume(returning: $0) }
        }
        return Set(cookies.map(\.name))
    }

    func testExcludedCookieDomainAndItsSiblingsSurvive() async throws {
        let store = store()
        try await put("keep", domain: "keep.example.com", in: store)
        try await put("same-site", domain: "sibling.example.com", in: store)
        try await put("remove", domain: "other.example.net", in: store)
        let plan = try ExtensionBrowsingData.Plan(["cookies": true], options: ["excludeOrigins": ["https://keep.example.com:8443"]])
        try await plan.remove(from: [store])
        let left = await names(in: store)
        XCTAssertEqual(left, ["keep", "same-site"], "Cookie exclusions protect the complete registrable domain")
    }

    func testIncludedCookiesUseRegistrableDomainButDoNotDeleteOtherSites() async throws {
        let store = store()
        try await put("selected", domain: "one.example.com", in: store)
        try await put("same-site", domain: "two.example.com", in: store)
        try await put("keep", domain: "other.example.net", in: store)
        let plan = try ExtensionBrowsingData.Plan(["cookies": true], options: ["origins": ["http://one.example.com:3000"]])
        try await plan.remove(from: [store])
        let left = await names(in: store)
        XCTAssertEqual(left, ["keep"])
    }

    func testMultiLabelPublicSuffixKeepsUnrelatedRegistrableSitesSeparate() async throws {
        let store = store()
        try await put("keep", domain: ".example.co.uk", in: store)
        try await put("same-site", domain: "accounts.example.co.uk", in: store)
        try await put("remove", domain: "other.co.uk", in: store)
        let plan = try ExtensionBrowsingData.Plan(["cookies": true], options: ["excludeOrigins": ["https://www.example.co.uk"]])
        try await plan.remove(from: [store])
        let left = await names(in: store)
        XCTAssertEqual(left, ["keep", "same-site"], "co.uk itself must not group unrelated registrable sites")
    }

    func testAddressCookieScopesDoNotGroupDistinctAddresses() async throws {
        let store = store()
        try await put("selected", domain: "127.0.0.1", in: store)
        try await put("keep", domain: "127.0.0.2", in: store)
        let plan = try ExtensionBrowsingData.Plan(["cookies": true], options: ["origins": ["http://127.0.0.1:3000"]])
        try await plan.remove(from: [store])
        let left = await names(in: store)
        XCTAssertEqual(left, ["keep"])
    }

    func testEquivalentAddressSpellingsPreserveExcludedCookies() async throws {
        let store = store()
        try await put("keep", domain: "127.0.0.1", in: store)
        try await put("remove", domain: "127.0.0.2", in: store)
        let plan = try ExtensionBrowsingData.Plan(["cookies": true], options: ["excludeOrigins": ["http://127.1"]])
        try await plan.remove(from: [store])
        let left = await names(in: store)
        XCTAssertEqual(left, ["keep"])
    }

    func testEquivalentIPv6SpellingsPreserveExcludedCookiesWhenSupported() async throws {
        let store = store()
        guard let cookie = HTTPCookie(properties: [
            .name: "keep", .value: "synthetic", .domain: "[2001:db8::1]", .path: "/", .expires: Date().addingTimeInterval(3600),
        ]) else { throw XCTSkip("Foundation does not accept this synthetic IPv6 cookie") }
        await withCheckedContinuation { done in store.httpCookieStore.setCookie(cookie) { done.resume() } }
        let inserted = await names(in: store)
        try XCTSkipIf(!inserted.contains("keep"), "WebKit does not accept this synthetic IPv6 cookie")
        try await put("remove", domain: "other.example.net", in: store)
        let plan = try ExtensionBrowsingData.Plan(["cookies": true], options: [
            "excludeOrigins": ["https://[2001:0db8:0:0:0:0:0:1]"],
        ])
        try await plan.remove(from: [store])
        let left = await names(in: store)
        XCTAssertEqual(left, ["keep"])
    }

    func testUnsafeMixedStorageRequestIsRejectedBeforeCookiesChange() async throws {
        let store = store()
        try await put("keep", domain: "example.com", in: store)
        for field in ["origins", "excludeOrigins"] {
            do {
                let plan = try ExtensionBrowsingData.Plan(["cookies": true, "localStorage": true],
                                                         options: [field: ["https://example.com:8443"]])
                try await plan.remove(from: [store])
                XCTFail("WebKit's domain records must not be used as an exact storage origin")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("exact origins"))
            }
            let left = await names(in: store)
            XCTAssertEqual(left, ["keep"], "The entire operation must be validated before deleting any selected data type")
        }
    }

    func testScopedCacheAndHistoryAreRejectedInsteadOfDeletingBroadly() {
        for type in ["cache", "cacheStorage", "indexedDB", "serviceWorkers", "fileSystems", "webSQL", "history"] {
            XCTAssertThrowsError(try ExtensionBrowsingData.Plan([type: true], options: ["origins": ["https://example.com:8443"]]), type)
            XCTAssertThrowsError(try ExtensionBrowsingData.Plan([type: true], options: ["excludeOrigins": ["https://example.com"]]), type)
        }
    }

    func testConflictingOrMalformedScopesAreRejectedBeforeMutation() {
        let cases: [[String: Any]] = [
            ["origins": ["https://example.com"], "excludeOrigins": ["https://other.example"]],
            ["origins": []], ["origins": "https://example.com"], ["excludeOrigins": [1]],
            ["origins": ["https://user:password@example.com"]],
            ["origins": ["https://example.com/path"]], ["origins": ["https://example.com?q=one"]],
            ["origins": ["https://."]], ["origins": ["https://*.example.com"]],
            ["origins": ["file:///tmp/example"]], ["origins": ["not an origin"]],
        ]
        for options in cases { XCTAssertThrowsError(try ExtensionBrowsingData.Plan(["cookies": true], options: options), "\(options)") }
    }

    func testUnsupportedOriginTypesAndTimeScopedCookiesAreRejected() {
        for selection in [["protectedWeb": true], ["extension": true], ["unprotectedWeb": false]] {
            XCTAssertThrowsError(try ExtensionBrowsingData.Plan(["cookies": true], options: ["originTypes": selection]))
        }
        XCTAssertNoThrow(try ExtensionBrowsingData.Plan(["cookies": true], options: [
            "originTypes": ["unprotectedWeb": true, "protectedWeb": false, "extension": false],
        ]))
        XCTAssertThrowsError(try ExtensionBrowsingData.Plan(["cookies": true], options: ["origins": ["https://example.com"], "since": 1]))
        XCTAssertThrowsError(try ExtensionBrowsingData.Plan(["cookies": true], options: ["originTypes": ["unprotectedWeb": 1]]))
        for since in ["invalid" as Any, -1, Double.infinity, true] {
            XCTAssertThrowsError(try ExtensionBrowsingData.Plan(["cookies": true], options: ["since": since]))
        }
    }

    func testEmptyAndFalseOnlyOriginTypeSelectionsCannotDeleteOrdinarySites() async throws {
        let store = store()
        try await put("keep", domain: "example.com", in: store)
        let selections: [[String: Bool]] = [
            [:], ["extension": false], ["protectedWeb": false],
            ["unprotectedWeb": false], ["unprotectedWeb": false, "protectedWeb": false, "extension": false],
        ]
        for selection in selections {
            do {
                let plan = try ExtensionBrowsingData.Plan(["cookies": true], options: ["originTypes": selection])
                try await plan.remove(from: [store])
                XCTFail("An explicit empty origin-type selection must never become the default all-ordinary-sites selection")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("ordinary website data"))
            }
            let left = await names(in: store)
            XCTAssertEqual(left, ["keep"])
        }
    }

    func testOriginsRetainTheirSchemeAndPort() throws {
        let insecure = try ExtensionBrowsingData.Origin("http://example.com:3000")
        let secure = try ExtensionBrowsingData.Origin("https://example.com:8443")
        XCTAssertNotEqual(insecure, secure)
        XCTAssertEqual(insecure.scheme, "http")
        XCTAssertEqual(insecure.port, 3000)
        XCTAssertEqual(secure.scheme, "https")
        XCTAssertEqual(secure.port, 8443)
    }

    func testEquivalentNumericHostSpellingsHaveOneCanonicalOrigin() throws {
        XCTAssertEqual(try ExtensionBrowsingData.Origin("http://127.1"),
                       try ExtensionBrowsingData.Origin("http://127.0.0.1"))
        XCTAssertEqual(try ExtensionBrowsingData.Origin("https://[2001:0db8:0:0:0:0:0:1]"),
                       try ExtensionBrowsingData.Origin("https://[2001:db8::1]"))
        XCTAssertNotEqual(try ExtensionBrowsingData.Origin("http://127.0.0.1"),
                          try ExtensionBrowsingData.Origin("http://127.0.0.2"))
    }

    func testUnscopedCookieRemovalStillWorks() async throws {
        let store = store()
        try await put("remove", domain: "example.com", in: store)
        let plan = try ExtensionBrowsingData.Plan(["cookies": true], options: [:])
        try await plan.remove(from: [store])
        let left = await names(in: store)
        XCTAssertTrue(left.isEmpty)
    }

    func testUnsupportedDataTypesDoNotPretendToBeRemoved() {
        XCTAssertThrowsError(try ExtensionBrowsingData.Plan(["downloads": true, "cookies": true], options: [:]))
    }
}

/// Exercise native dispatch, including argument validation before the
/// removal plan exists. Only a new disposable profile's synthetic cookie
/// store is used; no personal or preexisting profile is cleared.
@available(macOS 15.4, *)
@MainActor
final class ExtensionBrowsingDataDispatchTests: XCTestCase {
    private var browser: Browser!
    private var profile: Profile?
    private var folder: URL!
    private var context: WKWebExtensionContext!
    private var jar: WKHTTPCookieStore!
    private var previousFront: Browser?
    private var previousLazyTabs = false

    override class func setUp() {
        setenv("SEARCH_PROBE", "extension-removal-dispatch-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Proxy.shared.automaticTarget = nil
        Proxy.shared.take(ProxySetup())
        previousFront = Front.shared.browser
        previousLazyTabs = Shared.prefs.lazyTabs
        Shared.prefs.lazyTabs = true
        let made = Profiles.shared.add(named: "Disposable browsing-data dispatch fixture")
        profile = made
        browser = Browser(record: WindowRecord(space: made.home))
        Browsers.register(browser)
        Front.shared.set(browser)
        jar = Profiles.store(made.id).httpCookieStore
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "keep", .value: "synthetic", .domain: "dispatch.example.net", .path: "/", .expires: Date().addingTimeInterval(3600),
        ]))
        await withCheckedContinuation { done in jar.setCookie(cookie) { done.resume() } }
        let id = "removal-dispatch-\(UUID().uuidString.lowercased())"
        folder = Extensions.folder(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Browsing data dispatch fixture", "version": "1", "permissions": ["browsingData"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try ExtensionShims.prepare(folder, fresh: true)
        context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        context.uniqueIdentifier = id
        try await super.setUp()
    }

    override func tearDown() async throws {
        if let browser { Browsers.discard(browser) }
        browser = nil
        context = nil
        jar = nil
        if let profile { Profiles.shared.delete(profile.id) }
        profile = nil
        Front.shared.set(previousFront)
        Shared.prefs.lazyTabs = previousLazyTabs
        if let folder { try? FileManager.default.removeItem(at: folder) }
        try await super.tearDown()
    }

    private func names() async -> Set<String> {
        let cookies: [HTTPCookie] = await withCheckedContinuation { done in
            jar.getAllCookies { done.resume(returning: $0) }
        }
        return Set(cookies.map(\.name))
    }

    private func answer(_ api: String, _ args: [Any]) async throws -> [String: Any] {
        XCTAssertTrue(Extensions.shared.browser === browser)
        let result = try await ExtensionShims.answer(["api": api, "args": args], from: context, owner: Extensions.shared)
        return try XCTUnwrap(result as? [String: Any])
    }

    func testMalformedRemovalOptionsCannotBecomeGlobalCookieRemoval() async throws {
        let malformed: [[Any]] = [[], [NSNull()], ["invalid"], [1], [false], [["not", "an", "object"]]]
        for args in malformed {
            let reply = try await answer("browsingData.removeCookies", args)
            XCTAssertTrue((reply["error"] as? String)?.contains("options must be an object") == true)
            let left = await names()
            XCTAssertEqual(left, ["keep"], "Invalid options must not broaden into an unscoped deletion")
        }
        let valid = try await answer("browsingData.removeCookies", [[:]])
        XCTAssertNil(valid["error"], "The same fixture must reach a valid deletion, rather than failing another dispatch gate")
        let left = await names()
        XCTAssertTrue(left.isEmpty)
    }

    func testMalformedDataTypeMapsRejectWholeRequestBeforeCookieRemoval() async throws {
        let malformed: [[Any]] = [
            [[:]], [[:], NSNull()], [[:], "cookies"],
            [[:], ["cookies": true, "cache": "invalid"]],
            [[:], ["cookies": true, "history": NSNull()]],
            [[:], ["cookies": NSNumber(value: 1)]],
        ]
        for args in malformed {
            let reply = try await answer("browsingData.remove", args)
            XCTAssertTrue((reply["error"] as? String)?.contains("browsingData data types") == true)
            let left = await names()
            XCTAssertEqual(left, ["keep"], "No valid type may be removed when any member of the type map is invalid")
        }
        let valid = try await answer("browsingData.remove", [[:], ["cookies": true]])
        XCTAssertNil(valid["error"])
        let left = await names()
        XCTAssertTrue(left.isEmpty)
    }
}
