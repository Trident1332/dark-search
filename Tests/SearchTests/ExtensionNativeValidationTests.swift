import AppKit
import WebKit
import XCTest
@testable import Search

/// Calls the native dispatcher directly: injected JavaScript is not a
/// permission boundary and cannot protect Swift collection preconditions.
@available(macOS 15.4, *)
@MainActor
final class ExtensionNativeValidationTests: XCTestCase {
    private var browser: Browser!
    private var folders: [URL] = []
    private var previousFront: Browser?
    private var previousLazyTabs = false
    private var previousPolicy = NSApplication.ActivationPolicy.prohibited

    override class func setUp() {
        setenv("SEARCH_PROBE", "extension-native-validation-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        Proxy.shared.automaticTarget = nil
        Proxy.shared.take(ProxySetup())
        previousFront = Front.shared.browser
        browser = Browser(record: WindowRecord())
        previousLazyTabs = browser.prefs.lazyTabs
        browser.prefs.lazyTabs = true
        Browsers.register(browser)
        Front.shared.set(browser)
        try await super.setUp()
    }

    override func tearDown() async throws {
        if let browser {
            browser.prefs.lazyTabs = previousLazyTabs
            browser.closeAll()
            Browsers.discard(browser)
        }
        browser = nil
        Front.shared.set(previousFront)
        for folder in folders {
            Store.settings.removeObject(forKey: "extensions.granted.\(folder.lastPathComponent)")
            try? FileManager.default.removeItem(at: folder)
        }
        folders.removeAll()
        NSApp.setActivationPolicy(previousPolicy)
        try await super.tearDown()
    }

    private func fixture(required: [String] = [], optional: [String] = []) async throws -> WKWebExtensionContext {
        let id = "native-validation-\(UUID().uuidString.lowercased())"
        let folder = Extensions.folder(for: id)
        folders.append(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Native validation fixture", "version": "1",
                                       "permissions": required, "optional_permissions": optional]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try ExtensionShims.prepare(folder, fresh: true)
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        context.uniqueIdentifier = id
        return context
    }

    private func answer(_ api: String, _ args: [Any] = [], context: WKWebExtensionContext) async throws -> [String: Any] {
        let value = try await ExtensionShims.answer(["api": api, "args": args], from: context, owner: Extensions.shared)
        return try XCTUnwrap(value as? [String: Any])
    }

    func testInvalidCollectionCountsReturnErrorsInsteadOfTrapping() async throws {
        let context = try await fixture(required: ["bookmarks", "history"])
        let invalid: [Any] = [Int.min, -1, Int.max, Int(Int32.max) + 1, 1.5,
                              Double.nan, Double.infinity, true, "1", NSNull()]
        for count in invalid {
            for (api, args) in [("bookmarks.getRecent", [count]), ("history.search", [["maxResults": count]])] {
                let reply = try await answer(api, args, context: context)
                XCTAssertNotNil(reply["error"], "\(api) must reject \(count)")
                XCTAssertNil(reply["value"], "An invalid call must have no successful result")
            }
        }
        let zeroBookmarks = try await answer("bookmarks.getRecent", [0], context: context)
        XCTAssertNotNil(zeroBookmarks["error"], "Chrome requires a positive bookmark count")
    }

    func testValidCountsAndOmittedDefaultsStillReturnResults() async throws {
        let context = try await fixture(required: ["bookmarks", "history"])
        let page = URL(string: "https://native-validation.example.invalid/\(UUID().uuidString)")!
        let bookmark = browser.bookmarks.insert(.site("Fixture", page), into: nil)
        defer { browser.bookmarks.remove(bookmark.id) }
        browser.history.record(page, title: "Native validation fixture")
        defer {
            for visit in browser.history.everything() where visit.url == page { browser.history.forget(visit.key) }
        }
        let recent = try await answer("bookmarks.getRecent", [1], context: context)
        XCTAssertEqual((recent["value"] as? [[String: Any]])?.count, 1)
        let history = try await answer("history.search", [["text": "Native validation fixture", "maxResults": 1]], context: context)
        XCTAssertEqual((history["value"] as? [[String: Any]])?.count, 1)
        let zero = try await answer("history.search", [["maxResults": 0]], context: context)
        XCTAssertEqual((zero["value"] as? [[String: Any]])?.count, 0)
        for api in ["bookmarks.getRecent", "history.search"] {
            let reply = try await answer(api, context: context)
            XCTAssertNil(reply["error"])
            XCTAssertNotNil(reply["value"] as? [[String: Any]])
        }
    }

    func testInvalidDownloadIDsReturnErrorsBeforeIndexArithmetic() async throws {
        let context = try await fixture(required: ["downloads", "downloads.open"])
        let invalid: [Any] = [Int.min, -1, 0, Int.max, Int(Int32.max) + 1, 1.5, true, "1", NSNull()]
        for value in invalid {
            for api in ["downloads.open", "downloads.show"] {
                let reply = try await answer(api, [value], context: context)
                XCTAssertNotNil(reply["error"], "\(api) must reject \(value)")
            }
        }
        let unknown = try await answer("downloads.show", [Int(Int32.max)], context: context)
        XCTAssertTrue((unknown["error"] as? String)?.contains("No download") == true)
    }

    func testFontAndSystemEnumerationRequireTheirOwnPermissions() async throws {
        let context = try await fixture()
        for api in ["fontSettings.getFontList", "fontSettings.getFont", "system.cpu.getInfo",
                    "system.memory.getInfo", "system.storage.getInfo", "system.display.getInfo"] {
            let reply = try await answer(api, context: context)
            XCTAssertNotNil(reply["error"], api)
            XCTAssertNil(reply["value"], "Undeclared access must not enumerate user information")
        }
        let cpu = try await fixture(required: ["system.cpu"])
        let allowedCPU = try await answer("system.cpu.getInfo", context: cpu)
        XCTAssertNil(allowedCPU["error"])
        let deniedDisplay = try await answer("system.display.getInfo", context: cpu)
        XCTAssertNotNil(deniedDisplay["error"], "A CPU grant is not a display grant")
    }

    func testRequiredEnumerationPermissionsAllowAccess() async throws {
        let context = try await fixture(required: ["fontSettings", "system.cpu", "system.memory", "system.storage", "system.display"])
        for api in ["fontSettings.getFontList", "system.cpu.getInfo", "system.memory.getInfo",
                    "system.storage.getInfo", "system.display.getInfo"] {
            let reply = try await answer(api, context: context)
            XCTAssertNil(reply["error"], api)
            XCTAssertNotNil(reply["value"], api)
        }
    }

    func testOptionalEnumerationPermissionGrantAndRemovalTakeEffectImmediately() async throws {
        let permissions = ["fontSettings", "system.display"]
        let context = try await fixture(optional: permissions)
        let apis = ["fontSettings.getFontList", "system.display.getInfo"]
        for api in apis {
            let reply = try await answer(api, context: context)
            XCTAssertNotNil(reply["error"], "Optional declaration alone must not grant access")
        }
        let grant = try await answer("permissions.request", [permissions], context: context)
        XCTAssertEqual(grant["value"] as? Bool, true)
        for api in apis {
            let reply = try await answer(api, context: context)
            XCTAssertNil(reply["error"], api)
        }
        _ = try await answer("permissions.remove", [permissions], context: context)
        for api in apis {
            let reply = try await answer(api, context: context)
            XCTAssertNotNil(reply["error"], "Revocation must stop native enumeration immediately")
        }
    }
}
