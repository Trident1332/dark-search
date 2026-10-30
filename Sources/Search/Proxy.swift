import Foundation
import Network
import Security
import WebKit

// Settings › Proxy: every page, and everything the browser fetches for a
// page, through a proxy of your own — and only the browser. Nothing else on
// the Mac changes: the Mac's own proxy settings are left alone, and taken
// when no proxy is set here.
//
// WebKit takes a proxy per store (WKWebsiteDataStore.proxyConfigurations,
// macOS 14), so the route is set on every store the moment a page is
// configured on it and again whenever the settings change: the shared one,
// each profile's, each space's own, a private tab's and the extensions'.
// What the browser fetches outside WebKit — suggestions, icons, an update,
// an extension's socket — goes through URLSession with the same route (see
// `Proxy.session`).
//
// The password never sits in the settings file: it is kept in the keychain
// as a proxy password for the proxy's server, and read only when the route
// is built. A test run keeps it in memory, for the run.

/// What kind of proxy it is. SOCKS5 carries every connection as it is; HTTP
/// and HTTPS tunnel each connection through a CONNECT request, the second
/// over TLS to the proxy itself.
enum ProxyKind: String, CaseIterable, Identifiable {
    case http, https, socks5

    var id: String { rawValue }

    var title: String {
        switch self {
        case .http: return "HTTP"
        case .https: return "HTTPS"
        case .socks5: return "SOCKS5"
        }
    }

    /// The port a proxy of this kind usually listens on, for the field's
    /// placeholder and for a port left empty.
    var usualPort: UInt16 {
        switch self {
        case .http, .https: return 8080
        case .socks5: return 1080
        }
    }

    fileprivate var keychainProtocol: CFString {
        switch self {
        case .http: return kSecAttrProtocolHTTPProxy
        case .https: return kSecAttrProtocolHTTPSProxy
        case .socks5: return kSecAttrProtocolSOCKS
        }
    }
}

/// The proxy as set, without its password: enough to tell whether two
/// settings would build the same route.
struct ProxySetup: Equatable {
    var on = false
    var kind = ProxyKind.socks5
    var host = ""
    var port: UInt16? = nil
    /// The proxy asks for a name and password.
    var signsIn = false
    var user = ""
    /// Sites reached directly, as if there were no proxy: a site, or a
    /// whole domain with its subdomains. The Mac itself always is.
    var bypass: [String] = []
    /// Empty: every profile. Otherwise only these profiles' pages take the
    /// route; the others stay on the Mac's settings.
    var profiles: Set<UUID> = []
    /// Reconnect at startup and hold all Search traffic until an authenticated
    /// check succeeds. Off, unauthenticated routes may fail over directly.
    var blocks = true
    /// A mark beside the address while pages take the route.
    var shows = true
    /// Website peer connections are off while the proxy is on. The bundled
    /// dialer has its own mandatory proxy route and relay-only media policy.
    var hidesCalls = true
    /// Use the exit location's IANA time zone in WebKit processes.
    var matchesTimeZone = true

    var persistent: Bool { on && blocks }

    /// The port as set, or the kind's usual one.
    var portOrUsual: UInt16 { port ?? kind.usualPort }

    var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether what is set could be connected to at all: a host.
    var complete: Bool { !trimmedHost.isEmpty }

    /// An enabled route stays in force while its fields are being edited.
    /// An incomplete server blocks connections instead of going direct.
    var routes: Bool { on }

    /// Whether a profile's pages take the route.
    func applies(to profile: UUID) -> Bool {
        guard routes else { return false }
        return persistent || profiles.isEmpty || profiles.contains(profile)
    }

    /// What the proxy is called in a line of words: its host and port.
    var name: String { "\(trimmedHost):\(portOrUsual)" }

    /// The domains WebKit is told to reach directly: WebKit's list already
    /// covers a domain's subdomains. The Mac itself is always on it.
    var excluded: [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for raw in ["localhost", "127.0.0.1", "::1"] + (persistent ? [] : bypass) {
            let site = ProxySetup.domain(raw)
            guard !site.isEmpty, seen.insert(site).inserted else { continue }
            out.append(site)
        }
        return out
    }

    /// One line of the bypass list, as a domain: lowercase, no scheme, path,
    /// port or leading star, so "https://*.Example.com/x" is "example.com".
    static func domain(_ typed: String) -> String {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        while text.hasPrefix("*.") || text.hasPrefix(".") || text.hasPrefix("*") {
            text = String(text.dropFirst(text.hasPrefix("*.") ? 2 : 1))
        }
        // A port on a plain host (not on a bare IPv6 address).
        if !text.contains("["), text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
            text = String(text[..<colon])
        }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }
}

/// How the last test of the connection went.
enum ProxyCheck: Equatable {
    case untried
    case testing
    /// Reached, in this many milliseconds, with where sites see you from.
    case reached(ms: Int, address: String?, place: String?)
    case failed(String)
}

/// The route as it is, applied to every store there is and every store yet
/// to be made, and what it is doing right now. One for the app.
@MainActor
final class Proxy: ObservableObject {
    static let shared = Proxy()

    /// The settings, as Preferences last handed them over.
    @Published private(set) var setup = ProxySetup()
    /// The last test, for Settings › Proxy › Connection.
    @Published private(set) var check = ProxyCheck.untried
    /// The proxy stopped answering: a page failed on it, and nothing has
    /// confirmed recovery since. Cleared by Test or by the probe that runs
    /// every fifteen seconds and then reloads the failed pages.
    @Published private(set) var dropped = false
    /// The proxy asked a page for a name and password it didn't have, or
    /// didn't take the ones it was given. Cleared when credentials change
    /// or the proxy is confirmed to be working again.
    @Published private(set) var refused = false
    /// Local Keychain access failed before the proxy could be authenticated.
    @Published private(set) var credentialIssue: String?
    /// Where sites see you from, from the last successful test: "Frankfurt,
    /// Germany", or just the address. For the address bar.
    @Published private(set) var place: String?
    @Published private(set) var countryCode: String?
    @Published private(set) var timeZoneID: String?
    @Published private(set) var ready = false
    @Published private(set) var changingContent = false
    var waiting: Bool { setup.persistent && !ready }
    var protectsLocation: Bool { (setup.routes && (setup.blocks || setup.hidesCalls)) || Onion.shared.hasTabs }
    /// Tests supply a local endpoint; a rehearsal never contacts a live service.
    var automaticTarget: URL?
    var countryFlag: String? { ProxyCountry.flag(for: countryCode) }
    /// Goes up whenever the route changes, for sessions kept outside WebKit
    /// to be made again with the new one.
    @Published private(set) var revision = 0

