import AppKit
import WebKit
import XCTest
@testable import Search

/// Native DOM ranges in local fixtures: no cloud provider, live browser or
/// matching-text search is involved in choosing or changing the target.
@MainActor
final class AISelectedTextTests: XCTestCase {
    private var activationPolicy: NSApplication.ActivationPolicy?

    override class func setUp() {
        setenv("SEARCH_PROBE", "selected-text-tests-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        try await super.setUp()
    }

    override func tearDown() async throws {
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        try await super.tearDown()
    }

    func testCapturedDuplicateIsTheOnlyPassageChangedAfterFocusAndSelectionMove() async throws {
        let web = try await page("<p id='first'>Return policy quote</p><p id='chosen'>Return policy quote</p><p id='other'>Other words</p><input id='entry'>")
        try await select("chosen", in: web)
        let target = try await take(in: web, expected: "Return policy quote")
        defer { target.invalidate() }
        var changes: [String] = []
        target.onReplace = { changes.append($0) }
        try await select("other", in: web)
        _ = try await web.evaluateJavaScript("document.getElementById('entry').focus(); true")

        let result = try await replace(target, text: "hi test", expected: "Return policy quote")

        equal(result["ok"] as? Bool, true)
        equal(result["text"] as? String, "hi test")
        equal(result["title"] as? String, "Keep this title")
        equal(target.originalText, "Return policy quote")
        equal(target.text, "hi test")
        equal(changes, ["hi test"])
        equal(try await string("document.getElementById('first').textContent", in: web), "Return policy quote")
        equal(try await string("document.getElementById('chosen').textContent", in: web), "hi test")
        equal(try await string("document.getElementById('other').textContent", in: web), "Other words")
        equal(try await string("document.title", in: web), "Keep this title")
    }

    func testCrossInlineSelectionBecomesLiteralTextWithoutChangingOtherContentOrTitle() async throws {
        let web = try await page("<p id='chosen'>Alpha <strong>brave</strong> world</p><p id='other'><em>Unchanged</em></p>")
        try await select("chosen", in: web)
        let target = try await take(in: web, expected: "Alpha brave world")
        defer { target.invalidate() }
        let literal = "<b>hi test</b> & <script>fixture()</script>"

        let result = try await replace(target, text: literal, expected: target.text)

        equal(result["ok"] as? Bool, true)
        equal(try await string("document.getElementById('chosen').textContent", in: web), literal)
        equal(try await string("String(document.getElementById('chosen').children.length)", in: web), "0")
        equal(try await string("String(document.querySelectorAll('script').length)", in: web), "0")
        equal(try await string("document.getElementById('other').innerHTML", in: web), "<em>Unchanged</em>")
        equal(try await string("document.title", in: web), "Keep this title")
    }

    func testPartialRangeKeepsItsSurroundingTextAndSupportsRepeatedEdits() async throws {
        let web = try await page("<p id='chosen'>Start target end</p>")
        _ = try await web.evaluateJavaScript("""
        (() => { const node = document.getElementById('chosen').firstChild, range = document.createRange();
          range.setStart(node,6); range.setEnd(node,12); const selection=getSelection();
          selection.removeAllRanges(); selection.addRange(range); return true; })()
        """)
        let target = try await take(in: web, expected: "target")
        defer { target.invalidate() }
        var changes: [String] = []
        target.onReplace = { changes.append($0) }

        equal(try await replace(target, text: "first", expected: "target")["ok"] as? Bool, true)
        equal(try await replace(target, text: "second", expected: "first")["ok"] as? Bool, true)
        let read = try await result(target, name: "read_selected_text")

        equal(read["text"] as? String, "second")
        equal(changes, ["first", "second"])
        equal(try await string("document.getElementById('chosen').textContent", in: web), "Start second end")
        equal(try await string("document.title", in: web), "Keep this title")
    }

    func testWrongExpectedTextDoesNotChangeOrInvalidateTheCapturedPassage() async throws {
        let web = try await page("<p id='chosen'>Original quote</p>")
        try await select("chosen", in: web)
        let target = try await take(in: web, expected: "Original quote")
        defer { target.invalidate() }
        var changes = 0
        target.onReplace = { _ in changes += 1 }

        let wrong = try await replace(target, text: "wrong", expected: "A different quote")
        equal(wrong["ok"] as? Bool, false)
        XCTAssertNotNil(wrong["error"])
        equal(changes, 0)
        equal(try await string("document.getElementById('chosen').textContent", in: web), "Original quote")
        equal(try await result(target, name: "read_selected_text")["ok"] as? Bool, true)
        equal(try await replace(target, text: "Correct edit", expected: "Original quote")["ok"] as? Bool, true)
        equal(changes, 1)
    }

    func testEmptyReplacementCanBeEditedAgainButFailsAfterItsAnchorIsHidden() async throws {
        let web = try await page("<p id='chosen'>Original quote</p><p id='other'>Unchanged</p>")
        try await select("chosen", in: web)
        let target = try await take(in: web, expected: "Original quote")
        defer { target.invalidate() }
        var changes: [String] = []
        target.onReplace = { changes.append($0) }

        equal(try await replace(target, text: "", expected: "Original quote")["ok"] as? Bool, true)
        equal(try await result(target, name: "read_selected_text")["text"] as? String, "")
        equal(try await replace(target, text: "Again", expected: "")["ok"] as? Bool, true)
        equal(try await replace(target, text: "", expected: "Again")["ok"] as? Bool, true)
        _ = try await web.evaluateJavaScript("document.getElementById('chosen').style.display='none'; true")

        equal(try await replace(target, text: "Must not appear", expected: "")["ok"] as? Bool, false)
        equal(changes, ["", "Again", ""])
        equal(try await string("document.getElementById('chosen').textContent", in: web), "")
        equal(try await string("document.getElementById('other').textContent", in: web), "Unchanged")
        equal(try await string("document.title", in: web), "Keep this title")
    }

    func testRemovingAnEmptyAnchorCannotRetargetItsLiveRangeToTheParent() async throws {
        let web = try await page("<p id='chosen'>Original quote</p><p id='other'>Unchanged</p>")
        try await select("chosen", in: web)
        let target = try await take(in: web, expected: "Original quote")
        defer { target.invalidate() }
        equal(try await replace(target, text: "", expected: "Original quote")["ok"] as? Bool, true)
        _ = try await web.evaluateJavaScript("document.getElementById('chosen').replaceChildren(); true")

        let read = try await result(target, name: "read_selected_text")
        equal(read["ok"] as? Bool, false)
        equal(read["invalidated"] as? Bool, true)
        equal(try await replace(target, text: "Must not appear", expected: "")["ok"] as? Bool, false)
        equal(try await string("document.getElementById('chosen').textContent", in: web), "")
        equal(try await string("document.getElementById('other').textContent", in: web), "Unchanged")
        equal(try await string("document.title", in: web), "Keep this title")
    }

    func testWebsiteDOMReplacementMakesTheOldAnchorPermanentlyStale() async throws {
        let web = try await page("<p id='chosen'>Original quote</p><p id='other'>Original quote</p>")
        try await select("chosen", in: web)
        let target = try await take(in: web, expected: "Original quote")
        defer { target.invalidate() }
        _ = try await web.evaluateJavaScript("document.getElementById('chosen').textContent='Website update'; true")

        let read = try await result(target, name: "read_selected_text")
        let edit = try await replace(target, text: "hi test", expected: "Original quote")

        equal(read["ok"] as? Bool, false)
        equal(read["invalidated"] as? Bool, true)
        equal(edit["ok"] as? Bool, false)
        equal(try await string("document.getElementById('chosen').textContent", in: web), "Website update")
        equal(try await string("document.getElementById('other').textContent", in: web), "Original quote")
    }

    func testNavigationEvenToTheSameURLInvalidatesTheOriginalDocument() async throws {
        let web = try await page("<p id='chosen'>Original quote</p>")
        try await select("chosen", in: web)
        let target = try await take(in: web, expected: "Original quote")
        defer { target.invalidate() }
        web.loadHTMLString("<!doctype html><title>New document</title><p id='chosen'>Original quote</p>", baseURL: URL(string: "https://selection-fixture.invalid/page")!)
        try await loaded(web, title: "New document")

        let edit = try await replace(target, text: "hi test", expected: "Original quote")

        equal(edit["ok"] as? Bool, false)
        equal(try await string("document.getElementById('chosen').textContent", in: web), "Original quote")
        equal(try await string("document.title", in: web), "New document")
    }

    func testHiddenControlsEditableContentAndMediaCannotBecomeEditableRanges() async throws {
        for unsafe in ["<span style='display:none'>hidden</span>", "<input value='fixture'>", "<span contenteditable='true'>draft</span>", "<img src='data:,'>"] {
            let web = try await page("<p id='chosen'>Visible \(unsafe) words</p>")
            try await select("chosen", in: web)

            let capture = await AISelectedText.capture(in: web)

            equal(capture.text, "Visible words")
            XCTAssertNil(capture.target, "The range includes non-prose or hidden content: \(unsafe)")
            XCTAssertNil(AISelectedText.take(in: web, matching: capture.text))
        }
    }

    func testMultiRangeCaptureSuppliesAQuoteWithoutAnEditableTarget() async throws {
        let web = try await page("<p id='first'>First quote</p><p id='second'>Second quote</p>")
        // WebKit normally exposes a single range. A test-world selection
        // facade exercises the explicit multi-range refusal with real ranges.
        _ = try await web.callAsyncJavaScript("""
        const first=document.createRange(), second=document.createRange();
        first.selectNodeContents(document.getElementById('first'));
        second.selectNodeContents(document.getElementById('second'));
        window.getSelection=()=>({isCollapsed:false,rangeCount:2,getRangeAt:index=>index===0?first:second});
        return true;
        """, arguments: [:], in: nil, contentWorld: Web.world)

        let capture = await AISelectedText.capture(in: web)

        equal(capture.text, "First quote Second quote")
        XCTAssertNil(capture.target)
    }

    func testHidingThePreviouslyVisibleTargetFailsClosed() async throws {
        let web = try await page("<p id='chosen'>Original quote</p>")
        try await select("chosen", in: web)
        let target = try await take(in: web, expected: "Original quote")
        defer { target.invalidate() }
        _ = try await web.evaluateJavaScript("document.getElementById('chosen').style.display='none'; true")

        let edit = try await replace(target, text: "hi test", expected: "Original quote")

        equal(edit["ok"] as? Bool, false)
        equal(try await string("document.getElementById('chosen').textContent", in: web), "Original quote")
    }

    func testTakeRequiresExactCapturedQuoteAndInvalidationPreventsFurtherEdits() async throws {
        let web = try await page("<p id='chosen'>Original quote</p>")
        try await select("chosen", in: web)
        let captured = await AISelectedText.capture(in: web)
        let rejected = try XCTUnwrap(captured.target)
        XCTAssertNil(AISelectedText.take(in: web, matching: "Different quote"))
        XCTAssertNil(AISelectedText.take(in: web, matching: "Original quote"))
        equal(try await result(rejected, name: "read_selected_text")["ok"] as? Bool, false)

        try await select("chosen", in: web)
        let target = try await take(in: web, expected: "Original quote")
        target.invalidate()
        equal(try await replace(target, text: "hi test", expected: "Original quote")["ok"] as? Bool, false)
        equal(try await string("document.getElementById('chosen').textContent", in: web), "Original quote")
    }

    private func page(_ body: String) async throws -> WKWebView {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        web.loadHTMLString("<!doctype html><html><head><title>Keep this title</title></head><body>\(body)</body></html>", baseURL: URL(string: "https://selection-fixture.invalid/page")!)
        try await loaded(web, title: "Keep this title")
        return web
    }

    private func loaded(_ web: WKWebView, title: String) async throws {
        for _ in 0..<400 {
            if !web.isLoading, (try? await web.evaluateJavaScript("document.title")) as? String == title { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw URLError(.timedOut)
    }

    private func select(_ id: String, in web: WKWebView) async throws {
        _ = try await web.callAsyncJavaScript("""
        document.activeElement?.blur();
        const range=document.createRange();range.selectNodeContents(document.getElementById(id));
        const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);return true;
        """, arguments: ["id": id], in: nil, contentWorld: .page)
    }

    private func take(in web: WKWebView, expected: String) async throws -> AISelectedText {
        let captured = await AISelectedText.capture(in: web)
        equal(captured.text, expected)
        let target = try XCTUnwrap(AISelectedText.take(in: web, matching: captured.text))
        XCTAssertTrue(target === captured.target)
        XCTAssertNil(AISelectedText.take(in: web, matching: captured.text), "A pending target is consumed only once")
        return target
    }

    private func result(_ target: AISelectedText, name: String, arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let text = await target.tool(name, arguments: arguments)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func replace(_ target: AISelectedText, text: String, expected: String) async throws -> [String: Any] {
        try await result(target, name: "replace_selected_text", arguments: ["text": text, "expectedText": expected])
    }

    private func string(_ expression: String, in web: WKWebView) async throws -> String {
        let value = try await web.evaluateJavaScript(expression)
        return try XCTUnwrap(value as? String)
    }

    // Evaluate async fixture reads before handing values to XCTest's
    // synchronous autoclosures, keeping failures at their calling lines.
    private func equal<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}
