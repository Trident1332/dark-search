import AppKit
import Security
import SwiftUI
import WebKit

// Phone calls from the browser: Otto's dialer, built in.
//
// Otto's dialer is a softphone in a web page — SIP.js over a WebSocket to a
// FreeSWITCH box, the call's sound through WebRTC — which its Chrome
// extension shows in Chrome's side panel beside otto's leads table, so that
// a click on a number there is a call. Search shows the same page in its own
// side panel (SidePanel.swift), loaded from the app's own files
// (Resources/Dialer, copied into the bundle by build.sh), with a script of
// Search's own in place of Chrome's (search.js): what the page kept in
// chrome.storage it keeps in Search's settings and keychain, and what it
// told its background worker it tells Search, through one message handler.
//
// A number reaches the dialer four ways: a right-click on a number selected
// or under the pointer on any page, or a tel: link clicked (DialMenu.swift);
// otto's own click-to-call on the sites Settings › Dialer lists, the same
// window.postMessage bridge the extension offers (DialerSiteRelay); and the
// keypad. Off until Settings › Dialer turns it on; the line's details live
// there, the seat's password in the keychain (DialerPassword).
//
// The page connects to the phone server directly, never through Settings ›
// Proxy: a call's sound can't take a proxy's route, and the dialer is a
// thing reached for on purpose, not a page that happens to load.

/// Settings › Dialer, as the dialer takes them.
struct DialerSetup: Equatable {
    var on = false
    var wss = ""
    var domain = ""
    var user = ""
    /// The country numbers written without a code belong to, ISO 3166-1.
    var region = "GB"
    /// A number handed over is called at once; off, it waits on the keypad.
    var autodial = true
    /// Hosts whose pages may use the dialer, as otto's do.
    var sites: [String] = Dialer.defaultSites

    var trimmedWSS: String { wss.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedDomain: String { domain.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedUser: String { user.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Everything the page needs to sign in, the password aside.
    var complete: Bool { !trimmedWSS.isEmpty && !trimmedDomain.isEmpty && !trimmedUser.isEmpty }
    /// What the page connects with: changed, the page reconnects.
    var connection: [String] { [trimmedWSS, trimmedDomain, trimmedUser] }

    /// A WebSocket address as the page needs it: ws:// or wss://, nothing else.
    static func validWSS(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), url.host() != nil else { return false }
        return scheme == "ws" || scheme == "wss"
    }
}

@MainActor
final class Dialer: ObservableObject {
    static let shared = Dialer()

    /// The sites otto's extension bridges out of the box: otto itself, and a
    /// copy running on this Mac.
    nonisolated static let defaultSites = ["otto.investigate.agency", "localhost", "127.0.0.1"]

    /// What the page reads as its connection (chrome.storage.local's keys).
    nonisolated static let configKeys = ["wss", "domain", "user", "password", "autodial", "region"]
    /// What the page keeps for itself: recent calls, the trunk and the voice
    /// it was left on, and the calls otto hasn't taken yet.
    nonisolated static let pageKeys = ["history", "provider", "voice", "callOutbox"]
    /// Finished calls otto hasn't taken, newest last, at most this many.
    nonisolated static let outboxMost = 50

    private(set) var setup = DialerSetup()

    private init() {}

    /// Settings changed. Off: every window's dialer goes. A changed line:
    /// every page signs in again, as the extension does when its options
    /// are saved.
    func take(_ new: DialerSetup) {
        let old = setup
        setup = new
        guard old != new else { return }
        if old.on, !new.on {
            for browser in Browsers.all { browser.dropDialer() }
            objectWillChange.send()
            return
        }
        var changed: [String] = []
        if old.connection != new.connection { changed += ["wss", "domain", "user"] }
        if old.region != new.region { changed.append("region") }
        if old.autodial != new.autodial { changed.append("autodial") }
        if !changed.isEmpty { for browser in Browsers.all { browser.dialerPage?.settingsChanged(changed) } }
        objectWillChange.send()
    }

    /// The seat's password went into or out of the keychain.
    func passwordChanged() {
        for browser in Browsers.all { browser.dialerPage?.settingsChanged(["password"]) }
        objectWillChange.send()
    }

    /// A page's status changed: Settings › Dialer › Status redraws.
    func statusChanged() { objectWillChange.send() }

    // MARK: - the files

    /// Where the dialer's page is: in the app, or, for a run from the build
    /// folder, in the checkout the build came from.
    static let files: URL? = {
        if let path = ProcessInfo.processInfo.environment["SEARCH_DIALER_FILES"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("Dialer", isDirectory: true)) }
        if Store.testing {
            // A run from the build folder, or the test suite: the checkout
            // the build came from, found from the binary or from this file.
            if var at = Bundle.main.executableURL?.deletingLastPathComponent() {
                for _ in 0..<6 {
                    candidates.append(at.appendingPathComponent("Resources/Dialer", isDirectory: true))
                    at.deleteLastPathComponent()
                }
            }
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            candidates.append(source.appendingPathComponent("Resources/Dialer", isDirectory: true))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("dialer.html").path) }
    }()

