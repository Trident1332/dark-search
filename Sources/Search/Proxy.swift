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
    /// A page fails rather than slip out directly when the proxy can't be
    /// reached. Off, WebKit falls back to a direct connection.
    var blocks = true
    /// A mark beside the address while pages take the route.
    var shows = true
    /// Peer connections are off while the proxy is on: a call can't go
    /// through a proxy, so one would have shown the Mac's own address.
    var hidesCalls = true

    /// The port as set, or the kind's usual one.
    var portOrUsual: UInt16 { port ?? kind.usualPort }

    var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether what is set could be connected to at all: a host.
    var complete: Bool { !trimmedHost.isEmpty }

    /// On, and set well enough to route through.
    var routes: Bool { on && complete }

    /// Whether a profile's pages take the route.
    func applies(to profile: UUID) -> Bool {
        guard routes else { return false }
        return profiles.isEmpty || profiles.contains(profile)
    }

    /// What the proxy is called in a line of words: its host and port.
    var name: String { "\(trimmedHost):\(portOrUsual)" }

    /// The domains WebKit is told to reach directly: WebKit's list already
    /// covers a domain's subdomains. The Mac itself is always on it.
    var excluded: [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for raw in ["localhost", "127.0.0.1", "::1"] + bypass {
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
    /// got through since. Cleared when a page loads, or when the probe that
    /// runs every fifteen seconds reaches it again.
    @Published private(set) var dropped = false
    /// The proxy asked a page for a name and password it didn't have, or
    /// didn't take the ones it was given. Cleared when a page gets through.
    @Published private(set) var refused = false
    /// Where sites see you from, from the last successful test: "Frankfurt,
    /// Germany", or just the address. For the address bar.
    @Published private(set) var place: String?
    /// Goes up whenever the route changes, for sessions kept outside WebKit
    /// to be made again with the new one.
    @Published private(set) var revision = 0

    private var task: Task<Void, Never>?
    private var probe: Task<Void, Never>?
    /// A page just failed: one look at the proxy, to tell its fault from
    /// the site's before saying so.
    private var confirming: Task<Void, Never>?
    /// The stores given a route so far, to take it off them again, and
    /// whose pages each serves.
    private var routed: [ObjectIdentifier: Routed] = [:]
    /// Tabs whose page failed on the proxy: reloaded once it answers.
    private let failedTabs = NSHashTable<Tab>.weakObjects()

    private struct Routed {
        weak var store: WKWebsiteDataStore?
        var profile: UUID?
    }

    /// The route for what the browser fetches outside WebKit, read from any
    /// thread (see `session`). Built on the main actor whenever the settings
    /// change; nil while no profile's pages take the route.
    nonisolated private static let snapshotLock = NSLock()
    nonisolated(unsafe) private static var snapshot: ProxyConfiguration?
    nonisolated(unsafe) private static var snapshotRevision = 0
    nonisolated(unsafe) private static var keptFetches: (revision: Int, session: URLSession)?

    private init() {}

    // MARK: - the settings

    /// Preferences hands the settings over here, at launch and on every
    /// change. Every store made so far is given the route, or has it taken
    /// away, straight away; every open page's calls switch follows.
    func take(_ fresh: ProxySetup) {
        let before = setup
        setup = fresh
        guard fresh != before else { return }
        if fresh.on != before.on || fresh.kind != before.kind || fresh.trimmedHost != before.trimmedHost
            || fresh.portOrUsual != before.portOrUsual || fresh.signsIn != before.signsIn || fresh.user != before.user {
            check = .untried
            place = nil
            refused = false
        }
        if !fresh.routes {
            dropped = false
            stopProbe()
            forgetFailures()
        }
        reroute()
    }

    /// The password was kept or taken out: the same settings, another route.
    func passwordChanged() {
        check = .untried
        refused = false
        reroute()
    }

    private func reroute() {
        revision += 1
        let route = setup.routes ? configuration() : nil
        Proxy.snapshotLock.lock()
        Proxy.snapshot = route
        Proxy.snapshotRevision = revision
        Proxy.snapshotLock.unlock()
        for (id, kept) in routed {
            guard let store = kept.store else { routed[id] = nil; continue }
            let wanted = kept.profile.map(setup.applies(to:)) ?? setup.routes
            store.proxyConfigurations = wanted ? [configuration()] : []
        }
        for page in Web.pages.allObjects {
            follow(page.configuration.preferences, store: page.configuration.websiteDataStore)
        }
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
        if let already, already.store === store, already.profile == profile, store.proxyConfigurations.isEmpty == !wanted {
            // The same store asked for again with nothing changed: WebKit
            // is not told twice.
            return
        }
        store.proxyConfigurations = wanted ? [configuration()] : []
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
    func follow(_ preferences: WKPreferences, profile: UUID) {
        let calls = !(setup.applies(to: profile) && setup.hidesCalls)
        let set = NSSelectorFromString("_setPeerConnectionEnabled:")
        guard preferences.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(preferences.method(for: set), to: Setter.self)(preferences, set, calls)
    }

    /// The same, for a page whose store says whose it is. A store never
    /// handed over — a page made some other way — counts as Personal's.
    func follow(_ preferences: WKPreferences, store: WKWebsiteDataStore) {
        follow(preferences, profile: profile(of: store) ?? Profile.personalID)
    }

    /// WebKit's and URLSession's route, built afresh each time so the
    /// password is read from the keychain only now.
    func configuration() -> ProxyConfiguration {
        let host = NWEndpoint.Host(setup.trimmedHost)
        let port = NWEndpoint.Port(rawValue: setup.portOrUsual) ?? NWEndpoint.Port(rawValue: setup.kind.usualPort)!
        let endpoint = NWEndpoint.hostPort(host: host, port: port)
        var made: ProxyConfiguration
        switch setup.kind {
        case .socks5: made = ProxyConfiguration(socksv5Proxy: endpoint)
        case .http: made = ProxyConfiguration(httpCONNECTProxy: endpoint)
        case .https: made = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: NWProtocolTLS.Options())
        }
        if setup.signsIn, !setup.user.isEmpty, let password = ProxyPassword.read(setup), !password.isEmpty {
            made.applyCredential(username: setup.user, password: password)
        }
        made.allowFailover = !setup.blocks
        made.excludedDomains = setup.excluded
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
        snapshotLock.unlock()
        if let route { configuration.proxyConfigurations = [route] }
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
    /// an update, an extension from the store, its update check: the shared
    /// session itself while no proxy is on, and one with its defaults and
    /// the route while one is. Any thread.
    nonisolated static var fetches: URLSession {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        guard let snapshot else { return .shared }
        if let keptFetches, keptFetches.revision == snapshotRevision { return keptFetches.session }
        let configuration = URLSessionConfiguration.default
        configuration.proxyConfigurations = [snapshot]
        let made = URLSession(configuration: configuration)
        keptFetches = (snapshotRevision, made)
        return made
    }

    // MARK: - the connection

    /// Settings › Proxy › Connection › Test: one request through the proxy
    /// to a site that answers with where it was reached from. Nothing is
    /// sent until the button is pressed, and only the proxy's own address
    /// reaches that site.
    func test() {
        task?.cancel()
        guard setup.complete else {
            check = .failed("Enter the proxy's address first")
            return
        }
        check = .testing
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        var route = self.configuration()
        route.allowFailover = false
        configuration.proxyConfigurations = [route]
        let session = URLSession(configuration: configuration)
        let started = Date()
        task = Task { [weak self] in
            defer { session.invalidateAndCancel() }
            let result: ProxyCheck
            do {
                var request = URLRequest(url: Proxy.whereAmI)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await session.data(for: request)
                let ms = Int((Date().timeIntervalSince(started) * 1000).rounded())
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    // Reached, but the site had nothing to say: the proxy
                    // works, where you appear from is unknown.
                    result = .reached(ms: ms, address: nil, place: nil)
                } else {
                    let seen = Proxy.read(data)
                    result = .reached(ms: ms, address: seen.address, place: seen.place)
                }
            } catch is CancellationError {
                return
            } catch {
                result = .failed(Proxy.explain(error))
            }
            self?.finish(result)
        }
    }

    private func finish(_ result: ProxyCheck) {
        check = result
        if case .reached(_, let address, let spot) = result {
            place = spot ?? address
            dropped = false
            refused = false
            stopProbe()
        }
    }

    /// CFNetwork's errors, whose proxy ones (306, 310) carry no NSURLError.
    static let cfNetwork = kCFErrorDomainCFNetwork as String

    /// Answers with the address it was reached from and, when it knows,
    /// the city and country of that address. Reached only on Test.
    static let whereAmI = URL(string: "https://ipinfo.io/json")!

    /// What the answer says: the address, and "City, Country" when both are
    /// there (the country spelled out from its code, in the Mac's language).
    static func read(_ data: Data) -> (address: String?, place: String?) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (nil, nil) }
        let address = (json["ip"] as? String)?.trimmingCharacters(in: .whitespaces)
        let city = (json["city"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let code = (json["country"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let country = code.isEmpty ? "" : (Locale.current.localizedString(forRegionCode: code) ?? code)
        let place = [city, country].filter { !$0.isEmpty }.joined(separator: ", ")
        return (address?.isEmpty == false ? address : nil, place.isEmpty ? nil : place)
    }

    /// A failed test in plain words.
    static func explain(_ error: Error) -> String {
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
        if (error as NSError).code == NSURLErrorUserAuthenticationRequired {
            refused = true
            tab?.failure = Proxy.refusedMessage
            return
        }
        if let tab { failedTabs.add(tab) }
        if dropped {
            tab?.failure = Proxy.droppedMessage
            return
        }
        guard confirming == nil else { return }
        confirming = Task { [weak self] in
            guard let self else { return }
            let listening = await self.reachable()
            self.confirming = nil
            guard !listening, self.setup.routes else {
                self.failedTabs.removeAllObjects()
                return
            }
            self.dropped = true
            for tab in self.failedTabs.allObjects where tab.failure != nil { tab.failure = Proxy.droppedMessage }
            self.startProbe()
        }
    }

    /// The proxy asked a page who it is: the name and password it was
    /// given, if any, weren't taken. Said in Settings; the page's own
    /// sign-in box is not shown for a proxy.
    func challenged() {
        guard setup.routes else { return }
        refused = true
    }

    /// A page got through: the proxy is up.
    func loaded(profile: UUID) {
        guard dropped || refused, setup.applies(to: profile) else { return }
        dropped = false
        refused = false
        stopProbe()
    }

    /// The errors a dead or refusing proxy gives a page, as opposed to a
    /// site that is down: nothing listening, no name, a tunnel refused.
    static func looksLikeProxyTrouble(_ error: Error) -> Bool {
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

    /// Settings stop routing while a probe is on its way: nothing to wait
    /// for any more.
    private func forgetFailures() {
        confirming?.cancel()
        confirming = nil
        failedTabs.removeAllObjects()
    }

    /// What a page says over itself while the proxy is down, in place of
    /// "The site refused the connection".
    static let droppedMessage = "The proxy isn't answering. Search tries it again every 15 seconds."
    static let refusedMessage = "The proxy didn't accept the name or password. See Settings › Proxy."

    private func startProbe() {
        guard probe == nil else { return }
        probe = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self else { return }
                if await self.reachable() {
                    self.dropped = false
                    self.probe = nil
                    self.cameBack()
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
    nonisolated(unsafe) private static var rehearsal: [String: String] = [:]

    private static func identity(_ setup: ProxySetup) -> [String: Any] {
        [kSecClass as String: kSecClassInternetPassword,
         kSecAttrServer as String: setup.trimmedHost,
         kSecAttrPort as String: Int(setup.portOrUsual),
         kSecAttrProtocol as String: setup.kind.keychainProtocol,
         kSecAttrAccount as String: setup.user,
         kSecAttrLabel as String: label]
    }

    private static func key(_ setup: ProxySetup) -> String { "\(setup.user)@\(setup.name)/\(setup.kind.rawValue)" }

    static func read(_ setup: ProxySetup) -> String? {
        guard !setup.user.isEmpty, setup.complete else { return nil }
        if Store.testing { return rehearsal[key(setup)] }
        var asked = identity(setup)
        asked[kSecReturnData as String] = true
        asked[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(asked as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Kept, or taken out when empty.
    @discardableResult
    static func save(_ password: String, for setup: ProxySetup) -> Bool {
        guard !setup.user.isEmpty, setup.complete else { return false }
        if password.isEmpty { return forget(setup) }
        if Store.testing {
            rehearsal[key(setup)] = password
            return true
        }
        guard let data = password.data(using: .utf8) else { return false }
        let fields: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: label]
        let status = SecItemUpdate(identity(setup) as CFDictionary, fields as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var fresh = identity(setup).merging(fields) { _, new in new }
        fresh[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(fresh as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func forget(_ setup: ProxySetup) -> Bool {
        if Store.testing {
            rehearsal[key(setup)] = nil
            return true
        }
        let status = SecItemDelete(identity(setup) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Whether a password is kept for what is set, without reading it.
    static func kept(_ setup: ProxySetup) -> Bool {
        guard !setup.user.isEmpty, setup.complete else { return false }
        if Store.testing { return rehearsal[key(setup)] != nil }
        var asked = identity(setup)
        asked[kSecReturnAttributes as String] = true
        asked[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(asked as CFDictionary, nil) == errSecSuccess
    }
}
