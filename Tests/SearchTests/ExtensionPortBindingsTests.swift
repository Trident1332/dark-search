import AppKit
import WebKit
import XCTest
@testable import Search

@available(macOS 15.4, *)
@MainActor
final class ExtensionPortBindingsTests: XCTestCase {
    override class func setUp() {
        if ProcessInfo.processInfo.environment["SEARCH_PROBE"] == nil {
            setenv("SEARCH_PROBE", "extension-port-bindings-\(getpid())", 1)
        }
        super.setUp()
    }

    func testScopeSurvivesKeepingTheSameDocumentButNotClosingIt() async throws {
        try await withFixture { owner, context, browser in
            let bindings = ExtensionPortBindings.shared
            let page = self.page(in: browser)
            defer { page.close() }
            owner.openedAside(page)
            let view = page.web
            let scope = try XCTUnwrap(bindings.register("kept", in: context, view: view, owner: owner))
            let previous = owner.adapter(for: page)
            XCTAssertEqual(bindings.register("kept", in: context, view: view, owner: owner), scope)

            browser.insert(page, at: browser.tabs.count)
            try await self.until {
                let current = owner.adapter(for: page)
                return current !== previous && context.openTabs.contains(current)
            }
            XCTAssertTrue(page.built === view)
            XCTAssertFalse(context.openTabs.contains(previous))
            XCTAssertTrue(bindings.allowed(scope, in: context, owner: owner),
                          "changing only the windowless adapter must preserve the document's ports")

            browser.close(page)
            XCTAssertFalse(bindings.allowed(scope, in: context, owner: owner))
            XCTAssertNil(bindings.register("closed", in: context, view: view, owner: owner),
                         "a retained WKWebView is not an open app tab")
        }
    }

    func testPrivateRevocationCannotBeUndoneByImmediateRegrantAndTorNeverRegisters() async throws {
        try await withFixture { owner, context, browser in
            let bindings = ExtensionPortBindings.shared
            let id = context.uniqueIdentifier
            owner.setPrivate(id, false)
            let denied = self.page(in: browser, shy: true)
            defer { denied.close() }
            owner.openedAside(denied)
            XCTAssertNil(bindings.register("denied", in: context, view: denied.web, owner: owner))

            owner.setPrivate(id, true)
            let privatePage = self.page(in: browser, shy: true)
            defer { privatePage.close() }
            owner.openedAside(privatePage)
            let scope = try XCTUnwrap(bindings.register("private", in: context, view: privatePage.web, owner: owner))
            XCTAssertTrue(bindings.allowed(scope, in: context, owner: owner))
            owner.setPrivate(id, false)
            owner.setPrivate(id, true)
            XCTAssertFalse(bindings.allowed(scope, in: context, owner: owner),
                           "regranting access cannot revive a scope issued before revocation")
            let regranted = try XCTUnwrap(bindings.register("regranted", in: context, view: privatePage.web, owner: owner))
            XCTAssertNotEqual(regranted, scope)
            owner.setPrivate(id, false)
            XCTAssertFalse(bindings.allowed(regranted, in: context, owner: owner))

            let normal = self.page(in: browser)
            defer { normal.close() }
            owner.openedAside(normal)
            let oldView = normal.web
            let normalScope = try XCTUnwrap(bindings.register("normal", in: context, view: oldView, owner: owner))
            normal.restore(url: URL(string: "https://private.example.invalid/")!, title: "Tor fixture", tor: true)
            XCTAssertTrue(normal.usesTor)
            XCTAssertFalse(bindings.allowed(normalScope, in: context, owner: owner))
            XCTAssertNil(bindings.register("old-tor", in: context, view: oldView, owner: owner))
            XCTAssertNil(bindings.register("tor", in: context, view: normal.web, owner: owner))
        }
    }

