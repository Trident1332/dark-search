import Foundation

/// Bounded SSE framing independent of URLSession's unbounded lines iterator.
/// Multi-line data fields and CRLF records are decoded only after a complete
/// event; UTF-8 scalars may be fragmented at any network byte boundary.
struct AISSEFramer {
    struct Event { let name: String; let data: String }
    static let maximumEventBytes = 2_000_000
    static let maximumResponseBytes = 8_000_000
    private var line = Data()
    private var data = Data()
    private var name = ""
    private var received = 0
    private var firstLine = true
    mutating func append(_ byte: UInt8) throws -> Event? {
        received += 1
        guard received <= Self.maximumResponseBytes else { throw AIError.unreadable }
        if byte != 10 {
            guard line.count < Self.maximumEventBytes else { throw AIError.unreadable }
            line.append(byte); return nil
        }
        return try endLine()
    }
    mutating func finish() throws -> Event? {
        if !line.isEmpty, let event = try endLine() { return event }
        return try flush()
    }
    private mutating func endLine() throws -> Event? {
        if line.last == 13 { line.removeLast() }
        if firstLine, line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
        firstLine = false
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty { return try flush() }
        guard let value = String(data: line, encoding: .utf8) else { throw AIError.unreadable }
        if value.hasPrefix(":") { return nil }
        let split = value.firstIndex(of: ":")
        let field = split.map { String(value[..<$0]) } ?? value
        var contents = split.map { String(value[value.index(after: $0)...]) } ?? ""
        if contents.hasPrefix(" ") { contents.removeFirst() }
        if field == "event" { name = contents }
        if field == "data" {
            let bytes = Data(contents.utf8)
            guard data.count + bytes.count + 1 <= Self.maximumEventBytes else { throw AIError.unreadable }
            data.append(bytes); data.append(10)
        }
        return nil
    }
    private mutating func flush() throws -> Event? {
        defer { data.removeAll(keepingCapacity: true); name = "" }
        guard !data.isEmpty else { return nil }
        data.removeLast()
        guard let text = String(data: data, encoding: .utf8) else { throw AIError.unreadable }
        return Event(name: name, data: text)
    }
}

/// Reconstructs one provider response while exposing answer deltas immediately.
/// Function inputs are data until the entire response terminates successfully;
/// signed/opaque reasoning remains in provider history and is never displayed.
struct AIStreamAccumulator {
    let wire: AIProvider.Wire
    private(set) var terminal = false
    private(set) var answer = ""
    private var root: [String: Any] = [:]
    private var message: [String: Any] = ["role": "assistant", "content": ""]
    private var calls: [Int: [String: Any]] = [:]
    private var items: [Int: [String: Any]] = [:]
    private var blocks: [Int: [String: Any]] = [:]
    private var argumentFragments: [Int: String] = [:]
    private var closedBlocks: Set<Int> = []
    private var reasoningDetails: [Int: [String: Any]] = [:]
    private var geminiParts: [[String: Any]] = []
    private var candidate: [String: Any] = [:]
    private var finishReason: String?

