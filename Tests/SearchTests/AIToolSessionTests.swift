import AppKit
import XCTest
@testable import Search

@MainActor
final class AIToolSessionTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "ai-tool-session-tests-\(getpid())", 1)
        super.setUp()
    }
    override func setUp() async throws {
        _ = NSApplication.shared
        _ = Shared.prefs
        try await super.setUp()
    }
    func testToolsRequireExplicitEnableAndOnlyAdvertisedToolsDispatch() async throws {
        let tab = Tab()
        let session = AIToolSession(tab: tab, localProvider: true)
        let disabled = await session.catalog()
        XCTAssertTrue(disabled.functions.isEmpty)
        session.setEnabled(true)
        let catalog = await session.catalog()
        XCTAssertEqual(Set(catalog.functions.compactMap { $0["name"] as? String }), ["analysis_status", "read_tool_evidence"])
        let refused = await session.call("execute_shell_command", arguments: ["command": "echo should-never-run"], generation: catalog.generation)
        XCTAssertNotNil(try object(refused)["error"])
        XCTAssertTrue(session.records.isEmpty)
        let status = try object(await session.call("analysis_status", arguments: [:], generation: catalog.generation))
        XCTAssertNotNil(status["evidence_id"])
        XCTAssertTrue((status["data"] as? String)?.contains("excluded") == true)
        XCTAssertEqual(session.records.count, 1)
    }
    func testChangingSelectionOrDisablingRevokesInFlightCatalog() async throws {
        let tab = Tab()
        let session = AIToolSession(tab: tab, localProvider: true)
        session.setEnabled(true)
        let first = await session.catalog()
        session.clearSelection()
        let firstResult = await session.call("analysis_status", arguments: [:], generation: first.generation)
        XCTAssertNotNil(try object(firstResult)["error"])
        let second = await session.catalog()
        session.setEnabled(false)
        let secondResult = await session.call("analysis_status", arguments: [:], generation: second.generation)
        XCTAssertNotNil(try object(secondResult)["error"])
        XCTAssertTrue(session.records.isEmpty)
    }
    func testPrivateTabNeverAdvertisesToolsToCloudProvider() async throws {
        let privateTab = Tab(shy: true)
        let session = AIToolSession(tab: privateTab, localProvider: false)
        session.setEnabled(true)
        let catalog = await session.catalog()
        XCTAssertTrue(catalog.functions.isEmpty)
        let denied = await session.call("analysis_status", arguments: [:], generation: catalog.generation)
        XCTAssertNotNil(try object(denied)["error"])
        let local = AIToolSession(tab: privateTab, localProvider: true)
        local.setEnabled(true)
        let localCatalog = await local.catalog()
        XCTAssertFalse(localCatalog.functions.isEmpty)
    }
    func testEvidenceCannotCrossConversations() async throws {
        let tab = Tab()
        let session = AIToolSession(tab: tab, localProvider: true)
        session.setEnabled(true)
        let catalog = await session.catalog()
        let status = try object(await session.call("analysis_status", arguments: [:], generation: catalog.generation))
        let id = try XCTUnwrap(status["evidence_id"] as? String)
        let repeated = try object(await session.call("read_tool_evidence", arguments: ["evidence_id": id], generation: catalog.generation))
        XCTAssertEqual(repeated["data"] as? String, status["data"] as? String)
        let other = AIToolSession(tab: tab, localProvider: true)
        other.setEnabled(true)
        let otherCatalog = await other.catalog()
        let otherEvidence = await other.call("read_tool_evidence", arguments: ["evidence_id": id], generation: otherCatalog.generation)
        XCTAssertNotNil(try object(otherEvidence)["error"])
    }
    func testToolConsentDescribesFilesAndRawInspectionData() {
        let ordinary = AIAssist.notice(for: .openAI, host: "fixture.invalid")
        let tools = AIAssist.notice(for: .openAI, host: "fixture.invalid", tools: true)
        XCTAssertFalse(ordinary.contains("selected local files"))
        XCTAssertTrue(tools.contains("selected local files"))
        XCTAssertTrue(tools.contains("cookies"))
        XCTAssertTrue(tools.contains("unredacted"))
    }
    func testSingleFileAttachmentDoesNotShareSiblingsAndIsRemovedOnClose() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("search-attachment-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: source) }
        let selected = source.appendingPathComponent("chosen.txt")
        try Data("chosen input".utf8).write(to: selected)
        try Data("unselected private input".utf8).write(to: source.appendingPathComponent("private.txt"))
        let tab = Tab()
        let session = AIToolSession(tab: tab, localProvider: true)
        await session.attach(selected)
        let workspace = try XCTUnwrap(session.workspace)
        XCTAssertNotEqual(workspace, source)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(session.target), encoding: .utf8), "chosen input")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("private.txt").path))
        session.dispose()
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
        XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), "chosen input")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("private.txt").path))
    }
    private func object(_ string: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }
}