    private var task: Task<Void, Never>?
    private var testID: UUID?
    private var credentialUnlock: (id: UUID, setup: ProxySetup, task: Task<Void, Never>)?
    private var probe: Task<Void, Never>?
    /// A page just failed: one look at the proxy, to tell its fault from
    /// the site's before saying so.
    private var confirming: Task<Void, Never>?
    /// The stores given a route so far, to take it off them again, and
    /// whose pages each serves.
    private var routed: [ObjectIdentifier: Routed] = [:]
    /// Tabs whose page failed on the proxy: reloaded once it answers.
    private let failedTabs = NSHashTable<Tab>.weakObjects()
    /// Destination failures are not proof of a proxy outage. Keep these
    /// apart until the proxy's own endpoint has failed its reachability check.
    private let suspectedTabs = NSHashTable<Tab>.weakObjects()
    private let otherViews = NSHashTable<WKWebView>.weakObjects()
    private var preferenceRules: [ObjectIdentifier: PreferenceRule] = [:]
    private var usedPools: [ObjectIdentifier: WKProcessPool] = [:]
    private var contentTransition: Task<Bool, Never>?

    private struct Routed {
        weak var store: WKWebsiteDataStore?
        var profile: UUID?
    }

    private struct PreferenceRule {
        weak var value: WKPreferences?
        var profile: UUID
        var tor = false
    }

    /// The route for what the browser fetches outside WebKit, read from any
    /// thread (see `session`). Built on the main actor whenever the settings
    /// change; nil while no profile's pages take the route.
    nonisolated private static let snapshotLock = NSLock()
    nonisolated(unsafe) private static var snapshot: ProxyConfiguration?
    nonisolated(unsafe) private static var onionSnapshot = OnionNetwork.configuration(port: nil, suffixOnly: true)
    nonisolated(unsafe) private static var snapshotRevision = 0
    nonisolated(unsafe) private static var keptFetches: (revision: Int, session: URLSession)?
    nonisolated(unsafe) private static var savedCredentials: ProxyCredentials?
    nonisolated(unsafe) private static var authentication: [ObjectIdentifier: ProxyAuthentication] = [:]

    private init() {}

    /// Long-lived clients must cancel connections using the previous route.
    nonisolated static let routeChanged = Notification.Name("SearchProxyRouteChanged")
    nonisolated static let contentChanged = Notification.Name("SearchProxyContentChanged")
    nonisolated static let connectionRestored = Notification.Name("SearchProxyConnectionRestored")

    // MARK: - the settings

    /// Preferences hands the settings over here, at launch and on every
    /// change. Every store made so far is given the route, or has it taken
    /// away, straight away; every open page's calls switch follows.
    func take(_ fresh: ProxySetup) {
        let before = setup
        setup = fresh
        guard fresh != before else { return }
        var networking = before
        networking.shows = fresh.shows
        if networking == fresh {
            // The address mark does not change the route or interrupt streams.
            for page in Web.pages.allObjects {
                follow(page.configuration.preferences, store: page.configuration.websiteDataStore)
            }
            return
        }
        cancelTest()
        check = .untried
        credentialIssue = nil
        if fresh.on != before.on || fresh.kind != before.kind || fresh.trimmedHost != before.trimmedHost
            || fresh.portOrUsual != before.portOrUsual || fresh.signsIn != before.signsIn || fresh.user != before.user {
            place = nil
            countryCode = nil
            refused = false
        }
        ready = false
        timeZoneID = nil
        if !fresh.routes {
            dropped = false
            forgetFailures()
        }
        confirming?.cancel()
        confirming = nil
        suspectedTabs.removeAllObjects()
        stopProbe()
        if (before.routes && (before.blocks || before.matchesTimeZone)) || (fresh.routes && (fresh.blocks || fresh.matchesTimeZone)) {
            suspendContent()
        }
        reroute()
        routePrepared()
    }

    /// The password was kept or taken out: the same settings, another route.
    func passwordChanged() {
        cancelTest()
        check = .untried
        credentialIssue = nil
        place = nil
        countryCode = nil
        refused = false
        ready = false
        timeZoneID = nil
        confirming?.cancel()
        confirming = nil
        suspectedTabs.removeAllObjects()
        stopProbe()
        if setup.routes && (setup.blocks || setup.matchesTimeZone) { suspendContent() }
        reroute()
        routePrepared()
    }

    private func cancelTest() {
        credentialUnlock?.task.cancel()
        credentialUnlock = nil
        testID = nil
        task?.cancel()
        task = nil
    }

    private func reroute() {
        revision += 1
        let route = setup.routes ? configuration() : nil
        let credentials = setup.routes ? ProxyCredentials(setup: setup, revision: revision,
            password: setup.signsIn ? ProxyPassword.read(setup) : nil) : nil
        if setup.routes, setup.signsIn, credentials?.password == nil {
            let issue = ProxyPassword.failureMessage(setup)
            credentialIssue = issue
            if check != .testing { check = .failed(issue) }
        } else {
            credentialIssue = nil
        }
        Proxy.snapshotLock.lock()
        Proxy.snapshot = route
        Proxy.snapshotRevision = revision
        Proxy.savedCredentials = credentials
        let sessions = Proxy.authentication.values.compactMap { $0.reportsFailures ? $0.session : nil }
        Proxy.keptFetches = nil
        Proxy.snapshotLock.unlock()
        sessions.forEach { $0.invalidateAndCancel() }
        for (id, kept) in routed {
            guard let store = kept.store else { routed[id] = nil; continue }
            let wanted = kept.profile.map(setup.applies(to:)) ?? setup.routes
            store.proxyConfigurations = configurations(for: store, wanted: wanted)
            followWorkers(in: store)
        }
        for page in Web.pages.allObjects {
            follow(page.configuration.preferences, store: page.configuration.websiteDataStore)
        }
        for (id, rule) in preferenceRules {
            guard let preferences = rule.value else { preferenceRules[id] = nil; continue }
            follow(preferences, profile: rule.profile, tor: rule.tor)
        }
        SiteLocation.shared.proxyChanged()
        Onion.shared.proxyChanged()
        NotificationCenter.default.post(name: Proxy.routeChanged, object: nil)
    }

