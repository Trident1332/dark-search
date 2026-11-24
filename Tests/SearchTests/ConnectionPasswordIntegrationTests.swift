import AppKit
import Foundation
import Security
import XCTest
@testable import Search

/// Both backends are synthetic. A network protocol trap also protects the
/// missing-password Poke test from creating any real connection.
@MainActor
final class ConnectionPasswordIntegrationTests: XCTestCase {
    private var vault: IntegrationVaultStore!
    private var legacy: IntegrationLegacyStore!

    override class func setUp() {
        setenv("SEARCH_PROBE", "connection-password-integration-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(Store.testing)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        vault = IntegrationVaultStore(); legacy = IntegrationLegacyStore()
        relaunch()
        _ = Shared.prefs
        Proxy.shared.automaticTarget = nil
        Proxy.shared.take(ProxySetup())
        try await until { !Proxy.shared.changingContent }
        IntegrationNetworkTrap.reset()
    }

    override func tearDown() async throws {
        Proxy.shared.automaticTarget = nil
        Proxy.shared.take(ProxySetup())
        try await until { !Proxy.shared.changingContent }
        ProxyPassword.useKeychainForTesting(nil)
        ConnectionPasswords.useBackendForTesting(nil, enabled: false)
        vault = nil; legacy = nil
        try await super.tearDown()
    }

    private func relaunch() {
        ConnectionPasswords.useBackendForTesting(vault.backend, enabled: true)
        ProxyPassword.useKeychainForTesting(legacy.copy)
    }

    private func proxy(_ kind: ProxyKind = .http) -> ProxySetup {
        ProxySetup(kind: kind, host: "integration-proxy.invalid", port: 8080, signsIn: true, user: "synthetic-user")
    }
    private func until(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if !condition() { XCTFail("Isolated proxy transition did not complete"); throw URLError(.timedOut) }
    }

    func testProxyReadsPresenceSaveForgetAndRelaunchNeverConsultLegacy() {
        let setup = proxy()
        for _ in 0..<10 {
            XCTAssertNil(ProxyPassword.read(setup))
            XCTAssertNil(ProxyPassword.read(setup, allowCredentialPrompt: true))
            XCTAssertFalse(ProxyPassword.kept(setup))
        }
        XCTAssertTrue(ProxyPassword.save("synthetic-vault-proxy", for: setup))
        XCTAssertEqual(ProxyPassword.read(setup), "synthetic-vault-proxy")
        XCTAssertTrue(ProxyPassword.kept(setup))
        relaunch()
        XCTAssertEqual(ProxyPassword.read(setup, allowCredentialPrompt: true), "synthetic-vault-proxy")
        XCTAssertTrue(ProxyPassword.forget(setup))
        relaunch()
        XCTAssertNil(ProxyPassword.read(setup))
        XCTAssertFalse(ProxyPassword.kept(setup))
        XCTAssertEqual(legacy.queryCount, 0)
    }

    func testVaultMissingPokeNeverAsksLegacyOrStartsNetwork() async throws {
        var setup = proxy()
        setup.on = true; setup.matchesTimeZone = false
        Proxy.shared.take(setup)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IntegrationNetworkTrap.self]
        let target = URL(string: "https://integration-poke.invalid/never-requested")!
        for _ in 0..<10 { Proxy.shared.test(configuration: configuration, target: target, allowCredentialPrompt: true) }
        try await until { Proxy.shared.check != .testing }
        XCTAssertNotEqual(Proxy.shared.check, .testing)
        XCTAssertTrue(Proxy.shared.waiting)
        XCTAssertNotNil(Proxy.shared.credentialIssue)
        XCTAssertEqual(IntegrationNetworkTrap.count, 0)
        XCTAssertEqual(legacy.queryCount, 0)
    }