    mutating func doneSentinel() throws {
        // [DONE] belongs to compatible Chat Completions streams. Other wires
        // carry a typed terminal event and must not execute truncated calls.
        guard wire == .openAI else { throw AIError.unreadable }
        terminal = true
    }
    mutating func consume(_ json: [String: Any], event: String = "") throws -> String {
        guard !terminal else { return "" }
        let piece: String
        switch wire {
        case .openAI: piece = try chat(json)
        case .responses: piece = try responses(json, event: event)
        case .anthropic: piece = try anthropic(json, event: event)
        case .gemini: piece = try gemini(json)
        }
        guard answer.utf8.count + piece.utf8.count <= AISSEFramer.maximumResponseBytes else { throw AIError.unreadable }
        answer += piece
        return piece
    }
    mutating func result() throws -> [String: Any] {
        guard terminal else { throw AIError.unreadable }
        switch wire {
        case .openAI:
            if !calls.isEmpty {
                message["tool_calls"] = try calls.keys.sorted().map { index -> [String: Any] in
                    let item = calls[index]!
                    guard let id = item["id"] as? String, !id.isEmpty,
                          let function = item["function"] as? [String: Any],
                          let name = function["name"] as? String, !name.isEmpty,
                          let args = function["arguments"] as? String else { throw AIError.unreadable }
                    _ = try Self.objectArguments(args)
                    return item
                }
            }
            if !reasoningDetails.isEmpty { message["reasoning_details"] = reasoningDetails.keys.sorted().compactMap { reasoningDetails[$0] } }
            var choice: [String: Any] = ["message": message]
            if let finishReason { choice["finish_reason"] = finishReason }
            return ["choices": [choice]]
        case .responses:
            let snapshot = root["output"] as? [[String: Any]] ?? []
            var output = snapshot.isEmpty ? items.keys.sorted().compactMap { items[$0] } : snapshot
            let visible = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }.contains { ($0["text"] as? String)?.isEmpty == false || ($0["refusal"] as? String)?.isEmpty == false }
            if !visible, !answer.isEmpty { output.append(["type": "message", "role": "assistant", "content": [["type": "output_text", "text": answer]]]) }
            for item in output where item["type"] as? String == "function_call" {
                guard let id = item["call_id"] as? String, !id.isEmpty,
                      let name = item["name"] as? String, !name.isEmpty,
                      let args = item["arguments"] as? String else { throw AIError.unreadable }
                _ = try Self.objectArguments(args)
            }
            root["output"] = output
            return root
        case .anthropic:
            guard closedBlocks.count == blocks.count else { throw AIError.unreadable }
            root["content"] = blocks.keys.sorted().compactMap { blocks[$0] }
            return root
        case .gemini:
            candidate["content"] = ["role": "model", "parts": geminiParts]
            root["candidates"] = [candidate]
            return root
        }
    }
    static func objectArguments(_ value: String) throws -> [String: Any] {
        guard value.utf8.count <= 1_000_000,
              let object = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else { throw AIError.unreadable }
        return object
    }
    private static func index(_ value: Any?, fallback: Int? = nil) throws -> Int {
        guard let result = (value as? Int) ?? fallback, result >= 0, result < 256 else { throw AIError.unreadable }
        return result
    }
    private mutating func chat(_ json: [String: Any]) throws -> String {
        guard let choice = (json["choices"] as? [[String: Any]])?.first else { return "" } // usage-only event
        if let index = choice["index"] as? Int, index != 0 { return "" }
        let delta = choice["delta"] as? [String: Any] ?? [:]
        var text = delta["content"] as? String ?? (delta["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
        if let refusal = delta["refusal"] as? String {
            message["refusal"] = (message["refusal"] as? String ?? "") + refusal
            text += refusal
        }
        message["content"] = (message["content"] as? String ?? "") + text
        for key in ["reasoning_content", "reasoning"] {
            if let fragment = delta[key] as? String { message[key] = (message[key] as? String ?? "") + fragment }
        }
        for (position, detail) in (delta["reasoning_details"] as? [[String: Any]] ?? []).enumerated() {
            let index = try Self.index(detail["index"], fallback: position)
            var kept = reasoningDetails[index] ?? [:]
            for (key, value) in detail {
                if ["text", "data", "summary", "signature"].contains(key), let fragment = value as? String { kept[key] = (kept[key] as? String ?? "") + fragment }
                else { kept[key] = value }
            }
            reasoningDetails[index] = kept
        }
        for fragment in delta["tool_calls"] as? [[String: Any]] ?? [] {
            let index = try Self.index(fragment["index"], fallback: calls.count <= 1 ? 0 : nil)
            var item = calls[index] ?? ["type": "function"]
            if let id = fragment["id"] as? String { item["id"] = (item["id"] as? String ?? "") + id }
            var function = item["function"] as? [String: Any] ?? [:]
            for key in ["name", "arguments"] {
                if let fragment = (fragment["function"] as? [String: Any])?[key] as? String {
                    let combined = (function[key] as? String ?? "") + fragment
                    guard combined.utf8.count <= 1_000_000 else { throw AIError.unreadable }
                    function[key] = combined
                }
            }
            item["function"] = function; calls[index] = item
        }
        if let reason = choice["finish_reason"] as? String { finishReason = reason; terminal = true }
        return text
    }
    private mutating func responses(_ json: [String: Any], event: String) throws -> String {
        let type = json["type"] as? String ?? event
        switch type {
        case "response.created", "response.in_progress":
            if let response = json["response"] as? [String: Any] { root.merge(response) { _, new in new }; root["output"] = nil }
        case "response.output_item.added", "response.output_item.done":
            let index = try Self.index(json["output_index"])
            guard let item = json["item"] as? [String: Any] else { throw AIError.unreadable }
            items[index] = item
        case "response.function_call_arguments.delta":
            let index = try Self.index(json["output_index"])
            guard var item = items[index], item["type"] as? String == "function_call", let delta = json["delta"] as? String else { throw AIError.unreadable }
            let arguments = (item["arguments"] as? String ?? "") + delta
            guard arguments.utf8.count <= 1_000_000 else { throw AIError.unreadable }
            item["arguments"] = arguments; items[index] = item
        case "response.function_call_arguments.done":
            let index = try Self.index(json["output_index"])
            guard var item = items[index], let args = json["arguments"] as? String else { throw AIError.unreadable }
            item["arguments"] = args; items[index] = item
        case "response.content_part.added", "response.content_part.done":
            let index = try Self.index(json["output_index"]), partIndex = try Self.index(json["content_index"])
            guard var item = items[index], let part = json["part"] as? [String: Any] else { throw AIError.unreadable }
            var content = item["content"] as? [[String: Any]] ?? []
            while content.count <= partIndex { content.append([:]) }
            content[partIndex] = part; item["content"] = content; items[index] = item
        case "response.output_text.delta", "response.refusal.delta":
            guard let text = json["delta"] as? String else { throw AIError.unreadable }
            if let index = json["output_index"] as? Int, var item = items[index] {
                let partIndex = try Self.index(json["content_index"], fallback: 0)
                var content = item["content"] as? [[String: Any]] ?? []
                while content.count <= partIndex { content.append([:]) }
                let key = type == "response.refusal.delta" ? "refusal" : "text"
                content[partIndex]["type"] = key == "text" ? "output_text" : "refusal"
                content[partIndex][key] = (content[partIndex][key] as? String ?? "") + text
                item["content"] = content; items[index] = item
            }
            return text
        case "response.completed":
            if let response = json["response"] as? [String: Any] { root.merge(response) { _, new in new } }
            // Preserve an explicit non-success status for the dispatch gate,
            // even if a compatible gateway mislabeled this terminal event.
            root["status"] = (json["response"] as? [String: Any])?["status"] as? String ?? "completed"
            terminal = true
        case "response.failed", "response.incomplete":
            // AIClient.failure consumes these before this accumulator.
            throw AIError.unreadable
        default: break // Usage/reasoning deltas finish in output_item.done.
        }
        return ""
    }
    private mutating func anthropic(_ json: [String: Any], event: String) throws -> String {
        let type = json["type"] as? String ?? event
        switch type {
        case "message_start":
            root = json["message"] as? [String: Any] ?? [:]
        case "content_block_start":
            let index = try Self.index(json["index"])
            guard blocks[index] == nil, let block = json["content_block"] as? [String: Any] else { throw AIError.unreadable }
            blocks[index] = block
            return block["type"] as? String == "text" ? (block["text"] as? String ?? "") : ""
        case "content_block_delta":
            let index = try Self.index(json["index"])
            guard !closedBlocks.contains(index), var block = blocks[index], let delta = json["delta"] as? [String: Any] else { throw AIError.unreadable }
            var text = ""
            switch delta["type"] as? String {
            case "text_delta":
                text = delta["text"] as? String ?? ""; block["text"] = (block["text"] as? String ?? "") + text
            case "input_json_delta":
                let combined = (argumentFragments[index] ?? "") + (delta["partial_json"] as? String ?? "")
                guard combined.utf8.count <= 1_000_000 else { throw AIError.unreadable }; argumentFragments[index] = combined
            case "thinking_delta": block["thinking"] = (block["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
            case "signature_delta": block["signature"] = (block["signature"] as? String ?? "") + (delta["signature"] as? String ?? "")
            default: break
            }
            blocks[index] = block; return text
        case "content_block_stop":
            let index = try Self.index(json["index"])
            guard var block = blocks[index], closedBlocks.insert(index).inserted else { throw AIError.unreadable }
            if block["type"] as? String == "tool_use" {
                if let args = argumentFragments[index] { block["input"] = try Self.objectArguments(args) }
                guard block["input"] is [String: Any], let id = block["id"] as? String, !id.isEmpty,
                      let name = block["name"] as? String, !name.isEmpty else { throw AIError.unreadable }
            }
            blocks[index] = block
        case "message_delta": if let delta = json["delta"] as? [String: Any] { root.merge(delta) { _, new in new } }
        case "message_stop": terminal = true
        default: break
        }
        return ""
    }
    private mutating func gemini(_ json: [String: Any]) throws -> String {
        if let feedback = json["promptFeedback"] { root["promptFeedback"] = feedback }
        guard let value = (json["candidates"] as? [[String: Any]])?.first else {
            if root["promptFeedback"] != nil { terminal = true }
            return ""
        }
        let parts = (value["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        for part in parts {
            if let call = part["functionCall"] as? [String: Any] {
                guard call["partialArgs"] == nil, call["willContinue"] == nil,
                      let name = call["name"] as? String, !name.isEmpty,
                      call["args"] == nil || call["args"] is [String: Any] else { throw AIError.unreadable }
            }
        }
        geminiParts.append(contentsOf: parts)
        for (key, value) in value where key != "content" { candidate[key] = value }
        if value["finishReason"] is String { terminal = true }
        return parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
    }
}
