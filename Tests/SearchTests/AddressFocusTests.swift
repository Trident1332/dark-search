import AppKit
import SwiftUI
import XCTest
@testable import Search

/// Real AppKit events in a browser window kept off every display. These
/// exercise the event monitor, native field editor and asynchronous focus
/// handoff together, rather than calling the keyboard test hook.
@MainActor
final class AddressFocusTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "address-focus-\(getpid())", 1)
        super.setUp()
    }

    func testTypingAfterBlankTabLosesFocusKeepsFirstAndFollowingCharacters() async throws {
        for split in [false, true] {
            try await withWindow(split: split) { browser, window, field in
                try await blur(window)
                try await key("q", code: 12, in: window)
                try await settle()
                XCTAssertEqual(browser.typed, "q", "The first key must reach the recovered field (split: \(split))")
                XCTAssertTrue(window.firstResponder === field.currentEditor())
                try await key("Z", code: 6, flags: .shift, in: window)
                try await settle()
                XCTAssertEqual(browser.typed, "qZ", "Focused typing must neither disappear nor be replayed twice")
            }
        }
    }

    func testTypingInAnotherNativeFieldDoesNotMoveToAddress() async throws {
        try await withWindow(split: false) { browser, window, _ in
            let other = NSTextField(frame: NSRect(x: 30, y: 150, width: 220, height: 28))
            other.isEditable = true
            let host = try XCTUnwrap(window.contentView)
            let parent = try XCTUnwrap(host.superview)
            parent.addSubview(other, positioned: .above, relativeTo: host)
            defer { other.removeFromSuperview() }
            XCTAssertTrue(window.makeFirstResponder(other))
            let editor = try XCTUnwrap(other.currentEditor())
            try await Task.sleep(for: .milliseconds(600))
            try await key("x", code: 7, in: window)
            try await settle()
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(other.stringValue, "x")
            XCTAssertEqual(browser.typed, "", "A new tab must not steal another control's input")
        }
    }

    func testNavigationAndModifiedKeysDoNotAutofocusBlankSearch() async throws {
        try await withWindow(split: false) { browser, window, field in
            try await blur(window)
            for (characters, code, flags) in [
                ("\u{f702}", UInt16(123), NSEvent.ModifierFlags.function),
                ("\u{7f}", UInt16(51), NSEvent.ModifierFlags()),
                ("x", UInt16(7), NSEvent.ModifierFlags.command),
                ("x", UInt16(7), NSEvent.ModifierFlags.control),
            ] {
                try await key(characters, code: code, flags: flags, in: window)
                try await settle()
                XCTAssertFalse(window.firstResponder === field.currentEditor() && field.currentEditor() != nil,
                               "Navigation and shortcut events must not request search focus")
                XCTAssertEqual(browser.typed, "")
            }
        }
    }

    func testClickingTopAddressBarFocusesSearchAndKeepsBlankDraft() async throws {
        for split in [false, true] {
            try await withWindow(split: split) { browser, window, field in
                browser.typed = "unfinished.example"
                try await settle()
                try await blur(window)
                // The address well fills the middle of the toolbar under
                // the tab strip. Use its centre, away from the native doors.
                let host = try XCTUnwrap(window.contentView)
                let local = NSPoint(x: host.bounds.midX, y: Metrics.strip + Metrics.bar / 2)
                let point = host.convert(NSPoint(x: local.x,
                    y: host.isFlipped ? local.y : host.bounds.height - local.y), to: nil)
                try await mouse(.leftMouseDown, at: point, in: window)
                try await mouse(.leftMouseUp, at: point, in: window)
                try await settle()
                XCTAssertTrue(window.firstResponder === field.currentEditor() && field.currentEditor() != nil,
                              "The toolbar address must restore the native search editor (split: \(split))")
                XCTAssertEqual(browser.typed, "unfinished.example", "Refocusing an unused tab must preserve its draft")
            }
        }
    }

    func testCommandLFinishesInlineRenameAndHandsTypingToAddress() async throws {
        try await withWindow(split: false) { browser, window, field in
            let tab = try XCTUnwrap(browser.active)
            browser.beginTabRename(tab)
            try await settle()
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            let inline = try XCTUnwrap(editor.delegate as? NSTextField)
            XCTAssertTrue(inline.delegate is TabAddressField.Coordinator,
                          "The regression must begin with the inline rename editor holding the keyboard")
            XCTAssertEqual(browser.editingTab, tab.id)
            browser.tabDraft = "Renamed"
            try await settle()

            try await key("l", code: 37, flags: .command, in: window)
            try await settle()
            XCTAssertNil(browser.editingTab, "Command-L must finish the competing inline edit")
            XCTAssertEqual(tab.name, "Renamed", "Leaving a rename commits its draft, just as clicking elsewhere does")
            XCTAssertTrue(window.firstResponder === field.currentEditor() && field.currentEditor() != nil,
                          "Command-L must hand the keyboard to the address field")
            try await key("q", code: 12, in: window)
            try await settle()
            XCTAssertEqual(browser.typed, "q", "The next key must reach the address once")
        }
    }

    private func withWindow(split: Bool,
                            _ body: (Browser, NSWindow, AddressField.Field) async throws -> Void) async throws {
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        let saved = (prefs.floatingNewTab, prefs.splitView, prefs.sidebar, prefs.bookmarksBar)
        prefs.floatingNewTab = false
        prefs.splitView = split
        prefs.sidebar = false
        prefs.bookmarksBar = false
        let previousFront = Front.shared.browser
        let browser = Browser(record: WindowRecord())
        browser.welcoming = false
        browser.newsShowing = false
        browser.newTab()
        Browsers.register(browser)
        Front.shared.set(browser)
        let window = AddressFocusTestWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 650),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = AddressFocusHostingView(rootView: ContentView(browser: browser))
        window.orderFrontRegardless()
        window.makeKey()
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        defer {
            ContentView.forget(browser)
            window.contentView = nil
            window.close()
            browser.closeAll()
            Browsers.discard(browser)
            Front.shared.set(previousFront)
            (prefs.floatingNewTab, prefs.splitView, prefs.sidebar, prefs.bookmarksBar) = saved
            NSApp.setActivationPolicy(policy)
        }
        try await settle()
        XCTAssertTrue(browser.active?.isBlank == true)
        let host = try XCTUnwrap(window.contentView)
        let field = try XCTUnwrap(addressField(in: host))
        XCTAssertNotNil(field.currentEditor(), "The fixture starts with a real focused address field")
        try await body(browser, window, field)
    }

    private func blur(_ window: NSWindow) async throws {
        // Wait out the original new-tab transition buffer before losing
        // focus, reproducing a user clicking away well after opening a tab.
        try await Task.sleep(for: .milliseconds(600))
        let point = NSPoint(x: 50, y: 80)
        try await mouse(.leftMouseDown, at: point, in: window)
        try await mouse(.leftMouseUp, at: point, in: window)
        try await settle()
        XCTAssertFalse(window.firstResponder is NSTextView, "The blank page click must really blur the field")
    }

    private func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = [],
                     in window: NSWindow) async throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        try dispatch(event, matching: .keyDown)
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) async throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        try dispatch(event, matching: type == .leftMouseDown ? .leftMouseDown : .leftMouseUp)
        try await Task.sleep(for: .milliseconds(30))
    }

    private func dispatch(_ event: NSEvent, matching mask: NSEvent.EventTypeMask) throws {
        NSApp.postEvent(event, atStart: true)
        let queued = try XCTUnwrap(NSApp.nextEvent(matching: mask, until: Date(timeIntervalSinceNow: 1),
                                                 inMode: .default, dequeue: true))
        NSApp.sendEvent(queued)
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(350)) }

    private func addressField(in view: NSView) -> AddressField.Field? {
        if let field = view as? AddressField.Field { return field }
        return view.subviews.compactMap { addressField(in: $0) }.first
    }
}

private final class AddressFocusTestWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The test app stays inactive, so the first click must reach SwiftUI's
/// gesture instead of being used solely to activate its offscreen window.
private final class AddressFocusHostingView: NSHostingView<ContentView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
