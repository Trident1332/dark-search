import SwiftUI

// Settings › Proxy, the parts that aren't a switch: the server's fields,
// the name and password, the connection's result and where sites see you
// from, the sites the proxy is skipped for — and the mark beside the
// address while pages take the route. The rows themselves are listed in
// SettingsIndex and drawn by Settings.swift, as every other section's are.

// MARK: - the mark beside the address

/// Beside the address of the tab you are on, while its pages take the
/// route: a green lock once the proxy is reached, with where sites see
/// you on hover; the network mark until then; amber while the proxy
/// isn't answering. A click opens Settings › Proxy.
struct ProxySign: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    var colour: Color = Palette.muted
    @ObservedObject private var proxy = Proxy.shared
    @ObservedObject private var onion = Onion.shared
    @State private var hovering = false

    private var shown: Bool {
        tab.id == browser.activeID && !tab.isBlank
            && (tab.usesTor || (proxy.setup.shows && proxy.routes(for: Spaces.profile(of: browser.spaceID))))
    }

    private var trouble: Bool {
        tab.usesTor ? !onion.ready : (!proxy.setup.complete || proxy.dropped || proxy.refused)
    }

    private var words: String {
        if tab.usesTor { return "Tor · \(onion.status)" }
        if !proxy.setup.complete { return "Enter a proxy address in Settings › Proxy" }
        if proxy.refused { return "The proxy didn't accept the name or password" }
        if proxy.dropped { return "The proxy isn't answering — trying again every 15 seconds" }
        if let place = proxy.place { return "Connected to \(place)" }
        return "Through \(proxy.setup.name)"
    }

    /// Reached, and nothing has gone wrong since.
    private var connected: Bool { !trouble && proxy.place != nil }

    var body: some View {
        if shown {
            Button { _ = browser.show(InternalPage(.settings, SettingsPanel.Page.proxy.rawValue)) } label: {
                Group {
                    if tab.usesTor {
                        Text("Tor").font(.system(size: 9, weight: .medium))
                    } else if connected {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9.5, weight: .medium))
                    } else {
                        Image(systemName: trouble ? "network.slash" : "network")
                            .font(.system(size: 9, weight: .medium))
                    }
                }
                    .foregroundStyle(trouble ? Palette.unsafe : connected ? Palette.safe : (hovering ? Palette.ink : colour.opacity(0.75)))
                    .contentTransition(.symbolEffect(.replace))
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
            .animation(Motion.settle, value: connected)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
    }
}

/// Tor's connection control; status and failures stay in the settings row.
/// No stop button: turning off onion support is the explicit way to stop it.
struct TorConnection: View {
    @ObservedObject private var onion = Onion.shared

    var body: some View {
        if onion.ready {
            Always(text: "Connected")
        } else {
            Pill(onion.isConnecting ? "Connecting" : "Connect") { onion.retry() }
                .disabled(onion.isConnecting)
                .opacity(onion.isConnecting ? 0.5 : 1)
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
                if kept, password.isEmpty {
                    Quick("Forget", tint: Palette.muted) { forget() }
                        .help("Take the password out of your keychain")
                        .transition(.opacity)
                }
            }
        }
        .padding(.leading, SettingsPanel.textInset)
        .padding(.trailing, 14)
        .padding(.bottom, 11)
        .onAppear { kept = ProxyPassword.kept(prefs.proxySetup) }
        .onChange(of: prefs.proxyUser) { _, _ in kept = ProxyPassword.kept(prefs.proxySetup) }
        .onChange(of: prefs.proxyHost) { _, _ in kept = ProxyPassword.kept(prefs.proxySetup) }
        .onChange(of: prefs.proxyKind) { _, _ in kept = ProxyPassword.kept(prefs.proxySetup) }
        .onChange(of: prefs.proxyPort) { _, _ in kept = ProxyPassword.kept(prefs.proxySetup) }
        .onChange(of: typing) { _, now in if !now { save() } }
        .animation(Motion.quick, value: kept)
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

    /// Out of the keychain; the route goes on without it.
    private func forget() {
        guard ProxyPassword.forget(prefs.proxySetup) else { return }
        kept = false
        Proxy.shared.passwordChanged()
    }
}

/// Under Use a proxy while it is off: what to have ready, so the rows
/// that unfold when it goes on come as no surprise.
struct ProxyHint: View {
    var body: some View {
        Text("You'll need its address and port, from whoever runs it")
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, SettingsPanel.textInset)
            .padding(.trailing, 14)
            .padding(.bottom, 11)
            .padding(.top, -4)
    }
}

/// Under Status, once a test reached the proxy: where sites see you from,
/// with its flag and the address they see; and the time zone pages keep,
/// when they follow the proxy's.
struct ProxyLocationLine: View {
    @ObservedObject private var proxy = Proxy.shared

    var body: some View {
        if case .reached(_, let address, let place) = proxy.check, place != nil || address != nil {
            Rule()
            Line("Where sites see you", place ?? address) {
                HStack(spacing: 8) {
                    if let code = proxy.countryCode {
                        FlatFlag(code: code)
                    }
                    if let address, place != nil {
                        Text(address)
                            .font(.system(size: 11.5))
                            .monospacedDigit()
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Palette.wash, in: Capsule())
                            .help("The address sites see, instead of your Mac's")
                    }
                }
            }
        }
        if let zone = proxy.timeZoneID {
            Rule()
            Line("Time zone", ProxyLocationLine.words(for: zone)) { EmptyView() }
        }
    }

    /// "Pacific Time · America/Los_Angeles": the zone in words, then as
    /// pages know it.
    static func words(for zone: String) -> String {
        guard let named = TimeZone(identifier: zone)?.localizedName(for: .generic, locale: .current), named != zone else { return zone }
        return "\(named) · \(zone)"
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