    func testManualVaultPokeRefreshesAnInitiallyMissingCredentialSnapshot() async throws {
        var setup = proxy()
        setup.on = true; setup.matchesTimeZone = false
        Proxy.shared.take(setup)
        let originalRevision = Proxy.shared.revision
        let oldSession = Proxy.makeSession(configuration: .ephemeral, reportsAuthenticationFailures: false)
        defer { oldSession.invalidateAndCancel() }
        let space = URLProtectionSpace(proxyHost: setup.trimmedHost, port: Int(setup.portOrUsual),
            type: NSURLProtectionSpaceHTTPProxy, realm: "Synthetic vault refresh", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: IntegrationChallengeSender())
        XCTAssertTrue(Proxy.authenticate(challenge, in: oldSession) { disposition, credential in
            XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
            XCTAssertNil(credential, "Initial route intentionally has no credential snapshot")
        })

        // Simulate another writer or an unlocked vault. Deliberately bypass
        // ProxyPassword.save/passwordChanged so Poke must refresh the snapshot.
        try vault.backend.save("synthetic-newly-available", ProxyPassword.vaultIdentity(setup))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IntegrationNetworkTrap.self]
        Proxy.shared.test(configuration: configuration,
            target: URL(string: "https://integration-poke.invalid/fake-response")!, allowCredentialPrompt: true)
        try await until { Proxy.shared.revision > originalRevision }
        let refreshed = Proxy.makeSession(configuration: .ephemeral, reportsAuthenticationFailures: false)
        defer { refreshed.invalidateAndCancel() }
        XCTAssertTrue(Proxy.authenticate(challenge, in: refreshed) { disposition, credential in
            XCTAssertEqual(disposition, .useCredential)
            XCTAssertEqual(credential?.user, setup.user)
            XCTAssertEqual(credential?.password, "synthetic-newly-available")
        })
        XCTAssertTrue(Proxy.authenticate(challenge, in: oldSession) { disposition, credential in
            XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
            XCTAssertNil(credential, "The old session must retain its retired credential snapshot")
        })
        XCTAssertEqual(legacy.queryCount, 0)
    }

    func testHTTPAndHTTPSUseTheirOwnValuesBeforeConsideringAnAlternate() {
        let http = proxy(), https = proxy(.https)
        XCTAssertNotEqual(ProxyPassword.vaultIdentity(http), ProxyPassword.vaultIdentity(https))
        XCTAssertTrue(ProxyPassword.save("synthetic-http", for: http))
        XCTAssertTrue(ProxyPassword.save("synthetic-https", for: https))
        relaunch()
        XCTAssertEqual(ProxyPassword.read(http), "synthetic-http")
        XCTAssertEqual(ProxyPassword.read(https), "synthetic-https")
        XCTAssertEqual(legacy.queryCount, 0)
    }

    func testMissingHTTPMayUseAnExistingHTTPSVaultValueWithoutLegacy() {
        XCTAssertTrue(ProxyPassword.save("synthetic-alternate", for: proxy(.https)))
        relaunch()
        XCTAssertEqual(ProxyPassword.read(proxy()), "synthetic-alternate")
        XCTAssertTrue(ProxyPassword.kept(proxy()))
        XCTAssertEqual(legacy.queryCount, 0)
    }

    func testHTTPForgetTombstonesBothTransportsAndCannotImportOldCopies() {
        let http = proxy(), https = proxy(.https)
        XCTAssertTrue(ProxyPassword.save("synthetic-http", for: http))
        XCTAssertTrue(ProxyPassword.save("synthetic-https", for: https))
        XCTAssertTrue(ProxyPassword.forget(http))
        relaunch()
        for setup in [http, https] {
            XCTAssertEqual(vault.entry(ProxyPassword.vaultIdentity(setup)), .deleted)
            XCTAssertNil(ProxyPassword.read(setup, allowCredentialPrompt: true))
            XCTAssertFalse(ProxyPassword.legacyImportAvailable(setup))
            XCTAssertFalse(ProxyPassword.importLegacy(setup))
        }
        XCTAssertEqual(legacy.queryCount, 0, "Even an available old password cannot bypass durable forget")
    }

    func testFailedHTTPForgetStillCancelsPendingHTTPSImportAndPersistsItsTombstone() {
        let http = proxy(), httpsKey = ProxyPassword.vaultIdentity(proxy(.https))
        vault.failForgets(for: ProxyPassword.vaultIdentity(http))
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0), result = IntegrationBooleanAnswer()
        defer { release.signal() }
        DispatchQueue.global().async {
            result.set(ConnectionPasswords.importLegacy(httpsKey) {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
                return "synthetic-stale-https-approval"
            })
            completed.signal()
        }
        guard entered.wait(timeout: .now() + 2) == .success else {
            release.signal(); XCTFail("Synthetic HTTPS approval did not start"); return
        }
        XCTAssertFalse(ProxyPassword.forget(http), "The primary write failure must remain visible")
        release.signal()
        XCTAssertEqual(completed.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(result.get(), false, "A failed primary forget cannot leave the alternate approval live")
        XCTAssertEqual(vault.entry(httpsKey), .deleted)
        relaunch()
        XCTAssertEqual(vault.entry(httpsKey), .deleted)
        XCTAssertFalse(ConnectionPasswords.importLegacy(httpsKey) { XCTFail("The old HTTPS copy was forgotten"); return "synthetic-old" })
        XCTAssertEqual(legacy.queryCount, 0)
    }

    func testSOCKSForgetDoesNotChangeHTTPOrHTTPS() {
        let socks = proxy(.socks5), http = proxy(), https = proxy(.https)
        XCTAssertTrue(ProxyPassword.save("synthetic-socks", for: socks))
        XCTAssertTrue(ProxyPassword.save("synthetic-http", for: http))
        XCTAssertTrue(ProxyPassword.save("synthetic-https", for: https))
        XCTAssertTrue(ProxyPassword.forget(socks))
        relaunch()
        XCTAssertNil(ProxyPassword.read(socks))
        XCTAssertFalse(ProxyPassword.importLegacy(socks))
        XCTAssertEqual(ProxyPassword.read(http), "synthetic-http")
        XCTAssertEqual(ProxyPassword.read(https), "synthetic-https")
        XCTAssertEqual(legacy.queryCount, 0)
    }

    func testPrimaryVaultErrorCannotFallThroughToAlternateOrLegacy() {
        let http = proxy(), https = proxy(.https)
        XCTAssertTrue(ProxyPassword.save("synthetic-alternate", for: https))
        vault.failReads(for: ProxyPassword.vaultIdentity(http))
        vault.clearReads()
        XCTAssertNil(ProxyPassword.read(http))
        XCTAssertNil(ProxyPassword.read(http, allowCredentialPrompt: true))
        XCTAssertFalse(ProxyPassword.kept(http))
        XCTAssertFalse(vault.readKeys.contains(ProxyPassword.vaultIdentity(https)))
        XCTAssertEqual(legacy.queryCount, 0)
    }

    func testCanonicalIdentityRetainsExactAccountAndConnectionNamespace() {
        var p = proxy(), sameProxy = p
        sameProxy.host = "  INTEGRATION-PROXY.INVALID  "
        XCTAssertEqual(ProxyPassword.vaultIdentity(p), ProxyPassword.vaultIdentity(sameProxy))
        p.user = "SYNTHETIC-USER"
        XCTAssertNotEqual(ProxyPassword.vaultIdentity(p), ProxyPassword.vaultIdentity(sameProxy))
    }

    func testVaultOnlyProxySaveCannotPopulateLegacyModeCache() {
        let setup = proxy()
        XCTAssertTrue(ProxyPassword.save("synthetic-vault-only", for: setup))
        XCTAssertEqual(legacy.queryCount, 0)
        ConnectionPasswords.setUsesVault(false)
        XCTAssertEqual(ProxyPassword.read(setup), IntegrationLegacyStore.password)
        XCTAssertEqual(legacy.queryCount, 1, "Changing storage homes must consult that home's own credential")
    }
}