    /// Tor listener changes update its isolated stores and suffix guards,
    /// without replacing the normal proxy or canceling its connections.
    func refreshOnionRoute(port: UInt16?) {
        for (id, kept) in routed {
            guard let store = kept.store else { routed[id] = nil; continue }
            guard Onion.shared.owns(store) else { continue }
            store.proxyConfigurations = [Onion.shared.configuration(for: store, port: port)]
        }
    }

    private func configurations(for store: WKWebsiteDataStore, wanted: Bool) -> [ProxyConfiguration] {
        if Onion.shared.owns(store) { return [Onion.shared.configuration(for: store, port: Onion.shared.port)] }
        let onion = OnionNetwork.configuration(port: nil, suffixOnly: true)
        return wanted ? [onion, configuration()] : [onion]
    }

    // MARK: - stores and pages

    /// A store takes the route, or is left on the Mac's settings, the moment
    /// a page is configured on it and whenever the settings change. Asked
    /// for a store already routed, nothing changes. `profile`: whose pages
    /// use it; nil for a store that serves every profile (favicons), which
    /// takes the route when any profile does.
    func apply(to store: WKWebsiteDataStore, profile: UUID?) {
        let id = ObjectIdentifier(store)
        let wanted = profile.map(setup.applies(to:)) ?? setup.routes
        let already = routed[id]
        routed[id] = Routed(store: store, profile: profile)
        if let already, already.store === store, already.profile == profile {
            // The same store asked for again with nothing changed: WebKit
            // is not told twice.
            return
        }
        store.proxyConfigurations = configurations(for: store, wanted: wanted)
        followWorkers(in: store)
    }

    /// Whose pages a store serves, as it was handed over; nil for one never
    /// seen, or one serving every profile.
    func profile(of store: WKWebsiteDataStore) -> UUID? { routed[ObjectIdentifier(store)]?.profile }

    /// Whether the route is on for a profile's pages: what the address bar
    /// goes by.
    func routes(for profile: UUID) -> Bool { setup.applies(to: profile) }

    /// A page's preferences follow the calls switch: peer connections off
    /// while its pages take the route and the switch is on. Through a name
    /// outside the public framework, as Safari's own switches are; a WebKit
    /// without it leaves calls on.
    func follow(_ preferences: WKPreferences, profile: UUID, tor: Bool = false) {
        preferenceRules[ObjectIdentifier(preferences)] = PreferenceRule(value: preferences, profile: profile, tor: tor)
        let calls = !tor && !(setup.applies(to: profile) && (setup.blocks || setup.hidesCalls))
        let set = NSSelectorFromString("_setPeerConnectionEnabled:")
        guard preferences.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(preferences.method(for: set), to: Setter.self)(preferences, set, calls)
    }

    /// The same, for a page whose store says whose it is. A store never
    /// handed over — a page made some other way — counts as Personal's.
    func follow(_ preferences: WKPreferences, store: WKWebsiteDataStore) {
        follow(preferences, profile: profile(of: store) ?? Profile.personalID, tor: Onion.shared.owns(store))
    }

    private func followWorkers(in store: WKWebsiteDataStore) {
        let selector = NSSelectorFromString("_setServiceWorkerOverridePreferences:")
        guard store.responds(to: selector) else { return }
        let preferences = WKPreferences()
        follow(preferences, store: store)
        typealias Setter = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        unsafeBitCast(store.method(for: selector), to: Setter.self)(store, selector, preferences)
    }

