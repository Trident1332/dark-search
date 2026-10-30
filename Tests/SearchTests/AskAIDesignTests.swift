import AppKit
import WebKit
import XCTest
@testable import Search

/// Interactions introduced by the approved panel design. Providers are
/// synthetic, questions stop at consent, and copying uses a private board.
@MainActor
final class AskAIDesignTests: XCTestCase {
    private var browser: Browser!
    private var source: Tab!
    private var activationPolicy: NSApplication.ActivationPolicy?
    private var savedAI = false
    private var savedProvider: AIProvider?
    private var savedModel = ""

    override class func setUp() {
        setenv("SEARCH_PROBE", "ask-ai-design-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        _ = Shared.prefs
        Proxy.shared.automaticTarget = nil
        Proxy.shared.take(ProxySetup())
        for _ in 0..<100 where Proxy.shared.changingContent { try await Task.sleep(for: .milliseconds(20)) }
        browser = Browser(record: WindowRecord())
        browser.closeAll()
        savedAI = browser.prefs.ai
        savedProvider = browser.prefs.aiProvider
        savedModel = browser.prefs.aiModels[AIProvider.openAI.rawValue] ?? ""
        browser.prefs.ai = true
        browser.prefs.aiProvider = .openAI
        browser.prefs.setAIModel("synthetic-model", for: .openAI)
        _ = AIKeys.save("synthetic-design-test-key", for: .openAI)
        Store.settings.removeObject(forKey: "ai.told.openAI")

        source = Tab(configuration: Web.configuration(space: browser.spaceID))
        source.setAddressOptimistically(URL(string: "https://design-fixture.invalid/article")!)
        browser.prepare(source)
        source.web.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        source.web.loadHTMLString("<!doctype html><title>Design fixture</title><p>A public page quote.</p>", baseURL: source.pageAddress)
        try await until {
            guard !self.source.web.isLoading else { return false }
            return (try? await self.source.web.evaluateJavaScript("document.title") as? String) == "Design fixture"
        }
        browser.showRow([source], active: source.id)
        try await super.setUp()
    }

    override func tearDown() async throws {
        browser?.closeAssistant()
        browser?.closeAll()
        if let browser {
            browser.prefs.ai = savedAI
            browser.prefs.aiProvider = savedProvider
            browser.prefs.setAIModel(savedModel, for: .openAI)
        }
        AIKeys.forget(.openAI)
        source = nil
        browser = nil
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        try await super.tearDown()
    }

    func testShortcutShowsItsQuestionAndWaitsForConsentWithoutChangingContextOrModel() async throws {
        browser.askAboutPage(from: source, selection: "The captured public quote")
        let assistant = try XCTUnwrap(browser.assisting)
        try await until { !assistant.reading }
        let context = assistant.context
        let model = assistant.model

        assistant.submitSuggestion("Summarize this context")

        XCTAssertEqual(assistant.pendingQuestion, "Summarize this context")
        XCTAssertNotNil(assistant.notice)
        XCTAssertTrue(assistant.turns.isEmpty, "A shortcut must not bypass consent and start a provider request")
        XCTAssertEqual(assistant.context, context)
        XCTAssertEqual(assistant.model, model)
        XCTAssertFalse(Store.settings.bool(forKey: "ai.told.openAI"))

        assistant.submitSuggestion("A second shortcut")
        XCTAssertEqual(assistant.pendingQuestion, "Summarize this context", "A pending consent belongs to its original question")
        XCTAssertTrue(assistant.turns.isEmpty)
    }

    func testShortcutWhileContextIsStillReadingDoesNotQueueAnUnexpectedQuestion() async throws {
        browser.askAboutPage(from: source, selection: "The captured public quote")
        let assistant = try XCTUnwrap(browser.assisting)
        XCTAssertTrue(assistant.reading)
        assistant.submitSuggestion("Summarize this context")
        XCTAssertNil(assistant.pendingQuestion)
        XCTAssertNil(assistant.notice)
        XCTAssertTrue(assistant.turns.isEmpty)
        try await until { !assistant.reading }
        XCTAssertNil(assistant.pendingQuestion)
        XCTAssertTrue(assistant.draft.isEmpty)
    }

    func testFriendlyModelLabelsUseTheFullConfiguredIdentifier() {
        let models = [
            OpenCodeAI.Model(id: "gpt/shared", name: "Fixture GPT", providerName: "GPT provider",
                             host: "gpt.fixture.invalid", origin: "https://gpt.fixture.invalid"),
            OpenCodeAI.Model(id: "claude/shared", name: "Fixture Claude", providerName: "Claude provider",
                             host: "claude.fixture.invalid", origin: "https://claude.fixture.invalid")
        ]
        XCTAssertEqual(AssistantPanel.modelLabel(for: "gpt/shared", provider: .openCode, models: models), "Fixture GPT")
        XCTAssertEqual(AssistantPanel.modelLabel(for: "claude/shared", provider: .openCode, models: models), "Fixture Claude")
        XCTAssertEqual(AssistantPanel.modelLabel(for: "missing/very-long-internal-id", provider: .openCode, models: models), "Choose model")
        XCTAssertEqual(AssistantPanel.modelLabel(for: "synthetic-model", provider: .openAI, models: []), AIProvider.openAI.name)
    }

    func testOpenCodePickerCannotRebindAConversationUsingAnotherProvider() async throws {
        browser.askAboutPage(from: source, selection: "The captured public quote")
        let assistant = try XCTUnwrap(browser.assisting)
        try await until { !assistant.reading }
        let savedOpenCodeModel = browser.prefs.aiModels[AIProvider.openCode.rawValue]
        browser.chooseAssistantModel("synthetic-other-provider/model")
        XCTAssertEqual(assistant.provider, .openAI)
        XCTAssertEqual(assistant.model, "synthetic-model")
        XCTAssertEqual(browser.prefs.aiModels[AIProvider.openCode.rawValue], savedOpenCodeModel)
        XCTAssertTrue(assistant.turns.isEmpty)
        XCTAssertNil(assistant.notice)
    }

    func testCopyAnswerClearsPreviousClipboardFormatsAndCopiesOnlyPlainAnswerText() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("<p>Old page or credential fixture</p>", forType: .html)
        board.setString("Old page or credential fixture", forType: .string)
        board.setData(Data("{\\rtf1 Old page fixture}".utf8), forType: .rtf)
        let previousFormat = NSPasteboard.PasteboardType("com.example.ask-ai-old-context")
        board.setData(Data("Old private context fixture".utf8), forType: previousFormat)
        let answer = "A plain answer.\nSecond paragraph — exact Unicode and spacing."

        AssistantPanel.copyAnswer(answer, to: board)

        XCTAssertEqual(board.string(forType: .string), answer)
        XCTAssertNil(board.string(forType: .html))
        XCTAssertNil(board.data(forType: .rtf))
        XCTAssertNil(board.data(forType: previousFormat))
        let plainTextTypes: Set<NSPasteboard.PasteboardType> = [.string, .init("NSStringPboardType")]
        XCTAssertTrue(Set(board.types ?? []).isSubset(of: plainTextTypes), "Copy answer must publish only plain-text formats")
    }

    private func until(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw URLError(.timedOut)
    }
}
