import AppKit
import WebKit
import XCTest
@testable import Search

@MainActor
final class AIPageAvailabilityTests: XCTestCase {
    private var tabs: [Tab] = []
    private var assistants: [Assistant] = []
    private var policy: NSApplication.ActivationPolicy?

    override class func setUp() {
        setenv("SEARCH_PROBE", "ai-page-availability-\(getpid())", 1)
        super.setUp()
    }
    override func setUp() async throws {
        _ = NSApplication.shared
        policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        _ = Shared.prefs
        Proxy.shared.automaticTarget = nil
        Proxy.shared.take(ProxySetup())
        for _ in 0..<100 where Proxy.shared.changingContent { try await Task.sleep(for: .milliseconds(20)) }
        _ = AIKeys.save("synthetic-empty-page-key", for: .openAI)
        Store.settings.removeObject(forKey: "ai.told.openAI")
        Store.settings.removeObject(forKey: "ai.told.openAI.tools-v1")
    }
    override func tearDown() async throws {
        assistants.forEach { $0.stop() }
        tabs.forEach { $0.aiInspection.stop(); $0.built?.stopLoading() }
        assistants.removeAll(); tabs.removeAll()
        AIKeys.forget(.openAI)
        if let policy { NSApp.setActivationPolicy(policy) }
    }
    private func page(_ html: String) async throws -> Tab {
        let tab = Tab(configuration: Web.configuration())
        tabs.append(tab)
        let url = URL(string: "https://empty-page-fixture.invalid/public?token=fixture-url-secret")!
        tab.setAddressOptimistically(url)
        tab.web.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        tab.web.loadHTMLString("<!doctype html><title>Fixture source</title><style>body{font:18px system-ui}p{max-width:600px}</style>" + html, baseURL: url)
        for _ in 0..<400 where tab.web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(tab.web.isLoading)
        return tab
    }
    private func assistant(_ tab: Tab) async throws -> Assistant {
        let assistant = Assistant(tab: tab, provider: .openAI, model: "synthetic-empty-page-model", summary: false)
        assistants.append(assistant)
        for _ in 0..<400 where assistant.reading { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(assistant.reading)
        return assistant
    }

    func testHiddenStreamingSectionCannotReplaceTheVisibleArticle() async throws {
        let hidden = String(repeating: "hidden-streaming-secret ", count: 100)
        let visible = String(repeating: "Visible public article text. ", count: 20)
        let tab = try await page("<div hidden id='streaming-buffer'><article><p>\(hidden)</p><p>\(hidden)</p><a href='https://hidden-secret.invalid'>Hidden link</a></article></div><main><p>\(visible)</p><p>\(visible)</p></main>")
        let captured = await AIPage.read(tab)
        let read = try XCTUnwrap(captured)
        XCTAssertTrue(read.text.contains("Visible public article"))
        XCTAssertFalse(read.text.contains("hidden-streaming-secret"))
        XCTAssertFalse(read.links.contains { $0.contains("hidden-secret") })
    }

    func testEmptyArticleFallsBackToVisibleBodyWithoutReadingHiddenOrEditableText() async throws {
        let hidden = String(repeating: "hidden-prose-secret ", count: 100)
        let tab = try await page("<article style='height:40px'><p hidden>\(hidden)</p><p hidden>\(hidden)</p></article><div><p>Visible short body text.</p></div><input type='password' value='password-secret'><div contenteditable>editable-secret</div>")
        let captured = await AIPage.read(tab)
        let read = try XCTUnwrap(captured)
        XCTAssertTrue(read.text.contains("Visible short body text"))
        XCTAssertFalse(read.text.contains("hidden-prose-secret"))
        XCTAssertFalse(read.text.contains("password-secret"))
        XCTAssertFalse(read.text.contains("editable-secret"))
    }

    func testNoReadableTextStillEnablesTheComposerAndSubmitsToConsent() async throws {
        let tab = try await page("<canvas width='400' height='300'></canvas><input type='password' value='password-secret'><textarea>textarea-secret</textarea><p hidden>hidden-secret</p>")
        let empty = await AIPage.read(tab)
        XCTAssertNil(empty, "The extractor must not invent text or include hidden form values")
        let assistant = try await assistant(tab)
        XCTAssertTrue(assistant.context?.unavailable == true)
        XCTAssertEqual(assistant.context?.text, "")
        XCTAssertNil(assistant.trouble)
        XCTAssertNotNil(assistant.contextProblem)
        assistant.draft = "Can you help me?"
        XCTAssertTrue(assistant.canSubmit, "The Send button and Return key must stay usable after extraction fails")
        assistant.submit()
        for _ in 0..<300 where assistant.reading { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(assistant.pendingQuestion, "Can you help me?")
        XCTAssertNotNil(assistant.notice, "Missing page text must not bypass cloud consent")
        XCTAssertFalse(assistant.canSubmit)
        XCTAssertTrue(assistant.turns.isEmpty)
    }

    func testMissingTextPromptIsHonestAndDoesNotIncludeFormValuesOrURLTokens() async throws {
        let tab = try await page("<canvas></canvas><input value='typed-secret'><p hidden>hidden-secret</p>")
        let assistant = try await assistant(tab)
        let read = try XCTUnwrap(assistant.context)
        let prompt = AIPage.opening(read, .question("Help me"), fence: "fixture-fence")
        XCTAssertTrue(prompt.contains("page text unavailable"))
        XCTAssertTrue(prompt.contains("no website text was captured"))
        XCTAssertTrue(prompt.contains("available browser tools"))
        for secret in ["typed-secret", "hidden-secret", "fixture-url-secret"] { XCTAssertFalse(prompt.contains(secret)) }
    }

    func testSuccessfulPageReadStillAttachesItsRealText() async throws {
        let tab = try await page("<main><h1>Public fixture</h1><p>Readable website text.</p></main>")
        let assistant = try await assistant(tab)
        XCTAssertFalse(try XCTUnwrap(assistant.context).unavailable)
        XCTAssertTrue(assistant.context?.text.contains("Readable website text") == true)
        XCTAssertNil(assistant.contextProblem)
    }

    func testFixedContentRemainsReadableWhenTheBodyHasZeroHeight() async throws {
        let tab = try await page("<style>body{height:0;overflow:hidden}main{position:fixed;inset:0;background:white;color:black}</style><main><h1>Rendered page</h1><p>Visible fixed page content.</p></main>")
        let captured = await AIPage.read(tab)
        XCTAssertTrue(try XCTUnwrap(captured).text.contains("Visible fixed page content"))
    }

    func testDisplayContentsAndZeroFontWrappersKeepVisibleDescendantsOnly() async throws {
        let tab = try await page("<main style='display:contents'><div style='font-size:0'><span>tiny-hidden-secret</span><p style='font-size:18px'>Visible descendant content.</p></div></main>")
        let captured = await AIPage.read(tab)
        let read = try XCTUnwrap(captured)
        XCTAssertTrue(read.text.contains("Visible descendant content"))
        XCTAssertFalse(read.text.contains("tiny-hidden-secret"))
    }

    func testReaderRetriesContentThatAppearsAfterTheFirstRender() async throws {
        let tab = try await page("<script>setTimeout(()=>{document.body.insertAdjacentHTML('beforeend','<p>Delayed rendered page content.</p>')},300)</script>")
        let captured = await AIPage.read(tab)
        XCTAssertTrue(try XCTUnwrap(captured).text.contains("Delayed rendered page content"))
    }

    func testSubmittingReadsTheCurrentPageInsteadOfThePanelOpeningSnapshot() async throws {
        let tab = try await page("<p id='prose'>Original page content.</p>")
        let assistant = try await assistant(tab)
        _ = try await tab.web.evaluateJavaScript("document.getElementById('prose').textContent='Updated page content.';true")
        assistant.draft = "Explain the current content"
        assistant.submit()
        for _ in 0..<300 where assistant.reading { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(assistant.context?.text.contains("Updated page content") == true)
        XCTAssertFalse(assistant.context?.text.contains("Original page content") == true)
        XCTAssertNotNil(assistant.notice)
    }

    func testStoppingARenderRetryRestoresTheQuestionWithoutALateRequest() async throws {
        let tab = try await page("<canvas></canvas>")
        let assistant = try await assistant(tab)
        assistant.draft = "Keep this question"
        assistant.submit()
        XCTAssertTrue(assistant.reading)
        assistant.cancelAnswer()
        XCTAssertEqual(assistant.draft, "Keep this question")
        XCTAssertNil(assistant.pendingQuestion)
        try await Task.sleep(for: .milliseconds(1600))
        XCTAssertFalse(assistant.reading)
        XCTAssertNil(assistant.notice)
        XCTAssertTrue(assistant.turns.isEmpty)
    }
}
