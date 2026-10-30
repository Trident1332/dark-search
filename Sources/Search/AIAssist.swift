import SwiftUI

// The AI add-on as you meet it: Summarize Page and Ask About This Page…, and
// the panel the answer comes in. One page at a time, from your click; the
// questions after the first stay with that tab in memory; closing its panel
// clears them, and nothing is written to disk. The answer is plain text, never a link to
// follow or a picture to fetch, marked for what it is: a model's reading,
// which may be wrong, and where it ran. What the page says goes to the model
// as the page's words to read, never as orders (see AIPage), and anything
// in the answer the page didn't have is pointed out.
//
// A provider off this Mac is shown what it will be sent the first time it is
// used, before anything goes. A private tab uses only what runs on this Mac.

/// One conversation about one page.
@MainActor
final class Assistant: ObservableObject, Identifiable {
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        /// Nil for the summary.
        let question: String?
        var answer = ""
        var done = false
        var failed: String?
        /// Addresses, emails and numbers in the answer the page doesn't have.
        var strays: [String] = []
    }

    let id = UUID()
    let tab: Tab.ID
    let sourceURL: URL?
    let standalone: Bool
    let provider: AIProvider
    @Published private(set) var model: String
    /// The exact quote captured by the context menu, or nil for the page.
    let selection: String?
    /// Asked for a summary, rather than opened for a question.
    let summary: Bool

    @Published private(set) var turns: [Turn] = []
    @Published private(set) var reading = true
    @Published var draft = ""
    /// What a provider off this Mac is sent, not yet agreed to.
    @Published private(set) var notice: String?
    @Published private(set) var trouble: String?
    /// The page has words addressed to an AI (see AIPage.addressesAI).
    @Published private(set) var addressed = false
    @Published private(set) var context: AIPage.Read?
    @Published private(set) var destinationHost: String

    private let fence = AIPage.newFence()
    private var messages: [AIMessage] = []
    private var waiting: AIPage.Ask?
    private var task: Task<Void, Never>?
    private var connection: OpenCodeAI.Connection?
    private var consentKey: String?
    private weak var sourceTab: Tab?
    @Published private(set) var inspectEnabled = false
    @Published private(set) var inspectionBusy = false
    @Published private(set) var inspectionSnapshot: AIInspectionSnapshot?
    @Published private(set) var inspectionProblem: String?
    private var inspectionTask: Task<Void, Never>?
    var inspection: AIInspection? { sourceTab?.aiInspection }


    init(tab: Tab, provider: AIProvider, model: String, summary: Bool, selection: String? = nil, standalone: Bool = false) {
        self.tab = tab.id
        self.sourceTab = tab
        self.sourceURL = tab.pageAddress
        self.standalone = standalone
        self.provider = provider
        self.model = model
        self.summary = summary
        let quote = selection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.selection = quote.isEmpty ? nil : String(quote.prefix(AIPage.limit))
        self.destinationHost = provider == .openCode
            ? ((try? OpenCodeAI.catalogue())?.first { $0.id == model }?.host ?? "your OpenCode provider") : provider.host
        if standalone {
            self.context = AIPage.Read(title: "", url: nil, text: "", links: [], cut: false)
            self.reading = false
            return
        }
        let address = tab.pageAddress
        task = Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            let read = await AIPage.read(tab, selection: self.selection)
            guard !Task.isCancelled else { return }
            guard tab.pageAddress == address else {
                self.reading = false
                self.trouble = "The page changed. Choose Ask AI again for its current text."
                return
            }
            self.context = read
            self.addressed = read?.addressed ?? false
            self.reading = false
            self.inspectEnabled = tab.aiInspection.recording
            guard self.context != nil else {
                self.trouble = "There's nothing on this page to read."
                return
            }
            if summary { if self.inspectEnabled { self.captureForQuestion(.summary) } else { self.ask(.summary) } }
        }
    }

    var busy: Bool { inspectionBusy || reading || turns.last.map { !$0.done } ?? false }

    var pendingQuestion: String? {
        guard case .question(let question) = waiting else { return nil }
        return question
    }

    /// Where it ran, for the foot of every answer.
    var place: String {
        provider == .thisMac ? "on this Mac · \(model)"
            : provider.isLocal ? "on this Mac · \(provider.name) · \(model)" : "\(destinationHost) · \(model)"
    }

    func submit() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !busy, notice == nil, context != nil else { return }
        draft = ""
        let ask = AIPage.Ask.question(String(question.prefix(2000)))
        if inspectEnabled {
            captureForQuestion(ask)
        } else { self.ask(ask) }
    }

    func submitSuggestion(_ question: String) {
        guard !busy, notice == nil, context != nil else { return }
        draft = question
        submit()
    }

    func setInspection(_ enabled: Bool) {
        guard !standalone, !enabled || (!busy && notice == nil) else { return }
        inspectionTask?.cancel(); inspectionTask = nil
        if !enabled {
            inspectionBusy = false
            cancelAnswer()
            inspectEnabled = false; inspectionSnapshot = nil; inspectionProblem = nil
            sourceTab?.aiInspection.stop()
            return
        }
        guard provider != .thisMac else {
            inspectionProblem = "Choose OpenCode or another provider with tool support to let AI read inspection data."
            return
        }
        guard let sourceTab else { return }
        inspectionBusy = true
        inspectionTask = Task { [weak self, weak sourceTab] in
            guard let self, let sourceTab else { return }
            await sourceTab.aiInspection.start(in: sourceTab)
            guard !Task.isCancelled else { return }
            self.inspectEnabled = sourceTab.aiInspection.recording
            if self.inspectEnabled {
                do { self.inspectionSnapshot = try await sourceTab.aiInspection.snapshot() }
                catch { self.inspectionProblem = error.localizedDescription }
            } else { self.inspectionProblem = sourceTab.aiInspection.problem }
            self.inspectionBusy = false
        }
    }
    func refreshInspection() {
        guard inspectEnabled, !busy else { return }
        captureForQuestion(nil)
    }
    private func captureForQuestion(_ question: AIPage.Ask?) {
        guard let inspection else { return }
        inspectionBusy = true; inspectionProblem = nil
        inspectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await inspection.snapshot()
                guard !Task.isCancelled else { return }
                self.inspectionSnapshot = snapshot
                self.inspectionBusy = false
                if let question { self.ask(question) }
            } catch {
                guard !Task.isCancelled else { return }
                self.inspectionBusy = false; self.inspectionProblem = error.localizedDescription
                if case .question(let text) = question { self.draft = text }
            }
        }
    }

    private func ask(_ ask: AIPage.Ask) {
        var key = "ai.told.\(provider.rawValue)"
        var destination = destinationHost
        if provider == .openCode {
            do {
                let chosen = try OpenCodeAI.connection(for: model)
                connection = chosen
                destinationHost = chosen.base.host() ?? "your OpenCode provider"
                destination = chosen.origin
                // The destination agreed to and the request use this same
                // immutable snapshot, even if OpenCode's file changes later.
                var origin = URLComponents(url: chosen.base, resolvingAgainstBaseURL: false)
                origin?.path = ""
                key += "." + (origin?.string ?? chosen.base.absoluteString)
            } catch {
                trouble = error.localizedDescription
                return
            }
        }
        consentKey = key
        if !provider.isLocal, !Store.settings.bool(forKey: key) {
            waiting = ask
            notice = AIAssist.notice(for: provider, host: destination)
            return
        }
        send(ask)
    }

    /// The notice read and agreed to: what was asked goes.
    func agree() {
        guard let consentKey, let waiting else { return }
        Store.settings.set(true, forKey: consentKey)
        notice = nil
        self.waiting = nil
        send(waiting)
    }

    private func send(_ ask: AIPage.Ask) {
        guard let read = context else { return }
        trouble = nil
        switch ask {
        case .summary:
            messages = [AIMessage(role: .user, text: AIPage.opening(read, .summary, fence: fence))]
            turns.append(Turn(question: nil))
        case .question(let question):
            messages.append(AIMessage(role: .user, text: !standalone && messages.isEmpty ? AIPage.opening(read, ask, fence: fence) : question))
            turns.append(Turn(question: question))
        }
        // The key, read now and let go with the request.
        let key = provider.isLocal || provider == .openCode ? nil : AIKeys.key(for: provider)
        let system = standalone ? "You are a helpful assistant. Answer the person directly in plain text. You have no access to their tabs, files or device. Distinguish uncertain claims from facts." : AIPage.system(fence: fence)
        let stream = provider == .thisMac
            ? AIEngine.shared.stream(system: system, messages: messages)
            : inspectEnabled && inspectionSnapshot != nil
                ? AIClient.shared.inspect(provider, model: model, system: system, messages: messages, key: key,
                                          connection: connection, snapshot: inspectionSnapshot!, live: inspection!)
                : AIClient.shared.stream(provider, model: model, system: system, messages: messages, key: key,
                                         connection: connection)
        connection = nil
        let turnID = turns[turns.count - 1].id
        task = Task { @MainActor [weak self] in
            do {
                for try await piece in stream {
                    guard !Task.isCancelled, let self, self.turns.last?.id == turnID, self.turns.last?.done == false else { return }
                    self.turns[self.turns.count - 1].answer += piece
                    // Longer than any answer about a page needs: a model
                    // talked into writing on and on is stopped.
                    if self.turns[self.turns.count - 1].answer.count > Assistant.longest { break }
                }
                self?.finish(nil, turn: turnID)
            } catch {
                self?.finish(error.localizedDescription, turn: turnID)
            }
        }
    }

    static let longest = 16_000

    private func finish(_ failed: String?, turn expected: UUID? = nil) {
        guard let last = turns.last, !last.done, expected == nil || last.id == expected, let read = context else { return }
        var turn = turns[turns.count - 1]
        turn.done = true
        turn.failed = failed
        turns[turns.count - 1] = turn
        // Checked away from the window's thread: a long answer is a long look.
        let id = turn.id, answer = turn.answer, standalone = self.standalone || inspectEnabled
        Task.detached(priority: .userInitiated) { [weak self] in
            let strays = standalone ? [] : AIPage.strays(in: answer, from: read)
            await MainActor.run {
                guard let self, let index = self.turns.firstIndex(where: { $0.id == id }) else { return }
                self.turns[index].strays = strays
            }
        }
        if failed == nil, !turn.answer.isEmpty {
            messages.append(AIMessage(role: .assistant, text: turn.answer))
        } else if !messages.isEmpty {
            // A question that got no answer isn't part of what follows; the
            // page goes again with the next one if it was the first.
            messages.removeLast()
        }
    }

    func stop() {
        inspectionTask?.cancel(); inspectionTask = nil
        task?.cancel()
        task = nil
        connection = nil
        waiting = nil
    }

    func chooseModel(_ model: String) {
        guard provider == .openCode, !busy, notice == nil,
              let chosen = (try? OpenCodeAI.catalogue())?.first(where: { $0.id == model }) else { return }
        self.model = chosen.id
        destinationHost = chosen.host
        trouble = nil
    }

    func cancelAnswer() {
        guard !reading, turns.last?.done == false else { return }
        task?.cancel()
        task = nil
        finish(nil)
    }
}

