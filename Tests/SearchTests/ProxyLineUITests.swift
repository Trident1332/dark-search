import AppKit
import SwiftUI
import XCTest
@testable import Search

@MainActor
final class ProxyLineUITests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "proxy-line-ui-\(getpid())", 1)
        super.setUp()
    }

    func testSecurePasteSubmitsWithReturnClearsOnSuccessAndRetainsFailedInput() async throws {
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        defer { NSApp.setActivationPolicy(policy) }
        var submitted: [ProxyLine] = []
        var refuse = false
        let host = NSHostingView(rootView: ProxyLineEntry(kind: .socks5) { line in
            submitted.append(line)
            return refuse ? "Synthetic vault unavailable" : nil
        }.padding(16).frame(width: 560))
        let window = ProxyLineTestWindow(contentRect: NSRect(x: -10000, y: -10000, width: 560, height: 120), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil); window.makeKey()
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        func secureField(_ view: NSView) -> NSSecureTextField? {
            if let field = view as? NSSecureTextField { return field }
            return view.subviews.lazy.compactMap { secureField($0) }.first
        }
        let field = try XCTUnwrap(secureField(host), "The one-line credentials must use a native secure text field")
        func enter(_ value: String) async throws {
            XCTAssertTrue(window.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor())
            editor.selectAll(nil); editor.insertText(value)
            try await Task.sleep(for: .milliseconds(80))
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            NSApp.sendEvent(event)
            try await Task.sleep(for: .milliseconds(100))
        }
        try await enter("proxy.example:1080:account,mobile:synthetic-password")
        XCTAssertEqual(submitted.count, 1)
        XCTAssertEqual(submitted.first?.user, "account,mobile")
        XCTAssertEqual(submitted.first?.password, "synthetic-password")
        XCTAssertEqual(field.stringValue, "", "Successful import must clear the transient credentials")
        try await enter("proxy.example:0:user:synthetic-password")
        XCTAssertEqual(submitted.count, 1, "Malformed input must not reach the settings callback")
        XCTAssertFalse(field.stringValue.isEmpty)
        refuse = true
        try await enter("other.example:1080:user:synthetic-password")
        XCTAssertEqual(submitted.count, 2)
        XCTAssertFalse(field.stringValue.isEmpty, "A failed save must retain the masked input for retry")
    }
}

private final class ProxyLineTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