    static var page: URL? { files?.appendingPathComponent("dialer.html") }

    // MARK: - sites

    /// A host whose pages may use the dialer: one of the sites listed, as
    /// typed, case aside.
    func allows(host: String?) -> Bool {
        guard setup.on, let host = host?.lowercased(), !host.isEmpty else { return false }
        return setup.sites.contains { $0.lowercased() == host }
    }

    /// A site as the list keeps it: its host alone.
    nonisolated static func site(_ typed: String) -> String { ProxySetup.domain(typed) }

    // MARK: - what the page keeps

    /// The connection and the page's own values, for chrome.storage.local.get.
    /// Nil keys: everything.
    func values(_ keys: [String]?) -> [String: Any] {
        let wanted = keys ?? (Dialer.configKeys + Dialer.pageKeys)
        var out: [String: Any] = [:]
        for key in wanted {
            switch key {
            case "wss": out[key] = setup.trimmedWSS
            case "domain": out[key] = setup.trimmedDomain
            case "user": out[key] = setup.trimmedUser
            case "password": out[key] = DialerPassword.read(setup) ?? ""
            case "autodial": out[key] = setup.autodial
            case "region": out[key] = setup.region
            default: if Dialer.pageKeys.contains(key), let value = pageValue(key) { out[key] = value }
            }
        }
        return out
    }

    /// The page's own values, written. The connection is Settings' and the
    /// keychain's to write, never the page's.
    func set(_ values: [String: Any]) {
        for (key, value) in values where Dialer.pageKeys.contains(key) { setPageValue(key, value) }
    }

    func remove(_ keys: [String]) {
        for key in keys where Dialer.pageKeys.contains(key) { Store.settings.removeObject(forKey: "dialer.page." + key) }
    }

    func pageValue(_ key: String) -> Any? {
        guard let data = Store.settings.data(forKey: "dialer.page." + key),
              let box = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return box["v"]
    }

    private func setPageValue(_ key: String, _ value: Any) {
        guard JSONSerialization.isValidJSONObject(["v": value]),
              let data = try? JSONSerialization.data(withJSONObject: ["v": value])
        else { return }
        Store.settings.set(data, forKey: "dialer.page." + key)
    }

    // MARK: - finished calls, for otto

    /// Every finished call to or from an outside number, waiting until an
    /// otto page says it has it (calls-ack), as the extension's background
    /// worker keeps them: newest last, the oldest dropped past fifty, a
    /// record with the same id replacing its earlier self.
    var outbox: [[String: Any]] {
        (pageValue("callOutbox") as? [[String: Any]])?.filter { ($0["id"] as? String).map { !$0.isEmpty } ?? false } ?? []
    }