enum AIAssist {
    /// What a provider off this Mac is sent, said once, the first time it is
    /// used — and a word on what it does with it where that matters.
    static func notice(for provider: AIProvider, host: String? = nil) -> String {
        var text = "Dark Search sends the quoted context shown here, the page's address and your question to \(host ?? provider.host)"
        text += provider == .openRouter ? ", which passes them to the model's provider." : "."
        text += " Their terms and privacy policy apply. Nothing is sent until you ask, never from a private tab, and Dark Search keeps no copy."
        switch provider {
        case .gemini:
            text += "\n\nOn Gemini's free tier, outside the EEA, Switzerland and the UK, Google may use this to improve its products, and people may read it. Don't use it on sensitive pages."
        case .openRouter:
            text += "\n\nDark Search asks OpenRouter to use only providers that keep nothing (zero data retention)."
        default:
            break
        }
        return text
    }
}

extension Browser {
    func askFromAddress() {
        let question = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if launching || (active?.isWeb != true && active?.isBlank != true) { newTab() }
        startAssistant(summary: false, standalone: active?.isBlank == true)
        if let assistant = assisting, !question.isEmpty, question != active?.pageAddress?.absoluteString {
            assistant.draft = question
        }
        if active?.isBlank == true { editing = false } else { dismiss() }
    }
    func summarizePage() { startAssistant(summary: true) }
    func askAboutPage() { startAssistant(summary: false) }
    func askAboutPage(from tab: Tab, selection: String? = nil) { startAssistant(summary: false, from: tab, selection: selection) }

