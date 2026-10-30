import AppKit
import Network
import WebKit
import XCTest
@testable import Search

/// Real Browser tab transitions and real SSE consumption, with every page,
/// key, question and response supplied by this loopback-only fixture. No
/// OpenCode configuration, external provider or user browser window is used.
@MainActor
final class AssistantTabPersistenceTests: XCTestCase {
    private var browser: Browser!
    private var server: HeldAssistantServer!
    private var savedPolicy: NSApplication.ActivationPolicy?
    private var savedProvider: AIProvider?
    private var savedAI = false
    private var savedModel = ""
    private var savedMock: URL?

    override class func setUp() {
        setenv("SEARCH_PROBE", "assistant-tab-persistence-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        savedPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        guard Store.testing else { throw XCTSkip("Synthetic keys and profiles require the isolated test world") }
        let prefs = Shared.prefs
        savedProvider = prefs.aiProvider
        savedAI = prefs.ai
        savedModel = prefs.aiModels[AIProvider.openAI.rawValue] ?? ""
        prefs.ai = true
        prefs.aiProvider = .openAI
        prefs.setAIModel("synthetic-held-model", for: .openAI)
        Proxy.shared.automaticTarget = nil
        Proxy.shared.take(ProxySetup())
        try await until { !Proxy.shared.changingContent }
        server = try HeldAssistantServer()
        try await server.start()
        savedMock = AIProvider.mock
        AIProvider.mock = server.url
        XCTAssertEqual(AIKeys.save("synthetic-held-stream-key", for: .openAI), .kept)
        Store.settings.set(true, forKey: "ai.told.openAI")
        browser = Browser(record: WindowRecord())
        browser.closeAll()
        try await super.setUp()
    }

    override func tearDown() async throws {
        browser?.closeAll()
        AIKeys.forget(.openAI)
        AIProvider.mock = savedMock
        Store.settings.removeObject(forKey: "ai.told.openAI")
        if let browser {
            browser.prefs.ai = savedAI
            browser.prefs.aiProvider = savedProvider
            browser.prefs.setAIModel(savedModel, for: .openAI)
        }
        server?.stop()
        server = nil
        browser = nil
        if let savedPolicy { NSApp.setActivationPolicy(savedPolicy) }
        try await super.tearDown()
    }

    func testSwitchingAwayAndBackRestoresDraftAndContinuesTheSameAnswer() async throws {
        let first = try await page("first"), second = try await page("second")
        browser.showRow([first, second], active: first.id)
        let (assistant, request) = try await answering(first, quote: "First page context", prefix: "First ")
        assistant.draft = "An unfinished follow-up"
        let turn = try XCTUnwrap(assistant.turns.last?.id)

        var expected = "First "
        for cycle in 0..<10 {
            browser.select(second, floatPrevious: false)
            XCTAssertNil(browser.assisting, "A different tab must not display this page's conversation")
            XCTAssertFalse(browser.sidePanelShown)
            let next = cycle == 0 ? "answer" : " \(cycle)"
            expected += next
            server.emit(next, to: request)
            try await until { assistant.turns.last?.answer == expected || server.closed(request) }

            browser.select(first, floatPrevious: false)
            let restored = try XCTUnwrap(browser.assisting, "The source tab must restore its existing conversation")
            XCTAssertTrue(restored === assistant)
            XCTAssertEqual(restored.turns.last?.id, turn)
            XCTAssertEqual(restored.turns.last?.answer, expected)
            XCTAssertEqual(restored.draft, "An unfinished follow-up")
            XCTAssertTrue(restored.busy, "Hiding a tab must not cancel its in-flight answer")
            XCTAssertEqual(browser.sidePanel, .assistant)
            XCTAssertTrue(browser.sidePanelShown)
            XCTAssertEqual(server.requestCount, 1, "Repeated returns must not submit the question again")
        }
        server.finish(request)
        try await until { assistant.turns.last?.done == true }
        XCTAssertNil(assistant.turns.last?.failed)
        XCTAssertEqual(server.requestCount, 1, "Returning must not submit the question again")
    }

    func testDirectActiveIDChangesRestoreTheSameStreamingConversation() async throws {
        let first = try await page("first"), second = try await page("second")
        browser.showRow([first, second], active: first.id)
        let (assistant, request) = try await answering(first, quote: "Direct switch context", prefix: "Direct ")
        assistant.draft = "Direct switch draft"
        // focusPane, restoration and other activation paths can assign the
        // published ID directly rather than calling Browser.select.
        browser.activeID = second.id
        XCTAssertNil(browser.assisting)
        XCTAssertFalse(browser.sidePanelShown)
        server.emit("answer", to: request)
        try await until { assistant.turns.last?.answer == "Direct answer" || server.closed(request) }
        browser.activeID = first.id
        let restored = try XCTUnwrap(browser.assisting)
        XCTAssertTrue(restored === assistant)
        XCTAssertEqual(restored.draft, "Direct switch draft")
        XCTAssertEqual(restored.turns.last?.answer, "Direct answer")
        XCTAssertTrue(restored.busy)
        XCTAssertEqual(browser.sidePanel, .assistant)
        XCTAssertTrue(browser.sidePanelShown)
        XCTAssertEqual(server.requestCount, 1)
        server.finish(request)
        try await until { assistant.turns.last?.done == true }
    }

    func testTwoTabsKeepIndependentConversationsAndDrafts() async throws {
        let first = try await page("first"), second = try await page("second")
        browser.showRow([first, second], active: first.id)
        let (one, firstRequest) = try await answering(first, quote: "First context", prefix: "One ")
        one.draft = "First draft"
        browser.select(second, floatPrevious: false)
        let (two, secondRequest) = try await answering(second, quote: "Second context", prefix: "Two ")
        two.draft = "Second draft"
        server.emit("answer", to: firstRequest)
        server.emit("answer", to: secondRequest)
        server.finish(firstRequest)
        server.finish(secondRequest)
        try await until { two.turns.last?.done == true && (one.turns.last?.done == true || server.closed(firstRequest)) }

        browser.select(first, floatPrevious: false)
        let restoredFirst = try XCTUnwrap(browser.assisting)
        XCTAssertTrue(restoredFirst === one)
        XCTAssertEqual(restoredFirst.turns.last?.answer, "One answer")
        XCTAssertEqual(restoredFirst.draft, "First draft")
        XCTAssertEqual(restoredFirst.context?.text, "First context")
        browser.select(second, floatPrevious: false)
        let restoredSecond = try XCTUnwrap(browser.assisting)
        XCTAssertTrue(restoredSecond === two)
        XCTAssertEqual(restoredSecond.turns.last?.answer, "Two answer")
        XCTAssertEqual(restoredSecond.draft, "Second draft")
        XCTAssertEqual(restoredSecond.context?.text, "Second context")
        XCTAssertNotEqual(one.id, two.id)
        XCTAssertEqual(server.requestCount, 2)
    }

    func testExplicitCloseCancelsAnswerAndDoesNotRestoreItOnReturn() async throws {
        let first = try await page("first"), second = try await page("second")
        browser.showRow([first, second], active: first.id)
        let (_, request) = try await answering(first, quote: "First context", prefix: "Started")
        browser.closeAssistant()
        try await until { server.closed(request) }
        browser.select(second, floatPrevious: false)
        browser.select(first, floatPrevious: false)
        XCTAssertNil(browser.assisting)
        XCTAssertFalse(browser.sidePanelShown)
    }

    func testClosingBackgroundSourceCancelsOnlyItsConversation() async throws {
        let first = try await page("first"), second = try await page("second")
        browser.showRow([first, second], active: first.id)
        let (_, firstRequest) = try await answering(first, quote: "First context", prefix: "One")
        browser.select(second, floatPrevious: false)
        let (two, secondRequest) = try await answering(second, quote: "Second context", prefix: "Two ")
        browser.close(first)
        try await until { server.closed(firstRequest) }
        XCTAssertFalse(browser.tabs.contains { $0.id == first.id })
        XCTAssertTrue(browser.assisting === two)
        server.emit("survives", to: secondRequest)
        server.finish(secondRequest)
        try await until { two.turns.last?.done == true }
        XCTAssertEqual(two.turns.last?.answer, "Two survives")
    }

    func testBackgroundNavigationCancelsOldContextAndCannotRestoreIt() async throws {
        let first = try await page("first"), second = try await page("second")
        browser.showRow([first, second], active: first.id)
        let (_, request) = try await answering(first, quote: "Old page context", prefix: "Old answer")
        browser.select(second, floatPrevious: false)
        let destination = server.url.appendingPathComponent("changed")
        first.go(to: destination)
        try await until { !first.web.isLoading && first.pageAddress == destination }
        try await until { server.closed(request) }
        browser.select(first, floatPrevious: false)
        XCTAssertNil(browser.assisting, "A different document must not restore the previous page's conversation")
        XCTAssertFalse(browser.sidePanelShown)
        browser.askAboutPage(from: first, selection: "New page context")
        let next = try XCTUnwrap(browser.assisting)
        try await until { !next.reading }
        XCTAssertEqual(next.context?.text, "New page context")
        XCTAssertTrue(next.turns.isEmpty)
        XCTAssertEqual(server.requestCount, 1, "Reopening only reads local context")
    }

    func testWebsiteTriggeredSameURLReloadClearsBackgroundConversation() async throws {
        let first = try await page("reload-source", fromServer: true), second = try await page("second")
        browser.showRow([first, second], active: first.id)
        let address = try XCTUnwrap(first.pageAddress)
        _ = try await first.web.evaluateJavaScript("window.__assistantReloadFixture = 'original-document'; true")
        let (_, request) = try await answering(first, quote: "Original document context", prefix: "Original answer")
        browser.select(second, floatPrevious: false)
        XCTAssertFalse(server.closed(request), "Parking the tab must keep its stream alive until document replacement")

        // Bypass Tab.reload and its explicit-navigation callback, as a
        // website calling location.reload() does. Commit must retire the
        // old context even though its URL has not changed at all.
        XCTAssertNotNil(first.web.reload())
        try await until {
            guard !first.web.isLoading, first.pageAddress == address else { return false }
            return (try? await first.web.evaluateJavaScript("typeof window.__assistantReloadFixture === 'undefined' && document.title === 'Local fixture'") as? Bool) == true
        }
        try await until { server.closed(request) }
        XCTAssertEqual(first.pageAddress, address)
        browser.select(first, floatPrevious: false)
        XCTAssertNil(browser.assisting)
        XCTAssertFalse(browser.sidePanelShown)
        XCTAssertEqual(server.requestCount, 1, "Reload must not resubmit the discarded conversation")
    }

    func testClosingTheWindowCancelsEveryBackgroundStreamAndReleasesItsCache() async throws {
        let first = try await page("first"), second = try await page("second")
        browser.showRow([first, second], active: first.id)
        let (_, firstRequest) = try await answering(first, quote: "First context", prefix: "One")
        browser.select(second, floatPrevious: false)
        let (_, secondRequest) = try await answering(second, quote: "Second context", prefix: "Two")
        XCTAssertEqual(browser.assistantSessions.count, 2)
        // This is the same cleanup called when the owning browser window
        // closes. No NSWindow or live application is involved in the fixture.
        browser.closeAll()
        try await until { server.closed(firstRequest) && server.closed(secondRequest) }
        XCTAssertTrue(browser.assistantSessions.isEmpty)
        XCTAssertTrue(browser.tabs.isEmpty)
        XCTAssertNil(browser.assisting)
        XCTAssertNil(browser.sidePanel)
        XCTAssertFalse(browser.sidePanelShown)
    }

    func testReturningToAssistantTabPreservesAnExplicitSiteOrDialerPanel() async throws {
        let first = try await page("first"), second = try await page("second")
        browser.showRow([first, second], active: first.id)
        let (assistant, request) = try await answering(first, quote: "Protected context", prefix: "Protected ")
        assistant.draft = "Protected draft"
        let markers: [SidePanelContent] = [
            .site(url: server.url.appendingPathComponent("panel-marker"), space: browser.spaceID),
            .dialer
        ]
        for marker in markers {
            browser.select(second, floatPrevious: false)
            // Assign only presentation state; never create a dialer service
            // or navigate a side-panel WKWebView.
            browser.sidePanel = marker
            browser.sidePanelShown = true
            browser.select(first, floatPrevious: false)
            XCTAssertEqual(browser.sidePanel, marker)
            XCTAssertTrue(browser.sidePanelShown)
            XCTAssertNil(browser.assisting, "An automatic return must not replace the explicitly opened panel")
            XCTAssertNil(browser.dialerPage)

            browser.closeSidePanel()
            browser.select(second, floatPrevious: false)
            browser.select(first, floatPrevious: false)
            XCTAssertTrue(browser.assisting === assistant, "Preserving another panel must keep the conversation available")
            XCTAssertEqual(browser.assisting?.draft, "Protected draft")
        }
        server.emit("answer", to: request)
        server.finish(request)
        try await until { assistant.turns.last?.done == true }
        XCTAssertEqual(assistant.turns.last?.answer, "Protected answer")
        XCTAssertEqual(server.requestCount, 1)
    }

    private func page(_ name: String, fromServer: Bool = false) async throws -> Tab {
        let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
        let address = server.url.appendingPathComponent("page-\(name)")
        tab.setAddressOptimistically(address)
        browser.prepare(tab)
        tab.web.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        if fromServer { tab.web.load(URLRequest(url: address)) }
        else { tab.web.loadHTMLString("<!doctype html><title>\(name) fixture</title><p>Synthetic public page</p>", baseURL: address) }
        let expectedTitle = fromServer ? "Local fixture" : "\(name) fixture"
        try await until {
            guard !tab.web.isLoading else { return false }
            return (try? await tab.web.evaluateJavaScript("document.title") as? String) == expectedTitle
        }
        return tab
    }

    private func answering(_ tab: Tab, quote: String, prefix: String) async throws -> (Assistant, Int) {
        browser.askAboutPage(from: tab, selection: quote)
        let assistant = try XCTUnwrap(browser.assisting)
        try await until { !assistant.reading }
        let request = server.requestCount
        assistant.draft = "Explain the synthetic context"
        assistant.submit()
        try await until { server.requestCount == request + 1 }
        server.emit(prefix, to: request)
        try await until { assistant.turns.last?.answer == prefix }
        XCTAssertTrue(assistant.busy)
        return (assistant, request)
    }

    private func until(_ predicate: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.timedOut)
    }
}