    /// A call the page reports over: filed, and handed to every otto page
    /// open. How many wait, or nil for a record that isn't one.
    @discardableResult
    func fileCall(_ record: Any?) -> Int? {
        guard let clean = Dialer.cleanRecord(record), let id = clean["id"] as? String else { return nil }
        var list = outbox.filter { ($0["id"] as? String) != id }
        list.append(clean)
        if list.count > Dialer.outboxMost { list.removeFirst(list.count - Dialer.outboxMost) }
        setPageValue("callOutbox", list)
        tellSites([clean])
        return list.count
    }

    /// Otto has these: gone from the outbox.
    func ackCalls(_ ids: [String]) -> Int {
        let gone = Set(ids.prefix(200))
        let list = outbox.filter { !gone.contains($0["id"] as? String ?? "") }
        setPageValue("callOutbox", list)
        return list.count
    }

    /// A record as the outbox takes it (calls.js's clean): an id, an outside
    /// number — six digits or more, no feature code — an outcome it knows,
    /// and times that are numbers. Nothing else is kept.
    nonisolated static func cleanRecord(_ record: Any?) -> [String: Any]? {
        guard let r = record as? [String: Any], let id = r["id"] as? String, !id.isEmpty, id.count <= 80,
              let outcome = r["outcome"] as? String,
              ["answered", "no-answer", "busy", "failed", "cancelled", "missed"].contains(outcome)
        else { return nil }
        let number = plainNumber(r["number"])
        guard external(number) else { return nil }
        guard let started = finite(r["startedAt"]), let ended = finite(r["endedAt"]) else { return nil }
        let answered: Any? = r["answeredAt"].flatMap { $0 is NSNull ? nil : finite($0) }
        if r["answeredAt"] != nil, !(r["answeredAt"] is NSNull), answered == nil { return nil }
        var out: [String: Any] = [
            "id": id, "number": number, "name": String((r["name"] as? String ?? "").prefix(80)),
            "direction": (r["direction"] as? String) == "in" ? "in" : "out",
            "startedAt": started, "answeredAt": answered ?? NSNull(), "endedAt": ended,
            "durationSec": max(0, (finite(r["durationSec"]) ?? 0).rounded()), "outcome": outcome,
        ]
        out["ref"] = cleanRef(r["ref"]) ?? NSNull()
        return out
    }

    /// Digits with a leading + kept, as a record names the other party.
    nonisolated static func plainNumber(_ value: Any?) -> String {
        let text = (value as? String) ?? (value as? NSNumber).map { "\($0)" } ?? ""
        let plus = text.trimmingCharacters(in: .whitespaces).hasPrefix("+") ? "+" : ""
        return plus + text.filter(\.isNumber)
    }

    /// A number that leaves the box: no feature code, six digits at least.
    nonisolated static func external(_ number: String) -> Bool {
        !number.contains("*") && !number.contains("#") && number.filter(\.isNumber).count >= 6
    }

    /// Otto's reference for a call — which lead it was for — carried along
    /// and handed back untouched: a small plain object, or nothing.
    nonisolated static func cleanRef(_ value: Any?) -> [String: Any]? {
        guard let object = value as? [String: Any], JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 400
        else { return nil }
        return object
    }