    /// WebKit's and URLSession's route, built afresh each time so the
    /// password is read from the keychain only now.
    func configuration(forTest: Bool = false) -> ProxyConfiguration {
        guard setup.complete, forTest || !waiting else {
            // Keep a valid proxy configuration in force while the fields
            // are incomplete. The reserved .invalid domain cannot resolve,
            // and failover must remain off even when ordinarily allowed.
            var blocked = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "missing-proxy.invalid", port: 9))
            blocked.allowFailover = false
            return blocked
        }
        let host = NWEndpoint.Host(setup.trimmedHost)
        let port = NWEndpoint.Port(rawValue: setup.portOrUsual) ?? NWEndpoint.Port(rawValue: setup.kind.usualPort)!
        let endpoint = NWEndpoint.hostPort(host: host, port: port)
        var made: ProxyConfiguration
        switch setup.kind {
        case .socks5: made = ProxyConfiguration(socksv5Proxy: endpoint)
        case .http: made = ProxyConfiguration(httpCONNECTProxy: endpoint)
        case .https: made = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: NWProtocolTLS.Options())
        }
        if setup.signsIn {
            guard !setup.user.isEmpty, let password = ProxyPassword.read(setup), !password.isEmpty else {
                var blocked = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "missing-proxy.invalid", port: 9))
                blocked.allowFailover = false
                return blocked
            }
            made.applyCredential(username: setup.user, password: password)
        }
        // Network treats rejected preapplied credentials as a failed route
        // before the auth delegate runs. Failover would hide that error and
        // send the request directly, so authenticated routes keep it visible.
        made.allowFailover = !forTest && !setup.blocks && !setup.signsIn
        // The catch-all proxy is never a candidate for a hidden-service
        // name, even if the framework tries another proxy configuration.
        made.excludedDomains = forTest ? [] : setup.excluded + ["onion", "onion."]
        return made
    }

    // MARK: - outside WebKit

    /// A session configuration for what the browser fetches outside WebKit
    /// — suggestions, icons, an update — with the route whenever any
    /// profile's pages take it: one of those fetches serves every profile,
    /// and going out directly would name the site to the network. Without
    /// the proxy it is the configuration handed in, untouched. Any thread.
    nonisolated static func session(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        snapshotLock.lock()
        let route = snapshot
        let onion = onionSnapshot
        snapshotLock.unlock()
        configuration.proxyConfigurations = [onion] + (route.map { [$0] } ?? [])
        return configuration
    }

    /// Goes up with the route, for a session kept for a while to be made
    /// again (EngineSuggest, ExtensionSocket, Copy Image). Any thread.
    nonisolated static var routesRevision: Int {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshotRevision
    }

    /// In place of URLSession.shared for what Search fetches for itself —
    /// an update, an extension from the store, its update check. Managed even
    /// with the proxy off, so enabling it cancels earlier direct connections.
    nonisolated static var fetches: URLSession {
        snapshotLock.lock()
        let revision = snapshotRevision
        if let keptFetches, keptFetches.revision == revision { snapshotLock.unlock(); return keptFetches.session }
        snapshotLock.unlock()
        let made = makeSession(configuration: .default)
        snapshotLock.lock()
        if snapshotRevision == revision { keptFetches = (revision, made) }
        snapshotLock.unlock()
        return made
    }

    /// Tests stand in for the network with URLProtocol classes, which the
    /// shared session takes from `registerClass` and a session of its own
    /// does not: these go in front of every session made here. Setting
    /// them lets go of the session kept for `fetches`, made before they
    /// were there.
    nonisolated static var protocolClasses: [AnyClass] {
        get { snapshotLock.lock(); defer { snapshotLock.unlock() }; return stubs }
        set { snapshotLock.lock(); stubs = newValue; keptFetches = nil; snapshotLock.unlock() }
    }
    nonisolated(unsafe) private static var stubs: [AnyClass] = []

    /// Every session has a bounded proxy-authentication policy, including
    /// sessions whose own delegates handle redirects, downloads, or streams.
    nonisolated static func makeSession(configuration: URLSessionConfiguration,
                                       delegate: URLSessionDelegate? = nil, delegateQueue: OperationQueue? = nil,
                                       route: ProxyConfiguration? = nil, reportsAuthenticationFailures: Bool = true) -> URLSession {
        snapshotLock.lock()
        let current = route.map { [$0] } ?? ([onionSnapshot] + (snapshot.map { [$0] } ?? []))
        let credentials = savedCredentials
        if !stubs.isEmpty {
            configuration.protocolClasses = stubs + (configuration.protocolClasses ?? [])
        }
        configuration.proxyConfigurations = current
        let handler = ProxyAuthentication(credentials: credentials, reportsFailures: reportsAuthenticationFailures)
        let made = URLSession(configuration: configuration, delegate: delegate ?? handler, delegateQueue: delegateQueue)
        handler.session = made
        authentication = authentication.filter { $0.value.session != nil }
        authentication[ObjectIdentifier(made)] = handler
        snapshotLock.unlock()
        return made
    }

    @discardableResult
    nonisolated static func authenticate(_ challenge: URLAuthenticationChallenge, in session: URLSession? = nil,
                                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) -> Bool {
        snapshotLock.lock()
        let handler: ProxyAuthentication?
        if let session {
            let found = authentication[ObjectIdentifier(session)]
            handler = found?.session === session ? found : nil
        } else {
            handler = ProxyAuthentication(credentials: savedCredentials)
        }
        snapshotLock.unlock()
        return handler?.respond(to: challenge, completionHandler: completionHandler) ?? false
    }

    nonisolated private static func authenticationFailure(in session: URLSession) -> String? {
        snapshotLock.lock()
        let handler = authentication[ObjectIdentifier(session)]
        snapshotLock.unlock()
        return handler?.failure
    }

    nonisolated static func authenticationError(_ error: Error, in session: URLSession) {
        snapshotLock.lock()
        let handler = authentication[ObjectIdentifier(session)]
        let credentials = handler?.session === session && handler?.reportsFailures == true ? handler?.credentials : nil
        snapshotLock.unlock()
        guard let credentials else { return }
        Task { @MainActor in
            guard shared.revision == credentials.revision else { return }
            if isAuthenticationFailure(error) {
                if credentials.setup.signsIn, credentials.password == nil {
                    shared.credentialFailed(ProxyPassword.failureMessage(credentials.setup), revision: credentials.revision)
                } else {
                    shared.authenticationFailed(credentials.setup.signsIn ? ProxyAuthentication.rejected : ProxyAuthentication.missing,
                                                revision: credentials.revision)
                }
            } else if looksLikeProxyTrouble(error), shared.setup.persistent {
                shared.confirmFailure(error, tab: nil)
            }
        }
    }

    func authenticationFailed(_ message: String, revision: Int) {
        guard setup.routes, self.revision == revision else { return }
        refused = true
        place = nil
        countryCode = nil
        check = .failed(message)
        if setup.persistent { connectionFailed(message) }
    }

    private func credentialFailed(_ message: String, revision: Int) {
        guard setup.routes, self.revision == revision else { return }
        credentialIssue = message
        refused = false
        place = nil
        countryCode = nil
        check = .failed(message)
        if setup.persistent { connectionFailed(message) }
    }

    // MARK: - the connection

    /// Manual and automatic checks use the real authenticated route, without
    /// bypasses or failover. The location service sees the proxy exit IP.
    func test(configuration base: URLSessionConfiguration = .ephemeral, target: URL = Proxy.whereAmI,
              allowCredentialPrompt: Bool = false) {
        if !allowCredentialPrompt, credentialUnlock != nil { return }
        if allowCredentialPrompt, setup.routes, setup.complete, setup.signsIn, !setup.user.isEmpty {
            if credentialUnlock?.setup == setup { return }
            cancelTest()
            check = .testing
            let id = UUID()
            let selected = setup
            let expectedRevision = revision
            let unlocking = Task { [weak self] in
                let password = await Task.detached(priority: .userInitiated) {
                    ProxyPassword.read(selected, allowCredentialPrompt: true)
                }.value
                guard !Task.isCancelled, let self, self.credentialUnlock?.id == id,
                      self.revision == expectedRevision, self.setup == selected else { return }
                self.credentialUnlock = nil
                if let password {
                    Proxy.snapshotLock.lock()
                    let current = Proxy.savedCredentials
                    Proxy.snapshotLock.unlock()
                    if current?.setup != selected || current?.revision != self.revision || current?.password != password {
                        self.reroute()
                    }
                }
                self.test(configuration: base, target: target)
            }
            credentialUnlock = (id, selected, unlocking)
            return
        }
        cancelTest()
        guard setup.routes else { check = .failed("Turn on Use a proxy before testing the connection"); return }
        guard setup.complete else {
            check = .failed("Enter the proxy's address first")
            if setup.persistent { startProbe() }
            return
        }
        if setup.signsIn, setup.user.isEmpty || ProxyPassword.read(setup)?.isEmpty != false {
            credentialFailed(ProxyPassword.failureMessage(setup), revision: revision)
            return
        }
        check = .testing
        let id = UUID()
        testID = id
        let testedRevision = revision
        let authenticationMessage = setup.signsIn ? ProxyAuthentication.rejected : ProxyAuthentication.missing
        let configuration = base.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        let route = self.configuration(forTest: true)
        configuration.proxyConfigurations = [route]
        let session = Proxy.makeSession(configuration: configuration, route: route, reportsAuthenticationFailures: false)
        let started = Date()
        task = Task { [weak self] in
            defer { session.invalidateAndCancel() }
            let result: ProxyCheck
            var authenticationFailure: String?
            var testedCountryCode: String?
            var testedTimeZone: String?
            do {
                var request = URLRequest(url: target)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await session.proxyData(for: request)
                let ms = Int((Date().timeIntervalSince(started) * 1000).rounded())
                if let http = response as? HTTPURLResponse, http.statusCode == 407 {
                    authenticationFailure = authenticationMessage
                    result = .failed(authenticationMessage)
                } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    // Reached, but the site had nothing to say: the proxy
                    // works, where you appear from is unknown.
                    result = self?.setup.persistent == true
                        ? .failed("The location service returned HTTP \(http.statusCode). Dark Search stays offline and retries")
                        : .reached(ms: ms, address: nil, place: nil)
                } else {
                    let seen = Proxy.read(data)
                    testedCountryCode = seen.countryCode
                    testedTimeZone = seen.timeZone
                    if self?.setup.matchesTimeZone == true, seen.timeZone == nil {
                        result = .failed("The proxy location did not include a valid time zone. Test again")
                    } else if self?.setup.matchesTimeZone == true, !ProxyTimeZone.isSupported {
                        result = .failed("This version of WebKit cannot match the proxy time zone")
                    } else if self?.setup.persistent == true, seen.address == nil {
                        result = .failed("The proxy location could not be verified. Dark Search stays offline")
                    } else {
                        result = .reached(ms: ms, address: seen.address, place: seen.place)
                    }
                }
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                guard let failure = Proxy.authenticationFailure(in: session) else { return }
                authenticationFailure = failure
                result = .failed(failure)
            } catch {
                if Proxy.isAuthenticationFailure(error) {
                    authenticationFailure = authenticationMessage
                    result = .failed(authenticationMessage)
                } else {
                    result = .failed(Proxy.authenticationFailure(in: session) ?? Proxy.explain(error))
                }
            }
            guard !Task.isCancelled, let self, self.testID == id,
                  self.revision == testedRevision else { return }
            self.task = nil
            self.testID = nil
            if let authenticationFailure { self.authenticationFailed(authenticationFailure, revision: testedRevision) }
            await self.finish(result, countryCode: testedCountryCode, timeZone: testedTimeZone, revision: testedRevision)
        }
    }

    private func finish(_ result: ProxyCheck, countryCode: String?, timeZone: String?, revision testedRevision: Int) async {
        guard revision == testedRevision else { return }
        if case .reached(_, let address, let spot) = result {
            let zone = setup.matchesTimeZone ? timeZone : nil
            var acceptingRevision = testedRevision
            if zone != timeZoneID {
                suspendContent()
                if setup.persistent && ready {
                    ready = false
                    reroute()
                    acceptingRevision = revision
                }
            }
            let stopped = await contentTransition?.value ?? true
            guard !Task.isCancelled, revision == acceptingRevision else { return }
            guard stopped || !setup.persistent else {
                connectionFailed("Dark Search could not stop the previous browser processes. Restart Dark Search to reconnect")
                return
            }
            place = spot ?? address
            self.countryCode = countryCode
            timeZoneID = zone
            let wasWaiting = waiting
            ready = true
            if wasWaiting { reroute() }
            resumeContent()
            guard !waiting else { return }
            recovered()
            check = result
        } else if case .failed(let message) = result, setup.persistent {
            connectionFailed(message)
        } else {
            check = result
        }
    }

    /// Keep the route closed before touching old pages or awaiting WebKit.
    private func connectionFailed(_ message: String) {
        guard setup.persistent else { return }
        confirming?.cancel()
        confirming = nil
        suspectedTabs.removeAllObjects()
        let wasReady = ready
        ready = false
        dropped = true
        check = .failed(message)
        if wasReady {
            suspendContent()
            reroute()
        }
        startProbe()
    }

    func track(_ view: WKWebView) {
        otherViews.add(view)
        let pool = view.configuration.processPool
        usedPools[ObjectIdentifier(pool)] = pool
    }

    func prepare(_ configuration: WKWebViewConfiguration) {
        follow(configuration.preferences, store: configuration.websiteDataStore)
        configuration.processPool = processPool(for: configuration.websiteDataStore)
        Onion.shared.prepare(configuration)
        let pool = configuration.processPool
        usedPools[ObjectIdentifier(pool)] = pool
    }

    func processPool(for store: WKWebsiteDataStore) -> WKProcessPool {
        if Onion.shared.owns(store), let pool = ProxyTimeZone.pool(for: "UTC") { return pool }
        let applies = profile(of: store).map(setup.applies(to:)) ?? setup.routes
        if applies, let zone = timeZoneID, let pool = ProxyTimeZone.pool(for: zone) { return pool }
        return Web.pool
    }

    private func suspendContent() {
        guard !changingContent else { return }
        changingContent = true
        var pools = [Web.pool] + ProxyTimeZone.pools + Array(usedPools.values)
        for tab in Tab.proxyTabs.allObjects {
            if let view = tab.built { pools.append(view.configuration.processPool) }
            tab.suspendForProxy()
        }
        for view in otherViews.allObjects {
            pools.append(view.configuration.processPool)
            ProxyTimeZone.close(view)
        }
        // Do not terminate the network process: that destroys private stores.
        contentTransition = Task { await ProxyTimeZone.restartWorkers(in: pools) }
    }

    private func resumeContent() {
        guard changingContent else { return }
        changingContent = false
        contentTransition = nil
        if #available(macOS 15.4, *), !Store.testing, !Extensions.shared.proxyChanged() {
            if setup.persistent {
                connectionFailed("Dark Search could not restart extensions safely. Restart Dark Search to reconnect")
                return
            }
            check = .failed("Some extensions could not restart. Restart Dark Search to use them again")
        }
        for tab in Tab.proxyTabs.allObjects { tab.resumeAfterProxy() }
        NotificationCenter.default.post(name: Proxy.contentChanged, object: nil)
    }

    private func routePrepared() {
        let expected = revision
        Task { [weak self] in
            guard let self else { return }
            let stopped = await self.contentTransition?.value ?? true
            guard self.revision == expected else { return }
            if self.setup.persistent {
                guard WKPreferences().responds(to: NSSelectorFromString("_setPeerConnectionEnabled:")) else {
                    self.connectionFailed("This version of WebKit cannot block direct peer connections")
                    return
                }
                guard stopped else {
                    self.connectionFailed("Dark Search could not stop the previous browser processes. Restart Dark Search to reconnect")
                    return
                }
                self.automaticCheck()
                self.startProbe()
            } else {
                self.resumeContent()
                if self.setup.routes && self.setup.matchesTimeZone { self.automaticCheck() }
                else if self.dropped { self.startProbe() }
            }
        }
    }

    private func automaticCheck() {
        guard setup.routes, task == nil, credentialUnlock == nil else { return }
        guard let target = Store.testing ? automaticTarget : Proxy.whereAmI else { return }
        test(target: target, allowCredentialPrompt: false)
    }

    /// CFNetwork's errors, whose proxy ones (306, 310) carry no NSURLError.
    static let cfNetwork = kCFErrorDomainCFNetwork as String

    /// Answers with the address it was reached from and, when it knows,
    /// the city, country and IANA time zone of that address.
    nonisolated static let whereAmI = URL(string: "https://ipinfo.io/json")!

    /// What the answer says: the address, and "City, Country" when both are
    /// there (the country spelled out from its code, in the Mac's language).
    static func read(_ data: Data) -> (address: String?, place: String?, countryCode: String?, timeZone: String?) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (nil, nil, nil, nil) }
        let address = (json["ip"] as? String)?.trimmingCharacters(in: .whitespaces)
        let city = (json["city"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let code = ProxyCountry.normalized(json["country"] as? String)
        let country = code.map { Locale.current.localizedString(forRegionCode: $0) ?? $0 } ?? ""
        let place = [city, country].filter { !$0.isEmpty }.joined(separator: ", ")
        return (address?.isEmpty == false ? address : nil, place.isEmpty ? nil : place, code, ProxyTimeZone.identifier(json["timezone"] as? String))
    }

    /// A failed test in plain words.
    static func explain(_ error: Error) -> String {
        if isAuthenticationFailure(error) { return ProxyAuthentication.rejected }
        let nsError = error as NSError
        switch (nsError.domain, nsError.code) {
        case (NSURLErrorDomain, NSURLErrorTimedOut): return "The proxy didn't answer in time"
        case (NSURLErrorDomain, NSURLErrorCannotFindHost), (NSURLErrorDomain, NSURLErrorDNSLookupFailed):
            return "No proxy by that name could be found"
        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost): return "Nothing is listening at that address and port"
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet): return "This Mac is offline"
        case (NSURLErrorDomain, NSURLErrorUserAuthenticationRequired): return "The proxy didn't accept the name or password"
        case (NSURLErrorDomain, NSURLErrorSecureConnectionFailed), (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted):
            return "The proxy's certificate isn't trusted"
        case (NSURLErrorDomain, NSURLErrorNetworkConnectionLost): return "The connection to the proxy was lost"
        case (Proxy.cfNetwork, 306), (Proxy.cfNetwork, 310):
            return "The proxy refused the connection"
        default: return nsError.localizedDescription
        }
    }

    // MARK: - when it drops

    /// A page failed on the way out, with an error a dead proxy gives. A
    /// site that is down gives the same one through a proxy, so the proxy
    /// is asked once, now: not listening, and it counts as dropped until it
    /// answers again — the page says so in place of its own words, a probe
    /// asks every fifteen seconds, and the tab loads again once it does.
    /// Listening, and the failure was the site's: nothing is said.
    func failed(_ error: Error, profile: UUID, tab: Tab?) {
        guard setup.applies(to: profile), Proxy.looksLikeProxyTrouble(error) else { return }
        if Proxy.isAuthenticationFailure(error) {
            if let tab { failedTabs.add(tab) }
            if let credentialIssue { tab?.failure = credentialIssue; return }
            authenticationFailed(setup.signsIn ? ProxyAuthentication.rejected : ProxyAuthentication.missing, revision: revision)
            tab?.failure = Proxy.refusedMessage
            return
        }
        confirmFailure(error, tab: tab)
    }

    /// DNS, timeout and connection errors can belong to the requested site,
    /// an icon or an optional service. Check the configured proxy endpoint
    /// before closing every page; failover remains disabled on each request
    /// throughout this check, so it cannot fall back to a direct connection.
    private func confirmFailure(_ error: Error, tab: Tab?) {
        if dropped {
            if let tab { failedTabs.add(tab) }
            tab?.failure = Proxy.droppedMessage
            return
        }
        if let tab { suspectedTabs.add(tab) }
        guard confirming == nil else { return }
        let failedRevision = revision
        let message = Proxy.explain(error)
        confirming = Task { [weak self] in
            guard let self else { return }
            let listening = await self.reachable()
            guard !Task.isCancelled, self.revision == failedRevision else { return }
            self.confirming = nil
            let suspects = self.suspectedTabs.allObjects
            self.suspectedTabs.removeAllObjects()
            guard !listening, self.setup.routes else { return }
            for tab in suspects where tab.failure != nil {
                self.failedTabs.add(tab)
                tab.failure = Proxy.droppedMessage
            }
            if self.setup.persistent {
                self.connectionFailed(message)
                self.automaticCheck()
            } else {
                self.dropped = true
                self.startProbe()
            }
        }
    }

    /// Only an explicit proxy test or its recovery probe establishes health.
    /// A page commit can have come from cache, a bypass, or a local document.
    private func recovered() {
        confirming?.cancel()
        confirming = nil
        suspectedTabs.removeAllObjects()
        dropped = false
        refused = false
        credentialIssue = nil
        stopProbe()
        cameBack()
        NotificationCenter.default.post(name: Proxy.connectionRestored, object: nil)
    }

    /// The errors a dead or refusing proxy gives a page, as opposed to a
    /// site that is down: nothing listening, no name, a tunnel refused.
    static func looksLikeProxyTrouble(_ error: Error) -> Bool {
        if isAuthenticationFailure(error) { return true }
        let nsError = error as NSError
        switch (nsError.domain, nsError.code) {
        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost), (NSURLErrorDomain, NSURLErrorTimedOut),
             (NSURLErrorDomain, NSURLErrorCannotFindHost), (NSURLErrorDomain, NSURLErrorDNSLookupFailed),
             (NSURLErrorDomain, NSURLErrorNetworkConnectionLost), (NSURLErrorDomain, NSURLErrorUserAuthenticationRequired):
            return true
        case (Proxy.cfNetwork, 306), (Proxy.cfNetwork, 310):
            return true
        default:
            return false
        }
    }

    /// Network can reject pre-applied proxy credentials before Foundation
    /// delivers a challenge. Classify its error codes, including wrappers,
    /// rather than depending on a localized description.
    static func isAuthenticationFailure(_ error: Error) -> Bool {
        var pending = [error as NSError]
        var seen: Set<ObjectIdentifier> = []
        while let current = pending.popLast(), seen.count < 32 {
            guard seen.insert(ObjectIdentifier(current)).inserted else { continue }
            if current.domain == NSPOSIXErrorDomain,
               [Int(POSIXErrorCode.EAUTH.rawValue), Int(POSIXErrorCode.ENEEDAUTH.rawValue)].contains(current.code) { return true }
            if current.domain == cfNetwork, [307, 122].contains(current.code) { return true }
            if current.domain == NSURLErrorDomain, current.code == NSURLErrorUserAuthenticationRequired { return true }
            pending.append(contentsOf: current.underlyingErrors.map { $0 as NSError })
        }
        return false
    }

    /// Settings stop routing while a probe is on its way: nothing to wait
    /// for any more.
    private func forgetFailures() {
        confirming?.cancel()
        confirming = nil
        suspectedTabs.removeAllObjects()
        failedTabs.removeAllObjects()
    }

    /// What a page says over itself while the proxy is down, in place of
    /// "The site refused the connection".
    static let droppedMessage = "The proxy isn't answering. Dark Search tries it again every 15 seconds."
    static let refusedMessage = "The proxy didn't accept the name or password. See Settings › Proxy."

    private func startProbe() {
        guard probe == nil else { return }
        let probingRevision = revision
        probe = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self else { return }
                if self.setup.persistent {
                    self.automaticCheck()
                    continue
                }
                let listening = await self.reachable()
                guard !Task.isCancelled, self.revision == probingRevision else { return }
                if listening {
                    self.recovered()
                    return
                }
            }
        }
    }

    private func stopProbe() {
        probe?.cancel()
        probe = nil
    }

    /// The proxy answers again: the tabs that failed on it load again,
    /// each from its own address.
    private func cameBack() {
        let tabs = failedTabs.allObjects
        failedTabs.removeAllObjects()
        for tab in tabs where tab.failure != nil {
            tab.failure = nil
            tab.reload()
        }
    }

    /// One TCP connection to the proxy's port, nothing sent: enough to tell
    /// whether it is listening again.
    private func reachable() async -> Bool {
        guard setup.complete else { return false }
        let host = NWEndpoint.Host(setup.trimmedHost)
        guard let port = NWEndpoint.Port(rawValue: setup.portOrUsual) else { return false }
        let connection = NWConnection(host: host, port: port, using: .tcp)
        let once = Once()
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let answer: @Sendable (Bool) -> Void = { ok in
                guard once.first() else { return }
                connection.cancel()
                done.resume(returning: ok)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: answer(true)
                case .failed, .cancelled, .waiting: answer(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6) { answer(false) }
        }
    }
}