/// The test decides exactly when each SSE answer advances or finishes.
/// Incoming request bodies are discarded after bounded HTTP framing.
private final class HeldAssistantServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "AssistantTabPersistenceTests.loopback")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var requests: [NWConnection] = []
    private var ended: Set<Int> = []
    private var starting = true

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")! }
    var requestCount: Int { lock.withLock { requests.count } }
    func closed(_ request: Int) -> Bool { lock.withLock { ended.contains(request) } }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if self.firstStart() { continuation.resume() }
                case .failed(let error):
                    if self.firstStart() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return connection.cancel() }
                self.lock.withLock { self.connections.append(connection) }
                connection.start(queue: self.queue)
                self.read(connection)
            }
            listener.start(queue: queue)
        }
    }

    func emit(_ text: String, to request: Int) {
        let payload: [String: Any] = ["choices": [["delta": ["content": text]]]]
        let json = try! JSONSerialization.data(withJSONObject: payload)
        send(Data("data: \(String(decoding: json, as: UTF8.self))\n\n".utf8), to: request)
    }

    func finish(_ request: Int) {
        send(Data("data: [DONE]\n\n".utf8), to: request, finish: true)
    }

    func stop() {
        listener.cancel()
        lock.withLock { connections }.forEach { $0.cancel() }
    }

    private func firstStart() -> Bool {
        lock.withLock { let wasStarting = starting; starting = false; return wasStarting }
    }

    private func send(_ data: Data, to request: Int, finish: Bool = false) {
        guard let connection = lock.withLock({ requests.indices.contains(request) ? requests[request] : nil }) else { return }
        queue.async {
            var chunk = Data("\(String(data.count, radix: 16))\r\n".utf8)
            chunk.append(data)
            chunk.append(Data("\r\n".utf8))
            if finish { chunk.append(Data("0\r\n\r\n".utf8)) }
            connection.send(content: chunk, completion: .contentProcessed { _ in
                if finish { connection.cancel() }
            })
        }
    }

    private func read(_ connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count <= 65_536 else { return connection.cancel() }
            guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if error == nil, !complete { self.read(connection, buffer: buffer) } else { connection.cancel() }
                return
            }
            let lines = String(decoding: buffer[..<boundary.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            var length = 0
            for line in lines.dropFirst() where line.lowercased().hasPrefix("content-length:") {
                length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? -1
            }
            guard length >= 0, length <= 65_536 else { return connection.cancel() }
            guard buffer.count - boundary.upperBound >= length else {
                if error == nil, !complete { self.read(connection, buffer: buffer) } else { connection.cancel() }
                return
            }
            guard lines.first?.hasPrefix("POST /openAI/chat/completions ") == true else {
                let body = Data("<!doctype html><title>Local fixture</title><p>Local fixture</p>".utf8)
                var response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(body)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let index = self.lock.withLock { let index = self.requests.count; self.requests.append(connection); return index }
            connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in })
            self.monitorClosure(connection, request: index)
        }
    }

    private func monitorClosure(_ connection: NWConnection, request: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, complete, error in
            guard let self else { return }
            if complete || error != nil { self.lock.withLock { _ = self.ended.insert(request) } }
            else { self.monitorClosure(connection, request: request) }
        }
    }
}