    nonisolated private static func finite(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !(value is Bool) else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    /// Records to every otto page open, in Search's own world, where the
    /// bridge script posts them on to the page (DialerSiteRelay).
    func tellSites(_ records: [[String: Any]]) {
        guard !records.isEmpty, JSONSerialization.isValidJSONObject(records),
              let data = try? JSONSerialization.data(withJSONObject: records),
              let json = String(data: data, encoding: .utf8)
        else { return }
        for browser in Browsers.all {
            for tab in browser.tabs {
                guard let web = tab.built, let address = tab.address,
                      ["http", "https"].contains(address.scheme?.lowercased() ?? ""), allows(host: address.host())
                else { continue }
                web.evaluateJavaScript("window.__searchDialerSite && window.__searchDialerSite.calls(\(json))", in: nil, in: Web.world) { _ in }
            }
        }
    }

    /// Otto's Settings › Dialer writes the line (setConfig): the same keys
    /// the extension takes, into Settings and the keychain.
    func takeConfig(_ config: [String: Any]) {
        let prefs = Shared.prefs
        if let wss = config["wss"] as? String { prefs.dialerWSS = wss }
        if let domain = config["domain"] as? String { prefs.dialerDomain = domain }
        if let user = config["user"] as? String { prefs.dialerUser = user }
        if let region = config["region"] as? String {
            let clean = region.uppercased().filter { $0.isLetter && $0.isASCII }
            if clean.count == 2 { prefs.dialerRegion = clean }
        }
        if let autodial = config["autodial"] as? Bool { prefs.dialerAutodial = autodial }
        if let provider = config["provider"] as? String { setPageValue("provider", provider == "telicall" ? "telicall" : "numero") }
        if let password = config["password"] as? String, !password.isEmpty,
           DialerPassword.save(password, for: prefs.dialerSetup) {
            passwordChanged()
        }
    }

    /// The line as otto reads it back (getConfig): the keys the extension
    /// shows, the password among them, as its own options page would.
    func configForSites() -> [String: Any] {
        var out = values(Dialer.configKeys)
        out["provider"] = pageValue("provider") ?? "numero"
        out["updatesUrl"] = ""
        return out
    }

    // MARK: - the microphone

    /// macOS said no to the microphone: where to say yes, offered once per
    /// ask, over the window.
    func explainMicrophone(in browser: Browser?) {
        guard !Store.testing else { return }
        let alert = NSAlert()
        alert.messageText = "Search needs the microphone"
        alert.informativeText = "Allow Search under System Settings › Privacy & Security › Microphone, then call again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        let open = { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) } }
        if let window = browser?.window {
            alert.beginSheetModal(for: window) { answer in if answer == .alertFirstButtonReturn { open() } }
        } else if alert.runModal() == .alertFirstButtonReturn {
            open()
        }
    }
}

// MARK: - the password

/// The seat's password, in the keychain as a generic password of Search's,
/// one per seat and server. A test run keeps it in memory, as the proxy's
/// rehearsal does.
enum DialerPassword {
    private static let service = Store.world.map { "Search Dialer (\($0))" } ?? "Search Dialer"
    nonisolated(unsafe) private static var rehearsal: [String: String] = [:]
    /// What the keychain answered this launch, per seat: the password, or
    /// nil for a refusal. Asked once. The keychain puts its question — its
    /// sheet for the login password — for every build it doesn't know, and
    /// an ad-hoc signed build is a new one to it every time it is built;
    /// asked on every read, it came with every reconnect, and a Deny only
    /// had the page ask again, thousands of times (feedback, 29 Oct 2026).
    /// Saving or forgetting the password starts afresh.
    nonisolated(unsafe) private static var answered: [String: String?] = [:]

    private static func account(_ setup: DialerSetup) -> String { "\(setup.trimmedUser)@\(setup.trimmedDomain)" }

