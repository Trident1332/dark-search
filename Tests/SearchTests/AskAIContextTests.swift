import AppKit
import WebKit
import XCTest
@testable import Search

/// The selected quote and the page it belongs to are read locally. Test
/// questions stop at consent; no test contacts an AI provider.
@MainActor
final class AskAIContextTests: XCTestCase {
    private var browser: Browser!
    private var views: [WKWebView] = []
    private var activationPolicy: NSApplication.ActivationPolicy?
    private var savedAI = false
    private var savedProvider: AIProvider?
    private var savedModel = ""
    private var savedSplit = true

    override class func setUp() {
        setenv("SEARCH_PROBE", "ask-ai-context-\(getpid())", 1)
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
        savedSplit = browser.prefs.splitView
        browser.prefs.ai = true
        browser.prefs.aiProvider = .openAI
        browser.prefs.setAIModel("fixture-model", for: .openAI)
        browser.prefs.splitView = true
        _ = AIKeys.save("synthetic-context-test-key", for: .openAI)
        Store.settings.removeObject(forKey: "ai.told.openAI")
        Store.settings.removeObject(forKey: "ai.told.openAI.tools-v1")
        try await super.setUp()
    }

    override func tearDown() async throws {
        browser?.closeAssistant()
        browser?.closeAll()
        if let browser {
            browser.prefs.ai = savedAI
            browser.prefs.aiProvider = savedProvider
            browser.prefs.setAIModel(savedModel, for: .openAI)
            browser.prefs.splitView = savedSplit
        }
        Store.settings.removeObject(forKey: "ai.told.openAI")
        Store.settings.removeObject(forKey: "ai.told.openAI.tools-v1")
        AIKeys.forget(.openAI)
        browser = nil
        for view in views { view.stopLoading() }
        views.removeAll()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        try await super.tearDown()
    }

    func testSelectionCapturesTheVisibleQuoteWithoutFormValuesOrHiddenText() async throws {
        let web = try await page()
        try await select("document.getElementById('quote')", in: web)
        let quote = try await selected(in: web)
        XCTAssertEqual(quote, "Visible public quote")

        // A website can synthesize a selection across nodes a person could
        // not highlight; only readable, non-form text is eligible context.
        try await select("document.body", in: web)
        let broad = try await selected(in: web)
        XCTAssertFalse(broad.contains("password-fixture-secret"))
        XCTAssertFalse(broad.contains("typed-fixture-secret"))
        XCTAssertFalse(broad.contains("textarea-fixture-secret"))
        XCTAssertFalse(broad.contains("editable-fixture-secret"))
        XCTAssertFalse(broad.contains("hidden-fixture-secret"))
        XCTAssertFalse(broad.contains("inert-fixture-secret"))
    }

    func testSelectionNeverReadsTextInputsPasswordsTextareasOrEditableFields() async throws {
        let web = try await page()
        for id in ["typed", "password", "textarea"] {
            _ = try await web.evaluateJavaScript("document.getElementById('\(id)').focus(); document.getElementById('\(id)').select(); true")
            let value = try await selected(in: web)
            XCTAssertEqual(value, "", id)
        }
        _ = try await web.evaluateJavaScript("document.getElementById('editable').focus(); true")
        try await select("document.getElementById('editable')", in: web)
        let editable = try await selected(in: web)
        XCTAssertEqual(editable, "")
    }

    func testRightClickedSplitPaneOwnsTheVisibleQuoteAndAssistant() async throws {
        let source = try await browserPage(title: "Source page", path: "source")
        let other = try await browserPage(title: "Other page", path: "other")
        let split = TabSplit(tabs: [source.id, other.id], focused: other.id)
        browser.showRow([source, other], active: other.id, splits: [split])
        browser.askAboutPage(from: source, selection: "The selected source quote")
        let assistant = try XCTUnwrap(browser.assisting)
        try await until { !assistant.reading }
        XCTAssertEqual(browser.activeID, source.id)
        XCTAssertEqual(assistant.tab, source.id)
        XCTAssertEqual(assistant.selection, "The selected source quote")
        XCTAssertEqual(assistant.context?.text, "The selected source quote")
        XCTAssertEqual(assistant.context?.title, "Source page")
        XCTAssertEqual(assistant.context?.url?.path, "/source")
        XCTAssertEqual(browser.sidePanel, .assistant)
        XCTAssertTrue(browser.sidePanelShown)
        XCTAssertTrue(assistant.turns.isEmpty, "Opening the panel must not send the page to a model")
        XCTAssertNil(assistant.notice, "Consent is requested when a question is submitted")
        XCTAssertFalse(Store.settings.bool(forKey: "ai.told.openAI"))
    }

