import AppKit
import Security
import XCTest
@testable import Search

/// Synthetic Security responses exercise approval and cache behavior without
/// reading, changing, printing, or approving any real Keychain item.
@MainActor
final class ProxyPasswordApprovalTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "proxy-password-approval-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(Store.testing)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        _ = Shared.prefs
        Proxy.shared.automaticTarget = nil
        Proxy.shared.take(ProxySetup())
        ProxyPassword.useKeychainForTesting(nil)
        try await until { !Proxy.shared.changingContent }
    }

    override func tearDown() async throws {
        Proxy.shared.automaticTarget = nil
        Proxy.shared.take(ProxySetup())
        try await until { !Proxy.shared.changingContent }
        ProxyPassword.useKeychainForTesting(nil)
        try await super.tearDown()
    }

    private func account() -> ProxySetup {
        ProxySetup(kind: .http, host: "proxy-approval.invalid", port: 8080, signsIn: true,
                   user: "synthetic-\(UUID().uuidString)")
    }

    private func until(_ condition: @escaping @MainActor () -> Bool,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = Date().addingTimeInterval(5)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        if !condition() { XCTFail("The isolated Keychain operation did not finish", file: file, line: line); throw URLError(.timedOut) }
    }

    func testPresenceChecksCannotPromptOrReadPasswordData() {
        let fixture = PasswordQueryFixture { _ in (errSecSuccess, nil) }
        ProxyPassword.useKeychainForTesting(fixture.copy)
        let setup = account()
        for _ in 0..<20 { XCTAssertTrue(ProxyPassword.kept(setup)) }
        XCTAssertEqual(fixture.queries.count, 1)
        let query = fixture.queries[0]
        XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
        XCTAssertEqual(query[kSecReturnAttributes as String] as? Bool, true)
        XCTAssertNil(query[kSecReturnData as String])
    }

    func testBackgroundSuccessAndFailureAreCachedWithoutPermissionUI() {
        let results: [(OSStatus, Data?)] = [(errSecSuccess, Data("synthetic-password".utf8)), (errSecInteractionNotAllowed, nil)]
        for result in results {
            let fixture = PasswordQueryFixture { _ in result }
            ProxyPassword.useKeychainForTesting(fixture.copy)
            let setup = account()
            for _ in 0..<20 { _ = ProxyPassword.read(setup) }
            XCTAssertEqual(fixture.queries.count, 1)
            XCTAssertEqual(fixture.interactiveCount, 0)
            XCTAssertEqual(fixture.queries[0][kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
        }
    }

    func testRefusalIsCachedAndNeverFallsThroughToAnotherTransport() {
        for status in [errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed] {
            let fixture = PasswordQueryFixture { _ in (status, nil) }
            ProxyPassword.useKeychainForTesting(fixture.copy)
            let setup = account()
            for _ in 0..<20 { XCTAssertNil(ProxyPassword.read(setup, allowCredentialPrompt: true)) }
            XCTAssertEqual(fixture.interactiveCount, 1)
            XCTAssertEqual(fixture.queries.count, 1)
            XCTAssertEqual(fixture.queries[0][kSecAttrProtocol as String] as? String, kSecAttrProtocolHTTPProxy as String)
        }
    }

    func testOnlyMissingItemsMayUseTheAlternateTransport() {
        let fixture = PasswordQueryFixture { query in
            if query[kSecAttrProtocol as String] as? String == kSecAttrProtocolHTTPProxy as String { return (errSecItemNotFound, nil) }
            return (errSecSuccess, Data("synthetic-alternate".utf8))
        }
        ProxyPassword.useKeychainForTesting(fixture.copy)
        let setup = account()
        XCTAssertEqual(ProxyPassword.read(setup), "synthetic-alternate")
        XCTAssertEqual(ProxyPassword.read(setup), "synthetic-alternate")
        var https = setup
        https.kind = .https
        XCTAssertEqual(ProxyPassword.read(https), "synthetic-alternate")
        XCTAssertEqual(fixture.queries.count, 2)
    }

    func testExplicitRefusalSupersedesStaleBackgroundMissingResult() {
        let fixture = PasswordQueryFixture { query in
            if query[kSecAttrProtocol as String] as? String != kSecAttrProtocolHTTPProxy as String { return (errSecSuccess, Data("synthetic-alternate".utf8)) }
            return PasswordQueryFixture.interactive(query) ? (errSecUserCanceled, nil) : (errSecItemNotFound, nil)
        }
        ProxyPassword.useKeychainForTesting(fixture.copy)
        let setup = account()
        XCTAssertEqual(ProxyPassword.read(setup), "synthetic-alternate")
        XCTAssertNil(ProxyPassword.read(setup, allowCredentialPrompt: true))
        XCTAssertNil(ProxyPassword.read(setup), "An old missing result cannot bypass a later explicit refusal")
        XCTAssertEqual(fixture.interactiveCount, 1)
    }

    func testCacheUsesStructuredNormalizedIdentityAndExactUsername() {
        let fixture = PasswordQueryFixture { query in
            (errSecSuccess, Data(("synthetic-" + (query[kSecAttrAccount as String] as? String ?? "")).utf8))
        }
        ProxyPassword.useKeychainForTesting(fixture.copy)
        var first = account()
        first.host = "  Proxy-Approval.Invalid\n"
        first.port = nil
        XCTAssertNotNil(ProxyPassword.read(first))
        var same = first
        same.host = "proxy-approval.invalid"
        same.port = 8080
        XCTAssertNotNil(ProxyPassword.read(same))
        XCTAssertEqual(fixture.queries.count, 1)
        same.user = same.user.uppercased()
        XCTAssertNotNil(ProxyPassword.read(same))
        XCTAssertEqual(fixture.queries.count, 2)
        let a = ProxySetup(kind: .http, host: "c", port: 1, user: "a@b")
        let b = ProxySetup(kind: .http, host: "b@c", port: 1, user: "a")
        XCTAssertNotEqual(ProxyPassword.read(a), ProxyPassword.read(b), "User/host separators cannot collide in a cache key")
    }

    func testSaveAndForgetReplaceCachedRefusalWithoutReadingAgain() {
        let fixture = PasswordQueryFixture { _ in (errSecUserCanceled, nil) }
        ProxyPassword.useKeychainForTesting(fixture.copy)
        let setup = account()
        XCTAssertNil(ProxyPassword.read(setup, allowCredentialPrompt: true))
        XCTAssertTrue(ProxyPassword.save("synthetic-new-password", for: setup))
        XCTAssertEqual(ProxyPassword.read(setup), "synthetic-new-password")
        XCTAssertTrue(ProxyPassword.forget(setup))
        XCTAssertNil(ProxyPassword.read(setup, allowCredentialPrompt: true))
        XCTAssertFalse(ProxyPassword.kept(setup))
        XCTAssertEqual(fixture.queries.count, 1)
    }

    func testPendingApprovalDoesNotBlockPresenceAndCannotResurrectForgottenPassword() async throws {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let fixture = PasswordQueryFixture { _ in
            _ = release.wait(timeout: .now() + 4)
            return (errSecSuccess, Data("synthetic-old-password".utf8))
        }
        ProxyPassword.useKeychainForTesting(fixture.copy)
        let setup = account()
        let pending = Task.detached { ProxyPassword.read(setup, allowCredentialPrompt: true) }
        try await until { fixture.interactiveCount == 1 }
        let started = Date()
        XCTAssertFalse(ProxyPassword.kept(setup))
        XCTAssertNil(ProxyPassword.read(setup))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertEqual(fixture.queries.count, 1)
        XCTAssertTrue(ProxyPassword.forget(setup))
        release.signal()
        let old = await pending.value
        XCTAssertNil(old)
        XCTAssertNil(ProxyPassword.read(setup))
    }

    func testConcurrentSaveAndForgetKeepCacheConsistentWithStoredValue() async {
        let setup = account()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    if index.isMultiple(of: 2) { _ = ProxyPassword.save("synthetic-password", for: setup) }
                    else { _ = ProxyPassword.forget(setup) }
                }
            }
        }
        let cached = ProxyPassword.read(setup)
        ProxyPassword.useKeychainForTesting(nil)
        XCTAssertEqual(ProxyPassword.read(setup), cached)
        _ = ProxyPassword.forget(setup)
    }

    func testPokeCoalescesAndAutomaticChecksNeverCancelItsApprovalOrRetryRefusal() async throws {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let fixture = PasswordQueryFixture { query in
            guard PasswordQueryFixture.interactive(query) else { return (errSecInteractionNotAllowed, nil) }
            _ = release.wait(timeout: .now() + 4)
            return (errSecUserCanceled, nil)
        }
        ProxyPassword.useKeychainForTesting(fixture.copy)
        var setup = account()
        setup.on = true
        setup.matchesTimeZone = false
        Proxy.shared.take(setup)
        XCTAssertTrue(Proxy.shared.waiting)
        XCTAssertTrue(Proxy.shared.credentialIssue?.contains("Poke") == true)
        let target = URL(string: "http://127.0.0.1:9/never-requested")!
        Proxy.shared.test(target: target, allowCredentialPrompt: true)
        try await until { fixture.interactiveCount == 1 }
        Proxy.shared.test(target: target, allowCredentialPrompt: true)
        for _ in 0..<10 { Proxy.shared.test(target: target) }
        XCTAssertEqual(Proxy.shared.check, .testing)
        XCTAssertEqual(fixture.interactiveCount, 1)
        release.signal()
        try await until { Proxy.shared.check != .testing }
        XCTAssertTrue(Proxy.shared.waiting)
        XCTAssertFalse(Proxy.shared.refused, "A local Keychain refusal is not a rejected proxy login")
        XCTAssertTrue(Proxy.shared.credentialIssue?.contains("wasn't allowed") == true)
        Proxy.shared.test(target: target, allowCredentialPrompt: true)
        try await until { Proxy.shared.check != .testing }
        XCTAssertEqual(fixture.interactiveCount, 1)
    }

    func testLateApprovalCannotRerouteAnOffProxy() async throws {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let fixture = PasswordQueryFixture { query in
            guard PasswordQueryFixture.interactive(query) else { return (errSecInteractionNotAllowed, nil) }
            _ = release.wait(timeout: .now() + 4)
            return (errSecSuccess, Data("synthetic-password".utf8))
        }
        ProxyPassword.useKeychainForTesting(fixture.copy)
        var setup = account()
        setup.on = true
        Proxy.shared.take(setup)
        Proxy.shared.test(target: URL(string: "http://127.0.0.1:9/never-requested")!, allowCredentialPrompt: true)
        try await until { fixture.interactiveCount == 1 }
        Proxy.shared.take(ProxySetup())
        let offRevision = Proxy.shared.revision
        release.signal()
        try await until { fixture.running == 0 }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(Proxy.shared.setup.on)
        XCTAssertEqual(Proxy.shared.revision, offRevision)
    }
}

private final class PasswordQueryFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [[String: Any]] = []
    private var active = 0
    private let answer: ([String: Any]) -> (OSStatus, Data?)

    init(_ answer: @escaping ([String: Any]) -> (OSStatus, Data?)) { self.answer = answer }

    var queries: [[String: Any]] { lock.withLock { captured } }
    var running: Int { lock.withLock { active } }
    var interactiveCount: Int { queries.filter(Self.interactive).count }

    static func interactive(_ query: [String: Any]) -> Bool {
        query[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIAllow as String
    }

    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        lock.withLock { captured.append(query); active += 1 }
        defer { lock.withLock { active -= 1 } }
        return answer(query)
    }
}
