import Foundation

extension AIClient {
    /// Non-streaming tool responses use terminal metadata rather than SSE
    /// events. A successful HTTP response alone does not finish an answer.
    static func inspectionStopError(wire: AIProvider.Wire, result: [String: Any], answer: String, calls: Int) -> AIError? {
        let visible = !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let limited = AIError.unreachable("The provider reached its response limit before finishing. The recorded actions are still available; you can ask it to continue.")
        let blocked = AIError.unreachable("The provider stopped this answer because of its content filter. The recorded actions are still available.")
        switch wire {
        case .responses:
            switch result["status"] as? String {
            case "incomplete":
                let reason = (result["incomplete_details"] as? [String: Any])?["reason"] as? String
                if reason == "max_output_tokens" { return limited }
                if reason == "content_filter" { return blocked }
                return .unreachable("The provider stopped before finishing its answer. The recorded actions are still available.")
            case "failed", "cancelled", "canceled":
                return .unreachable("The provider did not finish this answer. The recorded actions are still available.")
            case "queued", "in_progress":
                return .unreachable("The provider returned an unfinished response. The recorded actions are still available.")
            default: break
            }
        case .openAI:
            let choice = (result["choices"] as? [[String: Any]])?.first
            switch choice?["finish_reason"] as? String {
            case "length": return limited
            case "content_filter": return blocked
            case "tool_calls", "function_call":
                if calls == 0 { return .unreachable("The provider requested a tool without returning a readable tool call.") }
            default: break
            }
        case .anthropic:
            switch result["stop_reason"] as? String {
            case "max_tokens", "model_context_window_exceeded": return limited
            case "pause_turn":
                return .unreachable("The provider paused before finishing its answer. The recorded actions are still available; you can ask it to continue.")
            case "refusal" where !visible:
                return .unreachable("The provider declined this request without returning an explanation.")
            default: break
            }
        case .gemini:
            if let feedback = result["promptFeedback"] as? [String: Any], feedback["blockReason"] is String { return blocked }
            let candidate = (result["candidates"] as? [[String: Any]])?.first
            switch candidate?["finishReason"] as? String {
            case "MAX_TOKENS": return limited
            case "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII": return blocked
            case "MALFORMED_FUNCTION_CALL", "UNEXPECTED_TOOL_CALL":
                return .unreachable("The provider stopped after returning an unreadable tool call.")
            default: break
            }
        }
        if calls == 0, !visible {
            return .unreachable("The provider stopped without returning an answer. The recorded actions are still available; you can ask it to continue.")
        }
        return nil
    }
}