    private static func identity(_ setup: DialerSetup) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account(setup)]
    }

    static func read(_ setup: DialerSetup) -> String? {
        guard !setup.trimmedUser.isEmpty else { return nil }
        if Store.testing { return rehearsal[account(setup)] }
        if let known = answered[account(setup)] { return known }
        var asked = identity(setup)
        asked[kSecReturnData as String] = true
        asked[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(asked as CFDictionary, &out)
        guard status == errSecSuccess,
              let data = out as? Data, let password = String(data: data, encoding: .utf8), !password.isEmpty
        else {
            // A no from the person at the keychain's sheet is the answer
            // for this launch. Nothing kept, or a keychain that couldn't be
            // asked just now, is asked again next time.
            if status == errSecAuthFailed || status == errSecUserCanceled { answered[account(setup)] = .some(nil) }
            return nil
        }
        answered[account(setup)] = password
        return password
    }

    static func kept(_ setup: DialerSetup) -> Bool { read(setup) != nil }

    @discardableResult
    static func save(_ password: String, for setup: DialerSetup) -> Bool {
        guard !setup.trimmedUser.isEmpty, !password.isEmpty else { return false }
        if Store.testing { rehearsal[account(setup)] = password; return true }
        answered.removeValue(forKey: account(setup))
        let data = Data(password.utf8)
        let query = identity(setup)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess {
            answered[account(setup)] = password
            return true
        }
        guard status == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = service
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return false }
        answered[account(setup)] = password
        return true
    }

    @discardableResult
    static func forget(_ setup: DialerSetup) -> Bool {
        answered.removeValue(forKey: account(setup))
        if Store.testing { rehearsal[account(setup)] = nil; return true }
        let status = SecItemDelete(identity(setup) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

// MARK: - the page

/// The dialer's page in one window: made when the dialer is first opened
/// there, kept while the dialer is on — signed in, so a call from a
/// right-click starts at once — and shown in the side panel when asked.
/// Closing the panel ends a call in progress, as closing Chrome's does, but
/// keeps the page and its registration.
@MainActor
final class DialerPage: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    static let handler = "dialer"

    let web: WKWebView
    weak var browser: Browser?
    /// What the page's status line says, and the kind its dot shows (reg,
    /// err, calling, oncall), and the card's state (idle, calling, incall).
    @Published private(set) var status = (text: "Starting…", kind: "", state: "idle")
    /// The page's scripts have run: a number can be handed to it directly.
    private(set) var ready = false
    /// The page has read what was waiting at its start.
    private var started = false
    /// A number handed over before the page could take it (storage.session's
    /// pendingDial, as the extension's worker leaves one).
    private var pending: [String: Any]?
    private var crashes: [Date] = []

    init(browser: Browser) {
        self.browser = browser
        let configuration = WKWebViewConfiguration()
        // Nothing to keep: the page's state lives in Search's settings.
        configuration.websiteDataStore = .nonPersistent()
        configuration.applicationNameForUserAgent = Web.userAgentName
        // The ring tone and the other side's voice play without a click in
        // the panel: a call started from a right-click never had one there.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        // Out of sight — the panel closed, the window behind another — the
        // page keeps its registration: never throttled or suspended.
        configuration.preferences.inactiveSchedulingPolicy = .none
        if #available(macOS 15.4, *), Store.testing { ExtensionCapture.mockDevices(configuration.preferences) }
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 380, height: 640), configuration: configuration)
        super.init()
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: DialerPage.handler)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsMagnification = false
        web.allowsBackForwardNavigationGestures = false
        Web.inspectable(web)
        load()
    }

    private func load() {
        guard let page = Dialer.page, let files = Dialer.files else {
            status = ("The dialer's files are missing", "err", "idle")
            return
        }
        ready = false
        started = false
        web.loadFileURL(page, allowingReadAccessTo: files)
    }

    /// Let go: a call in progress ends with it.
    func release() {
        hangUp()
        web.stopLoading()
        web.configuration.userContentController.removeScriptMessageHandler(forName: DialerPage.handler, contentWorld: .page)
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.removeFromSuperview()
    }

    // MARK: - numbers in

    /// A number to call, with who it is and otto's reference when there is
    /// one. Handed straight to the page once it listens; before then it
    /// waits where the page looks first (storage.session's pendingDial).
    func dial(_ number: String, name: String = "", ref: [String: Any]? = nil) {
        var request: [String: Any] = ["number": number, "name": String(name.prefix(80)), "at": Int(Date().timeIntervalSince1970 * 1000)]
        if let ref { request["ref"] = ref }
        pending = request
        deliver()
    }

    private func deliver() {
        guard ready, started, let pending else { return }
        var message = pending
        message["type"] = "dialer:dial"
        guard JSONSerialization.isValidJSONObject(message), let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8)
        else { return }
        web.evaluateJavaScript("window.__searchDialer && window.__searchDialer.deliver(\(json))") { _, _ in }
    }

    /// Settings changed: the page hears what, and reads the rest again.
    func settingsChanged(_ keys: [String]) {
        let values = Dialer.shared.values(keys)
        var changes: [String: Any] = [:]
        for key in keys { changes[key] = ["newValue": values[key] ?? ""] }
        guard JSONSerialization.isValidJSONObject(changes), let data = try? JSONSerialization.data(withJSONObject: changes),
              let json = String(data: data, encoding: .utf8)
        else { return }
        web.evaluateJavaScript("window.__searchDialer && window.__searchDialer.changed(\(json), 'local')") { _, _ in }
    }

    /// A call in progress ends; nothing else changes.
    func hangUp() {
        web.evaluateJavaScript("window.__searchDialer && window.__searchDialer.hangup()") { _, _ in }
    }

    /// What the display shows, for the bench.
    func state(_ answer: @escaping ([String: Any]) -> Void) {
        web.evaluateJavaScript("window.__searchDialer ? window.__searchDialer.state() : null") { value, _ in
            answer(value as? [String: Any] ?? [:])
        }
    }

    // MARK: - the bridge

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                           replyHandler: @escaping (Any?, String?) -> Void) {
        MainActor.assumeIsolated {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let op = body["op"] as? String
            else { return replyHandler(nil, "not for here") }
            replyHandler(answer(op, body), nil)
        }
    }

    private func answer(_ op: String, _ body: [String: Any]) -> [String: Any] {
        let dialer = Dialer.shared
        switch op {
        case "get":
            return ["values": dialer.values(body["keys"] as? [String])]
        case "set":
            dialer.set(body["values"] as? [String: Any] ?? [:])
            return ["ok": true]
        case "remove":
            dialer.remove(body["keys"] as? [String] ?? [])
            return ["ok": true]
        case "session.get":
            started = true
            defer { deliver() }
            if let pending, (body["keys"] as? [String]).map({ $0.contains("pendingDial") }) ?? true { return ["values": ["pendingDial": pending]] }
            return ["values": [:]]
        case "session.set":
            return ["ok": true]
        case "session.remove":
            if (body["keys"] as? [String] ?? []).contains("pendingDial") { pending = nil }
            return ["ok": true]
        case "message":
            let msg = body["msg"] as? [String: Any] ?? [:]
            switch msg["type"] as? String ?? "" {
            case "call-ended":
                guard let left = dialer.fileCall(msg["record"]) else { return ["reply": ["ok": false, "error": "Not a call record"]] }
                return ["reply": ["ok": true, "pending": left]]
            case "calls-ack":
                return ["reply": ["ok": true, "pending": dialer.ackCalls((msg["ids"] as? [Any] ?? []).map { "\($0)" })]]
            default:
                return ["reply": ["ok": true]]
            }
        case "settings":
            _ = browser?.show(InternalPage(.settings, SettingsPanel.Page.dialer.rawValue))
            return ["ok": true]
        case "microphone":
            dialer.explainMicrophone(in: browser)
            return ["ok": true]
        case "status":
            status = (body["text"] as? String ?? "", body["kind"] as? String ?? "", body["state"] as? String ?? "idle")
            dialer.statusChanged()
            return ["ok": true]
        case "ready":
            ready = true
            deliver()
            return ["ok": true]
        default:
            return ["error": "unknown"]
        }
    }

    // MARK: - WebKit

    /// The page's own file, and nothing else: a link in it goes nowhere.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        if navigationAction.targetFrame?.isMainFrame != true { return decisionHandler(.allow) }
        if url.isFileURL, let files = Dialer.files, url.standardizedFileURL.path.hasPrefix(files.standardizedFileURL.path) {
            return decisionHandler(.allow)
        }
        if url.scheme?.lowercased() == "about" { return decisionHandler(.allow) }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    /// The microphone, for the page itself: a call is what it is for, and
    /// macOS asks once for Search as a whole. The camera, never.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard frame.isMainFrame, type == .microphone, webView.url?.isFileURL == true else { return decisionHandler(.deny) }
        decisionHandler(.grant)
    }

    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func displayCapture(_ web: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, systemAudio: Bool,
                        decisionHandler: @escaping (Int) -> Void) {
        decisionHandler(0)
    }

    /// Its process gone: made again, twice a minute at most.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        crashes = crashes.filter { now.timeIntervalSince($0) < 60 } + [now]
        guard crashes.count <= 2 else { status = ("The dialer stopped", "err", "idle"); return }
        load()
    }
}

