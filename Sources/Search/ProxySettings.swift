import AppKit
import SwiftUI

// Settings › Proxy, the parts that aren't a switch: the server's fields,
// the name and password, the connection's result and where sites see you
// from, the sites the proxy is skipped for — and the mark beside the
// address while pages take the route. The rows themselves are listed in
// SettingsIndex and drawn by Settings.swift, as every other section's are.

// MARK: - the mark beside the address

/// Beside the address of the tab you are on, while its pages take the
/// route: the flat flag of where sites see you from once the proxy is
/// reached (Flag.swift), a green lock while the place isn't known, with
/// where sites see you on hover; the network mark until then; amber while
/// the proxy isn't answering. A click opens its menu (ProxyMenu).
struct ProxySign: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    var colour: Color = Palette.muted
    @ObservedObject private var proxy = Proxy.shared
    @ObservedObject private var onion = Onion.shared
    @ObservedObject private var prefs = Shared.prefs
    @State private var hovering = false

    private var shown: Bool {
        tab.id == browser.activeID && !tab.isBlank
            && (tab.usesTor || (proxy.setup.shows && (proxy.routes(for: Spaces.profile(of: browser.spaceID)) || (!proxy.setup.on && !prefs.savedProxies.isEmpty))))
    }

    private var trouble: Bool {
        tab.usesTor ? !onion.ready : proxy.setup.on && (!proxy.setup.complete || proxy.dropped || proxy.refused || proxy.credentialIssue != nil)
    }

    private var words: String {
        if tab.usesTor { return "Tor · \(onion.status)" }
        if !proxy.setup.on { return "Proxy off · Choose a saved connection" }
        if !proxy.setup.complete { return "Enter a proxy address in Settings › Proxy" }
        if let issue = proxy.credentialIssue { return issue }
        if proxy.refused { return "The proxy didn't accept the name or password" }
        if proxy.dropped { return "The proxy isn't answering — trying again every 15 seconds" }
        if let place = proxy.place { return "Connected to \(place)" }
        return "Through \(proxy.setup.name)"
    }

    /// Reached, and nothing has gone wrong since.
    private var connected: Bool { proxy.setup.on && !trouble && proxy.place != nil }

    var body: some View {
        if shown {
            // A plain button, its menu an NSMenu of its own: as a SwiftUI
            // Menu's label the mark went into an AppKit pop-up button, which
            // draws no Canvas, so the flag (Flag.swift) never showed.
            Button { ProxyMenu.show(for: browser) } label: {
                Group {
                    if tab.usesTor {
                        Text("Tor").font(.system(size: 9, weight: .medium))
                    } else if connected, let code = proxy.countryCode {
                        FlatFlag(code: code, width: 15)
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

/// The sign's menu: the saved connections, the one in use ticked, Turn off
/// proxy, and Proxy settings…, at the pointer as the profile badge's is.
@MainActor
enum ProxyMenu {
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }
    private static var actions: [Action] = []

    private static func item(_ title: String, checked: Bool = false, enabled: Bool = true,
                             _ run: @escaping () -> Void) -> NSMenuItem {
        let action = Action(run)
        actions.append(action)
        let item = NSMenuItem(title: title, action: #selector(Action.fire), keyEquivalent: "")
        item.target = action
        item.state = checked ? .on : .off
        item.isEnabled = enabled
        return item
    }

    static func show(for browser: Browser) {
        actions = []
        let prefs = Shared.prefs
        let on = Proxy.shared.setup.on
        let menu = NSMenu()
        menu.autoenablesItems = false
        for connection in prefs.savedProxies {
            let id = connection.id
            menu.addItem(item(connection.title, checked: on && prefs.selectedProxyID == id) {
                Shared.prefs.selectProxy(id, connect: true)
            })
        }
        if !prefs.savedProxies.isEmpty { menu.addItem(.separator()) }
        menu.addItem(item("Turn off proxy", enabled: prefs.proxyOn) { Shared.prefs.proxyOn = false })
        menu.addItem(.separator())
        menu.addItem(item("Proxy settings…") { [weak browser] in
            _ = browser?.show(InternalPage(.settings, SettingsPanel.Page.proxy.rawValue))
        })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
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
        VStack(spacing: 8) {
            ProxyLineEntry(kind: prefs.proxyKind) { line in
                prefs.applyProxyLine(line) ? nil : "The password couldn't be saved. Unlock your Mac and try again."
            }
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
        }
        .padding(.leading, SettingsPanel.textInset)
        .padding(.trailing, 14)
        .padding(.bottom, 11)
    }
}

/// Pasted credentials stay masked and are discarded once the fields are filled.
struct ProxyLineEntry: View {
    let kind: ProxyKind
    let apply: (ProxyLine) -> String?
    @State private var draft = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                ProxyField(label: "One line") {
                    SecureField("host:port:username:password", text: $draft)
                        .autocorrectionDisabled()
                        .accessibilityLabel("One-line proxy")
                        .onSubmit(fill)
                }
                Pill("Fill fields", action: fill).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(message ?? "Paste host:port:username:password. Uses \(kind.title) unless a scheme is included.")
                .font(.system(size: 11)).foregroundStyle(message == nil ? Palette.muted : Palette.failed)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: draft) { _, _ in message = nil }
        .onDisappear { draft = "" }
    }

    private func fill() {
        do {
            let line = try ProxyLine.parse(draft, kind: kind)
            if let error = apply(line) { message = error; return }
            draft = ""; message = nil
        } catch { message = error.localizedDescription }
    }
}

/// Under Requires a password: the name, and the password, which goes to
/// the keychain as it is typed and is never shown again. The field says
/// one is kept.
struct ProxySignInFields: View {
    @ObservedObject var prefs: Preferences
    @State private var password = ""
    @State private var kept = false
    @State private var canImport = false
    @State private var importing = false
    @State private var message: String?
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 6) {
            ProxyField(label: "Name") {
                TextField("", text: $prefs.proxyUser)
                    .autocorrectionDisabled()
            }
            ProxyField(label: "Password") {
                SecureField(kept ? ConnectionPasswords.passwordPlaceholder : "", text: $password)
                    .focused($typing)
                    .onSubmit(save)
                if kept, password.isEmpty {
                    Quick("Forget", tint: Palette.muted) { forget() }
                        .help("Remove this saved password")
                        .transition(.opacity)
                }
            }
            if canImport {
                HStack {
                    Quick(importing ? "Importing…" : "Import saved password", tint: Palette.muted) { importSaved() }
                        .disabled(importing)
                        .help("Move the old password to encrypted storage on this Mac. macOS may ask once for access to its old Keychain copy.")
                    Spacer()
                }
            }
            if let message {
                Text(message).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, SettingsPanel.textInset)
        .padding(.trailing, 14)
        .padding(.bottom, 11)
        .onAppear(perform: refresh)
        .onChange(of: prefs.proxyUser) { _, _ in refresh() }
        .onChange(of: prefs.proxyHost) { _, _ in refresh() }
        .onChange(of: prefs.proxyKind) { _, _ in refresh() }
        .onChange(of: prefs.proxyPort) { _, _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: Proxy.routeChanged)) { _ in refresh() }
        .onChange(of: typing) { _, now in if !now { save() } }
        .animation(Motion.quick, value: kept)
    }

    /// Kept on Return, or when the field is left: nothing to press, and the
    /// field is emptied so it holds the password no longer than that.
    private func save() {
        guard !password.isEmpty else { return }
        guard ProxyPassword.save(password, for: prefs.proxySetup) else {
            message = "The password couldn't be saved. Unlock your Mac and try again"
            return
        }
        password = ""
        message = nil
        refresh()
        Proxy.shared.passwordChanged()
    }

    /// Out of the keychain; the route goes on without it.
    private func forget() {
        guard ProxyPassword.forget(prefs.proxySetup) else {
            message = "The saved password couldn't be removed"
            return
        }
        message = nil
        refresh()
        Proxy.shared.passwordChanged()
    }

    private func refresh() {
        kept = ProxyPassword.kept(prefs.proxySetup)
        canImport = ProxyPassword.legacyImportAvailable(prefs.proxySetup)
    }

    private func importSaved() {
        guard !importing else { return }
        let setup = prefs.proxySetup
        importing = true
        message = nil
        NSApp.activate()
        Task { @MainActor in
            let imported = await Task.detached(priority: .userInitiated) { ProxyPassword.importLegacy(setup) }.value
            importing = false
            guard prefs.proxySetup == setup else { refresh(); return }
            refresh()
            if imported { Proxy.shared.passwordChanged() }
            else if !kept { message = "Import wasn't completed. Enter the password to save it here instead" }
        }
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

// MARK: - saved connections

struct SavedProxySettings: View {
    @ObservedObject var prefs: Preferences
    @State private var editing: SavedProxy?

    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:8) {
                Picker("Connection",selection:Binding<UUID?>(get:{ prefs.selectedProxyID },set:{ id in if let id { prefs.selectProxy(id) } })) {
                    if prefs.selectedProxyID==nil { Text("Custom configuration").tag(nil as UUID?) }
                    ForEach(prefs.savedProxies) { connection in Text(connection.title).tag(Optional(connection.id)) }
                }.labelsHidden().frame(maxWidth:.infinity,alignment:.leading)
                Pill("Add") { editing=SavedProxy() }
                if let selected=prefs.savedProxies.first(where:{ $0.id==prefs.selectedProxyID }) {
                    Pill("Edit") { editing=selected }
                    Pill("Remove") { prefs.removeProxy(selected.id) }
                        .help("Remove this saved entry. The current connection stays configured")
                } else if prefs.proxySetup.complete {
                    Pill("Save current") { editing=SavedProxy(name:"",setup:prefs.proxySetup,port:prefs.proxyPort) }
                }
            }
            if let selected=prefs.savedProxies.first(where:{ $0.id==prefs.selectedProxyID }) {
                Text("\(selected.kind.title) · \(selected.setup.name)").font(.system(size:11)).foregroundStyle(Palette.muted)
            } else if prefs.savedProxies.isEmpty {
                Text("Save connections here, then switch from the proxy icon beside the address.")
                    .font(.system(size:11)).foregroundStyle(Palette.muted)
            }
        }
        .padding(.leading,SettingsPanel.textInset).padding(.trailing,14).padding(.bottom,12)
        .sheet(item:$editing) { connection in SavedProxyEditor(prefs:prefs,connection:connection) }
    }
}