/// The first of several answers counts; the rest are dropped.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

// MARK: - the password

/// The proxy's password, in the keychain as a proxy password for its server
/// and kind — the item Keychain Access lists under the server's name — or,
/// in a test run, in memory. Never in the settings file.
enum ProxyPassword {
    private static let label = Store.world.map { "Search (\($0))" } ?? "Search"
    private static let lock = NSLock()
    private static let mutationLock = NSLock()

    private struct Identity: Hashable {
        let label: String
        let host: String
        let port: UInt16
        let kind: String
        let user: String
    }
    private enum Scope: Hashable { case presence, quiet, interactive }
    private struct Lookup: Hashable { let identity: Identity; let scope: Scope }
    private enum Answer {
        case password(String), present, missing, unavailable(OSStatus), pending, stale
    }
    private struct Ticket { let id: UUID; let epoch: Int; let backend: Int }
    private struct Mutation { let id: UUID; let items: [Identity] }

    nonisolated(unsafe) private static var rehearsal: [Identity: String] = [:]
    nonisolated(unsafe) private static var passwords: [Identity: String] = [:]
    nonisolated(unsafe) private static var answers: [Lookup: Answer] = [:]
    nonisolated(unsafe) private static var pending: [Lookup: UUID] = [:]
    nonisolated(unsafe) private static var epochs: [Identity: Int] = [:]
    nonisolated(unsafe) private static var mutating: [Identity: UUID] = [:]
    nonisolated(unsafe) private static var backendRevision = 0
    nonisolated(unsafe) private static var testingQuery: (([String: Any]) -> (OSStatus, Data?))?

