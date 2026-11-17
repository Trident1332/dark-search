import AppKit
import WebKit
import XCTest
@testable import Search

@available(macOS 15.4, *)
@MainActor
final class ExtensionAsideTests: XCTestCase {
    override class func setUp() {
        if ProcessInfo.processInfo.environment["SEARCH_PROBE"] == nil {
            setenv("SEARCH_PROBE", "extension-aside-\(getpid())", 1)
        }
        super.setUp()
    }

    func testWindowlessPageIsRegisteredOnceAndClosedWithoutEnteringTheRow() async throws {
        try await withFixture { owner, context, browser in
            let page = self.page(in: browser)
            defer { page.close() }
            let row = owner.visibleTabs(of: browser, for: context).map(\.id)
            owner.openedAside(page)
            let adapter = owner.adapter(for: page)
            XCTAssertTrue(context.openTabs.contains(adapter))
            XCTAssertTrue(adapter.aside)
            XCTAssertNil(adapter.window(for: context))
            XCTAssertEqual(adapter.indexInWindow(for: context), NSNotFound)
            XCTAssertEqual(owner.visibleTabs(of: browser, for: context).map(\.id), row)

            let count = context.openTabs.count
            owner.openedAside(page)
            XCTAssertEqual(context.openTabs.count, count)
            page.close()
            XCTAssertFalse(context.openTabs.contains(adapter))
        }
    }

    func testKeepingAsideCreatesOneNormalAdapterWithItsWindowAndIndex() async throws {
        try await withFixture { owner, context, browser in
            let page = self.page(in: browser)
            owner.openedAside(page)
            let previous = owner.adapter(for: page)
            let count = owner.visibleTabs(of: browser, for: context).count
            browser.insert(page, at: browser.tabs.count)
            try await self.until {
                let current = owner.adapter(for: page)
                return current !== previous && context.openTabs.contains(current)
            }
            let current = owner.adapter(for: page)
            XCTAssertFalse(context.openTabs.contains(previous))
            XCTAssertNil(previous.window(for: context), "the retired windowless adapter never acquires a window")
            XCTAssertFalse(current.aside)
            XCTAssertNotNil(current.window(for: context))
            XCTAssertEqual(current.indexInWindow(for: context), count)
            XCTAssertEqual(owner.visibleTabs(of: browser, for: context).filter { $0 === page }.count, 1)
        }
    }

    func testReloadLearnsOfAnAsideThatWasAlreadyOpen() async throws {
        try await withFixture { owner, context, browser in
            let page = self.page(in: browser)
            defer { page.close() }
            owner.openedAside(page)
            let adapter = owner.adapter(for: page)
            let id = context.uniqueIdentifier
            owner.reload(id)
            try await self.until {
                guard let replacement = owner.contexts[id], replacement !== context else { return false }
                return replacement.openTabs.contains(adapter)
            }
            XCTAssertNil(adapter.window(for: try XCTUnwrap(owner.contexts[id])))
        }
    }

    func testPrivateAsidesRequireConsentAndKeepIndependentStores() async throws {
        try await withFixture { owner, context, browser in
            let id = context.uniqueIdentifier
            owner.setPrivate(id, false)
            let beforeConsent = self.page(in: browser, shy: true)
            defer { beforeConsent.close() }
            XCTAssertFalse(beforeConsent.carriesExtensions)

            owner.setPrivate(id, true)
            let first = self.page(in: browser, shy: true)
            let second = self.page(in: browser, shy: true)
            defer { first.close(); second.close() }
            XCTAssertTrue(first.carriesExtensions)
            XCTAssertFalse(first.store === second.store, "each private page retains its own website store")
            XCTAssertFalse(first.store.isPersistent)
            XCTAssertFalse(second.store.isPersistent)

            owner.setPrivate(id, false)
            owner.openedAside(first)
            owner.openedAside(second)
            owner.openedAside(beforeConsent)
            let one = owner.adapter(for: first), two = owner.adapter(for: second)
            XCTAssertFalse(context.openTabs.contains(one))
            XCTAssertFalse(context.openTabs.contains(two))

            owner.setPrivate(id, true)
            XCTAssertTrue(context.openTabs.contains(one))
            XCTAssertTrue(context.openTabs.contains(two))
            XCTAssertFalse(context.openTabs.contains(owner.adapter(for: beforeConsent)),
                           "consent cannot add an extension controller to an older private page")
            XCTAssertFalse(owner.visibleTabs(of: browser, for: context).contains { $0 === first || $0 === second })

            owner.setPrivate(id, false)
            XCTAssertFalse(context.openTabs.contains(one))
            XCTAssertFalse(context.openTabs.contains(two))
        }
    }

    func testTorAsidesAreRejectedAndConversionRemovesAnExistingAside() async throws {
        try await withFixture { owner, context, browser in
            let page = self.page(in: browser)
            defer { page.close() }
            owner.openedAside(page)
            let previous = owner.adapter(for: page)
            XCTAssertTrue(context.openTabs.contains(previous))
            page.restore(url: URL(string: "https://private.example.invalid/")!, title: "Tor fixture", tor: true)
            XCTAssertTrue(page.usesTor)
            XCTAssertFalse(context.openTabs.contains(previous))
            owner.openedAside(page)
            XCTAssertFalse(context.openTabs.contains { ($0 as? ExtensionTab)?.tab === page })
            XCTAssertFalse(owner.adapter(for: page) === owner.adapter(for: page),
                           "Tor lookups remain sealed, uncached adapters")
        }
    }

    private func page(in browser: Browser, shy: Bool = false) -> Tab {
        let page = Tab(shy: shy, configuration: Web.configuration(shy: shy))
        browser.prepare(page)
        page.restore(url: URL(string: "about:blank#aside-\(UUID().uuidString)")!, title: "Aside")
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
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aside-extension-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = Crx.unpackedID(for: folder)
        defer {
            Browsers.discard(browser)
            if owner.installed.contains(where: { $0.id == id }) { owner.remove(id) }
            try? FileManager.default.removeItem(at: folder)
            NSApp.setActivationPolicy(activation)
        }
        try #"{"manifest_version":3,"name":"Aside fixture","version":"1.0","permissions":["tabs"]}"#
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
        XCTFail("extension aside fixture timed out")
        throw NSError(domain: "ExtensionAsideTests", code: 1)
    }
}