    private func startAssistant(summary: Bool, from source: Tab? = nil, selection: String? = nil, standalone: Bool = false) {
        guard AI.shipped || Store.testing, let tab = source ?? active, tab.isWeb || (standalone && tab.isBlank), !isPopup else { return }
        if source != nil {
            guard tabs.contains(where: { $0 === tab }) else { return }
            select(tab)
        }
        // Choosing Ask AI is the user's opt-in. Import model names from the
        // configuration they already use; no request is made on opening it.
        if !prefs.ai { prefs.ai = true }
        if prefs.aiProvider == nil, (try? OpenCodeAI.catalogue().isEmpty) == false { prefs.aiProvider = .openCode }
        guard prefs.ai, let provider = prefs.aiProvider else {
            settingsPage = .ai
            tuning = true
            announce(prefs.ai ? "Choose where the AI runs" : "Turn on AI in Settings › AI")
            return
        }
        // A web page, nothing else: not a file, not an extension's page.
        guard standalone || ["https", "http"].contains(tab.pageAddress?.scheme?.lowercased() ?? "") else {
            announce("AI works on web pages")
            return
        }
        // A private tab leaves nothing behind anywhere, a provider included.
        let shy = tab.shy || tab.usesTor || !tab.store.isPersistent
        guard !shy || provider.isLocal else {
            announce("In a private tab, only an AI on this Mac")
            return
        }
        if provider == .thisMac, AIEngine.shared.state != .ready {
            settingsPage = .ai
            tuning = true
            announce("The model isn't on this Mac yet")
            return
        }
        let model = prefs.aiModel(for: provider)
        guard !model.isEmpty else {
            settingsPage = .ai
            tuning = true
            announce("Choose a model for \(provider.name)")
            return
        }
        let ready = provider == .openCode ? OpenCodeAI.hint(for: model) != nil : AIKeys.hint(for: provider) != nil
        guard provider.isLocal || ready else {
            settingsPage = .ai
            tuning = true
            announce("No key for \(provider.name) yet")
            return
        }
        // Asked again on the page the panel is already about: the same
        // conversation goes on.
        if source == nil, !summary, let open = assistantSessions[tab.id], open.sourceURL == tab.pageAddress,
           open.provider == provider, open.selection == selection {
            if sidePanel != .assistant { closeSidePanel() }
            assisting = open
            sidePanel = .assistant
            sidePanelShown = true
            return
        }
        if sidePanel != .assistant { closeSidePanel() }
        closeAssistant(for: tab.id)
        let assistant = Assistant(tab: tab, provider: provider, model: model, summary: summary, selection: selection, standalone: standalone)
        assistantSessions[tab.id] = assistant
        assisting = assistant
        sidePanel = .assistant
        sidePanelShown = true
    }

    func closeAssistant() {
        if let assistant = assisting {
            tabs.first { $0.id == assistant.tab }?.aiInspection.stop()
            closeAssistant(for: assistant.tab)
        }
        else { hideAssistant() }
    }

    /// Leaving a tab only puts its panel away. Its request and draft belong
    /// to the same conversation when the tab comes back into view.
    func assistantFollowsActiveTab() {
        if let assistant = assisting, assistant.tab != activeID { hideAssistant() }
        guard let tab = active else { return }
        // Put away the old assistant before a bound extension panel returns.
        sidePanelFollows(tab)
        guard let assistant = assistantSessions[tab.id] else { return }
        let privatePage = tab.shy || tab.usesTor || !tab.store.isPersistent
        guard tab.isWeb || (assistant.standalone && tab.isBlank), assistant.inspectEnabled || assistant.sourceURL == tab.pageAddress,
              !privatePage || assistant.provider.isLocal else {
            closeAssistant(for: tab.id)
            return
        }
        // An explicitly opened dialer or other panel keeps its place.
        guard sidePanel == nil || sidePanel == .assistant else { return }
        assisting = assistant
        sidePanel = .assistant
        sidePanelShown = true
    }

    /// Explicitly closed, navigated, or removed: this tab's context is gone,
    /// including a conversation currently answering in the background.
    func closeAssistant(for tab: Tab.ID) {
        let stored = assistantSessions.removeValue(forKey: tab)
        stored?.stop()
        guard let shown = assisting, shown.tab == tab else { return }
        if shown !== stored { shown.stop() }
        hideAssistant()
    }

    func closeAllAssistants() {
        assistantSessions.values.forEach { $0.stop() }
        assistantSessions.removeAll()
        assisting?.stop()
        hideAssistant()
    }

    private func hideAssistant() {
        assisting = nil
        if sidePanel == .assistant {
            sidePanelShown = false
            sidePanel = nil
        }
    }

    func chooseAssistantModel(_ model: String) {
        guard let assistant = assisting, assistant.provider == .openCode, !assistant.busy, assistant.notice == nil else { return }
        assistant.chooseModel(model)
        prefs.setAIModel(assistant.model, for: .openCode)
    }

    /// The panel again with nothing said yet, about the page it is on.
    func restartAssistant() {
        guard let open = assisting else { return }
        let standalone = open.standalone
        closeAssistant()
        startAssistant(summary: false, standalone: standalone)
    }
}

// MARK: - the panel

/// Color stays in small surfaces and accents so long answers remain easy to read.
private enum AssistantStyle {
    static let blue = Color(red: 0.34, green: 0.48, blue: 0.96)
    static let violet = Color(red: 0.64, green: 0.40, blue: 0.90)
    static let teal = Color(red: 0.20, green: 0.69, blue: 0.73)

    /// The one gradient, kept for the few things that earn it: the spark,
    /// the send button, the thinking dots and the ring round a composer
    /// being typed in. Everything else is the panel's greys.
    static func gradient(_ opacity: Double = 1) -> LinearGradient {
        LinearGradient(colors: [blue.opacity(opacity), violet.opacity(opacity), teal.opacity(opacity)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The one tinted ink: the arrow a suggestion grows under the pointer,
    /// the check after a copy, the arc round Stop.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.55, green: 0.61, blue: 1.0, alpha: 1)
            : NSColor(srgbRed: 0.30, green: 0.39, blue: 0.88, alpha: 1)
    })
    /// Text a step short of ink: a suggestion at rest, the model's name.
    static let soft = grey(light: 0.30, dark: 0.73)
    /// The composer, and a row under the pointer: a step up from the ground.
    static let raised = grey(light: 0.957, dark: 0.14)

    private static func grey(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(white: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light, alpha: 1)
        })
    }

    /// Two curves, so the panel moves as one thing: an ease-out for what
    /// arrives and leaves, a short spring for what pops into place.
    static let arrival = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.26)
    static let pop = Animation.spring(response: 0.36, dampingFraction: 0.72)
    /// Siblings arrive one after another, this far apart.
    static let step = 0.06
}

