import AppKit
import SwiftUI
import XCTest
@testable import Search

@MainActor
final class AIActivityUITests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "ai-activity-ui-\(getpid())", 1)
        super.setUp()
    }

    func testEarlierHistoryAndIndividualCommandResultsExpandInTheNativeView() async throws {
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        defer { NSApp.setActivationPolicy(policy) }
        var activity = AIActivity()
        for index in 1...13 {
            let code = "return document.querySelectorAll('a').length + \(index)"
            activity.receive(.toolStarted("browser_evaluate", input: .init(tool: "browser_evaluate", arguments: ["code": code])))
            activity.receive(.toolReturned(.init(raw: "{\"ok\":true,\"result\":\(index)}")))
        }
        activity.finish()
        let host = NSHostingView(rootView: AIActivityView(activity: activity).padding(20).frame(width: 380))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 2400))
        let window = ActivityTestWindow(contentRect: NSRect(x: -10000, y: -10000, width: 380, height: 2400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        content.addSubview(host)
        window.orderFront(nil)
        window.makeKey()
        defer { host.removeFromSuperview(); window.contentView = nil; window.close() }
        func layout() -> CGFloat {
            let height = host.intrinsicContentSize.height
            host.frame = NSRect(x: 0, y: 2400 - height, width: 380, height: height)
            host.layoutSubtreeIfNeeded()
            return height
        }
        func picture(_ name: String) throws {
            guard let folder = ProcessInfo.processInfo.environment["SEARCH_ACTIVITY_SCREENSHOTS"],
                  let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: image)
            try image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
        func click(x: CGFloat, yFromTop y: CGFloat) throws {
            let point = NSPoint(x: x, y: host.isFlipped ? y : host.bounds.height - y)
            _ = try XCTUnwrap(content.hitTest(host.convert(point, to: content)))
            let location = host.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                NSApp.sendEvent(event)
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        let collapsed = layout()
        XCTAssertGreaterThan(collapsed, 100)
        try picture("collapsed-history")
        try click(x: 26, yFromTop: 27)
        try await Task.sleep(for: .milliseconds(150))
        let history = layout()
        try picture("all-history")
        XCTAssertGreaterThan(history, collapsed + 150, "A native press must reveal the eight earlier steps")
        try click(x: 24, yFromTop: 69)
        try await Task.sleep(for: .milliseconds(150))
        let detail = layout()
        try picture("expanded-history")
        XCTAssertGreaterThan(detail, history + 60, "A native press must reveal command and result content")
        try click(x: 24, yFromTop: 69)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(layout(), history, accuracy: 1, "The same step must collapse again")
    }
}

private final class ActivityTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