// MARK: - the window

extension Browser {
    /// The dialer is up in this window's side panel.
    var dialerShown: Bool { sidePanelShown && sidePanel == .dialer }

    /// The dialer into this window's side panel, in place of whatever is
    /// there. Only with the dialer on, and never in a pop-up window.
    func showDialer() {
        guard prefs.dialerOn, !isPopup else { return }
        if case .page(_, _, let tab?) = sidePanel { SidePanelPages.shared.unbind(tab, in: self) }
        if sidePanel != .dialer { SidePanelPages.shared.drop(in: self) }
        if dialerPage == nil { dialerPage = DialerPage(browser: self) }
        sidePanel = .dialer
        sidePanelShown = true
    }

    /// View › Show Dialer, and the key: up, or away again.
    func toggleDialer() {
        if dialerShown { closeSidePanel() } else { showDialer() }
    }

    /// A number to call: the dialer comes up and takes it.
    func call(_ number: String, name: String = "", ref: [String: Any]? = nil) {
        guard prefs.dialerOn else { return }
        showDialer()
        dialerPage?.dial(number, name: name, ref: ref)
    }

    /// The dialer turned off, or the window going: its page is let go.
    func dropDialer() {
        if dialerShown { closeSidePanel() }
        dialerPage?.release()
        dialerPage = nil
    }
}