    /// A synthetic Security backend, effective only in an isolated test run.
    static func useKeychainForTesting(_ query: (([String: Any]) -> (OSStatus, Data?))?) {
        guard Store.testing else { return }
        locked {
            testingQuery = query
            backendRevision += 1
            passwords.removeAll(); answers.removeAll(); pending.removeAll(); mutating.removeAll()
        }
    }

    private static func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static func key(_ setup: ProxySetup) -> Identity {
        Identity(label: label, host: setup.trimmedHost.lowercased(), port: setup.portOrUsual,
                 kind: setup.kind.rawValue, user: setup.user)
    }

    private static func identity(_ setup: ProxySetup) -> [String: Any] {
        [kSecClass as String: kSecClassInternetPassword,
         kSecAttrServer as String: setup.trimmedHost,
         kSecAttrPort as String: Int(setup.portOrUsual),
         kSecAttrProtocol as String: setup.kind.keychainProtocol,
         kSecAttrAccount as String: setup.user,
         kSecAttrLabel as String: label]
    }

    private static func candidates(_ setup: ProxySetup) -> [ProxySetup] {
        guard setup.kind != .socks5 else { return [setup] }
        var alternate = setup
        alternate.kind = setup.kind == .http ? .https : .http
        alternate.port = setup.portOrUsual
        return [setup, alternate]
    }

