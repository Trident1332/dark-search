import AppKit
import Foundation
import XCTest
@testable import Search

/// Held synthetic provider streams exercise the real agent loop. Every byte,
/// model, key and history item belongs to this fixture; no account is used.
@MainActor
final class AIClientStreamingTests: XCTestCase {
    private var folder: URL!
    private var client: AIClient!
    private var fixture: HeldAgentStream!

    override class func setUp() {
        setenv("SEARCH_PROBE", "ai-client-streaming-\(getpid())", 1)
        super.setUp()
    }
    override func setUp() async throws {
        _ = NSApplication.shared
        _ = Shared.prefs
        Proxy.shared.automaticTarget = nil
        Proxy.shared.take(ProxySetup())
        for _ in 0..<100 where Proxy.shared.changingContent { try await Task.sleep(for: .milliseconds(20)) }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fixture = HeldAgentStream()
        HeldAgentProtocol.fixture = fixture
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldAgentProtocol.self]
        client = AIClient(configuration: configuration)
        try await super.setUp()
    }
    override func tearDown() async throws {
        client?.session.invalidateAndCancel()
        fixture?.stop()
        HeldAgentProtocol.fixture = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
        client = nil; fixture = nil; folder = nil
        try await super.tearDown()
    }

    func testOpenAITextStreamsAndFragmentedToolArgumentsWaitForCompletion() async throws { try await exercise(.openAI) }
    func testResponsesStreamPreservesEncryptedReasoningAndCompletedCalls() async throws { try await exercise(.responses) }
    func testAnthropicStreamPreservesThinkingAndSignatureInToolHistory() async throws { try await exercise(.anthropic) }
    func testGeminiStreamPreservesFunctionAndEmptyTextThoughtSignatures() async throws { try await exercise(.gemini) }

    func testAnthropicRefusalCannotDispatchACompleteToolCallAfterVisibleText() async throws {
        try await exerciseRejectedTurn(.anthropic, terminal: [
            ["type": "message_delta", "delta": ["stop_reason": "refusal"]],
            ["type": "message_stop"]
        ])
    }

    func testGeminiOtherStopCannotDispatchACompleteFunctionCallAfterVisibleText() async throws {
        try await exerciseRejectedTurn(.gemini, terminal: [
            ["candidates": [["index": 0, "finishReason": "OTHER"]]]
        ])
    }

    private func exerciseRejectedTurn(_ wire: Wire, terminal: [[String: Any]]) async throws {
        let connection = try connection(wire)
        let tab = Tab(), tools = AIToolSession(tab: tab, localProvider: true)
        tools.setEnabled(true)
        defer { tools.dispose() }
        var answer = ""
        var progress: [String] = []
        let receiving = Task { @MainActor in
            for try await piece in self.client.agent(.openCode, model: connection.id, system: "Synthetic system", messages: [.init(role: .user, text: "Check status")], key: nil, connection: connection, tools: tools, onProgress: { event in
                await MainActor.run {
                    switch event {
                    case .preparing: progress.append("preparing")
                    case .waiting: progress.append("waiting")
                    case .toolStarted(let name, let input): progress.append(name)
                        XCTAssertFalse(input.command.text.isEmpty)
                    case .toolReturned: progress.append("returned")
                    case .answering: break
                    }
                }
            }) {
                answer += piece
            }
        }
        defer { receiving.cancel() }
        try await until { self.fixture.requests.count == 1 }
        for event in wire.opening { fixture.emit(event, to: 0) }
        fixture.emit(wire.text("Checking "), to: 0)
        try await until { answer.contains("Checking ") }
        for event in wire.toolBeginning + wire.toolEnding { fixture.emit(event, to: 0) }
        for event in terminal { fixture.emit(event, to: 0) }
        fixture.finish(0, done: false)
        do {
            try await receiving.value
            XCTFail("A refused or interrupted response must fail even when it contains visible text and a complete tool call")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertTrue(tools.records.isEmpty, "A non-success stop cannot authorize a completed tool call")
        XCTAssertEqual(progress, ["preparing", "waiting"], "Refused tools must not appear as running or completed activity")
        XCTAssertEqual(fixture.requests.count, 1, "No tool result or follow-up request can escape a refused response")
        XCTAssertTrue(answer.contains("Checking "), "Already streamed text remains visible with the failure")
    }

    private func exercise(_ wire: Wire) async throws {
        let connection = try connection(wire)
        let tab = Tab(), tools = AIToolSession(tab: tab, localProvider: true)
        tools.setEnabled(true)
        defer { tools.dispose() }
        var answer = ""
        var progress: [String] = []
        let receiving = Task { @MainActor in
            for try await piece in self.client.agent(.openCode, model: connection.id, system: "Synthetic system", messages: [.init(role: .user, text: "Check status")], key: nil, connection: connection, tools: tools, onProgress: { event in
                await MainActor.run {
                    switch event {
                    case .preparing: progress.append("preparing")
                    case .waiting: progress.append("waiting")
                    case .toolStarted(let name, let input): progress.append(name)
                        XCTAssertFalse(input.command.text.isEmpty)
                    case .toolReturned: progress.append("returned")
                    case .answering: break
                    }
                }
            }) {
                answer += piece
            }
        }
        defer { receiving.cancel() }
        try await until { self.fixture.requests.count == 1 }
        XCTAssertEqual(progress, ["preparing", "waiting"], "Provider waiting is visible before any answer bytes")
        let request = try XCTUnwrap(fixture.requests.first)
        XCTAssertEqual(request.headers["Accept"] ?? request.headers["accept"], "text/event-stream")
        if wire == .gemini {
            XCTAssertTrue(request.url.contains(":streamGenerateContent"))
            XCTAssertTrue(request.url.contains("alt=sse"))
        } else { XCTAssertEqual(request.body["stream"] as? Bool, true) }

        for event in wire.opening { fixture.emit(event, to: 0) }
        fixture.emit(wire.text("Checking "), to: 0, fragmented: true)
        try await until { answer.contains("Checking ") }
        XCTAssertEqual(fixture.requests.count, 1, "The first text must arrive before the held response completes")
        XCTAssertTrue(tools.records.isEmpty)

        for event in wire.toolBeginning { fixture.emit(event, to: 0, fragmented: true) }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(tools.records.isEmpty, "Partial tool arguments cannot execute")
        for event in wire.toolEnding { fixture.emit(event, to: 0) }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(tools.records.isEmpty, "Even complete arguments wait for the provider's completed response")
        XCTAssertFalse(progress.contains("analysis_status"), "Unfinished tool calls cannot be reported as running")
        for event in wire.completedToolTurn { fixture.emit(event, to: 0) }
        fixture.finish(0, done: wire == .openAI)
        try await until { self.fixture.requests.count == 2 }
        XCTAssertEqual(tools.records.count, 1)
        XCTAssertEqual(tools.records.first?.tool, "analysis_status")
        XCTAssertEqual(progress, ["preparing", "waiting", "analysis_status", "returned", "waiting"], "Actual tool dispatch and follow-up wait appear before the final answer")
        let second = try XCTUnwrap(fixture.requests.last?.body)
        let serialized = String(decoding: try JSONSerialization.data(withJSONObject: second), as: UTF8.self)
        XCTAssertTrue(serialized.contains("evidence_id"))
        try assertHistory(second, wire: wire)

        for event in wire.finalOpening { fixture.emit(event, to: 1) }
        fixture.emit(wire.text("Verified."), to: 1, fragmented: true)
        try await until { answer.contains("Verified.") }
        for event in wire.completedAnswer { fixture.emit(event, to: 1) }
        fixture.finish(1, done: wire == .openAI)
        try await receiving.value
        XCTAssertEqual(fixture.requests.count, 2)
        XCTAssertEqual(answer.components(separatedBy: "Checking ").count - 1, 1)
        XCTAssertEqual(answer.components(separatedBy: "Verified.").count - 1, 1)
        XCTAssertFalse(answer.contains("internal fixture thought"))
        XCTAssertFalse(answer.contains("opaque-reasoning"))
        XCTAssertFalse(answer.contains("signature"))
    }

    private func assertHistory(_ request: [String: Any], wire: Wire) throws {
        switch wire {
        case .openAI:
            let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
            let assistant = try XCTUnwrap(messages.first { $0["role"] as? String == "assistant" })
            let calls = try XCTUnwrap(assistant["tool_calls"] as? [[String: Any]])
            XCTAssertEqual((calls.first?["function"] as? [String: Any])?["arguments"] as? String, "{}")
        case .responses:
            let items = try XCTUnwrap(request["input"] as? [[String: Any]])
            let reasoning = try XCTUnwrap(items.first { $0["type"] as? String == "reasoning" })
            XCTAssertEqual(reasoning["encrypted_content"] as? String, "opaque-reasoning")
            XCTAssertTrue(items.contains { $0["type"] as? String == "function_call_output" })
            XCTAssertEqual(items.first { $0["type"] as? String == "function_call" }?["arguments"] as? String, "{}")
        case .anthropic:
            let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
            let blocks = try XCTUnwrap(messages.first { $0["role"] as? String == "assistant" }?["content"] as? [[String: Any]])
            let thinking = try XCTUnwrap(blocks.first { $0["type"] as? String == "thinking" })
            XCTAssertEqual(thinking["thinking"] as? String, "internal fixture thought")
            XCTAssertEqual(thinking["signature"] as? String, "anthropic-signature")
            XCTAssertTrue(blocks.contains { $0["type"] as? String == "tool_use" })
        case .gemini:
            let contents = try XCTUnwrap(request["contents"] as? [[String: Any]])
            let parts = try XCTUnwrap(contents.first { $0["role"] as? String == "model" }?["parts"] as? [[String: Any]])
            let call = try XCTUnwrap(parts.first { $0["functionCall"] != nil })
            XCTAssertEqual(call["thoughtSignature"] as? String, "gemini-call-signature")
            let tail = try XCTUnwrap(parts.first { $0["thoughtSignature"] as? String == "gemini-tail-signature" })
            XCTAssertEqual(tail["text"] as? String, "")
            XCTAssertTrue(parts.contains { $0["thought"] as? Bool == true })
        }
    }

    private func connection(_ wire: Wire) throws -> OpenCodeAI.Connection {
        let config: [String: Any] = ["model": "fixture/model", "provider": ["fixture": ["npm": wire.package, "options": ["baseURL": "http://127.0.0.1:9911/v1", "apiKey": "synthetic-stream-key"], "models": ["model": ["name": "Fixture"]]]]]
        let file = folder.appendingPathComponent("provider.json")
        try JSONSerialization.data(withJSONObject: config).write(to: file)
        return try OpenCodeAI.connection(for: "fixture/model", files: [file], environment: [:])
    }
    private func until(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.timedOut)
    }

    private enum Wire {
        case openAI, responses, anthropic, gemini
        var package: String {
            switch self {
            case .openAI: return "@ai-sdk/openai-compatible"
            case .responses: return "@ai-sdk/openai"
            case .anthropic: return "@ai-sdk/anthropic"
            case .gemini: return "@ai-sdk/google"
            }
        }
        var reasoning: [String: Any] { ["type": "reasoning", "id": "reasoning-1", "summary": [], "encrypted_content": "opaque-reasoning"] }
        var prelude: [String: Any] { ["type": "message", "id": "prelude-1", "role": "assistant", "content": [["type": "output_text", "text": "Checking "]]] }
        var call: [String: Any] { ["type": "function_call", "id": "item-1", "call_id": "call-1", "name": "analysis_status", "arguments": "{}"] }
        var opening: [[String: Any]] {
            switch self {
            case .anthropic: return [
                ["type": "message_start", "message": ["role": "assistant", "content": []]],
                ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": "", "signature": ""]],
                ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "internal fixture thought"]],
                ["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "anthropic-signature"]],
                ["type": "content_block_stop", "index": 0],
                ["type": "content_block_start", "index": 1, "content_block": ["type": "text", "text": ""]]
            ]
            case .gemini: return [gemini(parts: [["text": "internal fixture thought", "thought": true]])]
            case .responses: return [["type": "response.output_item.added", "output_index": 0, "item": reasoning], ["type": "response.output_item.done", "output_index": 0, "item": reasoning], ["type": "response.output_item.added", "output_index": 1, "item": ["type": "message", "id": "prelude-1", "role": "assistant", "content": []]], ["type": "response.content_part.added", "output_index": 1, "content_index": 0, "part": ["type": "output_text", "text": ""]]]
            case .openAI: return []
            }
        }
        func text(_ value: String) -> [String: Any] {
            switch self {
            case .openAI: return ["choices": [["index": 0, "delta": ["content": value]]]]
            case .responses: return ["type": "response.output_text.delta", "output_index": value == "Verified." ? 0 : 1, "content_index": 0, "delta": value]
            case .anthropic: return ["type": "content_block_delta", "index": value == "Verified." ? 0 : 1, "delta": ["type": "text_delta", "text": value]]
            case .gemini: return gemini(parts: [["text": value]])
            }
        }
        var toolBeginning: [[String: Any]] {
            switch self {
            case .openAI: return [["choices": [["index": 0, "delta": ["tool_calls": [["index": 0, "id": "call-1", "type": "function", "function": ["name": "analysis_status", "arguments": "{"]]]]]]]]
            case .responses: return [["type": "response.output_item.done", "output_index": 1, "item": prelude], ["type": "response.output_item.added", "output_index": 2, "item": ["type": "function_call", "id": "item-1", "call_id": "call-1", "name": "analysis_status", "arguments": ""]], ["type": "response.function_call_arguments.delta", "output_index": 2, "item_id": "item-1", "delta": "{"]]
            case .anthropic: return [["type": "content_block_stop", "index": 1], ["type": "content_block_start", "index": 2, "content_block": ["type": "tool_use", "id": "call-1", "name": "analysis_status", "input": [:]]], ["type": "content_block_delta", "index": 2, "delta": ["type": "input_json_delta", "partial_json": "{"]]]
            case .gemini: return [gemini(parts: [["functionCall": ["id": "call-1", "name": "analysis_status", "args": [:]], "thoughtSignature": "gemini-call-signature"]])]
            }
        }
        var toolEnding: [[String: Any]] {
            switch self {
            case .openAI: return [["choices": [["index": 0, "delta": ["tool_calls": [["index": 0, "function": ["arguments": "}"]]]]]]]]
            case .responses: return [["type": "response.function_call_arguments.delta", "output_index": 2, "item_id": "item-1", "delta": "}"], ["type": "response.output_item.done", "output_index": 2, "item": call]]
            case .anthropic: return [["type": "content_block_delta", "index": 2, "delta": ["type": "input_json_delta", "partial_json": "}"]], ["type": "content_block_stop", "index": 2]]
            case .gemini: return [gemini(parts: [["text": "", "thoughtSignature": "gemini-tail-signature"]])]
            }
        }
        var completedToolTurn: [[String: Any]] {
            switch self {
            case .openAI: return [["choices": [["index": 0, "delta": [:], "finish_reason": "tool_calls"]]]]
            case .responses: return [["type": "response.completed", "response": ["status": "completed", "output": [reasoning, prelude, call]]]]
            case .anthropic: return [["type": "message_delta", "delta": ["stop_reason": "tool_use"]], ["type": "message_stop"]]
            case .gemini: return [["candidates": [["index": 0, "finishReason": "STOP"]]]]
            }
        }
        var finalOpening: [[String: Any]] {
            switch self {
            case .anthropic: return [["type": "message_start", "message": ["role": "assistant", "content": []]], ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]]]
            case .responses: return [["type": "response.output_item.added", "output_index": 0, "item": ["type": "message", "id": "final-1", "role": "assistant", "content": []]], ["type": "response.content_part.added", "output_index": 0, "content_index": 0, "part": ["type": "output_text", "text": ""]]]
            default: return []
            }
        }
        var completedAnswer: [[String: Any]] {
            switch self {
            case .openAI: return [["choices": [["index": 0, "delta": [:], "finish_reason": "stop"]]]]
            case .responses: return [["type": "response.completed", "response": ["status": "completed", "output": [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Verified."]]]]]]]
            case .anthropic: return [["type": "content_block_stop", "index": 0], ["type": "message_delta", "delta": ["stop_reason": "end_turn"]], ["type": "message_stop"]]
            case .gemini: return [["candidates": [["index": 0, "finishReason": "STOP"]]]]
            }
        }
        private func gemini(parts: [[String: Any]]) -> [String: Any] { ["candidates": [["index": 0, "content": ["role": "model", "parts": parts]]]] }
    }
}

private final class HeldAgentStream: @unchecked Sendable {
    struct Request { let url: String; let headers: [String: String]; let body: [String: Any] }
    private let queue = DispatchQueue(label: "AIClientStreamingTests.provider")
    private let lock = NSLock()
    private var keptRequests: [Request] = []
    private var protocols: [HeldAgentProtocol] = []
    var requests: [Request] { lock.withLock { keptRequests } }
    func accept(_ stream: HeldAgentProtocol) {
        do {
            let body = try Self.body(stream.request)
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
            lock.withLock {
                protocols.append(stream)
                keptRequests.append(Request(url: stream.request.url!.absoluteString, headers: stream.request.allHTTPHeaderFields ?? [:], body: object))
            }
            let response = HTTPURLResponse(url: stream.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            stream.receive(response)
        } catch { stream.fail(error) }
    }
    func emit(_ object: [String: Any], to index: Int, fragmented: Bool = false) {
        let bytes = Data("data: \(String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self))\n\n".utf8)
        queue.async { [self] in
            guard let stream = lock.withLock({ protocols.indices.contains(index) ? protocols[index] : nil }) else { return }
            if fragmented {
                for offset in stride(from: 0, to: bytes.count, by: 7) { stream.load(bytes.subdata(in: offset..<min(offset + 7, bytes.count))) }
            } else { stream.load(bytes) }
        }
    }
    func finish(_ index: Int, done: Bool) {
        queue.async { [self] in
            guard let stream = lock.withLock({ protocols.indices.contains(index) ? protocols[index] : nil }) else { return }
            if done { stream.load(Data("data: [DONE]\n\n".utf8)) }
            stream.finish()
        }
    }
    func stop() {
        lock.withLock { protocols }.forEach { $0.fail(URLError(.cancelled)) }
    }
    static func body(_ request: URLRequest) throws -> Data {
        if let bytes = request.httpBody { return bytes }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 8192)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count < 2_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
        }
        return data
    }
}
private final class HeldAgentProtocol: URLProtocol {
    static var fixture: HeldAgentStream?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "127.0.0.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.fixture?.accept(self) }
    private let stateLock = NSLock()
    private var ended = false
    func receive(_ response: URLResponse) { if stateLock.withLock({ !ended }) { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) } }
    func load(_ data: Data) { if stateLock.withLock({ !ended }) { client?.urlProtocol(self, didLoad: data) } }
    func finish() {
        guard stateLock.withLock({ if ended { return false }; ended = true; return true }) else { return }
        client?.urlProtocolDidFinishLoading(self)
    }
    func fail(_ error: Error) {
        guard stateLock.withLock({ if ended { return false }; ended = true; return true }) else { return }
        client?.urlProtocol(self, didFailWithError: error)
    }
    override func stopLoading() { stateLock.withLock { ended = true } }
}
