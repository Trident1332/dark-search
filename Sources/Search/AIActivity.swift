import SwiftUI

/// Actual tool activity, never model reasoning. Raw commands and results are
/// bounded, held in memory, and shown only when the person expands a step.
enum AIActivityEvent: Sendable {
    case preparing, waiting, answering
    case toolStarted(String, input: AIActivity.Input = .empty)
    case toolReturned(AIActivity.Output = .empty)
}

struct AIActivity: Equatable {
    static let retainedLimit = 120
    enum Phase: String { case preparing, waiting, tool, answering, finished }
    struct Step: Identifiable, Equatable {
        let id = UUID()
        let number: Int
        let title: String
        let input: Input
        var output: Output?
        var returned = false
        var issue: Bool { output?.issue == true }
    }
    private(set) var phase = Phase.waiting
    private(set) var since = Date()
    private(set) var steps: [Step] = []
    private(set) var totalSteps = 0

    mutating func receive(_ event: AIActivityEvent, at date: Date = Date()) {
        guard phase != .finished else { return }
        let next: Phase
        switch event {
        case .preparing: next = .preparing
        case .waiting: next = .waiting
        case .answering: next = .answering
        case .toolStarted(let name, let input):
            totalSteps += 1
            steps.append(Step(number: totalSteps, title: Self.title(for: name), input: input))
            if steps.count > Self.retainedLimit { steps.removeFirst(steps.count - Self.retainedLimit) }
            next = .tool
        case .toolReturned(let output):
            if !steps.isEmpty {
                steps[steps.count - 1].returned = true
                steps[steps.count - 1].output = output
            }
            return
        }
        if phase != next || next == .tool { since = date }
        phase = next
    }

    mutating func finish() { phase = .finished }

    func status(at date: Date) -> String {
        let elapsed = max(0, Int(date.timeIntervalSince(since)))
        let title: String
        switch phase {
        case .preparing: title = "Preparing tools"
        case .waiting: title = elapsed >= 30 ? "Still waiting for the provider" : "Waiting for the provider"
        case .tool: title = "Running the current step"
        case .answering: title = "Receiving the answer"
        case .finished: return "Finished"
        }
        return "\(title) · \(elapsed)s"
    }

    static func title(for tool: String) -> String {
        switch tool {
        case "analysis_status", "local_tools_status": return "Check available tools"
        case "browser_snapshot": return "Read the page"
        case "browser_evaluate", "run_console": return "Run page JavaScript"
        case "read_inspection": return "Read page inspection"
        case "inspect_object": return "Inspect a page object"
        case "read_selected_text": return "Read the selected text"
        case "replace_selected_text": return "Replace the selected text"
        case "read_tool_evidence": return "Read more tool results"
        case "browser_fetch": return "Check a page request"
        case "browser_click": return "Click a page control"
        case "browser_fill": return "Fill a field"
        case "browser_assert": return "Check the result"
        case "browser_wait": return "Wait for the page"
        case "browser_select": return "Select an option"
        case "browser_press": return "Press a key"
        case "browser_scroll": return "Scroll the page"
        case "repository_read": return "Read the repository"
        default:
            if tool.hasPrefix("browser_") { return "Use a page tool" }
            if tool.hasPrefix("rea__") { return "Analyze the attached file" }
            if tool.hasPrefix("serena__") { return "Read source code" }
            return "Run an analysis tool"
        }
    }
}

