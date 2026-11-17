import Foundation
import XCTest
@testable import Search

final class AIStreamAccumulatorTests: XCTestCase {
    func testSSEFramingHandlesFragmentedUnicodeCRLFCommentsAndMultilineData() throws {
        let text = "\u{FEFF}: ping\r\nevent: example\r\ndata: {\"text\":\r\ndata: \"🇨🇦 hello\"}\r\n\r\n"
        var framer = AISSEFramer(), events = [AISSEFramer.Event]()
        for byte in text.utf8 { if let event = try framer.append(byte) { events.append(event) } }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].name, "example")
        let object = try JSONSerialization.jsonObject(with: Data(events[0].data.utf8)) as? [String: Any]
        XCTAssertEqual(object?["text"] as? String, "🇨🇦 hello")
        XCTAssertNil(try framer.finish())
    }
    func testSSERejectsOversizedRecordBeforeUnboundedLineAllocation() throws {
        var framer = AISSEFramer()
        for _ in 0..<AISSEFramer.maximumEventBytes { _ = try framer.append(65) }
        XCTAssertThrowsError(try framer.append(65))
    }
    func testChatParallelArgumentsAccumulateByIndexAndRequireTerminal() throws {
        var parser = AIStreamAccumulator(wire: .openAI)
        let text = try parser.consume(["choices": [["delta": ["content": "Checking "]]]])
        XCTAssertEqual(text, "Checking ")
        _ = try parser.consume(["choices": [["delta": ["tool_calls": [
            ["index": 1, "id": "second", "function": ["name": "two", "arguments": "{\"b\":"]],
            ["index": 0, "id": "first", "function": ["name": "one", "arguments": "{\"a\":"]]
        ]]]]])
        _ = try parser.consume(["choices": [["delta": ["tool_calls": [
            ["index": 0, "function": ["arguments": "1}"]], ["index": 1, "function": ["arguments": "2}"]]
        ]]]]])
        XCTAssertThrowsError(try parser.result(), "Valid JSON does not authorize execution before a terminal response.")
        try parser.doneSentinel()
        let message = ((try parser.result()["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
        let calls = try XCTUnwrap(message?["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.compactMap { $0["id"] as? String }, ["first", "second"])
        XCTAssertEqual((calls[1]["function"] as? [String: Any])?["arguments"] as? String, "{\"b\":2}")
        XCTAssertEqual(message?["content"] as? String, "Checking ")
    }
    func testMalformedOrTruncatedToolArgumentsNeverBecomeEmptyCall() throws {
        var parser = AIStreamAccumulator(wire: .openAI)
        _ = try parser.consume(["choices": [["delta": ["tool_calls": [["index": 0, "id": "call", "function": ["name": "tool", "arguments": "{\"path\":"]]]]]]])
        try parser.doneSentinel()
        XCTAssertThrowsError(try parser.result())
        XCTAssertThrowsError(try AIStreamAccumulator.objectArguments("[]"))
        XCTAssertThrowsError(try AIStreamAccumulator.objectArguments(""))
    }
    func testResponsesPreserveCompletedReasoningAndCanonicalCallSnapshot() throws {
        var parser = AIStreamAccumulator(wire: .responses)
        _ = try parser.consume(["type": "response.output_item.added", "output_index": 0, "item": ["type": "reasoning", "id": "reason"]])
        let reason: [String: Any] = ["type": "reasoning", "id": "reason", "summary": [], "encrypted_content": "opaque-signed-state"]
        _ = try parser.consume(["type": "response.output_item.done", "output_index": 0, "item": reason])
        _ = try parser.consume(["type": "response.output_item.added", "output_index": 1, "item": ["type": "function_call", "id": "fc", "call_id": "call", "name": "tool", "arguments": ""]])
        _ = try parser.consume(["type": "response.function_call_arguments.delta", "output_index": 1, "delta": "{"])
        _ = try parser.consume(["type": "response.function_call_arguments.delta", "output_index": 1, "delta": "}"])
        XCTAssertThrowsError(try parser.result())
        _ = try parser.consume(["type": "response.completed", "response": ["status": "completed"]])
        let output = try XCTUnwrap(parser.result()["output"] as? [[String: Any]])
        XCTAssertEqual(output[0]["encrypted_content"] as? String, "opaque-signed-state")
        XCTAssertEqual(output[1]["arguments"] as? String, "{}")
    }
    func testResponsesTerminalEventDoesNotEraseExplicitFailureStatus() throws {
        var parser = AIStreamAccumulator(wire: .responses)
        _ = try parser.consume(["type": "response.completed", "response": ["status": "incomplete", "output": [["type": "function_call", "call_id": "call", "name": "tool", "arguments": "{}"]]]])
        let result = try parser.result()
        XCTAssertEqual(result["status"] as? String, "incomplete")
        XCTAssertNotNil(AIClient.inspectionStopError(wire: .responses, result: result, answer: "", calls: 1))
    }
    func testResponsesTextWithoutFullFinalSnapshotStillHasVisibleFinalAnswer() throws {
        var parser = AIStreamAccumulator(wire: .responses)
        XCTAssertEqual(try parser.consume(["type": "response.output_text.delta", "delta": "Live "]), "Live ")
        XCTAssertEqual(try parser.consume(["type": "response.output_text.delta", "delta": "answer"]), "answer")
        _ = try parser.consume(["type": "response.completed", "response": ["status": "completed", "output": []]])
        let output = try XCTUnwrap(parser.result()["output"] as? [[String: Any]])
        XCTAssertEqual((output[0]["content"] as? [[String: Any]])?.first?["text"] as? String, "Live answer")
    }
    func testAnthropicSignedThinkingAndToolInputsAreReconstructedWithoutDisplayingThoughts() throws {
        var parser = AIStreamAccumulator(wire: .anthropic)
        XCTAssertEqual(try parser.consume(["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]]), "")
        XCTAssertEqual(try parser.consume(["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "hidden"]]), "")
        _ = try parser.consume(["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "signed"]])
        _ = try parser.consume(["type": "content_block_stop", "index": 0])
        _ = try parser.consume(["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "call", "name": "tool", "input": [:]]])
        _ = try parser.consume(["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": "{\"ok\":true}"]])
        _ = try parser.consume(["type": "content_block_stop", "index": 1])
        XCTAssertThrowsError(try parser.result())
        _ = try parser.consume(["type": "message_delta", "delta": ["stop_reason": "tool_use"]])
        _ = try parser.consume(["type": "message_stop"])
        let blocks = try XCTUnwrap(parser.result()["content"] as? [[String: Any]])
        XCTAssertEqual(blocks[0]["thinking"] as? String, "hidden")
        XCTAssertEqual(blocks[0]["signature"] as? String, "signed")
        XCTAssertEqual((blocks[1]["input"] as? [String: Any])?["ok"] as? Bool, true)
        XCTAssertEqual(parser.answer, "")
    }
    func testExplicitRefusalOrUnsuccessfulStopNeverAuthorizesCallsButVisibleRefusalCanDisplay() {
        let anthropic: [String: Any] = ["stop_reason": "refusal"]
        XCTAssertNotNil(AIClient.inspectionStopError(wire: .anthropic, result: anthropic, answer: "I cannot do that.", calls: 1))
        XCTAssertNil(AIClient.inspectionStopError(wire: .anthropic, result: anthropic, answer: "I cannot do that.", calls: 0))
        let gemini: [String: Any] = ["candidates": [["finishReason": "OTHER"]]]
        XCTAssertNotNil(AIClient.inspectionStopError(wire: .gemini, result: gemini, answer: "Checking status", calls: 1))
        for wire in [AIProvider.Wire.openAI, .responses, .anthropic, .gemini] {
            XCTAssertNil(AIClient.inspectionStopError(wire: wire, result: [:], answer: "", calls: 1), "Metadata-free JSON gateways remain compatible")
        }
    }
    func testGeminiTerminalCannotAuthorizeLaterCallOrContent() throws {
        var parser = AIStreamAccumulator(wire: .gemini)
        _ = try parser.consume(["candidates": [["finishReason": "STOP", "content": ["parts": [["text": "Done.", "thoughtSignature": "terminal-signature"]]]]]])
        XCTAssertEqual(try parser.consume(["candidates": [["content": ["parts": [["functionCall": ["name": "tool", "args": [:]]], ["text": "late text"]]]]]]), "")
        let candidate = try XCTUnwrap((parser.result()["candidates"] as? [[String: Any]])?.first)
        let parts = try XCTUnwrap((candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]])
        XCTAssertFalse(parts.contains { $0["functionCall"] != nil })
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0]["thoughtSignature"] as? String, "terminal-signature")
        XCTAssertEqual(parser.answer, "Done.")
    }
    func testGeminiPreservesSignatureOnlyPartAndRejectsUnsupportedPartialArguments() throws {
        var parser = AIStreamAccumulator(wire: .gemini)
        XCTAssertEqual(try parser.consume(["candidates": [["content": ["parts": [["text": "Visible"], ["text": "hidden", "thought": true]]]]]]), "Visible")
        _ = try parser.consume(["candidates": [["content": ["parts": [["functionCall": ["name": "tool", "args": [:]], "thoughtSignature": "call-signature"]]]]]])
        _ = try parser.consume(["candidates": [["finishReason": "STOP", "content": ["parts": [["text": "", "thoughtSignature": "tail-signature"]]]]]])
        let candidate = try XCTUnwrap((parser.result()["candidates"] as? [[String: Any]])?.first)
        let parts = try XCTUnwrap((candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.last?["thoughtSignature"] as? String, "tail-signature")
        var unsupported = AIStreamAccumulator(wire: .gemini)
        XCTAssertThrowsError(try unsupported.consume(["candidates": [["content": ["parts": [["functionCall": ["name": "tool", "partialArgs": [], "willContinue": true]]]]]]]))
    }
}
