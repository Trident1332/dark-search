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

    init(tab: Tab, provider: AIProvider, model: String, summary: Bool, selection: String? = nil) {
        self.tab = tab.id
        self.sourceURL = tab.pageAddress
        self.provider = provider
        self.model = model
        self.summary = summary
        let quote = selection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.selection = quote.isEmpty ? nil : String(quote.prefix(AIPage.limit))
        self.destinationHost = provider == .openCode
            ? ((try? OpenCodeAI.catalogue())?.first { $0.id == model }?.host ?? "your OpenCode provider") : provider.host
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
            guard self.context != nil else {
                self.trouble = "There's nothing on this page to read."
                return
            }
            if summary { self.ask(.summary) }
        }
    }

    var busy: Bool { reading || turns.last.map { !$0.done } ?? false }

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
        ask(.question(String(question.prefix(2000))))
    }

    func submitSuggestion(_ question: String) {
        guard !busy, notice == nil, context != nil else { return }
        draft = question
        submit()
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
            messages.append(AIMessage(role: .user, text: messages.isEmpty ? AIPage.opening(read, ask, fence: fence) : question))
            turns.append(Turn(question: question))
        }
        // The key, read now and let go with the request.
        let key = provider.isLocal || provider == .openCode ? nil : AIKeys.key(for: provider)
        let stream = provider == .thisMac
            ? AIEngine.shared.stream(system: AIPage.system(fence: fence), messages: messages)
            : AIClient.shared.stream(provider, model: model, system: AIPage.system(fence: fence), messages: messages, key: key,
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
        let id = turn.id, answer = turn.answer
        Task.detached(priority: .userInitiated) { [weak self] in
            let strays = AIPage.strays(in: answer, from: read)
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
    func summarizePage() { startAssistant(summary: true) }
    func askAboutPage() { startAssistant(summary: false) }
    func askAboutPage(from tab: Tab, selection: String? = nil) { startAssistant(summary: false, from: tab, selection: selection) }

    private func startAssistant(summary: Bool, from source: Tab? = nil, selection: String? = nil) {
        guard AI.shipped || Store.testing, let tab = source ?? active, tab.isWeb, !isPopup else { return }
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
        guard let scheme = tab.pageAddress?.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
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
        let assistant = Assistant(tab: tab, provider: provider, model: model, summary: summary, selection: selection)
        assistantSessions[tab.id] = assistant
        assisting = assistant
        sidePanel = .assistant
        sidePanelShown = true
    }

    func closeAssistant() {
        if let assistant = assisting { closeAssistant(for: assistant.tab) }
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
        guard tab.isWeb, assistant.sourceURL == tab.pageAddress,
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
}

// MARK: - the panel

struct AssistantPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var assistant: Assistant
    /// A deterministic rendering of these same controls, without native
    /// text fields or scroll views, for the isolated picture command.
    var drawn = false
    @FocusState private var typing: Bool
    @State private var models: [OpenCodeAI.Model] = []
    @State private var expandedContext = false

    private var catalogue: [OpenCodeAI.Model] {
        if !models.isEmpty { return models }
        return drawn ? (try? OpenCodeAI.catalogue()) ?? [] : []
    }

    private var chosenModel: OpenCodeAI.Model? { catalogue.first { $0.id == assistant.model } }
    private var modelName: String { Self.modelLabel(for: assistant.model, provider: assistant.provider, models: catalogue) }
    private var selected: Bool { assistant.selection != nil }
    private var empty: Bool {
        assistant.turns.isEmpty && assistant.notice == nil && assistant.trouble == nil && !assistant.reading
    }
    private var canSend: Bool {
        !assistant.busy && assistant.notice == nil && assistant.context != nil &&
            !assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var placeholder: String {
        !assistant.turns.isEmpty ? "Ask a follow-up…" : selected ? "Ask about this selection…" : "Ask about this page…"
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
            modelControl
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            Rectangle().fill(Palette.hairline).frame(height: 1).padding(.horizontal, 14)
            if let context = assistant.context { contextCard(context) }
            if drawn {
                conversation
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: empty ? .center : .topLeading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            } else {
                scrolling
            }
            composer
            privacyNote
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.ground)
        .onAppear {
            models = (try? OpenCodeAI.catalogue()) ?? []
            if !assistant.summary, !drawn { typing = true }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles").font(.system(size: 13, weight: .medium))
            Text("Ask AI").font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            Door(icon: "gearshape", help: "Settings › AI") { _ = browser.show(InternalPage(.settings, SettingsPanel.Page.ai.rawValue)) }
            Door(icon: "xmark", help: "Close") { browser.closeAssistant() }
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var modelControl: some View {
        HStack(spacing: 0) {
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
                } label: { modelChip }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize(horizontal: false, vertical: true)
                .disabled(assistant.busy || assistant.notice != nil)
                .accessibilityLabel("AI model")
            } else {
                modelChip
            }
            Spacer(minLength: 0)
        }
    }

    private var modelChip: some View {
        HStack(spacing: 14) {
            Text(verbatim: modelName)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.muted)
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Palette.wash.opacity(0.65), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private func contextCard(_ context: AIPage.Read) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(Motion.quick) { expandedContext.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: selected ? "text.quote" : "doc.text")
                    Text(selected ? "Selected text" : "Page context")
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .rotationEffect(.degrees(expandedContext ? 180 : 0))
                }
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expandedContext ? "Collapse context" : "Show the full context sent with your question")
            .accessibilityLabel(expandedContext ? "Collapse context" : "Expand context")
            if (!selected || expandedContext), !context.title.isEmpty {
                Text(verbatim: context.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
            }
            if expandedContext {
                ScrollView {
                    contextText(context.text)
                }
                .frame(maxHeight: 180)
            } else if selected {
                Text(verbatim: String(context.text.prefix(900)))
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            if let host = context.url?.host() {
                Text(verbatim: host)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(Palette.ink)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.wash.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .padding(.horizontal, 14)
        .padding(.top, 14)
    }

    private func contextText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12.5))
            .lineSpacing(2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 17) {
            VStack(alignment: .leading, spacing: 7) {
                Text("What would you like to know?")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(selected ? "Ask about the selected passage." : "Ask about this page or a selected passage.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                suggestionRow(selected ? "Summarize this selection" : "Summarize this page", icon: "doc.text") {
                    assistant.submitSuggestion(selected ? "Summarize this selected passage in a few sentences." : "Summarize this page in a few sentences.")
                }
                suggestionRow(selected ? "Explain this selection" : "Explain a selection", icon: "text.alignleft") {
                    if selected {
                        assistant.submitSuggestion("Explain this selected passage in clear, simple terms.")
                    } else {
                        browser.announce("Select a passage on the page, then right-click and choose Ask AI")
                        typing = true
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suggestionRow(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Palette.muted).frame(width: 16)
                Text(title).font(.system(size: 12.5)).lineLimit(2)
                Spacer(minLength: 4)
                Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            .foregroundStyle(Palette.ink)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.wash.opacity(0.28), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(assistant.busy || assistant.notice != nil || assistant.context == nil)
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let trouble = assistant.trouble, assistant.notice == nil {
                Text(verbatim: trouble).font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else if assistant.reading {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.system(size: 12))
                    Text("Reading the page…").font(.system(size: 12.5))
                }
                .foregroundStyle(Palette.muted)
            } else if empty {
                emptyState
            }
            if assistant.addressed, assistant.notice == nil {
                caution("This page has text written for an AI to follow. The answer may have been steered by it.")
            }
            ForEach(assistant.turns) { turn in
                TurnView(turn: turn).id(turn.id)
            }
            if let question = assistant.pendingQuestion { questionBubble(question).id("pending-question") }
            if let notice = assistant.notice { noticeCard(notice) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var scrolling: some View {
        GeometryReader { area in
            ScrollViewReader { scroller in
                ScrollView(showsIndicators: false) {
                    conversation
                        .frame(minHeight: max(0, area.size.height - 28), alignment: empty ? .center : .topLeading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                }
                .onChange(of: assistant.turns.last?.answer) { _, _ in
                    if let last = assistant.turns.last { scroller.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: assistant.pendingQuestion) { _, question in
                    if question != nil { scroller.scrollTo("pending-question", anchor: .top) }
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if drawn {
                Text(verbatim: assistant.draft.isEmpty ? placeholder : assistant.draft)
                    .foregroundStyle(assistant.draft.isEmpty ? Palette.muted : Palette.ink)
                    .font(.system(size: 12.5))
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
            } else {
                TextField("", text: $assistant.draft, prompt: Text(placeholder).foregroundStyle(Palette.muted), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($typing)
                    .lineLimit(1...5)
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
                    .submitLabel(.send)
                    .onSubmit { assistant.submit() }
                    .onKeyPress(.return, phases: .down) { press in
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        assistant.submit()
                        return .handled
                    }
                    .disabled(assistant.notice != nil)
            }
            if assistant.busy && !assistant.reading {
                Button { assistant.cancelAnswer() } label: { sendIcon(stopping: true) }
                    .buttonStyle(.plain)
                    .help("Stop answer")
                    .accessibilityLabel("Stop answer")
            } else {
                Button { assistant.submit() } label: { sendIcon(stopping: false) }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Send question")
                    .accessibilityLabel("Send question")
            }
        }
        .padding(12)
        .background(Palette.wash.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private func sendIcon(stopping: Bool) -> some View {
        Image(systemName: stopping ? "stop.fill" : "arrow.up")
            .font(.system(size: stopping ? 11 : 13, weight: .semibold))
            .foregroundStyle(Palette.ground)
            .frame(width: 29, height: 29)
            .background(Palette.ink.opacity(stopping || canSend ? 0.95 : 0.66), in: Circle())
    }

    private var privacyNote: some View {
        let note = assistant.provider.isLocal ? "Stays on this Mac" : "Only sent when you ask"
        let provider = chosenModel?.providerName ?? assistant.provider.name
        return Text("\(note) · \(provider)")
            .font(.system(size: 10.5))
            .foregroundStyle(Palette.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.top, 9)
            .padding(.bottom, 11)
            .help("AI may be wrong. Destination: \(assistant.destinationHost)")
    }

    private func caution(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 10, weight: .medium))
            Text(verbatim: text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Palette.muted)
        .padding(9)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func noticeCard(_ notice: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Answers from \(assistant.provider.name)")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.ink)
            Text(verbatim: notice)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Pill("Continue", filled: true) { assistant.agree() }
                Pill("Cancel") { browser.closeAssistant() }
            }
        }
        .padding(12)
        .background(Palette.wash.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private static func bubble(_ question: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 28)
            Text(verbatim: question)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(Palette.wash.opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func questionBubble(_ question: String) -> some View { Self.bubble(question) }

    private struct TurnView: View {
        let turn: Assistant.Turn
        @State private var copied = false

        var body: some View {
            VStack(alignment: .leading, spacing: 15) {
                if let question = turn.question { AssistantPanel.bubble(question) }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 14)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 9) {
                        if turn.answer.isEmpty, !turn.done {
                            Text("Thinking…").font(.system(size: 12.5)).foregroundStyle(Palette.faint)
                        }
                        // Plain text cannot fetch images or turn model output
                        // into links that the original page never contained.
                        if !turn.answer.isEmpty {
                            Text(verbatim: turn.answer)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Palette.ink)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let failed = turn.failed {
                            Text(verbatim: failed).font(.system(size: 12)).foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !turn.strays.isEmpty {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "exclamationmark.triangle").font(.system(size: 10, weight: .medium))
                                Text(verbatim: "Not on the page: " + turn.strays.joined(separator: ", "))
                                    .font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                            }
                            .foregroundStyle(Palette.muted)
                            .padding(8)
                            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        if !turn.answer.isEmpty {
                            Button {
                                AssistantPanel.copyAnswer(turn.answer)
                                copied = true
                            } label: {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.muted)
                                    .frame(width: 26, height: 25)
                                    .background(Palette.wash.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .help(copied ? "Copied" : "Copy answer")
                            .accessibilityLabel("Copy answer")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: turn.answer) { _, _ in copied = false }
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
