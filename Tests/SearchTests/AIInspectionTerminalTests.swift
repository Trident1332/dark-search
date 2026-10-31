import AppKit
import Foundation
import XCTest
@testable import Search

final class AIInspectionTerminalTests: XCTestCase {
    func testResponseLimitMetadataIsNotSuccessfulCompletionOnAnyWire() {
        let fixtures: [(AIProvider.Wire, [String: Any])] = [
            (.responses, ["status": "incomplete", "incomplete_details": ["reason": "max_output_tokens"]]),
            (.openAI, ["choices": [["finish_reason": "length"]]]),
            (.anthropic, ["stop_reason": "max_tokens"]),
            (.gemini, ["candidates": [["finishReason": "MAX_TOKENS"]]])
        ]
        for (wire, result) in fixtures {
            XCTAssertNotNil(AIClient.inspectionStopError(wire: wire, result: result, answer: "", calls: 0))
            XCTAssertNotNil(AIClient.inspectionStopError(wire: wire, result: result, answer: "Partial answer", calls: 0),
                            "A partial answer must keep its terminal failure visible")
        }
    }

    func testFilteringAndCanceledResponseMetadataReachTheCaller() {
        for (wire, result): (AIProvider.Wire, [String: Any]) in [
            (.responses, ["status": "cancelled"]),
            (.responses, ["status": "incomplete", "incomplete_details": ["reason": "content_filter"]]),
            (.openAI, ["choices": [["finish_reason": "content_filter"]]]),
            (.gemini, ["candidates": [["finishReason": "SAFETY"]]]),
            (.gemini, ["candidates": [["finishReason": "RECITATION"]]])
        ] {
            XCTAssertNotNil(AIClient.inspectionStopError(wire: wire, result: result, answer: "Partial", calls: 0))
        }
    }

    func testEmptyOrWhitespaceTerminalAnswerNeverSucceeds() {
        for wire in [AIProvider.Wire.responses, .openAI, .anthropic, .gemini] {
            for text in ["", " \n\t", "\u{2003}\r\n"] {
                XCTAssertNotNil(AIClient.inspectionStopError(wire: wire, result: [:], answer: text, calls: 0))
            }
            XCTAssertNil(AIClient.inspectionStopError(wire: wire, result: [:], answer: "", calls: 1),
                         "A valid tool round continues without requiring answer text")
            XCTAssertNil(AIClient.inspectionStopError(wire: wire, result: [:], answer: "A final answer", calls: 0))
        }
    }

    func testExecutionDigestKeepsRecentEvidenceAndFailureWithinItsTotalLimit() {
        var history = AIExecutionHistory()
        for index in 0..<60 {
            history.append(AIInspectionActivity(tool: "fixture_tool_\(index)",
                arguments: "fixture_argument_\(index) " + String(repeating: "🙂", count: 2000),
                result: "fixture_result_\(index) " + String(repeating: "🙂", count: 4000)))
        }
        history.recordOutcome("Synthetic provider response limit")
        let context = history.context
        XCTAssertEqual(history.totalCount, 60)
        XCTAssertLessThanOrEqual(history.retainedCount, 20)
        XCTAssertLessThanOrEqual(context.utf16.count, 8000)
        XCTAssertTrue(context.contains("fixture_tool_59"))
        XCTAssertTrue(context.contains("fixture_result_59"))
        XCTAssertTrue(context.contains("Synthetic provider response limit"))
        XCTAssertNotNil(context.range(of: "truncat", options: .caseInsensitive), "A shortened execution digest must identify its missing detail")
        XCTAssertNotNil(context.range(of: "untrusted", options: .caseInsensitive))
        history.recordOutcome(nil)
        XCTAssertTrue(history.context.contains("Synthetic provider response limit"), "A later completion must not erase the app's last failure evidence")
        XCTAssertLessThanOrEqual(history.context.utf16.count, 8000)
    }
}

/// Runs the actual non-streaming inspection request/parser against synthetic
/// HTTP responses, with a URLProtocol that never leaves this process.
@MainActor
final class AIInspectionTerminalRequestTests: XCTestCase {
    private var previousMock: URL?
    private var client: AIClient!