    /// Background/startup reads never present Keychain UI. Only an explicit
    /// Poke may ask, once per identity for this launch, including a refusal.
    static func read(_ setup: ProxySetup, allowCredentialPrompt: Bool = false) -> String? {
        guard !setup.user.isEmpty, setup.complete else { return nil }
        let scope: Scope = allowCredentialPrompt ? .interactive : .quiet
        for candidate in candidates(setup) {
            switch lookup(candidate, scope: scope) {
            case .password(let password): return password
            case .missing: continue
            default: return nil // A refusal is never permission to try another protected item.
            }
        }
        return nil
    }

    /// No lock is held while Security talks to its daemon or the person.
    /// A second synchronous reader fails closed while a lookup is pending.
    private static func lookup(_ setup: ProxySetup, scope: Scope) -> Answer {
        let item = key(setup)
        let lookup = Lookup(identity: item, scope: scope)
        var ticket: Ticket?
        let cached: Answer? = locked {
            if mutating[item] != nil { return .pending }
            if let password = passwords[item] { return scope == .presence ? .present : .password(password) }
            if let answer = answers[lookup] { return answer }
            if pending.keys.contains(where: { $0.identity == item }) { return .pending }
            let made = Ticket(id: UUID(), epoch: epochs[item] ?? 0, backend: backendRevision)
            pending[lookup] = made.id
            ticket = made
            return nil
        }
        if let cached { return cached }
        guard let ticket else { return .pending }
        var query = identity(setup)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = scope == .interactive ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        if scope == .presence { query[kSecReturnAttributes as String] = true }
        else { query[kSecReturnData as String] = true }
        let result: (OSStatus, Data?)
        let backend = locked { testingQuery }
        if Store.testing, let backend { result = backend(query) }
        else if Store.testing {
            let password = locked { rehearsal[item] }
            result = password.map { (errSecSuccess, scope == .presence ? nil : Data($0.utf8)) } ?? (errSecItemNotFound, nil)
        } else if scope == .presence {
            result = (KeychainAccess.copyMatching(query as CFDictionary, nil), nil)
        } else {
            var out: CFTypeRef?
            let status = KeychainAccess.copyMatching(query as CFDictionary, &out)
            result = (status, out as? Data)
        }
        let answer: Answer
        if result.0 == errSecItemNotFound { answer = .missing }
        else if result.0 != errSecSuccess { answer = .unavailable(result.0) }
        else if scope == .presence { answer = .present }
        else if let data = result.1, let password = String(data: data, encoding: .utf8), !password.isEmpty { answer = .password(password) }
        else { answer = .unavailable(errSecDecode) }
        return locked {
            if pending[lookup] == ticket.id { pending.removeValue(forKey: lookup) }
            guard (epochs[item] ?? 0) == ticket.epoch, backendRevision == ticket.backend, mutating[item] == nil else { return .stale }
            answers[lookup] = answer
            if scope == .interactive {
                // A later explicit refusal supersedes a stale background
                // "missing" result; it must never unlock the alternate slot.
                answers[Lookup(identity: item, scope: .quiet)] = answer
                answers.removeValue(forKey: Lookup(identity: item, scope: .presence))
            }
            if case .password(let password) = answer { passwords[item] = password }
            return answer
        }
    }