private struct SavedProxyEditor: View {
    @ObservedObject var prefs: Preferences
    @Environment(\.dismiss) private var dismiss
    @State private var connection: SavedProxy
    @State private var password = ""
    @State private var message: String?

    init(prefs: Preferences, connection: SavedProxy) {
        self.prefs=prefs; _connection=State(initialValue:connection)
    }
    private var exists: Bool { prefs.savedProxies.contains { $0.id==connection.id } }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text(exists ? "Edit proxy" : "Add proxy").font(.system(size:20,weight:.semibold))
            ProxyField(label:"Name") { TextField("Work, home, another location…",text:$connection.name) }
            ProxyLineEntry(kind: connection.kind) { line in
                connection = line.filling(connection)
                password = line.password ?? ""
                message = nil
                return nil
            }
            Picker("Type",selection:$connection.kind) {
                ForEach(ProxyKind.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            ProxyField(label:"Address") { TextField("proxy.example.com",text:$connection.host).autocorrectionDisabled() }
            ProxyField(label:"Port") { TextField(String(connection.kind.usualPort),text:$connection.port) }
            Toggle("Requires a username and password",isOn:$connection.signsIn).font(.system(size:12))
            if connection.signsIn {
                ProxyField(label:"Username") { TextField("",text:$connection.user).autocorrectionDisabled() }
                ProxyField(label:"Password") {
                    SecureField(ProxyPassword.kept(connection.setup) ? ConnectionPasswords.passwordPlaceholder : "",text:$password)
                }
                Text(ConnectionPasswords.storageHint).font(.system(size:11)).foregroundStyle(Palette.muted)
            }
            if let message { Text(message).font(.system(size:11)).foregroundStyle(Palette.failed) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save",action:save).keyboardShortcut(.defaultAction).disabled(!connection.valid)
            }.padding(.top,6)
        }.padding(24).frame(width:400).background(Palette.ground).foregroundStyle(Palette.ink)
    }
    private func save() {
        var saved=connection
        saved.name=saved.name.trimmingCharacters(in:.whitespacesAndNewlines)
        saved.host=saved.host.trimmingCharacters(in:.whitespacesAndNewlines)
        saved.port=saved.port.trimmingCharacters(in:.whitespacesAndNewlines)
        guard saved.valid else { return }
        let before=prefs.proxySetup
        let hasPassword=saved.signsIn && !password.isEmpty
        if hasPassword,!ProxyPassword.save(password,for:saved.setup) {
            message="The password couldn't be saved. Unlock your Mac and try again."
            return
        }
        let id=prefs.saveProxy(saved)
        if prefs.selectedProxyID==nil,prefs.savedProxies.count==1,!before.complete { prefs.selectProxy(id) }
        if hasPassword,prefs.proxyOn,prefs.proxySignsIn,
           ProxyPassword.vaultIdentity(saved.setup)==ProxyPassword.vaultIdentity(prefs.proxySetup),prefs.proxySetup==before {
            Proxy.shared.passwordChanged()
        }
        password=""; dismiss()
    }
}