private final class IntegrationVaultStore: @unchecked Sendable {
    enum Failure: Error { case unavailable }
    private let lock = NSLock()
    private var values: [String: ConnectionVault.Entry] = [:]
    private var failedReads: Set<String> = []
    private var failedForgets: Set<String> = []
    private var capturedReads: [String] = []
    var backend: ConnectionPasswords.Backend {
        .init(read: { key in
            self.lock.lock(); defer { self.lock.unlock() }
            self.capturedReads.append(key)
            if self.failedReads.contains(key) { throw Failure.unavailable }
            return self.values[key] ?? .missing
        }, save: { value, key in
            self.lock.lock(); defer { self.lock.unlock() }; self.values[key] = .value(value)
        }, forget: { key in
            self.lock.lock(); defer { self.lock.unlock() }
            if self.failedForgets.contains(key) { throw Failure.unavailable }
            self.values[key] = .deleted
        })
    }
    var readKeys: [String] { lock.lock(); defer { lock.unlock() }; return capturedReads }
    func clearReads() { lock.lock(); capturedReads.removeAll(); lock.unlock() }
    func failReads(for key: String) { lock.lock(); failedReads.insert(key); lock.unlock() }
    func failForgets(for key: String) { lock.lock(); failedForgets.insert(key); lock.unlock() }
    func entry(_ key: String) -> ConnectionVault.Entry { lock.lock(); defer { lock.unlock() }; return values[key] ?? .missing }
}

private final class IntegrationBooleanAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    func set(_ answer: Bool) { lock.lock(); value = answer; lock.unlock() }
    func get() -> Bool? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class IntegrationLegacyStore: @unchecked Sendable {
    static let password = "synthetic-legacy-copy"
    private let lock = NSLock()
    private var queries = 0
    var queryCount: Int { lock.lock(); defer { lock.unlock() }; return queries }
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        lock.lock(); queries += 1; lock.unlock()
        return (errSecSuccess, query[kSecReturnData as String] as? Bool == true ? Data(Self.password.utf8) : nil)
    }
}

private final class IntegrationNetworkTrap: URLProtocol {
    private static let lock = NSLock()
    private static var requests = 0
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    static func reset() { lock.lock(); requests = 0; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests += 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
    override func stopLoading() {}
}

private final class IntegrationChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
