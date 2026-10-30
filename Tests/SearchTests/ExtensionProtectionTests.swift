import AppKit
import JavaScriptCore
import WebKit
import XCTest
@testable import Search

@available(macOS 15.4, *)
@MainActor
final class ExtensionProtectionTests: XCTestCase {
    private var folders: [URL] = []
    private var browser: Browser?

    override class func setUp() {
        setenv("SEARCH_PROBE", "extension-protection-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        Browsers.register(browser)
        self.browser = browser
        try await super.setUp()
    }

    override func tearDown() async throws {
        if let browser { Browsers.discard(browser) }
        browser = nil
        for folder in folders {
            let id = folder.lastPathComponent
            Store.settings.removeObject(forKey: "extensions.granted.\(id)")
            Extensions.setSettings([:], for: id)
            try? FileManager.default.removeItem(at: folder)
        }
        folders.removeAll()
        try await super.tearDown()
    }

    private func fixture(required: [String] = [], optional: [String] = []) async throws -> WKWebExtensionContext {
        let id = "protection-\(UUID().uuidString.lowercased())"
        let folder = Extensions.folder(for: id)
        folders.append(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Protection fixture", "version": "1",
            "permissions": required, "optional_permissions": optional,
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try ExtensionShims.prepare(folder, fresh: true)
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        context.uniqueIdentifier = id
        // This grant exists in the running app for the internal bridge. It
        // must not authorize native hosts or appear as user-granted access.
        context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
        return context
    }

    private func answer(_ api: String, _ args: [Any], context: WKWebExtensionContext) async throws -> [String: Any] {
        let reply = try await ExtensionShims.answer(["api": api, "args": args], from: context, owner: Extensions.shared)
        return try XCTUnwrap(reply as? [String: Any])
    }

    func testUnsupportedBrowserControlsNeverClaimProtection() async throws {
        let context = try await fixture(required: ["privacy", "proxy"])
        let id = context.uniqueIdentifier
        let unsupported: [(String, Any)] = [
            ("proxy.settings", ["mode": "fixed_servers", "rules": ["singleProxy": ["host": "proxy.invalid", "port": 8080]]]),
            ("privacy.network.webRTCIPHandlingPolicy", "disable_non_proxied_udp"),
            ("privacy.websites.thirdPartyCookiesAllowed", false),
            ("privacy.websites.referrersEnabled", false),
        ]
        for (name, value) in unsupported {
            let set = try await answer("setting.set:\(name)", [["value": value]], context: context)
            XCTAssertNotNil(set["error"], name)
            XCTAssertNil(Extensions.settings(for: id)[name], "Unsupported changes must not be saved as accepted")
            let clear = try await answer("setting.clear:\(name)", [[:]], context: context)
            XCTAssertNotNil(clear["error"], name)
            // Old versions persisted these values. A read must not claim
            // that such a leftover is controlling the browser now.
            Extensions.setSettings([name: value], for: id)
            let get = try await answer("setting.get:\(name)", [[:]], context: context)
            let result = try XCTUnwrap(get["value"] as? [String: Any])
            XCTAssertEqual(result["levelOfControl"] as? String, "not_controllable", name)
            XCTAssertTrue(result["value"] is NSNull, name)
            Extensions.setSettings([:], for: id)
        }
    }

    func testPasswordManagerSavingControlStillSetsReadsAndClears() async throws {
        let context = try await fixture(required: ["privacy"])
        let name = "privacy.services.passwordSavingEnabled"
        let set = try await answer("setting.set:\(name)", [["value": false]], context: context)
        XCTAssertNil(set["error"])
        XCTAssertEqual(Extensions.settings(for: context.uniqueIdentifier)[name] as? Bool, false)
        let get = try await answer("setting.get:\(name)", [[:]], context: context)
        let result = try XCTUnwrap(get["value"] as? [String: Any])
        XCTAssertEqual(result["value"] as? Bool, false)
        XCTAssertEqual(result["levelOfControl"] as? String, "controlled_by_this_extension")
        let clear = try await answer("setting.clear:\(name)", [[:]], context: context)
        XCTAssertNil(clear["error"])
        XCTAssertNil(Extensions.settings(for: context.uniqueIdentifier)[name])
        let invalid = try await answer("setting.set:\(name)", [["value": "false"]], context: context)
        XCTAssertNotNil(invalid["error"])
        let scoped = try await answer("setting.set:\(name)", [["value": false, "scope": "incognito_session_only"]], context: context)
        XCTAssertNotNil(scoped["error"])
    }

    func testOptionalNativeMessagingNeedsConsentAndPersistsUntilRemoved() async throws {
        let context = try await fixture(optional: ["nativeMessaging"])
        let owner = Extensions.shared
        let previousAnswer = owner.answerForTests
        defer { owner.answerForTests = previousAnswer }
        XCTAssertFalse(Extensions.asksForNative(context))
        let before = try await answer("permissions.granted", [], context: context)
        XCTAssertFalse((before["value"] as? [String] ?? []).contains("nativeMessaging"))
        owner.answerForTests = false
        let denied = try await answer("permissions.request", [["nativeMessaging"]], context: context)
        XCTAssertEqual(denied["value"] as? Bool, false)
        XCTAssertFalse(Extensions.asksForNative(context))
        owner.answerForTests = true
        let granted = try await answer("permissions.request", [["nativeMessaging"]], context: context)
        XCTAssertEqual(granted["value"] as? Bool, true)
        XCTAssertTrue(Extensions.asksForNative(context))
        let reloaded = WKWebExtensionContext(for: context.webExtension)
        reloaded.uniqueIdentifier = context.uniqueIdentifier
        XCTAssertTrue(Extensions.asksForNative(reloaded), "Reload uses the saved optional grant")
        _ = try await answer("permissions.remove", [["nativeMessaging"]], context: reloaded)
        XCTAssertFalse(Extensions.asksForNative(context))
        XCTAssertFalse(Extensions.asksForNative(reloaded))
        XCTAssertEqual(context.permissionStatus(for: .nativeMessaging), .grantedExplicitly, "The internal bridge remains available")
    }

    func testRequiredNativeAccessStillWorksAndInjectedAccessCannotBeRequested() async throws {
        let required = try await fixture(required: ["nativeMessaging"])
        XCTAssertTrue(Extensions.asksForNative(required))
        _ = try await answer("permissions.remove", [["nativeMessaging"]], context: required)
        XCTAssertTrue(Extensions.asksForNative(required), "A required install permission is not an optional grant")
        let injected = try await fixture()
        XCTAssertFalse(Extensions.asksForNative(injected))
        let request = try await answer("permissions.request", [["nativeMessaging"]], context: injected)
        XCTAssertNotNil(request["error"], "The implementation bridge must not count as a manifest declaration")
        let granted = try await answer("permissions.granted", [], context: injected)
        XCTAssertFalse((granted["value"] as? [String] ?? []).contains("nativeMessaging"))
    }

    func testContentSettingsRejectBothPromiseAndCallbackCalls() throws {
        let script = ExtensionShims.script
        let refusalStart = try XCTUnwrap(script.range(of: "const refuse = (what) =>"))
        let refusalEnd = try XCTUnwrap(script.range(of: "define(\"search\"", range: refusalStart.upperBound..<script.endIndex))
        let contentStart = try XCTUnwrap(script.range(of: "const contentSetting = (name) =>"))
        let contentEnd = try XCTUnwrap(script.range(of: "put2(\"contentSettings\"", range: contentStart.upperBound..<script.endIndex))
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript("""
        const runtime = {};
        const withLastError = (error, callback) => {
          runtime.lastError = { message: error.message };
          try { callback(); } finally { delete runtime.lastError; }
        };
        \(script[refusalStart.lowerBound..<refusalEnd.lowerBound])
        \(script[contentStart.lowerBound..<contentEnd.lowerBound])
        const errors = [];
        for (const name of ['cookies', 'javascript', 'camera', 'microphone']) {
          const setting = contentSetting(name);
          for (const method of ['get', 'set', 'clear', 'getResourceIdentifiers']) {
            setting[method]({ setting: 'block' }, () => errors.push(runtime.lastError && runtime.lastError.message));
          }
        }
        let rejection;
        contentSetting('cookies').set({ setting: 'block' }).then(
          () => rejection = 'incorrectly accepted', error => rejection = error.message);
        """)
        XCTAssertNil(js.exception?.toString())
        XCTAssertEqual(js.evaluateScript("errors.length")?.toInt32(), 16)
        XCTAssertEqual(js.evaluateScript("errors.every(e => typeof e === 'string' && e.includes(\"isn't available in \(Brand.name)\"))")?.toBool(), true)
        XCTAssertEqual(js.evaluateScript("rejection")?.toString(), "contentSettings.cookies.set isn't available in \(Brand.name)")
        XCTAssertEqual(js.evaluateScript("runtime.lastError === undefined")?.toBool(), true)
    }
}