    func testNoSelectionReadsOnlyPublicPageTextBeforeAnyQuestionIsSent() async throws {
        let source = try await browserPage(title: "Source page", path: "source")
        browser.showRow([source], active: source.id)
        browser.askAboutPage(from: source)
        let assistant = try XCTUnwrap(browser.assisting)
        try await until { !assistant.reading }
        let context = try XCTUnwrap(assistant.context)
        XCTAssertTrue(context.text.contains("Visible public quote"))
        XCTAssertFalse(context.text.contains("typed-fixture-secret"))
        XCTAssertFalse(context.text.contains("textarea-fixture-secret"))
        XCTAssertFalse(context.text.contains("password-fixture-secret"))
        XCTAssertFalse(context.text.contains("editable-fixture-secret"))
        XCTAssertFalse(context.text.contains("hidden-fixture-secret"))
        XCTAssertTrue(assistant.turns.isEmpty)
    }

    func testPrivateAndSleepingTorPagesCannotOpenACloudAssistant() {
        let privatePage = Tab(shy: true)
        privatePage.setAddressOptimistically(URL(string: "https://ask-ai.invalid/private")!)
        browser.prepare(privatePage)
        browser.showRow([privatePage], active: privatePage.id)
        browser.askAboutPage(from: privatePage, selection: "Private quote")
        XCTAssertNil(browser.assisting)

        let torStore = Onion.shared.store(for: .nonPersistent())
        let torPage = Tab(configuration: Web.configuration(shy: true, store: torStore))
        torPage.setAddressOptimistically(URL(string: "https://ask-ai.invalid/tor")!)
        browser.prepare(torPage)
        browser.showRow([torPage], active: torPage.id)
        XCTAssertNil(torPage.built)
        XCTAssertTrue(torPage.usesTor)
        browser.askAboutPage(from: torPage, selection: "Tor quote")
        XCTAssertNil(browser.assisting)
        XCTAssertNil(torPage.built, "Blocking remote AI must not wake a sleeping Tor page")
    }

    func testCapturedSelectionIsBoundedAndStaysInsideThePageFence() async throws {
        let source = try await browserPage(title: "Source page", path: "source")
        browser.showRow([source], active: source.id)
        browser.askAboutPage(from: source, selection: String(repeating: "selected ", count: 5_000))
        let assistant = try XCTUnwrap(browser.assisting)
        try await until { !assistant.reading }
        let context = try XCTUnwrap(assistant.context)
        XCTAssertLessThanOrEqual(context.text.count, AIPage.limit + 20)
        let opening = AIPage.opening(context, .question("Explain this quote"), fence: "fixture-fence")
        XCTAssertTrue(opening.contains("<fixture-fence>"))
        XCTAssertTrue(opening.contains("</fixture-fence>"))
        XCTAssertTrue(opening.hasSuffix("Explain this quote"))
        XCTAssertTrue(assistant.turns.isEmpty)
    }

    func testSubmittingAQuestionWaitsForConsentWithoutStartingAnAnswer() async throws {
        let source = try await browserPage(title: "Source page", path: "source")
        browser.showRow([source], active: source.id)
        browser.askAboutPage(from: source, selection: "The captured quote")
        let assistant = try XCTUnwrap(browser.assisting)
        try await until { !assistant.reading }
        assistant.draft = "Explain this quote"
        assistant.submit()
        try await until { !assistant.reading }
        XCTAssertNotNil(assistant.notice)
        XCTAssertTrue(assistant.turns.isEmpty, "No provider request starts before consent")
        XCTAssertEqual(assistant.context?.text, "The captured quote")
        XCTAssertFalse(Store.settings.bool(forKey: "ai.told.openAI"))
    }

    func testClosingSourceCancelsPendingContextAndCannotReopenTheClosedTab() async throws {
        let source = try await browserPage(title: "Source page", path: "source")
        browser.showRow([source], active: source.id)
        browser.askAboutPage(from: source, selection: "The captured quote")
        let assistant = try XCTUnwrap(browser.assisting)
        browser.close(source)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNil(browser.assisting)
        XCTAssertNil(browser.sidePanel)
        XCTAssertFalse(browser.sidePanelShown)
        XCTAssertNil(assistant.context, "Closing immediately must cancel its scheduled context read")
        XCTAssertTrue(assistant.turns.isEmpty)
        browser.askAboutPage(from: source, selection: "The closed quote")
        XCTAssertNil(browser.assisting)
        XCTAssertFalse(browser.sidePanelShown)
    }

