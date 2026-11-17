import AppKit
import WebKit
import XCTest
@testable import Search

/// Settings › General › The floating video: Search's window unless picture
/// in picture is chosen, and the choice kept (idea 376). Entering picture
/// in picture puts a system window on screen, so that part is by eye.
@MainActor
final class NativePiPTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "native-pip-\(getpid())", 1)
        super.setUp()
    }

    func testSearchsWindowUnlessChosen() {
        let saved = Store.settings.object(forKey: "float.style")
        defer { Store.settings.set(saved, forKey: "float.style") }
        Store.settings.removeObject(forKey: "float.style")
        XCTAssertEqual(Preferences().floatStyle, .search)
        let prefs = Preferences()
        prefs.floatStyle = .system
        XCTAssertEqual(Preferences().floatStyle, .system)
        Store.settings.set("nonsense", forKey: "float.style")
        XCTAssertEqual(Preferences().floatStyle, .search)
    }

    func testScriptsAskOnlyForPictureInPicture() {
        let on = NativePiP.script(toggle: false)
        XCTAssertTrue(on.contains("var toggle = false"))
        XCTAssertTrue(NativePiP.script(toggle: true).contains("var toggle = true"))
        XCTAssertTrue(on.contains("webkitSetPresentationMode('picture-in-picture')"))
        XCTAssertFalse(on.contains("fullscreen"))
        XCTAssertTrue(NativePiP.off.contains("webkitSetPresentationMode('inline')"))
    }

    func testReturningVideoSelectsItsTabAndBringsBackClosedWindowState() {
        withBrowser { browser, tabs in
            let returningPage = tabs[0].web
            browser.select(tabs[1])
            browser.shut = true

            browser.webViewFullscreenMayReturnToInline(returningPage)

            XCTAssertEqual(browser.activeID, tabs[0].id)
            XCTAssertFalse(browser.shut)
            XCTAssertEqual(browser.tabs.map(\.id), tabs.map(\.id))

            // macOS may ask while its tab is already selected but the app is
            // behind another app. Showing its window must not need a tab swap.
            browser.shut = true
            browser.webViewFullscreenMayReturnToInline(returningPage)
            XCTAssertEqual(browser.activeID, tabs[0].id)
            XCTAssertFalse(browser.shut)
        }
    }

    func testReturningVideoFromAnotherBrowserCannotChangeThisOne() {
        withBrowser { browser, tabs in
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let foreignPage = WKWebView(frame: .zero, configuration: configuration)
            defer { ProxyTimeZone.close(foreignPage) }
            browser.select(tabs[1])
            browser.shut = true

            browser.webViewFullscreenMayReturnToInline(foreignPage)

            XCTAssertEqual(browser.activeID, tabs[1].id)
            XCTAssertTrue(browser.shut)
        }
    }

    private func withBrowser(_ body: (Browser, [Tab]) -> Void) {
        _ = NSApplication.shared
        let activation = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.closeAll()
        let saved = (browser.prefs.floatsOnLeave, browser.prefs.splitView)
        browser.prefs.floatsOnLeave = false
        browser.prefs.splitView = false
        defer {
            browser.closeAll()
            browser.prefs.floatsOnLeave = saved.0
            browser.prefs.splitView = saved.1
            NSApp.setActivationPolicy(activation)
        }
        for number in 1...2 {
            let tab = Tab(shy: true, configuration: Web.configuration(shy: true))
            browser.prepare(tab)
            browser.insert(tab, at: browser.tabs.count)
            tab.restore(url: URL(string: "about:blank#pip-\(number)")!, title: "Video \(number)")
        }
        body(browser, browser.tabs)
    }
}