@MainActor
final class AIClientToolTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "ai-client-tool-tests-\(getpid())", 1)
        super.setUp()
    }
    override func setUp() async throws {
        _ = NSApplication.shared
        _ = Shared.prefs
        Proxy.shared.automaticTarget = nil
        Proxy.shared.take(ProxySetup())
        for _ in 0..<100 where Proxy.shared.changingContent { try await Task.sleep(for: .milliseconds(20)) }
        try await super.setUp()
    }
    override func tearDown() async throws {
        AIToolProtocol.handler = nil
        try await super.tearDown()
    }

    func testModelToolRoundTripUsesRegistryAndReturnsEvidence() async throws {
        let tab = Tab()
        // Keep the actual owning tab alive for the entire request.
        let ownedTools = AIToolSession(tab: tab, localProvider: true)
        ownedTools.setEnabled(true)
        var requests = [[String: Any]]()
        AIToolProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: AIToolProtocol.body(request)) as! [String: Any]
            requests.append(body)
            if requests.count == 1 {
                return ["choices": [["message": ["role": "assistant", "content": NSNull(), "tool_calls": [["id": "fixture-call", "type": "function", "function": ["name": "analysis_status", "arguments": "{}"]]]]]]]
            }
            return ["choices": [["message": ["role": "assistant", "content": "Verified from tool evidence."]]]]
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIToolProtocol.self]
        let client = AIClient(configuration: configuration)
        var answer = ""
        for try await piece in client.agent(.ollama, model: "fixture-model", system: "Fixture instructions", messages: [.init(role: .user, text: "Check status")], key: nil, connection: nil, tools: ownedTools) { answer += piece }
        XCTAssertEqual(answer, "Verified from tool evidence.")
        XCTAssertEqual(requests.count, 2)
        let functions = try XCTUnwrap(requests.first?["tools"] as? [[String: Any]])
        XCTAssertTrue(functions.contains { ($0["function"] as? [String: Any])?["name"] as? String == "analysis_status" })
        let messages = try XCTUnwrap(requests.last?["messages"] as? [[String: Any]])
        let result = try XCTUnwrap(messages.first { $0["role"] as? String == "tool" }?["content"] as? String)
        XCTAssertTrue(result.contains("evidence_id"))
        XCTAssertEqual(ownedTools.records.count, 1)
        client.session.invalidateAndCancel()
    }

    func testInventedModelToolNeverDispatches() async throws {
        let tab = Tab()
        let session = AIToolSession(tab: tab, localProvider: true)
        session.setEnabled(true)
        var count = 0, response = ""
        AIToolProtocol.handler = { request in
            count += 1
            if count == 1 {
                return ["choices": [["message": ["role": "assistant", "tool_calls": [["id": "invented", "type": "function", "function": ["name": "execute_shell_command", "arguments": "{\"command\":\"never\"}"]]]]]]]
            }
            let body = try JSONSerialization.jsonObject(with: AIToolProtocol.body(request)) as! [String: Any]
            response = ((body["messages"] as? [[String: Any]])?.last?["content"] as? String) ?? ""
            return ["choices": [["message": ["role": "assistant", "content": "Unavailable."]]]]
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIToolProtocol.self]
        let client = AIClient(configuration: configuration)
        for try await _ in client.agent(.ollama, model: "fixture", system: "Fixture", messages: [], key: nil, connection: nil, tools: session) {}
        XCTAssertTrue(response.contains("not advertised"))
        XCTAssertTrue(session.records.isEmpty)
        client.session.invalidateAndCancel()
    }

    func testToolRoundTripPreservesResponsesAnthropicAndGeminiFormats() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tool-wire-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (package, wire) in [("@ai-sdk/openai", "responses"), ("@ai-sdk/anthropic", "anthropic"), ("@ai-sdk/google", "gemini")] {
            let config: [String: Any] = ["model": "fixture/model", "provider": ["fixture": ["npm": package, "options": ["baseURL": "http://localhost:9911/v1", "apiKey": "synthetic-tool-key"], "models": ["model": ["name": "Fixture"]]]]]
            let file = folder.appendingPathComponent(wire + ".json")
            try JSONSerialization.data(withJSONObject: config).write(to: file)
            let connection = try OpenCodeAI.connection(for: "fixture/model", files: [file], environment: [:])
            let tab = Tab(), session = AIToolSession(tab: tab, localProvider: true)
            session.setEnabled(true)
            var phase = 0
            var finalRequest: [String: Any] = [:]
            AIToolProtocol.handler = { request in
                phase += 1
                finalRequest = try JSONSerialization.jsonObject(with: AIToolProtocol.body(request)) as! [String: Any]
                switch (wire, phase) {
                case ("responses", 1): return ["output": [["type": "function_call", "call_id": "fixture-call", "name": "analysis_status", "arguments": "{}"]]]
                case ("responses", _): return ["output": [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Verified."]]]]]
                case ("anthropic", 1): return ["content": [["type": "tool_use", "id": "fixture-call", "name": "analysis_status", "input": [:]]]]
                case ("anthropic", _): return ["content": [["type": "text", "text": "Verified."]]]
                case ("gemini", 1): return ["candidates": [["content": ["role": "model", "parts": [["functionCall": ["id": "fixture-call", "name": "analysis_status", "args": [:]]]]]]]]
                default: return ["candidates": [["content": ["role": "model", "parts": [["text": "Verified."]]]]]]
                }
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [AIToolProtocol.self]
            let client = AIClient(configuration: configuration)
            var answer = ""
            for try await piece in client.agent(.openCode, model: connection.id, system: "Fixture", messages: [.init(role: .user, text: "Check")], key: nil, connection: connection, tools: session) { answer += piece }
            XCTAssertEqual(answer, "Verified.", wire)
            XCTAssertEqual(phase, 2, wire)
            XCTAssertEqual(session.records.count, 1, wire)
            let serialized = String(decoding: try JSONSerialization.data(withJSONObject: finalRequest), as: UTF8.self)
            XCTAssertTrue(serialized.contains("evidence_id"), wire)
            switch wire {
            case "responses":
                XCTAssertTrue(serialized.contains("function_call_output"))
                let definitions = try XCTUnwrap(finalRequest["tools"] as? [[String: Any]])
                XCTAssertTrue(definitions.allSatisfy { $0["strict"] as? Bool == false })
            case "anthropic": XCTAssertTrue(serialized.contains("tool_result"))
            default:
                XCTAssertTrue(serialized.contains("functionResponse"))
                XCTAssertTrue(serialized.contains("parametersJsonSchema"))
            }
            client.session.invalidateAndCancel()
        }
    }
}

private final class AIToolProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> [String: Any])?
    static func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 8192)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count < 0 { throw stream.streamError ?? AIError.unreadable }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count < 2_000_000 else { throw AIError.unreadable }
        }
        return data
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "localhost" || request.url?.host == "127.0.0.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let object = try Self.handler?(request) ?? ["error": "Missing fixture"]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: object))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