/// One element's entrance: it fades up into place a few steps after the
/// one above it. Off when drawn; under Reduce Motion it only fades.
private struct Arriving: ViewModifier {
    let step: Int
    let on: Bool
    let moves: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown || !on ? 1 : 0)
            .offset(y: shown || !on || !moves ? 0 : 6)
            .onAppear {
                guard on, !shown else { return }
                withAnimation(AssistantStyle.arrival.delay(Double(step) * AssistantStyle.step)) { shown = true }
            }
    }
}

private extension View {
    func arriving(_ step: Int, on: Bool, moves: Bool) -> some View {
        modifier(Arriving(step: step, on: on, moves: moves))
    }
}

/// The gradient spark: it turns into place, then breathes while the panel
/// waits. The breathing is the symbol's own, off the window's thread.
private struct SparkMark: View {
    var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(AssistantStyle.gradient())
            .symbolEffect(.pulse, options: .repeating.speed(0.4), isActive: !reduceMotion && !drawn)
            .rotationEffect(.degrees(arrived || drawn || reduceMotion ? 0 : -20))
            .scaleEffect(arrived || drawn || reduceMotion ? 1 : 0.6)
            .opacity(arrived || drawn ? 1 : 0)
            .frame(width: 30, height: 30, alignment: .leading)
            .onAppear { withAnimation(drawn || reduceMotion ? nil : AssistantStyle.pop) { arrived = true } }
            .accessibilityHidden(true)
    }
}

/// Only the glyph, the shimmer and the three dots redraw on the clock,
/// never the conversation or its layout.
private struct AssistantThinking: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var started = Date()
    var drawn = false
    var title = "Thinking"

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AssistantStyle.gradient())
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion && !drawn)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || drawn || scenePhase != .active)) { clock in
                let time = reduceMotion || drawn ? 0 : max(0, clock.date.timeIntervalSince(started))
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 13)).foregroundStyle(shimmer(at: time))
                    HStack(spacing: 3) {
                        ForEach(0..<3) { index in
                            let wave = (sin(time * 4 - Double(index) * 0.8) + 1) / 2
                            Circle().fill(AssistantStyle.gradient())
                                .frame(width: 4, height: 4)
                                .opacity(0.4 + wave * 0.6)
                                .offset(y: reduceMotion || drawn ? 0 : -wave * 3)
                        }
                    }
                    .frame(height: 12)
                }
            }
        }
        .frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .onAppear { started = Date() }
    }

    /// A band of ink sweeps the muted word once every 1.8 s, then rests.
    private func shimmer(at time: Double) -> LinearGradient {
        let phase = time.truncatingRemainder(dividingBy: 1.8) / 1.8
        let x = phase * 3 - 2
        return LinearGradient(stops: [.init(color: Palette.muted, location: 0), .init(color: Palette.muted, location: 0.38),
                                      .init(color: Palette.ink, location: 0.5),
                                      .init(color: Palette.muted, location: 0.62), .init(color: Palette.muted, location: 1)],
                              startPoint: UnitPoint(x: x, y: 0.5), endPoint: UnitPoint(x: x + 3, y: 0.5))
    }
}

/// A short track the gradient sweeps along while the page is being read.
private struct ReadingSweep: View {
    var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var started = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || drawn || scenePhase != .active)) { clock in
            let time = reduceMotion || drawn ? 0.4 : max(0, clock.date.timeIntervalSince(started))
            let phase = time.truncatingRemainder(dividingBy: 1.2) / 1.2
            let eased = phase < 0.5 ? 2 * phase * phase : 1 - pow(-2 * phase + 2, 2) / 2
            Capsule().fill(Palette.wash)
                .frame(width: 56, height: 2)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: [AssistantStyle.blue, AssistantStyle.violet, AssistantStyle.teal],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: 22, height: 2)
                        .offset(x: -22 + eased * 78)
                }
                .clipShape(Capsule())
        }
        .accessibilityHidden(true)
    }
}

/// A faint gradient ring that turns slowly round the composer while it is
/// being typed in. Only the ring redraws on the clock, and only then.
private struct FocusRing: View {
    let on: Bool
    var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var started = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !on || reduceMotion || drawn || scenePhase != .active)) { clock in
            let time = reduceMotion || drawn ? 0 : max(0, clock.date.timeIntervalSince(started))
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(AngularGradient(colors: [AssistantStyle.blue, AssistantStyle.violet, AssistantStyle.teal, AssistantStyle.blue],
                                              center: .center, angle: .degrees(time / 8 * 360)), lineWidth: 1)
        }
        .opacity(on ? 0.75 : 0)
        .allowsHitTesting(false)
    }
}

/// The arc that orbits Stop while an answer is on its way.
private struct StopArc: View {
    var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var started = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || drawn || scenePhase != .active)) { clock in
            let time = reduceMotion || drawn ? 0 : max(0, clock.date.timeIntervalSince(started))
            Circle().trim(from: 0, to: 0.28)
                .stroke(AssistantStyle.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(time / 0.9 * 360 - 90))
        }
        .padding(-3)
        .accessibilityHidden(true)
    }
}

/// Send gives under the pointer, as a tab does.
private struct SendStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(Motion.reduced ? nil : AssistantStyle.pop, value: configuration.isPressed)
    }
}

/// A question offered as a line of text: under the pointer it brightens,
/// gives a little to the right, and grows its arrow.
private struct AskSuggestion: View {
    let title: String
    let on: Bool
    let act: () -> Void
    @State private var hovering = false

    init(_ title: String, on: Bool, act: @escaping () -> Void) {
        self.title = title
        self.on = on
        self.act = act
    }

