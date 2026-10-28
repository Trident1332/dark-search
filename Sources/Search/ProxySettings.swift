import SwiftUI

// Settings › Proxy, the parts that aren't a switch: the server's fields,
// the name and password, the connection's result and where sites see you
// from, the sites the proxy is skipped for — and the mark beside the
// address while pages take the route. The rows themselves are listed in
// SettingsIndex and drawn by Settings.swift, as every other section's are.

// MARK: - the mark beside the address

/// Beside the address of the tab you are on, while its pages take the
/// route: the proxy's place when it is known, its name otherwise; amber
/// while the proxy isn't answering. A click opens Settings › Proxy.
struct ProxySign: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    var colour: Color = Palette.muted
    @ObservedObject private var proxy = Proxy.shared
    @State private var hovering = false

    private var shown: Bool {
        proxy.setup.shows && tab.id == browser.activeID && !tab.isBlank && proxy.routes(for: Spaces.profile(of: browser.spaceID))
    }

    private var trouble: Bool { !proxy.setup.complete || proxy.dropped || proxy.refused }

    private var words: String {
        if !proxy.setup.complete { return "Enter a proxy address in Settings › Proxy" }
        if proxy.refused { return "The proxy didn't accept the name or password" }
        if proxy.dropped { return "The proxy isn't answering — trying again every 15 seconds" }
        if let place = proxy.place { return "Through \(proxy.setup.name) · \(place)" }
        return "Through \(proxy.setup.name)"
    }

    var body: some View {
        if shown {
            Button { _ = browser.show(InternalPage(.settings, SettingsPanel.Page.proxy.rawValue)) } label: {
                Image(systemName: trouble ? "network.slash" : "network")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(trouble ? Palette.unsafe : (hovering ? Palette.ink : colour.opacity(0.75)))
                    .frame(width: 17, height: 15)
                    .background(Palette.ink.opacity(hovering ? 0.07 : 0),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(words)
            .accessibilityLabel(words)
            .animation(Motion.quick, value: hovering)
            .animation(Motion.quick, value: trouble)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
    }
}

// MARK: - fields

/// A field in the wash, as Settings draws the custom engine's: a small
/// label, then what is typed.
private struct ProxyField<Field: View>: View {
    let label: String
    @ViewBuilder let field: () -> Field

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .frame(width: 56, alignment: .leading)
            field()
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// Under Server: the proxy's address and port.
struct ProxyServerFields: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        HStack(spacing: 8) {
            ProxyField(label: "Address") {
                TextField("proxy.example.com", text: $prefs.proxyHost)
                    .autocorrectionDisabled()
            }
            ProxyField(label: "Port") {
                TextField(String(prefs.proxyKind.usualPort), text: $prefs.proxyPort)
                    .frame(width: 52)
            }
            .fixedSize()
        }
        .padding(.leading, SettingsPanel.textInset)
        .padding(.trailing, 14)
        .padding(.bottom, 11)
    }
}

/// Under Requires a password: the name, and the password, which goes to
/// the keychain as it is typed and is never shown again. The field says
/// one is kept.
struct ProxySignInFields: View {
    @ObservedObject var prefs: Preferences
    @State private var password = ""
    @State private var kept = false
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 6) {
            ProxyField(label: "Name") {
                TextField("", text: $prefs.proxyUser)
                    .autocorrectionDisabled()
            }
            ProxyField(label: "Password") {
                SecureField(kept ? "••••••••  kept in your keychain" : "", text: $password)
                    .focused($typing)
                    .onSubmit(save)
            }
        }
        .padding(.leading, SettingsPanel.textInset)
        .padding(.trailing, 14)
        .padding(.bottom, 11)
        .onAppear { kept = ProxyPassword.kept(prefs.proxySetup) }
        .onChange(of: prefs.proxyUser) { _, _ in kept = ProxyPassword.kept(prefs.proxySetup) }
        .onChange(of: prefs.proxyHost) { _, _ in kept = ProxyPassword.kept(prefs.proxySetup) }
        .onChange(of: typing) { _, now in if !now { save() } }
    }

    /// Kept on Return, or when the field is left: nothing to press, and the
    /// field is emptied so it holds the password no longer than that.
    private func save() {
        guard !password.isEmpty else { return }
        guard ProxyPassword.save(password, for: prefs.proxySetup) else { return }
        password = ""
        kept = true
        Proxy.shared.passwordChanged()
    }
}

/// Under Connection, once a test reached the proxy: where sites see you
/// from, and the address they see.
struct ProxyLocationLine: View {
    @ObservedObject private var proxy = Proxy.shared

    var body: some View {
        if case .reached(_, let address, let place) = proxy.check, place != nil || address != nil {
            Rule()
            Line("Location", [place, address.map { "Sites see \($0)" }].compactMap { $0 }.joined(separator: " · ")) {
                EmptyView()
            }
        }
    }
}

/// Under Don't use the proxy for: a line being typed, then each site with
/// a way to take it back. The Mac itself is always there.
struct ProxyBypassList: View {
    @ObservedObject var prefs: Preferences
    @Binding var draft: String?
    @FocusState private var typing: Bool

    var body: some View {
        if draft != nil {
            ProxyField(label: "Site") {
                TextField("example.com, or a whole domain", text: Binding(get: { draft ?? "" }, set: { draft = $0 }))
                    .autocorrectionDisabled()
                    .focused($typing)
                    .onSubmit(add)
                    .onExitCommand { draft = nil }
            }
            .padding(.leading, SettingsPanel.textInset)
            .padding(.trailing, 14)
            .padding(.bottom, 6)
            .onAppear { typing = true }
        }
        Rule()
        Line("This Mac", "localhost, 127.0.0.1 and ::1") { Always(text: "Always") }
        ForEach(prefs.proxyBypass, id: \.self) { site in
            Rule()
            Line(site, nil) {
                Pill("Remove") { prefs.proxyBypass.removeAll { $0 == site } }
            }
        }
    }

    /// What was typed, as a domain, once; nothing for a line that isn't one.
    func add() {
        let site = ProxySetup.domain(draft ?? "")
        guard !site.isEmpty else { return }
        if !prefs.proxyBypass.contains(site) { prefs.proxyBypass.append(site) }
        draft = nil
    }
}