// MARK: - the panel

/// The dialer in the side panel: a line naming it, with its settings and
/// close, and the page.
struct DialerPanelView: View {
    @ObservedObject var browser: Browser

    var body: some View {
        VStack(spacing: 0) {
            if let page = browser.dialerPage {
                DialerLine(browser: browser, page: page)
            }
            Rectangle().fill(Palette.hairline).frame(height: 1)
            PanelPage(web: browser.dialerPage?.web)
        }
    }
}

private struct DialerLine: View {
    @ObservedObject var browser: Browser
    @ObservedObject var page: DialerPage

    private var dot: Color {
        switch page.status.kind {
        case "reg", "oncall": return Palette.safe
        case "err": return Palette.unsafe
        case "calling": return Palette.muted
        default: return Palette.muted.opacity(0.5)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "phone.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.ink.opacity(0.78))
            Text("Dialer")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Circle().fill(dot).frame(width: 6, height: 6)
                .animation(Motion.quick, value: page.status.kind)
            // The line the page's own header used to carry: Registered,
            // Ringing…, Not configured. The header is hidden (search.css),
            // so this is where the state reads.
            Text(page.status.text)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .truncationMode(.tail)
                .animation(nil, value: page.status.text)
            Spacer(minLength: 0)
            Door(icon: "gearshape", help: "Settings › Dialer") { _ = browser.show(InternalPage(.settings, SettingsPanel.Page.dialer.rawValue)) }
            Door(icon: "xmark", help: "Close") { browser.closeSidePanel() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Settings › Dialer

/// A field in the wash, as Settings › Proxy draws its server's.
private struct DialerField<Field: View>: View {
    let label: String
    @ViewBuilder let field: () -> Field

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .frame(width: 72, alignment: .leading)
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

/// Under Phone server: the WebSocket address and the SIP domain.
struct DialerServerFields: View {
    @ObservedObject var prefs: Preferences

    private var badAddress: Bool { !prefs.dialerWSS.trimmingCharacters(in: .whitespaces).isEmpty && !DialerSetup.validWSS(prefs.dialerWSS) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DialerField(label: "WebSocket") {
                TextField("wss://sip.example.com:7443", text: $prefs.dialerWSS)
                    .autocorrectionDisabled()
            }
            DialerField(label: "Domain") {
                TextField("sip.example.com", text: $prefs.dialerDomain)
                    .autocorrectionDisabled()
            }
            if badAddress {
                Text("The WebSocket address starts with wss:// or ws://")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.unsafe)
                    .padding(.leading, 2)
                    .transition(.opacity)
            }
        }
        .padding(.leading, SettingsPanel.textInset)
        .padding(.trailing, 14)
        .padding(.bottom, 11)
        .animation(Motion.quick, value: badAddress)
    }
}

/// Under Seat: the extension, and its password, which goes to the keychain
/// as it is typed and is never shown again.
struct DialerSeatFields: View {
    @ObservedObject var prefs: Preferences
    @State private var password = ""
    @State private var kept = false
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 6) {
            DialerField(label: "Extension") {
                TextField("1001", text: $prefs.dialerUser)
                    .autocorrectionDisabled()
            }
            DialerField(label: "Password") {
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
        .onAppear { kept = DialerPassword.kept(prefs.dialerSetup) }
        .onChange(of: prefs.dialerUser) { _, _ in kept = DialerPassword.kept(prefs.dialerSetup) }
        .onChange(of: prefs.dialerDomain) { _, _ in kept = DialerPassword.kept(prefs.dialerSetup) }
        .onChange(of: typing) { _, now in if !now { save() } }
        .animation(Motion.quick, value: kept)
    }

    private func save() {
        guard !password.isEmpty, DialerPassword.save(password, for: prefs.dialerSetup) else { return }
        password = ""
        kept = true
        Dialer.shared.passwordChanged()
    }

    private func forget() {
        guard DialerPassword.forget(prefs.dialerSetup) else { return }
        kept = false
        Dialer.shared.passwordChanged()
    }
}

/// Default country: every country the Mac knows, by name.
struct DialerRegionPicker: View {
    @ObservedObject var prefs: Preferences

    private static let regions: [(code: String, name: String)] = {
        let locale = Locale.current
        return Locale.Region.isoRegions
            .map(\.identifier)
            .filter { $0.count == 2 }
            .compactMap { code in locale.localizedString(forRegionCode: code).map { (code, $0) } }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }()

    var body: some View {
        Picker("Default country", selection: $prefs.dialerRegion) {
            ForEach(DialerRegionPicker.regions, id: \.code) { region in
                Text(region.name).tag(region.code)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: 200)
    }
}

/// Under Sites that may use the dialer: the list, and a line to add one.
struct DialerSitesList: View {
    @ObservedObject var prefs: Preferences
    @Binding var draft: String?
    @FocusState private var typing: Bool

    var body: some View {
        if draft != nil {
            DialerField(label: "Site") {
                TextField("otto.example.com", text: Binding(get: { draft ?? "" }, set: { draft = $0 }))
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
        ForEach(prefs.dialerSites, id: \.self) { site in
            Rule()
            Line(site, nil) {
                Pill("Remove") { prefs.dialerSites.removeAll { $0 == site } }
            }
        }
    }

    func add() {
        let site = Dialer.site(draft ?? "")
        guard !site.isEmpty else { return }
        if !prefs.dialerSites.contains(site) { prefs.dialerSites.append(site) }
        draft = nil
    }
}

/// Under the switch while it is off: what to have ready.
struct DialerHint: View {
    var body: some View {
        Text("You'll need your phone server's WebSocket address, its domain, and a seat's extension and password — otto's Settings › Dialer has them")
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, SettingsPanel.textInset)
            .padding(.trailing, 14)
            .padding(.bottom, 11)
    }
}