/// Build display excerpts before crossing to the main actor. A result is not
/// re-parsed or serialized from SwiftUI's body or on each streamed token.
extension AIActivity {
    struct Excerpt: Equatable, Sendable {
        let text: String
        let truncated: Bool
        init(_ text: String, limit: Int, partial: Bool = false) {
            truncated = partial || text.utf8.count > limit
            if text.utf8.count <= limit { self.text = text; return }
            var bytes = Array(text.utf8.prefix(limit))
            while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
            self.text = String(bytes: bytes, encoding: .utf8) ?? ""
        }
    }
    struct Input: Equatable, Sendable {
        static let empty = Input(tool: "", arguments: [:])
        let command: Excerpt
        let summary: String
        init(tool: String, arguments: [String: Any]) {
            let script = arguments["code"] as? String ?? arguments["expression"] as? String
            if ["browser_evaluate", "run_console"].contains(tool), let script {
                var parameters = arguments
                parameters.removeValue(forKey: "code"); parameters.removeValue(forKey: "expression")
                command = Excerpt(script + (parameters.isEmpty ? "" : "\n\nParameters:\n" + AIActivity.pretty(parameters)), limit: 4096)
                // Fixed labels describe code features without exposing literal
                // field values, tokens or credentials in a collapsed row.
                var scopes: [String] = []
                if script.contains("fetch") || script.contains("XMLHttpRequest") { scopes.append("network requests") }
                if script.contains("document.cookie") { scopes.append("cookies") }
                if script.contains("localStorage") || script.contains("sessionStorage") { scopes.append("browser storage") }
                if script.contains("querySelector") || script.contains("getElement") || script.contains("document.body") { scopes.append("page elements") }
                if script.contains("location") { scopes.append("page address") }
                summary = scopes.isEmpty ? "Expand to view the script and its result" : "Script · " + scopes.joined(separator: ", ")
            } else {
                command = Excerpt(AIActivity.pretty(arguments), limit: 4096)
                let part = arguments["part"] as? String ?? ""
                summary = tool == "read_inspection" && ["index", "targets", "dom", "state", "console", "sockets", "request", "response", "body", "events"].contains(part)
                    ? "Inspection · " + part : "Expand to view the input and result"
            }
        }
    }
    struct Output: Equatable, Sendable {
        static let empty = Output(raw: "")
        let result: Excerpt
        let issue: Bool
        init(raw: String) {
            var text = raw
            var object = AIActivity.object(raw)
            var partial = false
            if let envelope = object, envelope["evidence_id"] is String, let data = envelope["data"] as? String {
                text = data
                partial = envelope["more"] as? Bool == true
                object = partial ? nil : AIActivity.object(data)
            }
            issue = object.map {
                ($0["error"] != nil && !($0["error"] is NSNull)) || $0["passed"] as? Bool == false
                    || $0["wasThrown"] as? Bool == true || $0["isError"] as? Bool == true
            } ?? false
            if let object { text = AIActivity.pretty(object) }
            result = Excerpt(text, limit: 8192, partial: partial)
        }
    }
    private static func object(_ text: String) -> [String: Any]? {
        guard text.utf8.count <= 256_000 else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
    private static func pretty(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "Input unavailable" }
        return text
    }
}

struct AIActivityView: View {
    let activity: AIActivity
    var drawn = false
    @State private var earlier = false
    @State private var expanded: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if activity.totalSteps > activity.steps.count {
                Text("\(activity.totalSteps - activity.steps.count) older steps are no longer retained")
                    .foregroundStyle(Palette.muted)
            }
            if activity.steps.count > 5 {
                DisclosureGroup("\(activity.steps.count - 5) earlier steps", isExpanded: $earlier) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(activity.steps.dropLast(5)) { step in row(step) }
                    }.padding(.top, 8)
                }
                .accessibilityIdentifier("ai-activity-earlier")
            }
            ForEach(activity.steps.suffix(5)) { step in row(step) }
            if activity.phase != .finished {
                TimelineView(.periodic(from: activity.since, by: 1)) { clock in
                    HStack(spacing: 8) {
                        if !drawn { ProgressView().controlSize(.mini) }
                        Text(activity.status(at: drawn ? activity.since : clock.date))
                            .monospacedDigit()
                    }
                    .foregroundStyle(Palette.muted)
                }
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Palette.muted)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI activity")
    }

    private func row(_ step: AIActivity.Step) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(step.id) }, set: { value in
            if value { expanded.insert(step.id) } else { expanded.remove(step.id) }
        })) {
            AIActivityStepDetails(step: step)
                .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(step.number).").monospacedDigit()
                    Text(step.title).foregroundStyle(Palette.ink)
                    Spacer(minLength: 0)
                    Text(step.issue ? "Needs attention" : step.returned ? "Finished" : activity.phase == .finished ? "Stopped" : "Running")
                        .foregroundStyle(step.issue ? Palette.failed : Palette.muted)
                }
                Text(step.input.summary).font(.system(size: 10.5))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("ai-activity-step-\(step.number)")
    }
}

struct AIActivityStepDetails: View {
    let step: AIActivity.Step
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            section("Command / input", step.input.command)
            if let output = step.output {
                section("Result", output.result)
            } else {
                Text(step.returned ? "The tool returned no text." : "No result received yet.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }
        .padding(10)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8))
    }
    private func section(_ title: String, _ excerpt: AIActivity.Excerpt) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.ink)
            ScrollView {
                Text(verbatim: excerpt.text.isEmpty ? "No text returned." : excerpt.text)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Palette.ink).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: excerptHeight(excerpt.text))
            if excerpt.truncated {
                Text("Excerpt · additional output is not shown here.")
                    .font(.system(size: 10.5)).foregroundStyle(Palette.muted)
            }
        }
    }

    private func excerptHeight(_ text: String) -> CGFloat {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .reduce(0) { $0 + max(1, ($1.count + 44) / 45) }
        return min(180, max(28, CGFloat(lines) * 14 + 4))
    }
}
