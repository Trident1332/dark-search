import AppKit
import Combine
import Darwin
import Foundation
import Network
import WebKit

/// The suffix route is present even before Tor starts. A hidden-service
/// name must never fall through to the Mac's DNS or another proxy.
enum OnionNetwork {
    /// These credentials identify a privacy context to Tor, not a login.
    /// Tor's SOCKS extension treats the password as its stream-isolation key.
    struct Isolation: Equatable, Sendable {
        static let username = "<torS0X>0"
        let password = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// The ordinary clients' closed onion-suffix guard never uses a private
    /// store's key, even if that guard is later rebuilt for another listener.
    private static let suffixIsolation = Isolation()

    static func configuration(port: UInt16?, suffixOnly: Bool = false, isolation: Isolation? = nil) -> ProxyConfiguration {
        var route = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port ?? 9)!))
        let key = isolation ?? (suffixOnly ? suffixIsolation : Isolation())
        route.applyCredential(username: Isolation.username, password: key.password)
        route.allowFailover = false
        route.excludedDomains = []
        if suffixOnly { route.matchDomains = ["onion", "onion."] }
        return route
    }

    static func permits(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if ["about", "data", "blob"].contains(scheme) { return true }
        guard ["http", "https", "ws", "wss"].contains(scheme), let raw = url.host() else { return false }
        let host = OnionAddress.canonicalHost(raw)
        var numeric = in_addr()
        let isNumeric = host.withCString { inet_aton($0, &numeric) != 0 }
        guard !host.isEmpty, host.contains("."), !host.contains(":"), !host.contains("["),
              host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local"),
              !host.hasSuffix(".localdomain"),
              host != "home.arpa", !host.hasSuffix(".home.arpa"), !isNumeric, !host.allSatisfy({ $0.isNumber || $0 == "." }),
              !(host.hasPrefix("0x") && host.dropFirst(2).allSatisfy(\.isHexDigit)) else { return false }
        return !OnionAddress.isOnionHost(host) || OnionAddress.isValidHost(host)
    }
}

/// Tor tabs keep their own temporary stores. A redirect to an ordinary
/// website remains in the same Tor store, including its workers and assets.
@MainActor
final class Onion: ObservableObject {
    static let shared = Onion()
    nonisolated static let stateChanged = Notification.Name("SearchOnionStateChanged")
    @Published private(set) var enabled = true
    @Published private(set) var status = "Tor starts when you open an onion website"
    @Published private(set) var isConnecting = false
    @Published private(set) var ready = false
    private var runtime: TorRuntime
    private var connection: Task<UInt16, Error>?
    private var generation = UUID()
    private var lastPort: UInt16?
    private var upstream: TorUpstream?
    private var rules: WKContentRuleList?
    private var ruleTask: Task<WKContentRuleList, Error>?
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private var stores: [ObjectIdentifier: TorStore] = [:]
    private var sourceStores: [ObjectIdentifier: SourceStore] = [:]
    private var quitObserver: NSObjectProtocol?

    private struct TorStore {
        weak var value: WKWebsiteDataStore?
        let isolation = OnionNetwork.Isolation()
    }
    private struct SourceStore {
        weak var source: WKWebsiteDataStore?
        weak var tor: WKWebsiteDataStore?
    }