    func testReplacingSourceOrClosingThePanelReleasesTheAssistant() async throws {
        let source = try await browserPage(title: "Source page", path: "source")
        browser.showRow([source], active: source.id)
        browser.askAboutPage(from: source, selection: "The captured quote")
        let assistant = try XCTUnwrap(browser.assisting)
        try await until { !assistant.reading }
        browser.replace(source, going: URL(string: "about:blank")!)
        XCTAssertNil(browser.assisting)
        XCTAssertNil(browser.sidePanel)
        XCTAssertFalse(browser.sidePanelShown)
        XCTAssertTrue(assistant.turns.isEmpty)

        let next = try await browserPage(title: "Another page", path: "another")
        browser.prepare(next)
        browser.showRow([next], active: next.id)
        browser.askAboutPage(from: next, selection: "Another quote")
        let pending = try XCTUnwrap(browser.assisting)
        browser.closeSidePanel()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNil(browser.assisting)
        XCTAssertNil(browser.sidePanel)
        XCTAssertFalse(browser.sidePanelShown)
        XCTAssertNil(pending.context)
    }

    func testAskAgainAfterNavigationCapturesNewPageInsteadOfReusingItsOldContext() async throws {
        let source = try await browserPage(title: "Source page", path: "source")
        browser.showRow([source], active: source.id)
        browser.askAboutPage()
        let first = try XCTUnwrap(browser.assisting)
        try await until { !first.reading }
        let destination = URL(string: "https://ask-ai.invalid/changed")!
        source.setAddressOptimistically(destination)
        source.web.loadHTMLString(html(title: "Changed page"), baseURL: destination)
        try await until {
            guard !source.web.isLoading, source.pageAddress == destination else { return false }
            return (try? await source.web.evaluateJavaScript("document.title") as? String) == "Changed page"
        }
        browser.askAboutPage()
        let second = try XCTUnwrap(browser.assisting)
        try await until { !second.reading }
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.sourceURL?.path, "/source")
        XCTAssertEqual(second.sourceURL?.path, "/changed")
        XCTAssertEqual(second.context?.title, "Changed page")
        XCTAssertEqual(second.context?.url?.path, "/changed")
        XCTAssertTrue(second.turns.isEmpty)
    }

    func testToolsOnlyConversationSurvivesNavigationAndReadsNewDocument() async throws {
        let source = try await browserPage(title: "Source page", path: "source")
        browser.showRow([source], active: source.id)
        browser.askAboutPage()
        let assistant = try XCTUnwrap(browser.assisting)
        try await until { !assistant.reading }
        assistant.tools.setEnabled(true)
        XCTAssertFalse(assistant.inspectEnabled)
        source.onExplicitNavigation?(source)
        XCTAssertTrue(browser.assisting === assistant)
        let destination = URL(string: "https://ask-ai.invalid/tool-destination")!
        source.setAddressOptimistically(destination)
        source.web.loadHTMLString(html(title: "Verified destination"), baseURL: destination)
        try await until {
            guard !source.web.isLoading else { return false }
            return (try? await source.web.evaluateJavaScript("document.title") as? String) == "Verified destination"
        }
        browser.assistantFollowsActiveTab()
        XCTAssertTrue(browser.assisting === assistant)
        let catalog = await assistant.tools.catalog()
        let snapshot = await assistant.tools.call("browser_snapshot", arguments: [:], generation: catalog.generation)
        XCTAssertTrue(snapshot.contains("Verified destination"))
        browser.askAboutPage()
        XCTAssertTrue(browser.assisting === assistant)
    }

    func testChangingCapabilitiesWhileConsentIsPendingReasksBeforeSending() async throws {
        Store.settings.removeObject(forKey: "ai.told.openAI.tools-v1")
        defer { Store.settings.removeObject(forKey: "ai.told.openAI.tools-v1") }
        let source = try await browserPage(title: "Consent fixture", path: "consent")
        browser.showRow([source], active: source.id)
        browser.askAboutPage()
        let assistant = try XCTUnwrap(browser.assisting)
        try await until { !assistant.reading }
        assistant.draft = "Review this fixture"
        assistant.submit()
        try await until { !assistant.reading }
        XCTAssertNotNil(assistant.notice)
        assistant.tools.setEnabled(false)
        assistant.agree()
        XCTAssertTrue(assistant.turns.isEmpty)
        XCTAssertTrue(assistant.notice?.contains("selected local files") == true)
        XCTAssertFalse(Store.settings.bool(forKey: "ai.told.openAI.tools-v1"))
    }


    func testQuestionsAutomaticallyEnableAvailableToolsBeforeCloudConsent() async throws {
        // Ordinary page consent must not bypass the broader tools notice.
        Store.settings.set(true, forKey: "ai.told.openAI")
        let source = try await browserPage(title: "Automatic tools", path: "automatic")
        browser.showRow([source], active: source.id)
        browser.askAboutPage()
        let assistant = try XCTUnwrap(browser.assisting)
        try await until { !assistant.reading }
        XCTAssertFalse(assistant.tools.enabled, "Opening Ask AI alone must not start or enable tools")
        assistant.draft = "Check the current page"
        assistant.submit()
        try await until { !assistant.reading }
        XCTAssertTrue(assistant.tools.enabled)
        XCTAssertTrue(assistant.notice?.contains("selected local files") == true)
        XCTAssertTrue(assistant.turns.isEmpty, "Automatic tools still require cloud consent")
        XCTAssertNil(assistant.tools.workspace, "A question cannot grant access to the home or page folder")
        let catalog = await assistant.tools.catalog()
        XCTAssertTrue(catalog.functions.contains { $0["name"] as? String == "browser_snapshot" })
    }

    func testSummariesAutomaticallyUseToolsAndStillWaitForCloudConsent() async throws {
        let source = try await browserPage(title: "Summary fixture", path: "summary")
        browser.showRow([source], active: source.id)
        browser.summarizePage()
        let assistant = try XCTUnwrap(browser.assisting)
        try await until { !assistant.reading }
        XCTAssertTrue(assistant.tools.enabled)
        XCTAssertNotNil(assistant.notice)
        XCTAssertTrue(assistant.turns.isEmpty)
        XCTAssertNil(assistant.tools.workspace)
    }

    func testHumanQuestionSelectsPublicRepositoryBeforeConsentWithoutASetupForm() async throws {
        let source = try await browserPage(title: "Repository fixture", path: "repository")
        browser.showRow([source], active: source.id)
        browser.askAboutPage(from: source, selection: "Quoted page https://github.com/untrusted/page-source")
        let assistant = try XCTUnwrap(browser.assisting)
        try await until { !assistant.reading }
        assistant.draft = "Review https://github.com/example/requested-project"
        assistant.submit()
        try await until { !assistant.reading }
        XCTAssertEqual(assistant.tools.repositoryName, "example/requested-project")
        XCTAssertNotNil(assistant.notice)
        XCTAssertTrue(assistant.turns.isEmpty)
        XCTAssertNil(assistant.tools.workspace)
    }

    func testPageQuotesCannotSelectRepositoriesAndExistingExplicitSourcesArePreserved() async throws {
        let source = try await browserPage(title: "Quoted sources", path: "quoted-sources")
        browser.showRow([source], active: source.id)
        browser.askAboutPage(from: source, selection: "Quoted page https://github.com/untrusted/page-source")
        var assistant = try XCTUnwrap(browser.assisting)
        try await until { !assistant.reading }
        assistant.draft = "Explain the quoted page"
        assistant.submit()
        try await until { !assistant.reading }
        XCTAssertEqual(assistant.tools.repositoryName, "")
        browser.closeAssistant()
        browser.askAboutPage(from: source)
        assistant = try XCTUnwrap(browser.assisting)
        try await until { !assistant.reading }
        assistant.tools.selectRepository("explicit/current-source")
        assistant.draft = "Compare with https://github.com/example/other-project"
        assistant.submit()
        try await until { !assistant.reading }
        XCTAssertEqual(assistant.tools.repositoryName, "explicit/current-source")
        XCTAssertNotNil(assistant.notice)
        XCTAssertTrue(assistant.turns.isEmpty)
    }

    func testRepositoryInferenceRejectsCredentialsOtherHostsQueriesAndAmbiguity() {
        XCTAssertEqual(AIAssist.requestedRepository(in: "Review [source](https://github.com/example/project.git)")?.label, "example/project")
        XCTAssertEqual(AIAssist.requestedRepository(in: "Use https://github.com/example/project/")?.label, "example/project")
        for question in [
            "http://github.com/example/project",
            "https://github.com.evil.invalid/example/project",
            "https://evil.invalid/https://github.com/example/project",
            "https://person@github.com/example/project",
            "https://github.com:443/example/project",
            "https://github.com/example/project?token=fixture",
            "https://github.com/example/project#readme",
            "https://github.com/example/project/tree/main",
            "https://github.com/example/%70roject",
            "https://github.com/example/one and https://github.com/example/two"
        ] {
            XCTAssertNil(AIAssist.requestedRepository(in: question), question)
        }
    }

    func testPendingCloudConsentCannotSendAfterTheTabLeavesSupportedPages() async throws {
        let source = try await browserPage(title: "Consent navigation", path: "consent-navigation")
        browser.showRow([source], active: source.id)
        browser.askAboutPage()
        let assistant = try XCTUnwrap(browser.assisting)
        try await until { !assistant.reading }
        assistant.draft = "Review this page"
        assistant.submit()
        try await until { !assistant.reading }
        XCTAssertNotNil(assistant.notice)
        source.setAddressOptimistically(URL(fileURLWithPath: "/private/tmp/unrelated-source"))
        assistant.agree()
        XCTAssertNil(assistant.notice)
        XCTAssertNotNil(assistant.trouble)
        XCTAssertTrue(assistant.turns.isEmpty)
        XCTAssertFalse(Store.settings.bool(forKey: "ai.told.openAI.tools-v1"))
    }

    func testAutomaticToolsRespectProviderSupportAndPrivateTabPolicy() async throws {
        let source = try await browserPage(title: "Provider policy", path: "provider-policy")
        let bundled = Assistant(tab: source, provider: .thisMac, model: "fixture", summary: false, standalone: true)
        bundled.prepareRequestTools(for: .question("Review https://github.com/example/project"))
        XCTAssertFalse(bundled.tools.enabled, "The bundled text engine has no tool-calling support")
        XCTAssertEqual(bundled.tools.repositoryName, "")
        bundled.stop()

        let privateSource = Tab(shy: true)
        privateSource.setAddressOptimistically(URL(string: "https://ask-ai.invalid/private-policy")!)
        let cloud = Assistant(tab: privateSource, provider: .openAI, model: "fixture", summary: false, standalone: true)
        cloud.prepareRequestTools(for: .question("Review https://github.com/example/project"))
        XCTAssertFalse(cloud.tools.enabled)
        XCTAssertEqual(cloud.tools.repositoryName, "")
        let denied = await cloud.tools.catalog()
        XCTAssertTrue(denied.functions.isEmpty)
        cloud.stop()

        let local = Assistant(tab: privateSource, provider: .ollama, model: "fixture", summary: false, standalone: true)
        local.prepareRequestTools(for: .question("Review https://github.com/example/project"))
        XCTAssertTrue(local.tools.enabled, "Tool-capable local providers can stay inside private sessions")
        XCTAssertEqual(local.tools.repositoryName, "example/project")
        XCTAssertNil(local.tools.workspace)
        local.stop()
    }

    private func browserPage(title: String, path: String) async throws -> Tab {
        let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
        tab.setAddressOptimistically(URL(string: "https://ask-ai.invalid/\(path)")!)
        browser.prepare(tab)
        tab.web.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        tab.web.loadHTMLString(html(title: title), baseURL: tab.pageAddress)
        try await until {
            guard !tab.web.isLoading else { return false }
            return (try? await tab.web.evaluateJavaScript("document.title") as? String) == title
        }
        return tab
    }

    private func page() async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        views.append(web)
        web.loadHTMLString(html(title: "Selection fixture"), baseURL: URL(string: "https://ask-ai.invalid/selection"))
        try await until {
            guard !web.isLoading else { return false }
            return (try? await web.evaluateJavaScript("document.title") as? String) == "Selection fixture"
        }
        return web
    }

    private func html(title: String) -> String {
        """
        <!doctype html><html><head><title>\(title)</title></head><body>
        <p id="quote">Visible public quote</p>
        <input id="typed" value="typed-fixture-secret">
        <input id="password" type="password" value="password-fixture-secret">
        <textarea id="textarea">textarea-fixture-secret</textarea>
        <div id="editable" contenteditable="true">editable-fixture-secret</div>
        <p style="display:none">hidden-fixture-secret</p>
        <p inert>inert-fixture-secret</p>
        </body></html>
        """
    }

    private func select(_ expression: String, in web: WKWebView) async throws {
        _ = try await web.evaluateJavaScript("""
        (() => { const range = document.createRange(); range.selectNodeContents(\(expression));
          const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range); return true; })()
        """)
    }

    private func selected(in web: WKWebView) async throws -> String {
        let value: Any? = try await withCheckedThrowingContinuation { done in
            web.evaluateJavaScript(AIPage.selected, in: nil, in: Web.world) { result in
                switch result {
                case .success(let value): done.resume(returning: value)
                case .failure(let error): done.resume(throwing: error)
                }
            }
        }
        return value as? String ?? ""
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