    override class func setUp() {
        setenv("SEARCH_PROBE", "ai-terminal-tests-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        _ = Shared.prefs
        Proxy.shared.automaticTarget = nil
        Proxy.shared.take(ProxySetup())
        for _ in 0..<100 where Proxy.shared.changingContent { try await Task.sleep(for: .milliseconds(20)) }
        previousMock = AIProvider.mock
        AIProvider.mock = URL(string: "http://127.0.0.1:1/")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIInspectionTerminalProtocol.self]
        client = AIClient(configuration: configuration)
        try await super.setUp()
    }

    override func tearDown() async throws {
        client?.session.invalidateAndCancel()
        client = nil
        AIInspectionTerminalProtocol.handler = nil
        AIProvider.mock = previousMock
        try await super.tearDown()
    }

    func testPartialTextIsDeliveredBeforeLengthFailure() async throws {
        AIInspectionTerminalProtocol.handler = { _ in
            ["choices": [["finish_reason": "length", "message": ["role": "assistant", "content": "Partial fixture answer"]]]]
        }
        var pieces = [String]()
        do {
            for try await piece in stream() { pieces.append(piece) }
            XCTFail("A response-length terminal state must throw after yielding its partial answer")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertEqual(pieces.joined(), "Partial fixture answer")
    }

    func testRefusalTextIsReturnedInsteadOfAnEmptySuccessfulAnswer() async throws {
        AIInspectionTerminalProtocol.handler = { _ in
            ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": NSNull(), "refusal": "Synthetic provider refusal"]]]]
        }
        var answer = ""
        for try await piece in stream() { answer += piece }
        XCTAssertEqual(answer, "Synthetic provider refusal")
    }

    func testToolEvidenceIsReportedBeforeAnEmptyTerminalResponse() async throws {
        var count = 0
        var lastRequest: [String: Any] = [:]
        AIInspectionTerminalProtocol.handler = { request in
            count += 1
            lastRequest = try JSONSerialization.jsonObject(with: AIInspectionTerminalProtocol.body(request)) as! [String: Any]
            if count == 1 {
                return ["choices": [["finish_reason": "tool_calls", "message": ["role": "assistant", "content": NSNull(),
                    "tool_calls": [["id": "fixture-tool", "type": "function", "function": ["name": "read_inspection", "arguments": "{\"part\":\"index\"}"]]]]]]]
            }
            return ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": " \n"]]]]
        }
        let activity = AIInspectionActivityRecorder()
        do {
            for try await _ in stream(priorActivity: "APP_OWNED_PRIOR_ACTIVITY_FIXTURE", onToolResult: { entry in activity.append(entry) }) {}
            XCTFail("A tool sequence must not silently end with an empty answer")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(activity.values.count, 1)
        XCTAssertEqual(activity.values.first?.tool, "read_inspection")
        XCTAssertFalse(activity.values.first?.result.isEmpty ?? true)
        let messages = try XCTUnwrap(lastRequest["messages"] as? [[String: Any]])
        XCTAssertTrue(messages.contains { $0["role"] as? String == "user" && $0["content"] as? String == "ORIGINAL_USER_REQUEST_FIXTURE" })
        XCTAssertTrue(messages.contains { $0["role"] as? String == "system" && ($0["content"] as? String ?? "").contains("APP_OWNED_PRIOR_ACTIVITY_FIXTURE") })
    }

    private func stream(priorActivity: String? = nil,
                        onToolResult: (@Sendable (AIInspectionActivity) async -> Void)? = nil) -> AsyncThrowingStream<String, Error> {
        let snapshot = try! AIInspectionSnapshot(networkJSON: "{\"records\":[]}", pageJSON: "{}")
        return client.inspect(.openAI, model: "synthetic-model", system: "Synthetic system instruction",
            messages: [.init(role: .user, text: "ORIGINAL_USER_REQUEST_FIXTURE")], key: "synthetic-terminal-key",
            connection: nil, snapshot: snapshot, live: AIInspection(), priorActivity: priorActivity, onToolResult: onToolResult)
    }
}

private final class AIInspectionActivityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = [AIInspectionActivity]()
    func append(_ entry: AIInspectionActivity) { lock.withLock { storage.append(entry) } }
    var values: [AIInspectionActivity] { lock.withLock { storage } }
}

private final class AIInspectionTerminalProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> [String: Any])?
    static func body(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
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
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "127.0.0.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let body = try Self.handler?(request) ?? ["error": "Missing synthetic response"]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
