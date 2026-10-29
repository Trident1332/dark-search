import AppKit
import AVFoundation
import Network
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
// With a proxy enabled, signaling uses a mandatory proxy route and audio uses
// only the phone server's TURN relay through a native, proxied TLS tunnel.
// Ordinary websites retain their separate peer-connection protection.

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
    /// Exact origins whose pages may use the dialer.
    var sites: [String] = Dialer.defaultSites
    var numeroUS = ""
    var numeroCA = ""
    var telicallUK = ""

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

    /// Local development servers require an explicit origin grant.
    nonisolated static let defaultSites = ["https://otto.investigate.agency"]

    /// What the page reads as its connection (chrome.storage.local's keys).
    nonisolated static let configKeys = ["wss", "domain", "user", "password", "autodial", "region", "numeroUS", "numeroCA", "telicallUK"]
    /// What the page keeps for itself: recent calls, the trunk and the voice
    /// it was left on, and the calls otto hasn't taken yet.
    nonisolated static let pageKeys = ["history", "provider", "voice", "callOutbox", "numeroLine"]
    /// Finished calls otto hasn't taken, newest last, at most this many.
    nonisolated static let outboxMost = 50

    private(set) var setup = DialerSetup()
    private let pages = NSHashTable<DialerPage>.weakObjects()
    private var policyObservers: [NSObjectProtocol] = []

    private init() {
        for name in [Proxy.routeChanged, Onion.stateChanged] {
            policyObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.policyChanged() }
            })
        }
        policyObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopPages() }
        })
    }

    var blockedReason: String? {
        if Proxy.shared.waiting {
            return "The proxy connection isn't ready. Open Proxy settings and Poke to reconnect before calling."
        }
        if Onion.shared.hasTabs {
            return "The dialer is unavailable while Tor tabs are open. Calls cannot use Tor."
        }
        return nil
    }

    private func policyChanged() {
        // An established call cannot keep using a former route after any
        // proxy or Tor transition, even when both routes are healthy.
        stopPages(immediately: true)
        objectWillChange.send()
    }

    private func stopPages(immediately: Bool = false) {
        for page in pages.allObjects {
            if immediately { page.release(immediately: true) }
            if let browser = page.browser, browser.dialerPage === page { browser.dropDialer() }
            else { page.release() }
        }
    }

    func track(_ page: DialerPage) { pages.add(page) }
    func untrack(_ page: DialerPage) { pages.remove(page) }

    /// Settings changed. Off: every window's dialer goes. A changed line:
    /// every page signs in again, as the extension does when its options
    /// are saved.
    func take(_ new: DialerSetup) {
        let old = setup
        var new = new
        new.sites = DialerOrigin.normalized(new.sites)
        setup = new
        guard old != new else { return }
        if old.on != new.on || old.sites != new.sites { Tab.refreshDialerBridge() }
        if !new.on {
            stopPages()
            objectWillChange.send()
            return
        }
        var changed: [String] = []
        if old.connection != new.connection { changed += ["wss", "domain", "user"] }
        if old.region != new.region { changed.append("region") }
        if old.autodial != new.autodial { changed.append("autodial") }
        if old.numeroUS != new.numeroUS { changed.append("numeroUS") }
        if old.numeroCA != new.numeroCA { changed.append("numeroCA") }
        if old.telicallUK != new.telicallUK { changed.append("telicallUK") }
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

    func allows(scheme: String, host: String, port: Int) -> Bool {
        setup.on && DialerOrigin.allows(setup.sites, scheme: scheme, host: host, port: port)
    }

    func allows(url: URL) -> Bool {
        guard let scheme = url.scheme, let host = url.host() else { return false }
        return allows(scheme: scheme, host: host, port: url.port ?? 0)
    }

    nonisolated static func site(_ typed: String) -> String { DialerOrigin.parse(typed)?.string ?? "" }

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
            case "numeroUS": out[key] = DialerNumero.value(setup.numeroUS)
            case "numeroCA": out[key] = DialerNumero.value(setup.numeroCA)
            case "telicallUK": out[key] = DialerTelicall.value(setup.telicallUK)
            default: if Dialer.pageKeys.contains(key), let value = pageValue(key) { out[key] = value }
            }
        }
        return out
    }

    /// The page's own values, written. The connection is Settings' and the
    /// keychain's to write, never the page's.
    func set(_ values: [String: Any]) {
        for (key, value) in values where Dialer.pageKeys.contains(key) { setPageValue(key, value) }
        let shared = ["provider", "numeroLine"].filter { values[$0] != nil }
        if !shared.isEmpty { for page in pages.allObjects { page.settingsChanged(shared) } }
    }

    func remove(_ keys: [String]) {
        for key in keys where Dialer.pageKeys.contains(key) { Store.settings.removeObject(forKey: "dialer.page." + key) }
        let shared = ["provider", "numeroLine"].filter { keys.contains($0) }
        if !shared.isEmpty { for page in pages.allObjects { page.settingsChanged(shared) } }
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
        let numeroAbsent = r["numeroLine"] == nil || r["numeroLine"] is NSNull || (r["numeroLine"] as? String) == ""
        let telicallAbsent = r["telicallLine"] == nil || r["telicallLine"] is NSNull || (r["telicallLine"] as? String) == ""
        if telicallAbsent, let value = r["numeroLine"] as? String, let line = DialerNumero(rawValue: value),
           let number = DialerNumero.number(r["fromNumber"] as? String ?? "") {
            out["numeroLine"] = line.rawValue
            out["fromNumber"] = number
        } else if numeroAbsent, r["telicallLine"] as? String == "uk",
                  let number = DialerTelicall.number(r["fromNumber"] as? String ?? "") {
            out["telicallLine"] = "uk"
            out["fromNumber"] = number
        }
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
                guard !tab.shy, !tab.usesTor, let web = tab.built, let address = tab.address,
                      allows(url: address)
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
        if let number = config["numeroUS"] as? String { prefs.dialerNumeroUS = number }
        if let number = config["numeroCA"] as? String { prefs.dialerNumeroCA = number }
        if let number = config["telicallUK"] as? String { prefs.dialerTelicallUK = number }
        if let provider = config["provider"] as? String { set(["provider": provider == "telicall" ? "telicall" : "numero"]) }
        if let value = config["numeroLine"] as? String, let line = DialerNumero(rawValue: value) { set(["numeroLine": line.rawValue]) }
        if let password = config["password"] as? String, !password.isEmpty,
           DialerPassword.save(password, for: prefs.dialerSetup) {
            passwordChanged()
        }
    }

    /// Websites can inspect the line's non-secret settings, never its password.
    func configForSites() -> [String: Any] {
        var out = values(Dialer.configKeys.filter { $0 != "password" })
        out["passwordSaved"] = DialerPassword.kept(setup)
        out["provider"] = pageValue("provider") ?? "numero"
        out["numeroLine"] = pageValue("numeroLine") ?? "us"
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
    /// a local signing certificate can produce a new partition hash after
    /// each build. Asked on every read, it came with every reconnect, and a Deny only
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
        let status = KeychainAccess.copyMatching(asked as CFDictionary, &out)
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

    static func kept(_ setup: DialerSetup) -> Bool {
        guard !setup.trimmedUser.isEmpty else { return false }
        if Store.testing { return rehearsal[account(setup)] != nil }
        // Settings redraws frequently, including while another page is open.
        // Checking presence must never read the protected value or show a dialog.
        var query = identity(setup)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        return KeychainAccess.copyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func save(_ password: String, for setup: DialerSetup) -> Bool {
        guard !setup.trimmedUser.isEmpty, !password.isEmpty else { return false }
        if Store.testing { rehearsal[account(setup)] = password; return true }
        answered.removeValue(forKey: account(setup))
        let data = Data(password.utf8)
        let query = identity(setup)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = KeychainAccess.update(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess {
            answered[account(setup)] = password
            return true
        }
        guard status == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = service
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard KeychainAccess.add(add as CFDictionary, nil) == errSecSuccess else { return false }
        answered[account(setup)] = password
        return true
    }

    @discardableResult
    static func forget(_ setup: DialerSetup) -> Bool {
        answered.removeValue(forKey: account(setup))
        if Store.testing { rehearsal[account(setup)] = nil; return true }
        let status = KeychainAccess.delete(identity(setup) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// OS permission is requested from Search itself, only when a call asks for
/// its microphone. A test run uses WebKit's mock device and never prompts TCC.
@MainActor
enum DialerMicrophone {
    enum RecoveryChoice: Equatable { case allow, cancel, openSettings }

    struct TestingGate {
        var status: @MainActor () -> AVAuthorizationStatus
        var request: @MainActor () async -> Bool
        var recover: @MainActor (AVAuthorizationStatus) async -> RecoveryChoice = { _ in .cancel }
        var openSettings: @MainActor () -> Void = {}
    }

    static var testingGate: TestingGate?

    static func status() -> AVAuthorizationStatus {
        if Store.testing { return testingGate?.status() ?? .authorized }
        return AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func request() async -> Bool {
        switch status() {
        case .authorized: return true
        case .notDetermined:
            if Store.testing { return await testingGate?.request() ?? false }
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default: return false
        }
    }

    static func openSettings() {
        if Store.testing { testingGate?.openSettings(); return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
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

    @Published private(set) var web: WKWebView
    weak var browser: Browser?
    /// What the page's status line says, and the kind its dot shows (reg,
    /// err, calling, oncall), and the card's state (idle, calling, incall).
    @Published private(set) var status = (text: "Starting…", kind: "", state: "idle")
    /// The page's scripts have run: a number can be handed to it directly.
    private(set) var ready = false
    private(set) var visible = false
    private(set) var released = false
    private var closed = false
    /// The page has read what was waiting at its start.
    private var started = false
    /// A number handed over before the page could take it (storage.session's
    /// pendingDial, as the extension's worker leaves one).
    private var pending: [String: Any]?
    private var crashes: [Date] = []
    private var microphoneRevision = 0
    private var microphoneRecoveryID: UUID?
    private var microphoneRecoveryAlert: NSAlert?
    private var microphoneRecoveryReply: ((DialerMicrophone.RecoveryChoice) -> Void)?
    private var protectedRoute: [String: Any] = ["mode": "blocked", "error": "Preparing the protected call route…"]
    private var routeGeneration = 0
    private var routeTask: Task<Void, Never>?
    private var routeRenewal: Task<Void, Never>?
    private var relayTunnel: DialerProxyTunnel?

    init(browser: Browser) {
        self.browser = browser
        web = Self.makeWeb()
        super.init()
        attachWeb()
        Dialer.shared.track(self)
        prepareCallRoute()
        load()
    }

    private static func makeWeb() -> WKWebView {
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
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 380, height: 640), configuration: configuration)
    }

    private func attachWeb() {
        web.configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: DialerPage.handler)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsMagnification = false
        web.allowsBackForwardNavigationGestures = false
        Web.inspectable(web)
    }

    private func replaceWeb() {
        microphoneRevision += 1
        cancelMicrophoneRecovery()
        let window = web.window
        let isContentView = window?.contentView === web
        web.setMicrophoneCaptureState(.none)
        web.configuration.userContentController.removeScriptMessageHandler(forName: DialerPage.handler, contentWorld: .page)
        web.navigationDelegate = nil
        web.uiDelegate = nil
        ProxyTimeZone.close(web)
        web.removeFromSuperview()
        web = Self.makeWeb()
        if Proxy.shared.setup.routes {
            web.configuration.websiteDataStore.proxyConfigurations = [Proxy.shared.configuration(forTest: true)]
        }
        attachWeb()
        if isContentView { window?.contentView = web }
    }

    private func prepareCallRoute() {
        routeGeneration += 1
        let generation = routeGeneration
        routeTask?.cancel()
        routeRenewal?.cancel()
        relayTunnel?.close()
        relayTunnel = nil
        guard Proxy.shared.setup.routes else {
            web.configuration.websiteDataStore.proxyConfigurations = []
            protectedRoute = ["mode": "direct"]
            return
        }
        // The dialer never inherits website exceptions or optional failover.
        // Install this before the local page can create its first WebSocket.
        var proxy = Proxy.shared.configuration(forTest: true)
        proxy.allowFailover = false
        proxy.excludedDomains = []
        web.configuration.websiteDataStore.proxyConfigurations = [proxy]
        protectedRoute = ["mode": "blocked", "error": "Connecting through the proxy…"]
        let setup = Dialer.shared.setup
        guard setup.complete else { return }
        let revision = Proxy.shared.revision
        routeTask = Task { [weak self] in
            do {
                let endpoint = try DialerRelayEndpoint(wss: setup.trimmedWSS)
                guard let password = DialerPassword.read(setup), !password.isEmpty else {
                    throw DialerRelayError.message("Allow access to your saved phone-server login in Dialer settings")
                }
                let ticket = try await DialerRelayRequest.fetch(endpoint: endpoint, user: setup.trimmedUser,
                                                               password: password, proxy: proxy)
                try Task.checkCancellation()
                guard let self, !self.released, self.routeGeneration == generation,
                      Proxy.shared.revision == revision, Dialer.shared.setup.connection == setup.connection
                else { return }
                let relay = try ticket.validated(for: endpoint)
                let tunnel = DialerProxyTunnel(host: relay.host, port: relay.port, proxy: proxy) { [weak self] error in
                    guard let self, self.routeGeneration == generation else { return }
                    self.failCallRoute(error)
                }
                self.relayTunnel = tunnel
                let port = try await tunnel.start()
                try Task.checkCancellation()
                guard !self.released, self.routeGeneration == generation, Proxy.shared.revision == revision else {
                    tunnel.close()
                    return
                }
                self.protectedRoute = ["mode": "proxy", "revision": "\(revision):\(generation)",
                    "turnURL": "turn:127.0.0.1:\(port)?transport=tcp", "username": relay.username,
                    "credential": relay.credential, "expiresAt": ticket.expiresAt]
                self.settingsChanged(["protectedRoute"])
                self.renewCallRoute(before: ticket.expiresAt, generation: generation)
            } catch is CancellationError { return }
            catch {
                guard let self, !self.released, self.routeGeneration == generation else { return }
                let message = (error as? DialerRelayError)?.localizedDescription
                    ?? "The protected call route couldn't connect. Check Proxy settings and try the dialer again."
                self.failCallRoute(message)
            }
        }
    }

    private func renewCallRoute(before expiresAt: Double, generation: Int) {
        routeRenewal = Task { [weak self] in
            let delay = max(1, expiresAt - Date().timeIntervalSince1970 - 90)
            try? await Task.sleep(for: .seconds(delay))
            while !Task.isCancelled, let self, !self.released, self.routeGeneration == generation {
                // Existing TURN allocations retain their authenticated key.
                // Rotate before the next call without interrupting this one.
                if self.status.state == "idle" {
                    self.replaceWeb()
                    self.prepareCallRoute()
                    self.load()
                    return
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func failCallRoute(_ message: String) {
        guard !released else { return }
        routeGeneration += 1
        routeTask?.cancel()
        routeRenewal?.cancel()
        relayTunnel?.close()
        relayTunnel = nil
        protectedRoute = ["mode": "blocked", "error": message]
        pending = nil
        web.setMicrophoneCaptureState(.none)
        // Stop existing signaling and media immediately; the replacement
        // local page may display the error but cannot start any connection.
        replaceWeb()
        status = (message, "err", "idle")
        load()
        Dialer.shared.statusChanged()
    }

    private func load() {
        guard !released, Dialer.shared.setup.on, Dialer.shared.blockedReason == nil else { return }
        guard let page = Dialer.page, let files = Dialer.files else {
            status = ("The dialer's files are missing", "err", "idle")
            return
        }
        ready = false
        started = false
        web.loadFileURL(page, allowingReadAccessTo: files)
    }

    /// Let go: a call in progress ends with it.
    func release(immediately: Bool = false) {
        if released {
            if immediately || Dialer.shared.blockedReason != nil { finishRelease() }
            return
        }
        let canFinishRecords = !immediately && ready && Dialer.shared.blockedReason == nil
        released = true
        routeGeneration += 1
        routeTask?.cancel()
        routeRenewal?.cancel()
        relayTunnel?.close()
        relayTunnel = nil
        microphoneRevision += 1
        cancelMicrophoneRecovery()
        pending = nil
        visible = false
        ready = false
        web.setMicrophoneCaptureState(.none)
        web.removeFromSuperview()
        if canFinishRecords {
            // The microphone is already stopped. Give a responsive page one
            // turn to file its last call, with a deadline if JavaScript stalls.
            web.evaluateJavaScript("window.__searchDialer && window.__searchDialer.shutdown(); void 0") { [self] _, _ in
                finishRelease()
            }
            Task { [self] in
                try? await Task.sleep(for: .milliseconds(100))
                finishRelease()
            }
        } else {
            // A protected route cannot wait for page JavaScript.
            finishRelease()
        }
    }

    private func finishRelease() {
        guard !closed else { return }
        closed = true
        ProxyTimeZone.close(web)
        web.configuration.userContentController.removeScriptMessageHandler(forName: DialerPage.handler, contentWorld: .page)
        web.navigationDelegate = nil
        web.uiDelegate = nil
        Dialer.shared.untrack(self)
    }

    func setVisible(_ shown: Bool) {
        guard !released else { return }
        visible = shown
        if !shown {
            microphoneRevision += 1
            cancelMicrophoneRecovery()
            pending = nil
            web.setMicrophoneCaptureState(.none)
        }
        if ready { pushVisibility() }
    }

    private func pushVisibility() {
        web.evaluateJavaScript("window.__searchDialer && window.__searchDialer.setVisible(\(visible ? "true" : "false"))") { _, _ in }
    }

    private var mayRequestMicrophone: Bool {
        !released && visible && Dialer.shared.setup.on && Dialer.shared.blockedReason == nil
            && mediaRouteReady
            && browser?.dialerPage === self && browser?.dialerShown == true
            && (Store.testing || web.window?.isVisible == true)
    }

    private var mediaRouteReady: Bool {
        if !Proxy.shared.setup.routes { return protectedRoute["mode"] as? String == "direct" }
        return protectedRoute["mode"] as? String == "proxy" && relayTunnel?.port != nil
            && (protectedRoute["expiresAt"] as? Double ?? 0) > Date().timeIntervalSince1970
    }

    /// Called by the local page's explicit Call path, never a permission
    /// query or page load. The OS response cannot revive a hidden old call.
    func requestMicrophonePermission() async -> Bool {
        guard mayRequestMicrophone else { return false }
        let revision = microphoneRevision
        focusMicrophoneWindow()
        let granted = await DialerMicrophone.request()
        guard granted, revision == microphoneRevision, mayRequestMicrophone else { return false }
        focusMicrophoneWindow()
        return true
    }

    private func focusMicrophoneWindow() {
        if !Store.testing, let window = web.window, window.isVisible {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(web)
        }
    }

    /// A failed media request needs a fresh user decision. An existing OS
    /// grant is reported honestly: the sheet asks to retry this call.
    func recoverMicrophonePermission() async -> Bool {
        guard mayRequestMicrophone, microphoneRecoveryID == nil else { return false }
        let revision = microphoneRevision
        let id = UUID()
        microphoneRecoveryID = id
        defer { if microphoneRecoveryID == id { microphoneRecoveryID = nil } }
        focusMicrophoneWindow()
        let status = DialerMicrophone.status()
        if status == .notDetermined {
            let granted = await DialerMicrophone.request()
            guard granted, microphoneRecoveryID == id, revision == microphoneRevision, mayRequestMicrophone else { return false }
            focusMicrophoneWindow()
            return true
        }
        let choice = await microphoneRecoveryChoice(status, id: id)
        guard microphoneRecoveryID == id, revision == microphoneRevision, mayRequestMicrophone else { return false }
        if choice == .openSettings {
            DialerMicrophone.openSettings()
            return false
        }
        guard status == .authorized, choice == .allow, DialerMicrophone.status() == .authorized else { return false }
        focusMicrophoneWindow()
        return true
    }

    private func microphoneRecoveryChoice(_ status: AVAuthorizationStatus, id: UUID) async -> DialerMicrophone.RecoveryChoice {
        guard microphoneRecoveryID == id, mayRequestMicrophone else { return .cancel }
        if Store.testing { return await DialerMicrophone.testingGate?.recover(status) ?? .cancel }
        guard let window = web.window, window.isVisible, window.attachedSheet == nil else { return .cancel }
        let alert = NSAlert()
        if status == .authorized {
            alert.messageText = "Allow microphone and retry this call?"
            alert.informativeText = "Search has macOS microphone permission, but the call could not open it. Allow Search to try again for this call."
            alert.addButton(withTitle: "Allow and Retry")
        } else {
            alert.messageText = "Microphone access is blocked"
            alert.informativeText = "Allow Search in System Settings › Privacy & Security › Microphone, then try the call again."
            alert.addButton(withTitle: "Open Microphone Settings")
        }
        alert.addButton(withTitle: "Cancel")
        return await withCheckedContinuation { continuation in
            microphoneRecoveryAlert = alert
            microphoneRecoveryReply = { continuation.resume(returning: $0) }
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, self.microphoneRecoveryID == id else { return }
                let reply = self.microphoneRecoveryReply
                self.microphoneRecoveryReply = nil
                self.microphoneRecoveryAlert = nil
                let choice: DialerMicrophone.RecoveryChoice = response == .alertFirstButtonReturn
                    ? (status == .authorized ? .allow : .openSettings) : .cancel
                reply?(choice)
            }
        }
    }

    private func cancelMicrophoneRecovery() {
        microphoneRecoveryID = nil
        let alert = microphoneRecoveryAlert
        let reply = microphoneRecoveryReply
        microphoneRecoveryAlert = nil
        microphoneRecoveryReply = nil
        if let alert {
            if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .cancel) }
            alert.window.orderOut(nil)
        }
        reply?(.cancel)
    }

    // MARK: - numbers in

    /// A number to call, with who it is and otto's reference when there is
    /// one. Handed straight to the page once it listens; before then it
    /// waits where the page looks first (storage.session's pendingDial).
    func dial(_ number: String, name: String = "", ref: [String: Any]? = nil) {
        guard !released, visible, Dialer.shared.setup.on, Dialer.shared.blockedReason == nil else { return }
        var request: [String: Any] = ["number": number, "name": String(name.prefix(80)), "at": Int(Date().timeIntervalSince1970 * 1000)]
        if let ref { request["ref"] = ref }
        pending = request
        deliver()
    }

    private func deliver() {
        guard !released, visible, ready, started, let pending else { return }
        var message = pending
        message["type"] = "dialer:dial"
        guard JSONSerialization.isValidJSONObject(message), let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8)
        else { return }
        web.evaluateJavaScript("window.__searchDialer && window.__searchDialer.deliver(\(json))") { _, _ in }
    }

    /// Settings changed: the page hears what, and reads the rest again.
    func settingsChanged(_ keys: [String]) {
        guard !released else { return }
        if keys.contains(where: { ["wss", "domain", "user", "password"].contains($0) }) {
            replaceWeb()
            prepareCallRoute()
            load()
            return
        }
        if keys.contains(where: { ["wss", "domain", "user", "password", "numeroUS", "numeroCA", "telicallUK", "provider", "numeroLine"].contains($0) }) {
            microphoneRevision += 1
            cancelMicrophoneRecovery()
        }
        var values = Dialer.shared.values(keys)
        if keys.contains("protectedRoute") { values["protectedRoute"] = protectedRoute }
        var changes: [String: Any] = [:]
        for key in keys { changes[key] = ["newValue": values[key] ?? ""] }
        guard JSONSerialization.isValidJSONObject(changes), let data = try? JSONSerialization.data(withJSONObject: changes),
              let json = String(data: data, encoding: .utf8)
        else { return }
        web.evaluateJavaScript("window.__searchDialer && window.__searchDialer.changed(\(json), 'local')") { _, _ in }
    }

    /// A call in progress ends; nothing else changes.
    func hangUp() {
        pending = nil
        microphoneRevision += 1
        cancelMicrophoneRecovery()
        guard !released else { return }
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
            guard !closed, message.webView === web, message.frameInfo.isMainFrame,
                  message.frameInfo.request.url?.standardizedFileURL == Dialer.page?.standardizedFileURL,
                  let body = message.body as? [String: Any], let op = body["op"] as? String
            else { return replyHandler(nil, "not for here") }
            if released {
                // Only final records may drain; no settings or credentials
                // are accessible after the page has been released.
                if op == "message", let msg = body["msg"] as? [String: Any], msg["type"] as? String == "call-ended",
                   let count = Dialer.shared.fileCall(msg["record"]) {
                    return replyHandler(["reply": ["ok": true, "pending": count]], nil)
                }
                if op == "set", let values = body["values"] as? [String: Any], let history = values["history"] {
                    Dialer.shared.set(["history": history])
                    return replyHandler(["ok": true], nil)
                }
                return replyHandler(nil, "the dialer has closed")
            }
            guard Dialer.shared.setup.on, Dialer.shared.blockedReason == nil else { return replyHandler(nil, "the dialer is unavailable") }
            if op == "microphone.request" || op == "microphone.recover" {
                let revision = microphoneRevision
                Task { @MainActor [weak self, weak requestingWeb = web] in
                    guard let self, requestingWeb === self.web, revision == self.microphoneRevision else {
                        return replyHandler(["state": "denied"], nil)
                    }
                    let granted: Bool
                    if op == "microphone.recover" { granted = await self.recoverMicrophonePermission() }
                    else { granted = await self.requestMicrophonePermission() }
                    let current = requestingWeb === self.web && revision == self.microphoneRevision
                    replyHandler(["state": granted && current ? "granted" : "denied"], nil)
                }
                return
            }
            replyHandler(answer(op, body), nil)
        }
    }

    private func answer(_ op: String, _ body: [String: Any]) -> [String: Any] {
        let dialer = Dialer.shared
        switch op {
        case "get":
            let keys = body["keys"] as? [String]
            var values = dialer.values(keys)
            if keys == nil || keys!.contains("protectedRoute") { values["protectedRoute"] = protectedRoute }
            return ["values": values]
        case "set":
            let values = body["values"] as? [String: Any] ?? [:]
            if values["provider"] != nil || values["numeroLine"] != nil {
                microphoneRevision += 1
                cancelMicrophoneRecovery()
            }
            dialer.set(values)
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
            if protectedRoute["mode"] as? String == "blocked", dialer.setup.complete {
                status = (protectedRoute["error"] as? String ?? "The protected call route is unavailable", "err", "idle")
                dialer.statusChanged()
                return ["ok": true]
            }
            status = (body["text"] as? String ?? "", body["kind"] as? String ?? "", body["state"] as? String ?? "idle")
            dialer.statusChanged()
            return ["ok": true]
        case "ready":
            ready = true
            pushVisibility()
            deliver()
            return ["ok": true]
        default:
            return ["error": "unknown"]
        }
    }

    // MARK: - WebKit

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard !released, webView === web else { return completionHandler(.cancelAuthenticationChallenge, nil) }
        if Proxy.authenticate(challenge, completionHandler: completionHandler) { return }
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    /// The page's own file, and nothing else: a link in it goes nowhere.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !released, webView === web else { return decisionHandler(.cancel) }
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
        guard !released, webView === web, visible, mediaRouteReady, Dialer.shared.setup.on, Dialer.shared.blockedReason == nil,
              frame.isMainFrame, type == .microphone,
              frame.request.url?.standardizedFileURL == Dialer.page?.standardizedFileURL
        else { return decisionHandler(.deny) }
        decisionHandler(.grant)
    }

    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func displayCapture(_ web: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, systemAudio: Bool,
                        decisionHandler: @escaping (Int) -> Void) {
        decisionHandler(0)
    }

    /// Its process gone: made again, twice a minute at most.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !released, webView === web else { return }
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
    @discardableResult
    func showDialer() -> Bool {
        guard prefs.dialerOn, !isPopup else { return false }
        if let reason = Dialer.shared.blockedReason {
            announce(reason)
            return false
        }
        if case .page(_, _, let tab?) = sidePanel { SidePanelPages.shared.unbind(tab, in: self) }
        if sidePanel != .dialer { SidePanelPages.shared.drop(in: self) }
        if dialerPage == nil { dialerPage = DialerPage(browser: self) }
        sidePanel = .dialer
        sidePanelShown = true
        dialerPage?.setVisible(true)
        return true
    }

    /// View › Show Dialer, and the key: up, or away again.
    func toggleDialer() {
        if dialerShown { closeSidePanel() } else { showDialer() }
    }

    /// A number to call: the dialer comes up and takes it.
    @discardableResult
    func call(_ number: String, name: String = "", ref: [String: Any]? = nil) -> Bool {
        guard showDialer() else { return false }
        dialerPage?.dial(number, name: name, ref: ref)
        return true
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
            if let page = browser.dialerPage { DialerContent(page: page) }
        }
    }
}

private struct DialerContent: View {
    @ObservedObject var page: DialerPage
    var body: some View { PanelPage(web: page.web) }
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

/// Owned outbound numbers, labelled by their provider rather than the
/// destination's default country, and kept apart from the SIP seat's login.
struct DialerPhoneFields: View {
    @ObservedObject var prefs: Preferences

    private var invalidNumero: Bool {
        [prefs.dialerNumeroUS, prefs.dialerNumeroCA].contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && DialerNumero.number($0) == nil
        }
    }

    private var invalidTelicall: Bool {
        !prefs.dialerTelicallUK.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && DialerTelicall.number(prefs.dialerTelicallUK) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DialerField(label: "US") {
                TextField("+1 …", text: $prefs.dialerNumeroUS).autocorrectionDisabled()
                    .accessibilityLabel("US number on Numero")
                provider("Numero")
            }
            DialerField(label: "Canada") {
                TextField("+1 …", text: $prefs.dialerNumeroCA).autocorrectionDisabled()
                    .accessibilityLabel("Canada number on Numero")
                provider("Numero")
            }
            DialerField(label: "UK") {
                TextField("+44 …", text: $prefs.dialerTelicallUK).autocorrectionDisabled()
                    .accessibilityLabel("UK number on Telicall")
                provider("Telicall")
            }
            if invalidNumero {
                Text("Enter a complete US or Canadian number, including its area code")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.unsafe)
            }
            if invalidTelicall {
                Text("Enter the UK number with +44 and no national 0 after the country code")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.unsafe)
            }
        }
        .padding(.leading, SettingsPanel.textInset)
        .padding(.trailing, 14)
        .padding(.bottom, 11)
    }

    private func provider(_ name: String) -> some View {
        Text(name).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize()
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
        // Room for the country's whole name, however narrow the row: the
        // words beside it wrap first.
        .frame(minWidth: 150, maxWidth: 200)
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
                TextField("https://otto.example.com or http://localhost:3000", text: Binding(get: { draft ?? "" }, set: { draft = $0 }))
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