    init(runtime: TorRuntime = .shared) {
        self.runtime = runtime
        runtime.onStateChanged = { [weak self] in self?.runtimeChanged() }
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    var port: UInt16? { ready && enabled && !Proxy.shared.waiting ? runtime.port : nil }
    var hasTabs: Bool { Tab.proxyTabs.allObjects.contains(where: \.usesTor) }
    func owns(_ store: WKWebsiteDataStore) -> Bool { stores[ObjectIdentifier(store)]?.value === store }

    func enteredTab() {
        SiteLocation.shared.proxyChanged()
        NotificationCenter.default.post(name: Onion.stateChanged, object: nil)
    }

    func useRuntimeForTesting(_ runtime: TorRuntime?) {
        guard Store.testing else { return }
        stop()
        self.runtime.onStateChanged = nil
        self.runtime = runtime ?? .shared
        self.runtime.onStateChanged = { [weak self] in self?.runtimeChanged() }
    }

    func store(for source: WKWebsiteDataStore) -> WKWebsiteDataStore {
        if owns(source) { return source }
        let key = ObjectIdentifier(source)
        if let kept = sourceStores[key], kept.source === source, let tor = kept.tor { return tor }
        sourceStores = sourceStores.filter { $0.value.source != nil && $0.value.tor != nil }
        stores = stores.filter { $0.value.value != nil }
        let made = WKWebsiteDataStore.nonPersistent()
        stores[ObjectIdentifier(made)] = TorStore(value: made)
        sourceStores[key] = SourceStore(source: source, tor: made)
        return made
    }

    /// A route rebuilt after Tor restarts keeps the same context key. Both
    /// WebKit's pages/downloads and auxiliary requests use this entry point.
    func configuration(for store: WKWebsiteDataStore, port: UInt16?) -> ProxyConfiguration {
        stores = stores.filter { $0.value.value != nil }
        let kept = stores[ObjectIdentifier(store)]
        let isolation = kept?.value === store ? kept?.isolation : nil
        return OnionNetwork.configuration(port: port, isolation: isolation)
    }

    func take(enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        stop()
        if !enabled { status = "Onion websites are off. Turn them on in Settings › Proxy" }
        for tab in Tab.proxyTabs.allObjects where tab.usesTor { tab.onionRouteChanged() }
    }

    func retry() {
        stop()
        Task { try? await connect() }
        for tab in Tab.proxyTabs.allObjects where tab.usesTor { tab.onionRouteChanged() }
    }

    func stop() {
        generation = UUID()
        connection?.cancel()
        connection = nil
        runtime.stop()
        ready = false
        isConnecting = false
        refreshRoute()
    }

    /// A change in Search's proxy retires the child's connections too. Tor
    /// receives the same upstream account over stdin, with no direct fallback.
    func proxyChanged() {
        let fresh = try? configuredUpstream()
        if runtime.isReady, fresh == upstream, !Proxy.shared.waiting { return }
        if connection != nil || runtime.phase != .idle { stop() }
        if hasTabs {
            for tab in Tab.proxyTabs.allObjects where tab.usesTor { tab.onionRouteChanged() }
        }
    }

    func connect() async throws -> UInt16 {
        try Task.checkCancellation()
        guard enabled else { throw TorRuntime.Failure(message: "Turn on Open onion websites in Settings › Proxy") }
        if let port { return port }
        if let connection {
            let id = generation
            let result = try await connection.value
            try Task.checkCancellation()
            guard generation == id else { throw CancellationError() }
            return result
        }
        let id = generation
        let operation = Task<UInt16, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            self.isConnecting = true
            defer { if self.generation == id { self.isConnecting = false } }
            guard ProxyTimeZone.isSupported,
                  WKPreferences().responds(to: NSSelectorFromString("_setPeerConnectionEnabled:")) else {
                throw TorRuntime.Failure(message: "This version of WebKit cannot protect Tor tabs")
            }
            _ = try await self.contentRules()
            while Proxy.shared.waiting {
                self.status = "Waiting for your configured proxy. See Connection above"
                try await Task.sleep(for: .milliseconds(200))
            }
            try Task.checkCancellation()
            let upstream = try self.configuredUpstream()
            self.upstream = upstream
            let port = try await self.runtime.start(upstream: upstream)
            try Task.checkCancellation()
            guard self.generation == id, !Proxy.shared.waiting else { throw CancellationError() }
            self.ready = true
            self.status = "Connected to Tor · Tor tabs use UTC"
            self.refreshRoute()
            return port
        }
        connection = operation
        let result: UInt16
        do {
            result = try await operation.value
        } catch {
            if generation == id {
                connection = nil
                ready = false
                if !(error is CancellationError) { status = error.localizedDescription }
                refreshRoute()
            }
            throw error
        }
        if generation == id { connection = nil }
        // A tab owns its wait, not the shared connection. Its cancellation
        // must not withdraw a route another tab has just finished starting.
        try Task.checkCancellation()
        guard generation == id else { throw CancellationError() }
        return result
    }

