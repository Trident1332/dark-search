import AppKit
import XCTest
@testable import Search

@MainActor
final class AskAIAddressTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "ask-ai-address-tests-\(getpid())", 1)
        super.setUp()
    }
    func testAskAIOnBlankTabKeepsQuestionAndWaitsForConsent() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.newTab()
        XCTAssertEqual(browser.active?.isBlank, true)
        browser.prefs.ai = true
        browser.prefs.aiProvider = .openAI
        browser.prefs.setAIModel("synthetic-model", for: .openAI)
        _ = AIKeys.save("synthetic-image-lookup-key", for: .openAI)
        defer { AIKeys.forget(.openAI) }
        Store.settings.removeObject(forKey: "ai.told.openAI")
        browser.typed = "Explain how a camera works"
        browser.askFromAddress()
        let assistant = try XCTUnwrap(browser.assisting)
        XCTAssertTrue(assistant.standalone)
        XCTAssertTrue(browser.fieldShowing, "Opening Ask AI must keep the new-tab search field visible")
        XCTAssertFalse(browser.editing, "A blank tab keeps its search field without an address overlay")
        XCTAssertEqual(browser.typed, "Explain how a camera works")
        XCTAssertEqual(assistant.draft, "Explain how a camera works")
        XCTAssertFalse(assistant.reading)
        XCTAssertNil(assistant.context?.url)
        assistant.submit()
        XCTAssertNotNil(assistant.notice)
        XCTAssertTrue(assistant.turns.isEmpty)
        let source = try XCTUnwrap(browser.active)
        browser.newTab()
        browser.select(source)
        XCTAssertTrue(browser.assisting === assistant)
        XCTAssertTrue(browser.fieldShowing, "Returning to Ask AI must keep the new-tab search field visible")
        browser.closeAssistant()
        XCTAssertTrue(browser.fieldShowing, "Closing Ask AI must leave the new-tab search field in place")
    }
    func testFloatingNewTabDoesNotAttachThePageBehindItToAskAI() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let original = browser.open(URL(string: "about:blank")!, foreground: true)
        original.setAddressOptimistically(URL(string: "https://private-fixture.invalid/account")!)
        browser.prefs.ai = true
        browser.prefs.aiProvider = .openAI
        _ = AIKeys.save("synthetic-floating-ai-key", for: .openAI)
        defer { AIKeys.forget(.openAI) }
        browser.prefs.floatingNewTab = true
        browser.launch()
        XCTAssertTrue(browser.launching)
        browser.typed = "Explain cameras"
        browser.askFromAddress()
        let assistant = try XCTUnwrap(browser.assisting)
        XCTAssertTrue(assistant.standalone)
        XCTAssertNotEqual(assistant.tab, original.id)
        XCTAssertNil(assistant.context?.url)
        XCTAssertEqual(assistant.draft, "Explain cameras")
        XCTAssertTrue(assistant.turns.isEmpty)
    }
}
