import AppKit
import SwiftUI
import XCTest
@testable import Search

@MainActor
final class OmniboxTransitionTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "omnibox-transitions-\(getpid())", 1)
        super.setUp()
    }

    func testFloatingFieldReopensAndDismissesWithAndWithoutSplitView() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.welcoming = false
        browser.newsShowing = false
        let prefs = browser.prefs
        let saved = (prefs.floatingNewTab, prefs.splitView, prefs.sidebar)
        defer {
            browser.closeAll()
            prefs.floatingNewTab = saved.0
            prefs.splitView = saved.1
            prefs.sidebar = saved.2
        }
        prefs.floatingNewTab = true
        prefs.sidebar = false
        browser.newTab()
        let tab = try XCTUnwrap(browser.active)
        tab.go(to: URL(string: "about:blank")!)
        // The empty fixture has no non-empty WebKit frame to reveal it.
        tab.web.showFirstFrame()

        for splitView in [false, true] {
            prefs.splitView = splitView
            let window = OmniboxTestWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ContentView(browser: browser))
            window.orderFrontRegardless()
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            defer {
                ContentView.forget(browser)
                window.contentView = nil
                window.close()
            }
            try await Task.sleep(for: .milliseconds(400))
            let count = browser.tabs.count
            for _ in 0..<2 {
                browser.launch()
                try await Task.sleep(for: .milliseconds(600))
                XCTAssertTrue(browser.launching)
                XCTAssertEqual(browser.tabs.count, count)
                XCTAssertEqual(browser.activeID, tab.id)
                let content = try XCTUnwrap(window.contentView)
                let field = try XCTUnwrap(addressField(in: content))
                let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
                XCTAssertTrue(window.firstResponder === editor)

                browser.dismiss()
                try await Task.sleep(for: .milliseconds(400))
                XCTAssertFalse(browser.launching)
                XCTAssertNil(addressField(in: content))
                XCTAssertTrue(window.firstResponder === tab.web)
                let point = tab.web.convert(NSPoint(x: tab.web.bounds.midX, y: tab.web.bounds.midY), to: content.superview)
                let hit = content.hitTest(point)
                XCTAssertTrue(hit === tab.web || hit?.isDescendant(of: tab.web) == true,
                              "The mounted, empty omnibox must not intercept page clicks (split: \(splitView))")
            }
        }
    }

    /// Look at the rendered page during the switch, not just after its fade
    /// has finished. Settings' rail and cards must not linger behind a real
    /// empty tab, with either owner of the field or either appearance.
    func testSettingsCutsToBlankWithoutCardsBehindTheField() async throws {
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        let saved = (prefs.floatingNewTab, prefs.splitView, prefs.sidebar, prefs.look, prefs.bookmarksBar)
        let settingsPage = Store.settings.object(forKey: "settings.page")
        defer {
            (prefs.floatingNewTab, prefs.splitView, prefs.sidebar, prefs.look, prefs.bookmarksBar) = saved
            Store.settings.set(settingsPage, forKey: "settings.page")
            NSApp.setActivationPolicy(policy)
        }
        prefs.floatingNewTab = false
        prefs.sidebar = false
        prefs.bookmarksBar = false

        for split in [false, true] {
            for look in [Look.light, .dark] {
                prefs.splitView = split
                prefs.look = look
                let browser = Browser(record: WindowRecord())
                browser.welcoming = false
                browser.newsShowing = false
                let settings = browser.show(InternalPage(.settings, SettingsPanel.Page.general.rawValue))
                let window = OmniboxTestWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 650),
                                      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = NSHostingView(rootView: ContentView(browser: browser))
                window.orderFrontRegardless()
                window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
                defer {
                    ContentView.forget(browser)
                    window.contentView = nil
                    window.close()
                    browser.closeAll()
                }
                XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "Fixture frame: \(window.frame)")
                try await Task.sleep(for: .milliseconds(400))
                let host = try XCTUnwrap(window.contentView)
                let name = "\(split ? "split" : "single")-\(look.rawValue)"
                let before = try frame(host, named: "\(name)-settings")
                XCTAssertEqual(browser.activeID, settings.id)
                browser.newTab()
                let blank = try XCTUnwrap(browser.active)
                XCTAssertTrue(blank.isBlank)
                XCTAssertNil(blank.address)
                XCTAssertNil(blank.page)
                var frames: [NSBitmapImageRep] = []
                for (index, wait) in [16, 16, 32, 48, 80, 128].enumerated() {
                    try await Task.sleep(for: .milliseconds(wait))
                    frames.append(try frame(host, named: "\(name)-transition-\(index)"))
                }
                try await Task.sleep(for: .milliseconds(300))
                let settled = try frame(host, named: "\(name)-settled")
                let field = try XCTUnwrap(addressField(in: host))
                let halo = field.convert(field.bounds, to: host).insetBy(dx: -152, dy: -144)
                let points = pageSamples(in: host.bounds, excluding: halo)
                XCTAssertGreaterThan(points.count, 500)
                XCTAssertGreaterThan(try changedFraction(before, settled, at: points, size: host.bounds.size), 0.01,
                                     "The sampled page must actually see Settings' rail or cards (\(name))")
                for (index, image) in frames.enumerated() {
                    XCTAssertLessThanOrEqual(try changedFraction(image, settled, at: points, size: host.bounds.size), 0.005,
                                             "Settings must be gone outside the field and its halo at transient frame \(index) (\(name))")
                }
            }
        }
    }

    private func frame(_ view: NSView, named name: String) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        if let folder = ProcessInfo.processInfo.environment["OMNIBOX_SHOTS"] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/\(name).png"))
        }
        return image
    }

    /// Avoid the chrome, the field and a generous allowance for the animated
    /// glow. Excluding both vertical orientations also keeps bitmap row order
    /// independent of whether the hosting view is flipped.
    private func pageSamples(in bounds: CGRect, excluding halo: CGRect) -> [CGPoint] {
        let reflected = CGRect(x: halo.minX, y: bounds.height - halo.maxY, width: halo.width, height: halo.height)
        var points: [CGPoint] = []
        for y in stride(from: 80.0, through: Double(bounds.height) - 80, by: 6) {
            for x in stride(from: 20.0, through: Double(bounds.width) - 20, by: 6) {
                let point = CGPoint(x: x, y: y)
                if !halo.contains(point), !reflected.contains(point) { points.append(point) }
            }
        }
        return points
    }

    /// Compare with this case's settled drawing, rather than a golden image
    /// or hard-coded colours. Small rendering differences are tolerated, but
    /// a rail, card edge, text or rectangular fill must not fade under the field.
    private func changedFraction(_ image: NSBitmapImageRep, _ settled: NSBitmapImageRep,
                                 at points: [CGPoint], size: CGSize) throws -> Double {
        XCTAssertEqual(image.pixelsWide, settled.pixelsWide)
        XCTAssertEqual(image.pixelsHigh, settled.pixelsHigh)
        var changed = 0
        for point in points {
            let x = Int(point.x / size.width * CGFloat(image.pixelsWide))
            let y = Int(point.y / size.height * CGFloat(image.pixelsHigh))
            let a = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            let b = try XCTUnwrap(settled.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            let delta = max(abs(a.redComponent - b.redComponent),
                            max(abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent)))
            if delta > 6.0 / 255 { changed += 1 }
        }
        return Double(changed) / Double(max(1, points.count))
    }

    private func addressField(in view: NSView) -> AddressField.Field? {
        if let field = view as? AddressField.Field { return field }
        return view.subviews.compactMap { addressField(in: $0) }.first
    }
}

/// AppKit normally pulls titled windows back onto a screen. These real
/// hosting windows render without ever covering the user's desktop.
private final class OmniboxTestWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