    private func configuredUpstream() throws -> TorUpstream? {
        let setup = Proxy.shared.setup
        guard setup.routes else { return nil }
        guard setup.complete else { throw TorRuntime.Failure(message: "Enter your proxy address before connecting to Tor") }
        let user = setup.signsIn ? setup.user : nil
        let password = setup.signsIn ? ProxyPassword.read(setup) : nil
        if setup.signsIn, user?.isEmpty != false || password?.isEmpty != false {
            throw TorRuntime.Failure(message: "Save your proxy name and password before connecting to Tor")
        }
        switch setup.kind {
        case .http: return .httpConnect(host: setup.trimmedHost, port: setup.portOrUsual, username: user, password: password)
        case .https: return .httpsConnect(host: setup.trimmedHost, port: setup.portOrUsual, username: user, password: password)
        case .socks5: return .socks5(host: setup.trimmedHost, port: setup.portOrUsual, username: user, password: password)
        }
    }

    private func runtimeChanged() {
        switch runtime.phase {
        case .idle: ready = false; if enabled { status = "Tor starts when you open an onion website" }
        case .starting(let progress): status = "Connecting to Tor · \(progress)%"
        case .ready: break // Only connect() opens the route after all prerequisites.
        case .failed(let message): ready = false; status = message
        }
        refreshRoute()
    }

    private func refreshRoute() {
        let fresh = port
        guard fresh != lastPort else { return }
        lastPort = fresh
        Proxy.shared.refreshOnionRoute(port: fresh)
    }

    func prepare(_ configuration: WKWebViewConfiguration) {
        guard owns(configuration.websiteDataStore) else { return }
        if #available(macOS 15.4, *) { configuration.webExtensionController = nil }
        if let rules, !controllers.contains(configuration.userContentController) {
            configuration.userContentController.add(rules)
            controllers.add(configuration.userContentController)
        }
    }

    private func contentRules() async throws -> WKContentRuleList {
        if let rules { return rules }
        if let ruleTask { return try await ruleTask.value }
        let task = Task<WKContentRuleList, Error> {
            // Network exempts local IP literals from proxy routing. Block
            // them in WebKit before any request, including XHR and sockets.
            let authority = "^[a-z][a-z0-9+.-]*://([^/@]+@)?"
            let filters = [
                authority + "([0-9]+(x[0-9a-f]+)?\\.)*[0-9]+(x[0-9a-f]+)?\\.?[:/]",
                authority + "\\[",
                authority + "[^./:]+\\.?[:/]",
                authority + "([^/:]+\\.)?localhost\\.?[:/]",
                authority + "([^/:]+\\.)?local\\.?[:/]",
                authority + "([^/:]+\\.)?localdomain\\.?[:/]",
                authority + "([^/:]+\\.)?home\\.arpa\\.?[:/]"
            ]
            let json = try JSONSerialization.data(withJSONObject: filters.map { ["trigger": ["url-filter": $0, "url-filter-is-case-sensitive": false], "action": ["type": "block"]] })
            return try await withCheckedThrowingContinuation { done in
                WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "Search.Onion.LocalNetwork.1", encodedContentRuleList: String(decoding: json, as: UTF8.self)) { list, error in
                    if let list { done.resume(returning: list) }
                    else { done.resume(throwing: error ?? TorRuntime.Failure(message: "Tor's local-network protection could not be enabled")) }
                }
            }
        }
        ruleTask = task
        do { let list = try await task.value; rules = list; ruleTask = nil; return list }
        catch { ruleTask = nil; throw error }
    }
}
