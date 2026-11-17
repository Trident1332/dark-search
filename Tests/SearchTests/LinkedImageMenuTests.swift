import AppKit
import WebKit
import XCTest
@testable import Search

@MainActor
final class LinkedImageMenuTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "linked-image-menu-\(getpid())", 1)
        super.setUp()
    }

    func testLinkedImageKeepsLinkCommandsAndRoutesBothImageActions() throws {
        _ = NSApplication.shared
        let page = makePage()
        defer { ProxyTimeZone.close(page) }
        let image = URL(string: "https://example.com/picture.png")!
        var actions: [(URL, Bool)] = []
        var saves: [URL] = []
        page.onImage = { actions.append(($0, $1)) }
        page.onSaveImageAs = { saves.append($0) }
        page.keptImage = image
        let (menu, copy, download) = makeMenu()
        let link = NSMenuItem(title: "Copy Link", action: nil, keyEquivalent: "")
        link.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierCopyLink")
        menu.addItem(link)

        page.willOpenMenu(menu, with: try event())

        XCTAssertTrue(menu.items.contains { $0 === link }, "Link actions must remain available")
        XCTAssertNil(page.keptImage)
        for item in [copy, download] {
            XCTAssertTrue(item.target === page)
            XCTAssertEqual(item.representedObject as? URL, image)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        }
        XCTAssertEqual(actions.map(\.0), [image, image])
        XCTAssertEqual(actions.map(\.1), [true, false])
        let save = try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "SearchSaveImageAs" })
        XCTAssertEqual(save.title, "Save Image As…")
        XCTAssertEqual(menu.index(of: save), menu.index(of: download) + 1)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(save.action), to: save.target, from: save))
        XCTAssertEqual(saves, [image])
    }

    func testNextMenuCannotReuseThePreviousImage() throws {
        _ = NSApplication.shared
        let page = makePage()
        defer { ProxyTimeZone.close(page) }
        page.keptImage = URL(string: "https://example.com/previous.png")!
        let first = makeMenu()
        page.willOpenMenu(first.0, with: try event())

        let (next, copy, download) = makeMenu()
        copy.representedObject = "native copy"
        download.representedObject = "native download"
        page.willOpenMenu(next, with: try event())

        XCTAssertNil(copy.target)
        XCTAssertNil(copy.action)
        XCTAssertEqual(copy.representedObject as? String, "native copy")
        XCTAssertNil(download.target)
        XCTAssertNil(download.action)
        XCTAssertEqual(download.representedObject as? String, "native download")
        XCTAssertFalse(next.items.contains { $0.identifier?.rawValue == "SearchSaveImageAs" })
    }

    func testMenuWithoutImageActionsStillConsumesTheAddress() throws {
        _ = NSApplication.shared
        let page = makePage()
        defer { ProxyTimeZone.close(page) }
        page.keptImage = URL(string: "https://example.com/previous.png")!
        page.willOpenMenu(NSMenu(), with: try event())
        XCTAssertNil(page.keptImage)
    }

    private func makePage() -> PageView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return PageView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
    }

    private func makeMenu() -> (NSMenu, NSMenuItem, NSMenuItem) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let copy = NSMenuItem(title: "Copy Image", action: nil, keyEquivalent: "")
        copy.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierCopyImage")
        let download = NSMenuItem(title: "Download Image", action: nil, keyEquivalent: "")
        download.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierDownloadImage")
        menu.addItem(copy)
        menu.addItem(download)
        return (menu, copy, download)
    }

    private func event() throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
    }
}