    /// Settings asks only for attributes, with UI forbidden, and never waits
    /// for an in-flight credential approval to finish.
    static func kept(_ setup: ProxySetup) -> Bool {
        guard !setup.user.isEmpty, setup.complete else { return false }
        for candidate in candidates(setup) {
            switch lookup(candidate, scope: .presence) {
            case .present, .password: return true
            case .missing: continue
            default: return false
            }
        }
        return false
    }

    static func failureMessage(_ setup: ProxySetup) -> String {
        locked {
            for candidate in candidates(setup) {
                let item = key(candidate)
                let interactive = answers[Lookup(identity: item, scope: .interactive)]
                let answer = interactive ?? answers[Lookup(identity: item, scope: .quiet)]
                switch answer {
                case .unavailable(let status):
                    if [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(status) {
                        return interactive == nil
                            ? "Poke to allow access to the saved proxy password"
                            : "Access to the saved proxy password wasn't allowed. Save it again or restart Dark Search to retry"
                    }
                    return "The saved proxy password couldn't be read. Save it again"
                case .pending:
                    return "Waiting for access to the saved proxy password"
                case .missing: continue
                default: break
                }
            }
            return ProxyAuthentication.missing
        }
    }

    private static func beginMutation(_ setup: ProxySetup) -> Mutation {
        let mutation = Mutation(id: UUID(), items: candidates(setup).map(key))
        locked {
            for item in mutation.items {
                epochs[item, default: 0] += 1
                passwords[item] = nil
                answers = answers.filter { $0.key.identity != item }
                mutating[item] = mutation.id
            }
        }
        return mutation
    }

    private static func endMutation(_ mutation: Mutation, password: (Identity, String)? = nil, forgotten: Bool = false) -> Bool {
        locked {
            guard mutation.items.allSatisfy({ mutating[$0] == mutation.id }) else { return false }
            for item in mutation.items {
                epochs[item, default: 0] += 1
                mutating.removeValue(forKey: item)
                passwords[item] = nil
                answers = answers.filter { $0.key.identity != item }
                if forgotten {
                    for scope in [Scope.presence, .quiet, .interactive] { answers[Lookup(identity: item, scope: scope)] = .missing }
                }
            }
            if let (item, value) = password { passwords[item] = value }
            return true
        }
    }

    @discardableResult
    static func save(_ password: String, for setup: ProxySetup) -> Bool {
        guard !setup.user.isEmpty, setup.complete else { return false }
        if password.isEmpty { return forget(setup) }
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let mutation = beginMutation(setup)
        let saved: Bool
        if Store.testing {
            locked { rehearsal[key(setup)] = password }
            saved = true
        } else {
            let fields: [String: Any] = [kSecValueData as String: Data(password.utf8), kSecAttrLabel as String: label]
            let status = KeychainAccess.update(identity(setup) as CFDictionary, fields as CFDictionary)
            if status == errSecSuccess { saved = true }
            else if status == errSecItemNotFound {
                var fresh = identity(setup).merging(fields) { _, new in new }
                fresh[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
                saved = KeychainAccess.add(fresh as CFDictionary, nil) == errSecSuccess
            } else { saved = false }
        }
        let published = endMutation(mutation, password: saved ? (key(setup), password) : nil)
        return saved && published
    }

    @discardableResult
    static func forget(_ setup: ProxySetup) -> Bool {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let mutation = beginMutation(setup)
        var forgotten = true
        for candidate in candidates(setup) {
            if Store.testing { locked { rehearsal[key(candidate)] = nil }; continue }
            let status = KeychainAccess.delete(identity(candidate) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound { forgotten = false; break }
        }
        let published = endMutation(mutation, forgotten: forgotten)
        return forgotten && published
    }
}
