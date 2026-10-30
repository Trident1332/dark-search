import SwiftUI

/// Every password kept, by site, and the notes beside them: the Passwords
/// page. The same white-and-hairline page as the rest, with one rule that
/// is its own: it opens locked, and nothing in it is shown until the Mac
/// has said who you are (VaultLock). Open, the list is on the left and
/// whatever is picked from it on the right; a secret is read only when it
/// is picked or shown, and let go with the row.
struct PasswordsPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var lock = VaultLock.shared

    /// What the page shows: the window's (Browser.passwordsPage), so a tab
    /// away and back finds it as it was, and the bench can set it.
    @ObservedObject private var page: PasswordsPage
    @FocusState private var hunting: Bool
    /// The Mac has been asked once since the page came: a no leaves the
    /// Unlock button, not another sheet.
    @State private var asked = false

    init(browser: Browser) {
        self.browser = browser
        page = browser.passwordsPage
    }

    private var section: Section {
        get { page.section }
        nonmutating set { page.section = newValue }
    }
    /// The site unfolded in the list.
    private var open: String? {
        get { page.open }
        nonmutating set { page.open = newValue }
    }
    private var picked: Pick? {
        get { page.picked }
        nonmutating set { page.picked = newValue }
    }
    /// The generator is up in place of the picked account.
    private var changing: Bool {
        get { page.changing }
        nonmutating set { page.changing = newValue }
    }
    private var adding: Adding? {
        get { page.adding }
        nonmutating set { page.adding = newValue }
    }
    private var checkup: Vault.Checkup? {
        get { page.checkup }
        nonmutating set { page.checkup = newValue }
    }

    enum Section: String, CaseIterable, Identifiable {
        case all, logins, notes, checkup, recent

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .logins: return "Logins"
            case .notes: return "Notes"
            case .checkup: return "Checkup"
            case .recent: return "Recently used"
            }
        }
    }

    enum Pick: Equatable {
        case login(Kept)
        case note(Note)
    }

    enum Adding: Equatable {
        case login, note
    }

    var body: some View {
        Plate("Dark Search Passwords", width: 980, close: { browser.managing = false }, aside: AnyView(status)) {
            if lock.open { opened } else { locked }
        } foot: {
            foot
        }
        .animation(Motion.settle, value: adding)
        .animation(Motion.settle, value: open)
        .animation(Motion.settle, value: lock.open)
        .onAppear {
            page.legacyCount = Vault.legacyCount
            guard !lock.open, !asked else { return }
            asked = true
            lock.unlock()
        }
        .onChange(of: lock.open) { _, now in
            if now {
                browser.relist()
                hunting = true
            } else {
                picked = nil
                changing = false
                adding = nil
                checkup = nil
                open = nil
            }
        }
        // What is picked follows the list: an account removed goes from the
        // right too, a note retitled is retitled there.
        .onChange(of: browser.saved) { _, saved in
            guard case .login(let kept) = picked else { return }
            picked = saved.first { $0.id == kept.id }.map(Pick.login)
            if picked == nil { changing = false }
        }
        .onChange(of: browser.notes) { _, notes in
            guard case .note(let note) = picked else { return }
            picked = notes.first { $0.id == note.id }.map(Pick.note)
        }
    }

    // MARK: - the lock

    /// Beside the title: open, and for how long, with Lock beside it.
    @ViewBuilder private var status: some View {
        if lock.open {
            HStack(spacing: 10) {
                Countdown(until: lock.until)
                Pill("Lock") { lock.lock() }
            }
        }
    }

    private var locked: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Palette.ink)
                .padding(.bottom, 4)
            Text("Dark Search Passwords is locked")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text("Unlock with Touch ID. Passwords lock again after \(VaultLock.lockAfter.spoken), when the Mac sleeps and when you lock the screen. Filling a website always asks for Touch ID.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .fixedSize(horizontal: false, vertical: true)
            Pill("Unlock", filled: true) { lock.unlock() }
                .padding(.top, 4)
            Text(tally)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .listHeight(420)
    }

    private var tally: String {
        let passwords = browser.saved.count == 1 ? "1 password" : "\(browser.saved.count) passwords"
        let notes = browser.notes.count == 1 ? "1 note" : "\(browser.notes.count) notes"
        return "\(passwords) in Dark Search Passwords" + (browser.notes.isEmpty ? "" : " · \(notes) in Keychain")
    }

    // MARK: - open

    private var opened: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Hunt(text: $browser.hunting, prompt: "Search sites, accounts and notes", focus: $hunting)
                Pill(adding == nil ? "Add" : "Cancel", filled: adding == nil) {
                    adding = adding == nil ? (section == .notes ? .note : .login) : nil
                }
            }

            if let adding {
                Card { AddForm(browser: browser, kind: adding) { self.adding = nil } }
                    .transition(.opacity)
            }

            HStack(alignment: .top, spacing: 14) {
                rail
                list
                detail
            }
            .listHeight(460)
        }
    }

    private var rail: some View {
        VStack(spacing: 2) {
            ForEach(Section.allCases) { which in
                RailRow(title: which.title, count: count(of: which), lit: section == which,
                        warn: which == .checkup && (checkup?.flags.count ?? 0) > 0) {
                    section = which
                    picked = nil
                    changing = false
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 150)
    }

    private func count(of section: Section) -> Int? {
        switch section {
        case .all: return browser.saved.count + browser.notes.count
        case .logins: return browser.saved.count
        case .notes: return browser.notes.count
        case .checkup: return checkup.map { $0.flags.count }
        case .recent: return nil
        }
    }

    @ViewBuilder private var list: some View {
        if section == .checkup {
            CheckupView(browser: browser, checkup: $page.checkup, checking: $page.checking) { kept in
                picked = .login(kept)
                changing = true
            }
        } else {
            ScrollView(showsIndicators: false) {
                Card { rows }
                    .padding(.bottom, 2)
            }
        }
    }

    /// What the search leaves of the section: sites with their accounts,
    /// the notes, or the accounts last used.
    @ViewBuilder private var rows: some View {
        let sites = section == .all || section == .logins ? browser.shownSites : []
        let notes = section == .all || section == .notes ? browser.shownNotes : []
        let recent = section == .recent ? lastUsed : []
        if sites.isEmpty, notes.isEmpty, recent.isEmpty {
            Nothing(nothingSaid)
        }
        ForEach(Array(sites.enumerated()), id: \.element.host) { index, site in
            if index > 0 { Rule() }
            Site(
                host: site.host,
                logins: site.logins,
                open: open == site.host,
                picked: pickedLogin,
                toggle: {
                    open = open == site.host ? nil : site.host
                    // One account: unfolding it is picking it.
                    if open == site.host, site.logins.count == 1 { pick(site.logins[0]) }
                },
                pick: pick
            )
        }
        if !notes.isEmpty, !sites.isEmpty {
            Rule(inset: 0)
            Text("Notes")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)
        }
        ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
            if index > 0 || !sites.isEmpty { Rule() }
            NoteRow(note: note, lit: pickedNote?.id == note.id) {
                picked = .note(note)
                changing = false
            }
        }
        ForEach(Array(recent.enumerated()), id: \.element.id) { index, kept in
            if index > 0 { Rule() }
            UsedRow(kept: kept, lit: pickedLogin?.id == kept.id) { pick(kept) }
        }
    }

    private var nothingSaid: String {
        let searching = !browser.hunting.trimmingCharacters(in: .whitespaces).isEmpty
        if searching { return "Nothing matches." }
        switch section {
        case .notes: return "No notes yet. Add one for the things that aren't a sign-in: a Wi-Fi password, a safe's combination, the recovery codes behind a login."
        case .recent: return "Nothing used to sign in yet."
        default: return "Nothing kept yet. Sign in somewhere and say yes, or bring yours in below."
        }
    }

    /// The accounts used to sign in, newest first, the search applied.
    private var lastUsed: [Kept] {
        let needle = browser.hunting.trimmingCharacters(in: .whitespaces).lowercased()
        return browser.saved
            .filter { $0.used != nil && (needle.isEmpty || $0.host.contains(needle) || $0.user.lowercased().contains(needle)) }
            .sorted { ($0.used ?? .distantPast) > ($1.used ?? .distantPast) }
            .prefix(40)
            .map { $0 }
    }

    private var pickedLogin: Kept? {
        if case .login(let kept) = picked { return kept }
        return nil
    }

    private var pickedNote: Note? {
        if case .note(let note) = picked { return note }
        return nil
    }

    private func pick(_ kept: Kept) {
        picked = .login(kept)
        changing = false
        lock.touch()
    }

    private var detail: some View {
        Card {
            switch picked {
            case .login(let kept):
                LoginDetail(browser: browser, kept: kept, changing: $page.changing) {
                    Ask.sure("Remove the password for \(kept.host)?",
                             detail: "It's removed from Dark Search Passwords. This can't be undone.",
                             confirm: "Remove", returnCancels: true) {
                        browser.forget(kept)
                        picked = nil
                    }
                }
                .id(kept.id)
            case .note(let note):
                NoteDetail(browser: browser, note: note) {
                    Ask.sure("Remove \"\(note.title)\"?",
                             detail: "The note is taken out of your keychain. This can't be undone.",
                             confirm: "Remove", returnCancels: true) {
                        browser.forgetNote(note)
                        picked = nil
                    }
                }
                .id(note.id)
            case nil:
                Nothing(section == .checkup
                        ? "Change… on an account opens a new password for it here."
                        : "Pick an account or a note to see it here.")
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(width: 340)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var foot: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Bring in from")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                // Which browser, which profile and what of it: the sheet.
                Pill("Bring in") { browser.lead(to: InternalPage(.importing)) }
                Pill("File") { browser.importFile() }
                Spacer(minLength: 0)
                // What the list shows, all of it or what the search
                // leaves: never more than can be seen (Browser.forgetShown).
                let shown = browser.shownSites.reduce(0) { $0 + $1.logins.count }
                if lock.open, shown > 0, section != .notes {
                    Pill(browser.hunting.trimmingCharacters(in: .whitespaces).isEmpty ? "Remove All" : "Remove \(shown)") {
                        browser.forgetShown()
                    }
                    .disabled(browser.forgetting)
                }
                Text(browser.saved.count == 1 ? "1 password" : "\(browser.saved.count) passwords")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            if page.legacyCount > 0 || page.importingLegacy || page.legacyImportResult != nil {
                legacyImport
            }
            Text("Imported logins stay encrypted in Dark Search Passwords on this Mac. Touch ID approves filling them on a website.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Only metadata is counted on appearance. Reading the old passwords
    /// and copying them into this vault starts with this explicit action.
    private var legacyImport: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Existing Keychain logins")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text(page.legacyImportResult ?? "\(page.legacyCount) saved \(page.legacyCount == 1 ? "login" : "logins") can be imported. The originals stay in Keychain.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if !lock.open {
                    Text("Unlock Passwords to import.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                }
            }
            Spacer(minLength: 0)
            if page.legacyCount > 0 || page.importingLegacy {
                Pill(page.importingLegacy ? "Importing" : "Import from Keychain", action: importLegacy)
                    .disabled(!lock.open || page.importingLegacy)
            }
        }
        .padding(.vertical, 4)
    }

    private func importLegacy() {
        guard lock.open, !page.importingLegacy else { return }
        page.importingLegacy = true
        page.legacyImportResult = nil
        Task {
            let result = await Vault.importLegacyLogins()
            page.importingLegacy = false
            page.legacyCount = Vault.legacyCount
            browser.relist()
            let message: String
            if let failure = Vault.lastFailure {
                message = failure
            } else {
                message = "Imported \(result.kept) \(result.kept == 1 ? "login" : "logins")" +
                    (result.skipped > 0 ? "; \(result.skipped) left unchanged" : "")
            }
            page.legacyImportResult = message
            browser.announce(message)
        }
    }

    // MARK: - pieces

    /// Open, and how long for, counted down beside the title.
    private struct Countdown: View {
        let until: Date?

        var body: some View {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 6) {
                    Image(systemName: "lock.open")
                        .font(.system(size: 10, weight: .medium))
                    Text(until.map { "Unlocked · locks in \(left(from: context.date, to: $0))" } ?? "Unlocked")
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                }
                .foregroundStyle(Palette.safe)
            }
        }

        private func left(from now: Date, to until: Date) -> String {
            let seconds = max(0, Int(until.timeIntervalSince(now).rounded()))
            if seconds >= 3600 {
                return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
            }
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
    }

    /// One of the sections down the left.
    private struct RailRow: View {
        let title: String
        let count: Int?
        let lit: Bool
        var warn = false
        let act: () -> Void

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: warn ? .medium : .regular))
                        .foregroundStyle(warn ? Palette.unsafe : Palette.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(lit ? Palette.wash : (hovering ? Palette.hover : .clear), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture(perform: act)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }

    /// A site, and under it its accounts once opened.
    private struct Site: View {
        let host: String
        let logins: [Kept]
        let open: Bool
        let picked: Kept?
        let toggle: () -> Void
        let pick: (Kept) -> Void

        @State private var hovering = false

        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Mark(icon: Favicons.shared.cached(host), letter: host.first.map { String($0).uppercased() } ?? "•", size: 16)
                    Text(host)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    if logins.contains(where: \.clear) {
                        Text("http")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.unsafe)
                    }
                    if logins.count > 1 {
                        Text("\(logins.count) accounts")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                    } else if let only = logins.first, !only.user.isEmpty, !open {
                        Text(only.user)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(open ? Palette.wash.opacity(0.6) : (hovering ? Palette.hover : .clear))
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)
                .onHover { hovering = $0 }
                .animation(Motion.quick, value: hovering)

                if open {
                    VStack(spacing: 0) {
                        ForEach(logins) { login in
                            AccountRow(login: login, lit: picked?.id == login.id) { pick(login) }
                        }
                    }
                    .padding(.leading, 30)
                    .padding(.trailing, 6)
                    .padding(.vertical, 4)
                    .transition(.opacity)
                }
            }
        }
    }

    /// One account under its site: the name, and the password as dots. Ten
    /// dots whatever it is: the row does not know the length until the
    /// secret is read, and a count that changed with it told anyone looking
    /// over a shoulder how long it was. The secret itself is the detail's.
    private struct AccountRow: View {
        let login: Kept
        let lit: Bool
        let pick: () -> Void

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 10) {
                Text(login.user.isEmpty ? "No username" : login.user)
                    .font(.system(size: 12))
                    .foregroundStyle(login.user.isEmpty ? Palette.faint : Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(String(repeating: "•", count: 10))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(lit ? Palette.ground : (hovering ? Palette.hover : .clear), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(lit ? Palette.hairline : .clear, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture(perform: pick)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }

    /// An account in Recently used: its site and name on one line, with
    /// when it was last used to sign in.
    private struct UsedRow: View {
        let kept: Kept
        let lit: Bool
        let pick: () -> Void

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 10) {
                Mark(icon: Favicons.shared.cached(kept.host), letter: kept.host.first.map { String($0).uppercased() } ?? "•", size: 16)
                Text(kept.host)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(kept.user.isEmpty ? "No username" : kept.user)
                    .font(.system(size: 11.5))
                    .foregroundStyle(kept.user.isEmpty ? Palette.faint : Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let used = kept.used {
                    Text(Said.ago(used))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(lit ? Palette.wash.opacity(0.6) : (hovering ? Palette.hover : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: pick)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }

    /// A note in the list: its title, and when it was last changed.
    private struct NoteRow: View {
        let note: Note
        let lit: Bool
        let pick: () -> Void

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: "note.text")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 16)
                Text(note.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let edited = note.edited {
                    Text("Edited \(Said.ago(edited))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(lit ? Palette.wash.opacity(0.6) : (hovering ? Palette.hover : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: pick)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }

    /// A small label over a value in the detail.
    private struct Label: View {
        let text: String
        init(_ text: String) { self.text = text }
        var body: some View {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
        }
    }

    /// How good a password is, as a bar and a word.
    private struct StrengthBar: View {
        let bits: Double
        let grade: Vault.Strength

        private var tint: Color {
            switch grade {
            case .weak: return Palette.unsafe
            case .fair: return Palette.muted
            case .strong: return Palette.safe
            }
        }

        var body: some View {
            HStack(spacing: 8) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.hairline)
                        Capsule().fill(tint)
                            .frame(width: geometry.size.width * min(1, bits / 100))
                    }
                }
                .frame(width: 120, height: 4)
                Text(bits > 0 ? "\(grade.title) · about \(Int(bits.rounded())) bits" : grade.title)
                    .font(.system(size: 12))
                    .foregroundStyle(tint)
            }
        }
    }

    // MARK: - an account

    /// The account picked: its site, name, password, the note beside it
    /// and when it was kept, with the things to do with each. The secret
    /// is read once the lock allows and let go with the view; with Ask
    /// again for each password on, only Show reads it.
    private struct LoginDetail: View {
        @ObservedObject var browser: Browser
        @ObservedObject private var lock = VaultLock.shared
        let kept: Kept
        @Binding var changing: Bool
        let remove: () -> Void

        @State private var secret: Secret?
        @State private var shown = false
        @State private var hide: DispatchWorkItem?
        @State private var editing = false
        @State private var draft = ""
        @State private var displayID = UUID()

        var body: some View {
            if changing {
                Generator(browser: browser, kept: kept, cancel: { changing = false }) { made in
                    browser.change(kept, to: made)
                    // Re-read the saved record when its detail returns;
                    // clearing this view must not lose its encrypted notes.
                    secret = nil
                    changing = false
                }
            } else {
                VStack(spacing: 0) {
                    header
                    Rule(inset: 0)
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Username")
                            Text(kept.user.isEmpty ? "No username" : kept.user)
                                .font(.system(size: 13))
                                .foregroundStyle(kept.user.isEmpty ? Palette.faint : Palette.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 8)
                        if !kept.user.isEmpty {
                            Quick("Copy") { browser.copyText(kept.user, said: "Username copied") }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    Rule()
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Password")
                            Text(shown ? (secret?.password ?? "") : String(repeating: "•", count: 10))
                                .font(.system(size: shown ? 12.5 : 10, design: .monospaced))
                                .foregroundStyle(shown ? Palette.ink : Palette.muted)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 8)
                        Quick(shown ? "Hide" : "Show") { shown ? conceal() : reveal() }
                        Quick("Copy") { browser.copy(kept) }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    if let secret {
                        Rule()
                        let strength = Vault.strength(of: secret.password)
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Strength")
                            StrengthBar(bits: strength.bits, grade: strength.grade)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        Rule()
                        notes(secret)
                    }
                    Rule()
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Kept")
                        Text(since)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.ink)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    Spacer(minLength: 0)
                    Rule(inset: 0)
                    HStack(spacing: 8) {
                        Pill("Change Password…") { changing = true }
                        Spacer(minLength: 0)
                        Pill("Remove", tint: .red.opacity(0.75), action: remove)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .onAppear { displayID = UUID(); load() }
                .onChange(of: lock.open) { _, now in
                    guard !now else { return }
                    clear()
                }
                .onDisappear(perform: clear)
                .animation(Motion.quick, value: shown)
                .animation(Motion.settle, value: secret == nil)
            }
        }

        private var header: some View {
            HStack(spacing: 10) {
                Mark(icon: Favicons.shared.cached(kept.host), letter: kept.host.first.map { String($0).uppercased() } ?? "•", size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kept.host)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(kept.used.map { "Used \(Said.ago($0))" } ?? "Not used to sign in yet")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 8)
                Quick("Open") {
                    if let url = URL(string: (kept.clear ? "http://" : "https://") + kept.host) { browser.open(url, foreground: true) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)
        }

        private func notes(_ secret: Secret) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Label("Notes")
                    Spacer(minLength: 8)
                    if editing {
                        Quick("Cancel") { draft = ""; editing = false }
                        Quick("Save") {
                            browser.change(kept, to: secret.password, notes: draft)
                            self.secret?.notes = draft
                            draft = ""
                            editing = false
                        }
                    } else {
                        Quick(secret.notes.isEmpty ? "Add" : "Edit") {
                            draft = secret.notes
                            editing = true
                        }
                    }
                }
                if editing {
                    TextEditor(text: $draft)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 60, maxHeight: 120)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else if !secret.notes.isEmpty {
                    Text(secret.notes)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(6)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }

        private var since: String {
            var said = kept.since.map { $0.formatted(date: .long, time: .omitted) } ?? "Before this was written down"
            if kept.clear { said += " · from a page over http" }
            return said
        }

        /// Open, and not asking for each: the password and note come with
        /// the pick, so the note and the strength can be shown. Otherwise
        /// nothing is read until Show.
        private func load() {
            guard lock.open, !VaultLock.asksEach, secret == nil else { return }
            secret = Vault.details(of: kept)
        }

        private func reveal() {
            let requested = displayID
            lock.allow("show the password for \(kept.host)") { ok in
                guard ok, lock.open, displayID == requested else { return }
                if secret == nil { secret = Vault.details(of: kept) }
                guard secret != nil else {
                    browser.announce(Vault.lastFailure ?? "The password couldn't be opened")
                    return
                }
                shown = true
                // Long enough to read or type across, and not a minute more.
                let work = DispatchWorkItem { conceal() }
                hide?.cancel()
                hide = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
            }
        }

        private func conceal() {
            hide?.cancel()
            hide = nil
            shown = false
        }

        private func clear() {
            displayID = UUID()
            conceal()
            secret = nil
            draft = ""
            editing = false
        }
    }

    /// A new password for the account, in place of its detail: made here,
    /// as long and of whatever kinds you say, and kept with Use.
    private struct Generator: View {
        @ObservedObject var browser: Browser
        let kept: Kept
        let cancel: () -> Void
        let use: (String) -> Void

        @State private var recipe = Vault.Recipe()
        @State private var length: Double = 20
        @State private var made = ""

        var body: some View {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("New password for \(kept.host)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(made)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                    let strength = Vault.strength(of: made)
                    StrengthBar(bits: strength.bits, grade: strength.grade)
                    HStack(spacing: 8) {
                        Pill("Another") { make() }
                        Pill("Copy") { browser.copyPassword(made) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                Rule(inset: 0)
                Line("Length", "Twenty is plenty; some sites take fewer") {
                    Steps(stops: Vault.Recipe.lengths, value: $length, home: 20) { "\(Int($0))" }
                }
                Rule()
                Line("Digits") { Switch(on: $recipe.digits) }
                Rule()
                Line("Symbols") { Switch(on: $recipe.symbols) }
                Rule()
                Line("Avoid look-alikes", "No l, 1, I, O or 0, for one you'll read out") { Switch(on: $recipe.plain) }
                Spacer(minLength: 0)
                Rule(inset: 0)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Use keeps it for \(kept.user.isEmpty ? kept.host : "\(kept.user) at \(kept.host)"). Change it on the site first, or next.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Pill("Cancel", action: cancel)
                        Spacer(minLength: 0)
                        Pill("Use", filled: true) { use(made) }
                    }
                }
                .padding(14)
            }
            .onAppear(perform: make)
            .onDisappear { made = "" }
            .onChange(of: recipe) { _, _ in make() }
            .onChange(of: length) { _, now in recipe.length = Int(now) }
        }

        private func make() { made = Vault.generate(recipe) }
    }

    // MARK: - a note

    /// The note picked: its title, its text once the lock allows, and the
    /// things to do with it. Edit turns both into fields.
    private struct NoteDetail: View {
        @ObservedObject var browser: Browser
        @ObservedObject private var lock = VaultLock.shared
        let note: Note
        let remove: () -> Void

        @State private var text: String?
        @State private var editing = false
        @State private var title = ""
        @State private var draft = ""
        @State private var readFailure: String?
        @State private var displayID = UUID()
        @FocusState private var focus: Int?

        var body: some View {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    if editing {
                        TextField("Title", text: $title)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .focused($focus, equals: 0)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        Text(note.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(2)
                        Text(note.edited.map { "Edited \(Said.ago($0))" } ?? "")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)
                Rule(inset: 0)
                if editing {
                    TextEditor(text: $draft)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Palette.ink)
                        .scrollContentBackground(.hidden)
                        .focused($focus, equals: 1)
                        .padding(8)
                } else if let text {
                    ScrollView(showsIndicators: false) {
                        Text(text.isEmpty ? "Nothing written yet." : text)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(text.isEmpty ? Palette.muted : Palette.ink)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                } else {
                    VStack(spacing: 8) {
                        Nothing(readFailure ?? "Locked.")
                        if readFailure != nil, lock.open { Pill("Try again", action: load) }
                    }
                }
                Spacer(minLength: 0)
                Rule(inset: 0)
                HStack(spacing: 8) {
                    if editing {
                        Pill("Cancel") { draft = ""; editing = false }
                        Pill("Save", filled: true, action: save)
                    } else {
                        Pill("Edit") {
                            guard let text else { return }
                            title = note.title
                            draft = text
                            editing = true
                            focus = 1
                        }
                        .disabled(text == nil)
                        Pill("Copy") {
                            if let text { browser.copyText(text, said: "Note copied") }
                        }
                        .disabled(text == nil)
                    }
                    Spacer(minLength: 0)
                    Pill("Remove", tint: .red.opacity(0.75), action: remove)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .onAppear { displayID = UUID(); load() }
            .onChange(of: lock.open) { _, now in
                guard !now else { return }
                clear()
            }
            .onDisappear(perform: clear)
        }

        private func load() {
            let requested = displayID
            lock.allow("open the note \(note.title)") { ok in
                guard lock.open, displayID == requested else { return }
                guard ok else { readFailure = "Touch ID wasn't approved"; return }
                guard let loaded = Vault.note(note.id) else {
                    readFailure = "The note couldn't be read from Keychain"
                    browser.announce("The note couldn't be read from Keychain")
                    return
                }
                readFailure = nil
                text = loaded
            }
        }

        private func clear() {
            displayID = UUID()
            text = nil
            draft = ""
            title = ""
            editing = false
            focus = nil
            readFailure = nil
        }

        private func save() {
            guard browser.keepNote(note.id, title: title, text: draft) != nil else { return }
            text = draft
            draft = ""
            editing = false
            browser.announce("Saved")
        }
    }

    // MARK: - the checkup

    /// Weak, reused, and kept from a page sent in the clear: counted, then
    /// listed, each with a way to a new password. Read when Check is
    /// pressed, never on its own.
    private struct CheckupView: View {
        @ObservedObject var browser: Browser
        @Binding var checkup: Vault.Checkup?
        @Binding var checking: Bool
        let change: (Kept) -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Stat("Weak", count: checkup?.weak, said: "Short, of one kind of character, or common")
                    Stat("Reused", count: checkup?.reused, said: "The same password on more than one account")
                    Stat("In the clear", count: checkup?.clear, said: "Kept from a page sent over plain http")
                }
                HStack(spacing: 10) {
                    Text(status)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Pill(checkup == nil ? "Check" : "Check Again", filled: checkup == nil, action: check)
                        .disabled(checking || browser.saved.isEmpty)
                }
                ScrollView(showsIndicators: false) {
                    Card {
                        if let checkup {
                            if checkup.flags.isEmpty {
                                Nothing("Nothing to say: every password is its own, strong, and kept from a page nobody on the way could read.")
                            }
                            ForEach(Array(checkup.flags.enumerated()), id: \.element.id) { index, flag in
                                if index > 0 { Rule() }
                                FlagRow(flag: flag) { change(flag.kept) }
                            }
                        } else {
                            Nothing("Check reads every password once, here on this Mac, and says which are weak, which are used on more than one account, and which came from a page sent in the clear. Nothing leaves the Mac.")
                        }
                    }
                    .padding(.bottom, 2)
                }
            }
        }

        private var status: String {
            if checking { return "Reading…" }
            guard let checkup else {
                return browser.saved.isEmpty ? "Nothing kept yet." : "Not checked yet."
            }
            let read = checkup.checked == 1 ? "1 password read" : "\(checkup.checked) passwords read"
            return "Checked \(Said.ago(checkup.at)) · \(read) once, here on this Mac"
        }

        private func check() {
            VaultLock.shared.allow("check your passwords") { ok in
                guard ok, !checking else { return }
                checking = true
                let kept = browser.saved
                // Checking every saved password can take a moment: off
                // the main thread, as imports are.
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Vault.checkup(kept)
                    DispatchQueue.main.async {
                        checkup = result
                        checking = false
                    }
                }
            }
        }

        private struct Stat: View {
            let title: String
            let count: Int?
            let said: String

            init(_ title: String, count: Int?, said: String) {
                self.title = title
                self.count = count
                self.said = said
            }

            var body: some View {
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                        Text(count.map(String.init) ?? "—")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(count == nil ? Palette.faint : (count == 0 ? Palette.safe : Palette.unsafe))
                            .monospacedDigit()
                        Text(said)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(14)
                }
            }
        }

        private struct FlagRow: View {
            let flag: Vault.Flag
            let change: () -> Void

            @State private var hovering = false

            var body: some View {
                HStack(spacing: 10) {
                    Mark(icon: Favicons.shared.cached(flag.kept.host), letter: flag.kept.host.first.map { String($0).uppercased() } ?? "•", size: 16)
                    Text(flag.kept.host)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minWidth: 100, maxWidth: 190, alignment: .leading)
                    Text(flag.kept.user.isEmpty ? "No username" : flag.kept.user)
                        .font(.system(size: 11.5))
                        .foregroundStyle(flag.kept.user.isEmpty ? Palette.faint : Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180, alignment: .leading)
                    Spacer(minLength: 8)
                    // The tags and the button keep their words on one line
                    // whatever the row has to give: the name gives instead.
                    HStack(spacing: 6) {
                        if flag.weak { Tag("Weak") }
                        if flag.sharedWith > 0 { Tag("Reused · \(flag.sharedWith + 1)") }
                        if flag.clear { Tag("http") }
                        Quick("Change…", act: change)
                    }
                    .fixedSize()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(hovering ? Palette.hover : .clear)
                .onHover { hovering = $0 }
                .animation(Motion.quick, value: hovering)
            }

            private struct Tag: View {
                let text: String
                init(_ text: String) { self.text = text }
                var body: some View {
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.unsafe)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(Palette.unsafe.opacity(0.35), lineWidth: 1))
                }
            }
        }
    }

    // MARK: - adding one

    /// Typing one in by hand: a login — the site, the name, the password,
    /// made here if you like — or a note, its title and text.
    private struct AddForm: View {
        @ObservedObject var browser: Browser
        @State var kind: Adding
        let done: () -> Void

        @State private var site = ""
        @State private var user = ""
        @State private var password = ""
        @State private var title = ""
        @State private var text = ""
        @FocusState private var focus: Int?

        init(browser: Browser, kind: Adding, done: @escaping () -> Void) {
            self.browser = browser
            _kind = State(initialValue: kind)
            self.done = done
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Segmented(options: [(Adding.login, "Login"), (Adding.note, "Note")], selection: $kind)
                if kind == .login {
                    HStack(spacing: 8) {
                        field("Site", text: $site, tag: 0)
                        field("Username", text: $user, tag: 1)
                    }
                    HStack(spacing: 8) {
                        ZStack(alignment: .leading) {
                            if password.isEmpty {
                                Text("Password").foregroundStyle(Palette.ink.opacity(0.3))
                                    .padding(.leading, 10)
                            }
                            SecureField("", text: $password)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(Palette.ink)
                                .focused($focus, equals: 2)
                                .onSubmit(keep)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                        }
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        Pill("Make One") { password = Vault.generate(Vault.Recipe()) }
                        Pill("Save", filled: true, action: keep)
                            .disabled(Vault.host(of: site).isEmpty || password.isEmpty)
                    }
                } else {
                    field("Title", text: $title, tag: 0)
                    TextEditor(text: $text)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Palette.ink)
                        .scrollContentBackground(.hidden)
                        .focused($focus, equals: 1)
                        .padding(6)
                        .frame(minHeight: 80, maxHeight: 160)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    HStack {
                        Spacer(minLength: 0)
                        Pill("Save", filled: true, action: keepNote)
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(14)
            .onAppear { focus = 0 }
            .onChange(of: kind) { _, _ in focus = 0 }
        }

        private func field(_ name: String, text: Binding<String>, tag: Int) -> some View {
            ZStack(alignment: .leading) {
                if text.wrappedValue.isEmpty {
                    Text(name).foregroundStyle(Palette.ink.opacity(0.3)).padding(.leading, 10)
                }
                TextField("", text: text)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.ink)
                    .focused($focus, equals: tag)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
            }
            .font(.system(size: 12.5))
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }

        private func keep() {
            let host = Vault.host(of: site)
            guard !host.isEmpty, !password.isEmpty else { return }
            browser.keep(host: host, user: user.trimmingCharacters(in: .whitespaces), password: password, notes: "")
            done()
        }

        private func keepNote() {
            guard browser.keepNote(title: title, text: text) != nil else { return }
            browser.announce("Note kept")
            done()
        }
    }
}

/// What the Passwords page is showing, kept with the window rather than
/// with the view: a tab away and back finds the page as it was, and the
/// bench can put it in any of its states to look at (Bench.swift,
/// "passwords"). None of it is a secret: which section, which account,
/// whether the generator is up.
@MainActor
final class PasswordsPage: ObservableObject {
    @Published var section = PasswordsPanel.Section.all
    /// The site unfolded in the list.
    @Published var open: String?
    @Published var picked: PasswordsPanel.Pick?
    /// The generator is up in place of the picked account.
    @Published var changing = false
    @Published var adding: PasswordsPanel.Adding?
    @Published var checkup: Vault.Checkup?
    @Published var checking = false
    @Published var legacyCount = 0
    @Published var importingLegacy = false
    @Published var legacyImportResult: String?
}

/// When something happened, as a person says it: "2 hours ago", "yesterday".
enum Said {
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()

    static func ago(_ date: Date, from now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return relative.localizedString(for: date, relativeTo: now)
    }
}