    var body: some View {
        Button(action: act) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13)).lineLimit(2)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AssistantStyle.accent)
                    .opacity(hovering ? 1 : 0)
                    .offset(x: hovering ? 0 : -4)
            }
            .foregroundStyle(hovering ? Palette.ink : AssistantStyle.soft)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(hovering ? AssistantStyle.raised : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .offset(x: hovering ? 2 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!on)
        .opacity(on ? 1 : 0.5)
        .onHover { hovering = $0 && on }
        .animation(Motion.quick, value: hovering)
    }
}

/// A small icon button with nothing round it until the pointer is over it.
private struct AskQuiet: View {
    let icon: String
    var help = ""
    var label = ""
    var tint: Color? = nil
    let act: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: act) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint ?? (hovering ? Palette.ink : Palette.muted))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26, height: 24)
                .background(hovering ? AssistantStyle.raised : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(label)
        .animation(Motion.quick, value: hovering)
        .animation(reduceMotion ? nil : AssistantStyle.pop, value: icon)
    }
}

/// The notice's two answers: Continue in the gradient, the other quiet.
private struct AssistantPill: View {
    let title: String
    var filled = false
    let act: () -> Void
    @State private var hovering = false

    init(_ title: String, filled: Bool = false, act: @escaping () -> Void) {
        self.title = title
        self.filled = filled
        self.act = act
    }

    var body: some View {
        Button(action: act) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(filled ? Color.white : (hovering ? Palette.ink : Palette.muted))
                .padding(.horizontal, 18)
                .frame(height: 34)
                .background {
                    if filled {
                        Capsule().fill(AssistantStyle.gradient())
                    } else if hovering {
                        Capsule().fill(AssistantStyle.raised)
                    }
                }
                .brightness(filled && hovering ? 0.06 : 0)
                .offset(y: hovering ? -1 : 0)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

struct AssistantPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var assistant: Assistant
    /// A deterministic rendering of these same controls, without native
    /// text fields or scroll views, for the isolated picture command.
    var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @FocusState private var typing: Bool
    @State private var models: [OpenCodeAI.Model] = []
    @State private var expandedContext = false
    @State private var overSend = false
    @State private var overModel = false

    private var moves: Bool { !reduceMotion && !drawn }
    private var motion: Animation? { moves ? AssistantStyle.arrival : nil }
    private var popping: Animation? { moves ? AssistantStyle.pop : nil }
    private var arrival: AnyTransition { moves ? .opacity.combined(with: .offset(y: 6)) : .opacity }
    /// A question, or the notice: from its corner, as a thing set down.
    private var popIn: AnyTransition {
        moves ? .opacity.combined(with: .scale(scale: 0.97, anchor: .bottomTrailing)).combined(with: .offset(y: 6)) : .opacity
    }

    private var catalogue: [OpenCodeAI.Model] {
        if !models.isEmpty { return models }
        return drawn ? (try? OpenCodeAI.catalogue()) ?? [] : []
    }

    private var chosenModel: OpenCodeAI.Model? { catalogue.first { $0.id == assistant.model } }
    private var modelName: String { Self.modelLabel(for: assistant.model, provider: assistant.provider, models: catalogue) }
    private var selected: Bool { assistant.selection != nil }
    /// About a page, rather than a conversation begun from the address bar.
    private var conversational: Bool { !assistant.standalone }
    private var empty: Bool {
        assistant.turns.isEmpty && assistant.notice == nil && assistant.trouble == nil && assistant.pendingQuestion == nil
    }
    private var canSend: Bool {
        !assistant.busy && assistant.notice == nil && assistant.context != nil &&
            !assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var stopping: Bool { assistant.busy && !assistant.reading }
    private var suggestable: Bool { !assistant.busy && assistant.notice == nil && assistant.context != nil }
    private var placeholder: String {
        assistant.standalone ? "Message Ask AI…" : !assistant.turns.isEmpty ? "Ask a follow-up…" : selected ? "Ask about this selection…" : "Ask about this page…"
    }
    private var invitation: String {
        assistant.standalone ? "Ask a question to get started." : selected ? "Ask about the selected passage." : "Ask about this page, or select a passage on it first."
    }

    static func modelLabel(for id: String, provider: AIProvider, models: [OpenCodeAI.Model]) -> String {
        if let model = models.first(where: { $0.id == id }) { return model.name }
        return provider == .openCode ? "Choose model" : provider.name
    }

    static func copyAnswer(_ answer: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(answer, forType: .string)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if drawn {
                conversation
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: empty ? .leading : .topLeading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, empty ? 64 : 12)
            } else {
                scrolling
            }
            inspection
            contextLine
            composer
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.ground)
        .opacity(appeared || drawn ? 1 : 0)
        .offset(x: appeared || drawn || reduceMotion ? 0 : 10)
        .animation(motion, value: appeared)
        .onAppear {
            appeared = true
            models = (try? OpenCodeAI.catalogue()) ?? []
            if !assistant.summary, !drawn { typing = true }
        }
    }

    @ViewBuilder private var inspection: some View {
        if conversational { InspectionControls(assistant: assistant).padding(.horizontal, 24).padding(.bottom, 10) }
    }

    /// A small name and Close; a plus to start over once something was said.
    private var header: some View {
        HStack(spacing: 2) {
            Text("Ask AI")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.muted)
                .arriving(0, on: !drawn, moves: moves)
            Spacer(minLength: 0)
            if !empty {
                Door(icon: "plus", help: "New conversation") { browser.restartAssistant() }
                    .transition(.opacity)
            }
            Door(icon: "xmark", help: "Close") { browser.closeAssistant() }
                .arriving(1, on: !drawn, moves: moves)
        }
        .frame(height: 48)
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .animation(motion, value: empty)
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let trouble = assistant.trouble, assistant.notice == nil {
                Text(verbatim: trouble).font(.system(size: 13)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else if empty {
                emptyState.transition(.opacity)
            }
            if assistant.addressed, assistant.notice == nil {
                caution("This page has text written for an AI to follow. The answer may have been steered by it.")
            }
            ForEach(assistant.turns) { turn in
                TurnView(turn: turn, drawn: drawn).id(turn.id).transition(arrival)
            }
            if let question = assistant.pendingQuestion {
                Self.bubble(question).id("pending-question").transition(popIn)
            }
            if let notice = assistant.notice { noticeCard(notice).transition(popIn) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Stable IDs trigger one entrance per turn, never an animation per token.
        .animation(motion, value: assistant.turns.map(\.id))
        .animation(popping, value: assistant.pendingQuestion)
        .animation(popping, value: assistant.notice != nil)
        .animation(motion, value: assistant.trouble)
    }

    private var scrolling: some View {
        GeometryReader { area in
            ScrollViewReader { scroller in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        conversation
                        Color.clear.frame(height: 1).id("answer-bottom")
                    }
                    .frame(minHeight: max(0, area.size.height - 8 - (empty ? 64 : 12)), alignment: empty ? .leading : .topLeading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, empty ? 64 : 12)
                }
                .onChange(of: assistant.turns.last?.answer) { _, _ in
                    // Follow streamed growth directly; overlapping scroll animations
                    // per token cause the answer to lag and then jump.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { scroller.scrollTo("answer-bottom", anchor: .bottom) }
                }
                .onChange(of: assistant.pendingQuestion) { _, question in
                    if question != nil { scroller.scrollTo("pending-question", anchor: .top) }
                }
            }
        }
    }