    func testScopeCleanupRequiresItsExactContextViewAndToken() async throws {
        try await withFixture { owner, context, browser in
            let bindings = ExtensionPortBindings.shared
            let page = self.page(in: browser), other = self.page(in: browser)
            defer { page.close(); other.close() }
            owner.openedAside(page)
            owner.openedAside(other)
            let view = page.web
            let scope = try XCTUnwrap(bindings.register("source", in: context, view: view, owner: owner))
            let sameIDContext = WKWebExtensionContext(for: context.webExtension)
            sameIDContext.uniqueIdentifier = context.uniqueIdentifier
            XCTAssertFalse(bindings.allowed(scope, in: sameIDContext, owner: owner))
            XCTAssertFalse(bindings.release(scope, in: sameIDContext))
            XCTAssertTrue(bindings.allowed(scope, in: context, owner: owner),
                          "a different context cannot invalidate a scope merely by copying its extension ID")
            XCTAssertNil(bindings.register("source", in: context, view: other.web, owner: owner))
            XCTAssertFalse(bindings.unregister("source", scope: scope, in: context, view: other.web))
            XCTAssertFalse(bindings.unregister("other-token", scope: scope, in: context, view: view))
            XCTAssertTrue(bindings.allowed(scope, in: context, owner: owner))
            XCTAssertTrue(bindings.unregister("source", scope: scope, in: context, view: view))
            XCTAssertFalse(bindings.allowed(scope, in: context, owner: owner))

            let terminal = try XCTUnwrap(bindings.register("terminal", in: context, view: view, owner: owner))
            XCTAssertTrue(bindings.release(terminal, in: context))
            XCTAssertFalse(bindings.release(terminal, in: context))
            let unloaded = try XCTUnwrap(bindings.register("unloaded", in: context, view: view, owner: owner))
            ExtensionWorkerRecovery.shared.unregister(context.uniqueIdentifier)
            XCTAssertFalse(bindings.allowed(unloaded, in: context, owner: owner))
        }
    }

    func testBoundedRegistryReclaimsClosedDocumentsAndUnregisteredPorts() async throws {
        try await withFixture { owner, context, browser in
            let bindings = ExtensionPortBindings(limit: 1)
            let page = self.page(in: browser), next = self.page(in: browser)
            defer { page.close(); next.close() }
            owner.openedAside(page)
            owner.openedAside(next)
            let view = page.web
            let scope = try XCTUnwrap(bindings.register("one", in: context, view: view, owner: owner))
            XCTAssertEqual(bindings.register("one", in: context, view: view, owner: owner), scope)
            XCTAssertNil(bindings.register("two", in: context, view: view, owner: owner))
            XCTAssertTrue(bindings.unregister("one", scope: scope, in: context, view: view))
            let replacement = try XCTUnwrap(bindings.register("two", in: context, view: view, owner: owner))
            XCTAssertNotEqual(replacement, scope)
            page.close()
            let nextScope = try XCTUnwrap(bindings.register("three", in: context, view: next.web, owner: owner))
            XCTAssertFalse(bindings.allowed(replacement, in: context, owner: owner))
            XCTAssertTrue(bindings.allowed(nextScope, in: context, owner: owner))
        }
    }

    private func page(in browser: Browser, shy: Bool = false) -> Tab {
        let page = Tab(shy: shy, configuration: Web.configuration(shy: shy))
        browser.prepare(page)
        page.restore(url: URL(string: "about:blank#port-scope-\(UUID().uuidString)")!, title: "Port scope")
        return page
    }

    private func withFixture(_ body: (Extensions, WKWebExtensionContext, Browser) async throws -> Void) async throws {
        _ = NSApplication.shared
        let activation = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let owner = Extensions.shared
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        Browsers.register(browser)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("port-scope-extension-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = Crx.unpackedID(for: folder)
        defer {
            Browsers.discard(browser)
            if owner.installed.contains(where: { $0.id == id }) { owner.remove(id) }
            try? FileManager.default.removeItem(at: folder)
            NSApp.setActivationPolicy(activation)
        }
        try #"{"manifest_version":3,"name":"Port scope fixture","version":"1.0","permissions":["tabs"]}"#
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        owner.installFolder(at: folder, confirm: false)
        try await until { owner.contexts[id] != nil }
        try await body(owner, XCTUnwrap(owner.contexts[id]), browser)
    }

    private func until(_ ready: () -> Bool) async throws {
        for _ in 0..<200 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("extension port scope fixture timed out")
        throw NSError(domain: "ExtensionPortBindingsTests", code: 1)
    }
}
