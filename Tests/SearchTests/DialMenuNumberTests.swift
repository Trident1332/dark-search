import AppKit
import WebKit
import XCTest
@testable import Search

/// Parsing and constructing a menu never invoke its Call action. The
/// synthetic page has no navigation, SIP connection, or telephone call.
final class DialMenuNumberTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "dial-menu-number-\(getpid())", 1)
        super.setUp()
    }

    private func selected(_ text: String) -> String? {
        Dialer.number(link: "", selection: text, around: "", offset: -1)
    }

    func testBothUserReportedTollFreeFormatsAreRecognized() {
        XCTAssertEqual(selected("1-855-336-2909"), "1-855-336-2909")
        XCTAssertEqual(selected("1-855 635 9272"), "1-855 635 9272")
        XCTAssertEqual(selected("855-336-2909"), "855-336-2909")
        XCTAssertEqual(selected("+1-855-336-2909"), "+1-855-336-2909")
        XCTAssertEqual(selected("1.855.336.2909"), "1.855.336.2909")
        XCTAssertEqual(selected("1-(855)-336-2909"), "1-(855)-336-2909")
    }

    func testCommonUnicodePhoneHyphensNormalizeToTheSameNumber() {
        for dash in ["\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2212}"] {
            let phone = "1\(dash)855\(dash)336\(dash)2909"
            XCTAssertEqual(selected(phone), "1-855-336-2909", "Dash U+\(String(dash.unicodeScalars.first!.value, radix: 16))")
        }
    }

    func testDatesAndLongSerialNumbersAreStillRejected() {
        for text in ["2026-10-29", "2026\u{2013}10\u{2013}29", "29.10.2026", "29/10/2026",
                     "1234-567-8901", "12345-67890-12345", "1-123-456-7890", "1-855-036-2909",
                     "1-855-336-2909-5", "1234567890123456"] {
            XCTAssertNil(selected(text), text)
        }
    }

    func testPointerOffsetsRemainUTF16WhenEmojiPrecedeTheNumber() {
        let phone = "1-855-336-2909"
        let text = String(repeating: "😀", count: 12) + " " + phone + " end"
        let range = (text as NSString).range(of: phone)
        let found = Dialer.number(link: "", selection: "", around: text, offset: range.location + range.length - 1)
        XCTAssertEqual(found, phone)
        XCTAssertNil(Dialer.number(link: "", selection: "", around: text, offset: 1))
        XCTAssertNil(Dialer.number(link: "", selection: "", around: text, offset: (text as NSString).length - 1))
    }

    @MainActor
    func testRecognizedSelectionsProduceNativeCallMenuItemWithoutCalling() throws {
        _ = NSApplication.shared
        let prefs = Shared.prefs
        let previous = prefs.dialerOn
        defer { prefs.dialerOn = previous }
        prefs.dialerOn = true
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = PageView(frame: .zero, configuration: configuration)
        defer { ProxyTimeZone.close(page) }
        var calls = 0
        page.onCall = { _ in calls += 1 }
        for text in ["1-855-336-2909", "1-855 635 9272", "1\u{2011}855\u{2011}336\u{2011}2909"] {
            page.dialNumber = { self.selected(text) }
            let menu = NSMenu(title: "Synthetic selection")
            menu.addItem(NSMenuItem(title: "Copy", action: nil, keyEquivalent: ""))
            page.addCallItem(to: menu)
            let item = try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "SearchCall" })
            let expected = try XCTUnwrap(selected(text))
            XCTAssertEqual(item.title, "Call \(expected)")
            XCTAssertEqual(item.representedObject as? String, expected)
            XCTAssertTrue(item.target === page)
        }
        prefs.dialerOn = false
        let disabled = NSMenu(title: "Dialer disabled")
        page.addCallItem(to: disabled)
        XCTAssertFalse(disabled.items.contains { $0.identifier?.rawValue == "SearchCall" })
        XCTAssertEqual(calls, 0, "Constructing or inspecting the menu must never place a call")
    }
}