    /// The spark, the question, and three questions ready to ask: plain
    /// lines, each arriving a step after the one above.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            SparkMark(drawn: drawn).padding(.bottom, 18)
            Text("What would you like to know?")
                .font(.system(size: 21, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .arriving(1, on: !drawn, moves: moves)
            Text(invitation)
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .lineSpacing(2)
                .padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)
                .arriving(2, on: !drawn, moves: moves)
            if conversational {
                VStack(alignment: .leading, spacing: 2) {
                    AskSuggestion(selected ? "Summarize this selection" : "Summarize this page", on: suggestable) {
                        assistant.submitSuggestion(selected ? "Summarize this selected passage in a few sentences." : "Summarize this page in a few sentences.")
                    }
                    .arriving(3, on: !drawn, moves: moves)
                    AskSuggestion(selected ? "Explain this selection" : "Explain a selection", on: suggestable) {
                        if selected {
                            assistant.submitSuggestion("Explain this selected passage in clear, simple terms.")
                        } else {
                            browser.announce("Select a passage on the page, then right-click and choose Ask AI")
                            typing = true
                        }
                    }
                    .arriving(4, on: !drawn, moves: moves)
                    AskSuggestion("List the key takeaways", on: suggestable) {
                        assistant.submitSuggestion(selected ? "List the key points of this selected passage as a short list." : "List the key points of this page as a short list.")
                    }
                    .arriving(5, on: !drawn, moves: moves)
                }
                .padding(.top, 22)
                .padding(.leading, -10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One muted line above the composer: what the question goes with, its
    /// title and site, or the sweep while the page is still being read. A
    /// click unfolds the whole of it.
    @ViewBuilder
    private var contextLine: some View {
        if conversational, assistant.reading || assistant.context != nil {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(motion) { expandedContext.toggle() }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: selected ? "text.quote" : "doc.text").font(.system(size: 10, weight: .medium))
                        if assistant.reading {
                            Text("Reading the page")
                            ReadingSweep(drawn: drawn)
                        } else if let context = assistant.context {
                            Text(verbatim: contextTitle(context))
                                .foregroundStyle(AssistantStyle.soft)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if let host = context.url?.host() {
                                Text(verbatim: "· \(host)").lineLimit(1).fixedSize()
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(assistant.context == nil)
                .help(expandedContext ? "Collapse context" : "Show the full context sent with your question")
                .accessibilityLabel(expandedContext ? "Collapse context" : "Expand context")
                if expandedContext, let context = assistant.context {
                    ScrollView {
                        Text(verbatim: context.text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.ink)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                    .transition(arrival)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            .animation(motion, value: assistant.reading)
            .arriving(5, on: !drawn, moves: moves)
        }
    }

    private func contextTitle(_ context: AIPage.Read) -> String {
        if selected {
            let line = context.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? context.text
            return "“\(line.trimmingCharacters(in: .whitespaces))”"
        }
        return context.title.isEmpty ? (context.url?.host() ?? "This page") : context.title
    }

    /// The one raised surface. Typing in it lifts it a point, deepens its
    /// shadow and lights the ring.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if drawn {
                Text(verbatim: assistant.draft.isEmpty ? placeholder : assistant.draft)
                    .foregroundStyle(assistant.draft.isEmpty ? Palette.muted : Palette.ink)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .topLeading)
            } else {
                TextField("", text: $assistant.draft, prompt: Text(placeholder).foregroundStyle(Palette.muted), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($typing)
                    .lineLimit(1...5)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .topLeading)
                    .submitLabel(.send)
                    .onSubmit { assistant.submit() }
                    .onKeyPress(.return, phases: .down) { press in
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        assistant.submit()
                        return .handled
                    }
                    .disabled(assistant.notice != nil)
            }
            Button {
                if stopping { assistant.cancelAnswer() } else { assistant.submit() }
            } label: { sendIcon }
                .buttonStyle(SendStyle())
                .disabled(!stopping && !canSend)
                .help(stopping ? "Stop answer" : "Send question")
                .accessibilityLabel(stopping ? "Stop answer" : "Send question")
                .onHover { overSend = $0 }
        }
        .padding(.leading, 16)
        .padding(.trailing, 9)
        .padding(.vertical, 9)
        .background(AssistantStyle.raised, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { FocusRing(on: typing && !drawn, drawn: drawn) }
        .shadow(color: .black.opacity(typing ? 0.18 : 0), radius: 14, y: 8)
        .offset(y: typing ? -1 : 0)
        .opacity(assistant.notice == nil ? 1 : 0.55)
        .animation(motion, value: typing)
        .animation(motion, value: assistant.notice == nil)
        .padding(.horizontal, 16)
        .arriving(6, on: !drawn, moves: moves)
    }

    private var sendIcon: some View {
        ZStack {
            if stopping {
                Circle().fill(Palette.wash)
                StopArc(drawn: drawn)
                Image(systemName: "stop.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.ink)
            } else {
                Circle().fill(AssistantStyle.gradient())
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.white)
            }
        }
        .frame(width: 30, height: 30)
        .opacity(stopping || canSend ? 1 : 0.3)
        .scaleEffect(overSend && (stopping || canSend) ? 1.06 : 1)
        .animation(motion, value: canSend)
        .animation(motion, value: stopping)
        .animation(popping, value: overSend)
    }

    /// The model, with the others behind it, and where a question goes.
    private var footer: some View {
        HStack(spacing: 8) {
            modelControl
            Spacer(minLength: 8)
            Text(assistant.provider.isLocal ? "Stays on this Mac" : "Only sent when you ask")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .help("AI may be wrong. Destination: \(assistant.destinationHost)")
        }
        .frame(height: 40)
        .padding(.leading, 12)
        .padding(.trailing, 20)
        .padding(.bottom, 4)
        .arriving(7, on: !drawn, moves: moves)
    }

    @ViewBuilder
    private var modelControl: some View {
        if assistant.provider == .openCode && !drawn {
            Menu {
                ForEach(Array(Set(catalogue.map(\.providerName))).sorted(), id: \.self) { provider in
                    Section(provider) {
                        ForEach(catalogue.filter { $0.providerName == provider }) { model in
                            Button { browser.chooseAssistantModel(model.id) } label: {
                                if model.id == assistant.model {
                                    Label(model.name, systemImage: "checkmark")
                                } else {
                                    Text(model.name)
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("AI settings…") { openSettings() }
            } label: { modelLabelView }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(assistant.busy || assistant.notice != nil)
            .accessibilityLabel("AI model")
        } else {
            Button { openSettings() } label: { modelLabelView }
                .buttonStyle(.plain)
                .help("Settings › AI")
                .accessibilityLabel("AI model")
        }
    }

    private func openSettings() {
        _ = browser.show(InternalPage(.settings, SettingsPanel.Page.ai.rawValue))
    }

    private var modelLabelView: some View {
        HStack(spacing: 5) {
            Text(verbatim: modelName)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(overModel ? Palette.ink : AssistantStyle.soft)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(overModel ? AssistantStyle.raised : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { overModel = $0 }
        .animation(Motion.quick, value: overModel)
    }

    private func caution(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.unsafe)
            Text(verbatim: text).font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What a provider off this Mac is sent, before anything goes.
    private func noticeCard(_ notice: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SparkMark(drawn: drawn).padding(.bottom, 18)
            Text("Answers from \(assistant.provider.name)")
                .font(.system(size: 19, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .arriving(1, on: !drawn, moves: moves)
            Text(verbatim: notice)
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .lineSpacing(3)
                .padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .arriving(2, on: !drawn, moves: moves)
            HStack(spacing: 6) {
                AssistantPill("Continue", filled: true) { assistant.agree() }
                AssistantPill("Not now") { browser.closeAssistant() }
            }
            .padding(.top, 22)
            .arriving(3, on: !drawn, moves: moves)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func bubble(_ question: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 40)
            Text(verbatim: question)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .lineSpacing(2.5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Palette.wash, in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18,
                                                                      bottomTrailingRadius: 6, topTrailingRadius: 18, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private struct TurnView: View {
        let turn: Assistant.Turn
        var drawn = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var copied = false

        private var moves: Bool { !reduceMotion && !drawn }

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                if let question = turn.question { AssistantPanel.bubble(question) }
                VStack(alignment: .leading, spacing: 10) {
                    if turn.answer.isEmpty, !turn.done {
                        AssistantThinking(drawn: drawn)
                            .transition(.opacity)
                    }
                    // Plain text cannot fetch images or turn model output
                    // into links that the original page never contained.
                    if !turn.answer.isEmpty {
                        Text(verbatim: turn.answer)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Palette.ink)
                            .lineSpacing(3.5)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let failed = turn.failed {
                        Text(verbatim: failed).font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !turn.strays.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: "exclamationmark.triangle").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.unsafe)
                            Text(verbatim: "Not on the page: " + turn.strays.joined(separator: ", "))
                                .font(.system(size: 11.5)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if turn.done, !turn.answer.isEmpty {
                        HStack(spacing: 2) {
                            AskQuiet(icon: copied ? "checkmark" : "doc.on.doc", help: copied ? "Copied" : "Copy answer",
                                  label: "Copy answer", tint: copied ? AssistantStyle.accent : nil) {
                                AssistantPanel.copyAnswer(turn.answer)
                                copied = true
                            }
                        }
                        .padding(.leading, -6)
                        .transition(moves ? .opacity.combined(with: .offset(y: 6)) : .opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Fade the first text in once, then leave every streamed
                // update immediate so animations cannot accumulate.
                .animation(moves ? .easeOut(duration: 0.18) : nil, value: turn.answer.isEmpty)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: turn.answer) { _, _ in copied = false }
            .animation(moves ? AssistantStyle.arrival : nil, value: turn.done)
            // Streamed text must update without interpolating its geometry.
            .animation(nil, value: turn.answer)
        }
    }
}

// MARK: - Settings › AI

struct AISettings: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    /// Drawn off screen, for a picture: menus and fields stood in for.
    var drawn = false
    @State private var pasted = ""
    @State private var hint: String?
    @State private var models: [String] = []
    @State private var looking = false
    @State private var openCodeModels: [OpenCodeAI.Model] = []
    @State private var openCodeProblem: String?
    @ObservedObject private var engine = AIEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Line("Use AI on pages", "Right-click a page or selected text and choose Ask AI. Nothing is sent until you ask") {
                    Switch(on: $prefs.ai)
                }
            }
            if prefs.ai {
                Card {
                    Line("Where it runs", place) {
                        if drawn {
                            Stand(prefs.aiProvider.map { $0.isLocal ? "\($0.name), on this Mac" : $0.name } ?? "Choose", menu: true)
                        } else {
                        Picker("", selection: Binding(get: { prefs.aiProvider }, set: { prefs.aiProvider = $0 })) {
                            Text("Choose").tag(AIProvider?.none)
                            ForEach(AIProvider.allCases.filter { $0 != .thisMac || engine.available || prefs.aiProvider == .thisMac }) { provider in
                                Text(provider == .thisMac ? provider.name : provider.isLocal ? "\(provider.name), on this Mac" : provider.name)
                                    .tag(AIProvider?.some(provider))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        }
                    }
                    if let provider = prefs.aiProvider {
                        Rule()
                        if provider == .openCode { openCode }
                        else if provider == .thisMac { onThisMac }
                        else if provider.isLocal { localModel(provider) }
                        else { key(provider); Rule(); cloudModel(provider) }
                    }
                }
                .onChange(of: prefs.aiProvider) { _, _ in
                    // A key typed for one provider is never saved for another.
                    pasted = ""
                    refresh()
                }
                .onAppear(perform: refresh)
                Card {
                    Line("Forget Search's keys", "Deletes keys saved by Search from this Mac's keychain. OpenCode manages its own credentials") {
                        Pill("Forget") {
                            AIKeys.forgetAll()
                            refresh()
                            browser.announce("Keys forgotten")
                        }
                    }
                }
            }
        }
    }

    /// The model here: downloaded when you say, checked, prepared once.
    @ViewBuilder
    private var onThisMac: some View {
        let size = ByteCountFormatter.string(fromByteCount: engine.downloadSize, countStyle: .file)
        if AIEngine.translated {
            Line("Model", "Needs the Apple Silicon version of Dark Search — this copy runs translated") { EmptyView() }
        } else {
            switch engine.state {
            case .absent:
                Line("Model", "\(AIEngine.model.name), downloaded once (\(size)) and checked. Nothing leaves this Mac") {
                    Pill("Download", filled: true) { engine.install() }
                }
            case .downloading(let done):
                Line("Model", "Downloading \(Int(done * 100))%") {
                    Pill("Cancel") { engine.cancelInstall() }
                }
            case .preparing:
                Line("Model", "Preparing it for this Mac — about twenty seconds, once") { EmptyView() }
            case .ready:
                Line("Model", "\(AIEngine.model.name), on this Mac. Nothing leaves it") {
                    Pill("Remove") { engine.remove() }
                }
            case .failed(let why):
                Line("Model", why) {
                    Pill("Try Again") { engine.install() }
                }
            }
        }
    }

    private var place: String {
        guard let provider = prefs.aiProvider else { return "A provider you have a key with, or an app on this Mac" }
        if provider == .openCode { return "Models and credentials from your OpenCode configuration. Choose a model in the Ask AI panel" }
        return provider.isLocal
            ? "Nothing leaves this Mac. Also in private tabs"
            : "Your key, kept in this Mac's keychain, sent only to \(provider.host). Never from a private tab"
    }

    @ViewBuilder
    private var openCode: some View {
        Line("OpenCode", openCodeProblem ?? "Credentials are read when you send a question and kept out of Search's settings") {
            Pill("Reload") { refresh() }
        }
        Rule()
        Line("Default model", openCodeModels.isEmpty ? "No supported configured models found" : "\(openCodeModels.count) configured models; you can also choose in the panel") {
            if drawn {
                Stand(prefs.aiModel(for: .openCode), menu: true, width: 200)
            } else {
                Picker("Model", selection: Binding(get: { prefs.aiModel(for: .openCode) }, set: { prefs.setAIModel($0, for: .openCode) })) {
                    ForEach(openCodeModels) { model in Text("\(model.providerName) · \(model.name)").tag(model.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 210)
            }
        }
    }

    @ViewBuilder
    private func key(_ provider: AIProvider) -> some View {
        if let hint {
            Line("Key", "\(hint), in this Mac's keychain") {
                Pill("Forget") {
                    AIKeys.forget(provider)
                    refresh()
                }
            }
        } else if !AIKeys.available {
            Line("Key", "This copy of Dark Search can't keep keys safely — it isn't the signed release. An app on this Mac still works") { EmptyView() }
        } else {
            Line("Key", provider == .openRouter ? "Paste one, or sign in and OpenRouter makes one for you" : "Paste your API key") {
                HStack(spacing: 6) {
                    SecureField("", text: $pasted, prompt: Text("Key").foregroundStyle(Palette.faint))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 130)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .onSubmit { save(provider) }
                    Pill("Save") { save(provider) }
                    if provider == .openRouter {
                        Pill("Sign In") {
                            AISignIn.start(in: browser)
                        }
                    }
                }
            }
        }
    }

    private func cloudModel(_ provider: AIProvider) -> some View {
        Line("Model", "Leave empty for \(provider.defaultModel)") {
            if drawn {
                Stand(prefs.aiModels[provider.rawValue].flatMap { $0.isEmpty ? nil : $0 } ?? provider.defaultModel, width: 170)
            } else {
            TextField("", text: Binding(get: { prefs.aiModels[provider.rawValue] ?? "" },
                                        set: { prefs.setAIModel($0, for: provider) }),
                      prompt: Text(provider.defaultModel).foregroundStyle(Palette.faint))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 170)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }

    /// A menu or a field, as a picture shows it.
    private struct Stand: View {
        let text: String
        var menu = false
        var width: CGFloat?
        init(_ text: String, menu: Bool = false, width: CGFloat? = nil) { self.text = text; self.menu = menu; self.width = width }
        var body: some View {
            HStack(spacing: 5) {
                Text(text).font(.system(size: 12)).foregroundStyle(menu ? Palette.ink : Palette.faint)
                if menu { Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.muted) }
            }
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(menu ? Palette.ground : Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(menu ? Palette.hairline : .clear, lineWidth: 1))
        }
    }

    @ViewBuilder
    private func localModel(_ provider: AIProvider) -> some View {
        if models.isEmpty {
            Line("Model", looking ? "Asking \(provider.name)" : "\(provider.name) isn't running, or has no model yet") {
                Pill("Look Again") { refresh() }
            }
        } else {
            Line("Model", "From \(provider.name) on this Mac") {
                Picker("", selection: Binding(get: { prefs.aiModel(for: provider) }, set: { prefs.setAIModel($0, for: provider) })) {
                    Text("Choose").tag("")
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    private func save(_ provider: AIProvider) {
        let key = pasted
        pasted = ""
        switch AIKeys.save(key, for: provider) {
        case .kept: browser.announce("Key kept in the keychain")
        case .unavailable: browser.announce("This copy of Dark Search can't keep keys")
        case .failed: browser.announce("The key wasn't kept")
        }
        refresh()
    }

    /// Looked at when the page is: a local app is asked for its models only
    /// now, never in the background.
    private func refresh() {
        guard let provider = prefs.aiProvider else { return }
        if provider == .openCode {
            do {
                openCodeModels = try OpenCodeAI.catalogue()
                openCodeProblem = nil
            } catch {
                openCodeModels = []
                openCodeProblem = error.localizedDescription
            }
            hint = OpenCodeAI.hint(for: prefs.aiModel(for: .openCode))
            return
        }
        hint = provider.isLocal ? nil : AIKeys.hint(for: provider)
        models = []
        guard provider.isLocal else { return }
        looking = true
        Task { @MainActor in
            models = await AIClient.shared.localModels(provider)
            looking = false
        }
    }
}
