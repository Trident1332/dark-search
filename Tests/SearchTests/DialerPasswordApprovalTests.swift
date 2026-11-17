import Foundation
import Security
import XCTest
@testable import Search

/// Synthetic queries exercise the actual read policy without Keychain items or UI.
final class DialerPasswordApprovalTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "dialer-password-approval-\(getpid())", 1)
        super.setUp()
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(Store.testing)
        DialerPassword.useKeychainForTesting(nil)
    }

    override func tearDown() {
        DialerPassword.useKeychainForTesting(nil)
        super.tearDown()
    }

    private func account() -> DialerSetup {
        DialerSetup(wss: "wss://dialer-approval.invalid", domain: "dialer-approval.invalid",
                    user: "synthetic-\(UUID().uuidString)")
    }

    private func until(_ condition: @escaping () -> Bool,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if !condition() {
            XCTFail("The synthetic password read did not finish", file: file, line: line)
            throw URLError(.timedOut)
        }
    }

    func testAutomaticReadsForbidUIAndCacheSuccess() {
        let fixture = DialerPasswordQueryFixture { _ in (errSecSuccess, Data("synthetic-password".utf8)) }
        DialerPassword.useKeychainForTesting(fixture.copy)
        let setup = account()
        for _ in 0..<20 { XCTAssertEqual(DialerPassword.read(setup), "synthetic-password") }
        XCTAssertEqual(DialerPassword.read(setup, allowCredentialPrompt: true), "synthetic-password")
        XCTAssertEqual(fixture.queries.count, 1)
        let query = fixture.queries[0]
        XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
    }

    func testQuietMissOrDenialDoesNotSuppressFirstExplicitRead() {
        for status in [errSecItemNotFound, errSecInteractionNotAllowed, errSecAuthFailed] {
            let fixture = DialerPasswordQueryFixture { query in
                DialerPasswordQueryFixture.interactive(query)
                    ? (errSecSuccess, Data("synthetic-approved".utf8)) : (status, nil)
            }
            DialerPassword.useKeychainForTesting(fixture.copy)
            let setup = account()
            for _ in 0..<20 { XCTAssertNil(DialerPassword.read(setup)) }
            XCTAssertEqual(fixture.queries.count, 1)
            XCTAssertEqual(DialerPassword.read(setup, allowCredentialPrompt: true), "synthetic-approved")
            XCTAssertEqual(DialerPassword.read(setup), "synthetic-approved")
            XCTAssertEqual(fixture.interactiveCount, 1)
            XCTAssertEqual(fixture.queries.count, 2)
        }
    }

    func testExplicitRefusalIsNotRetriedByEitherScope() {
        for status in [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed] {
            let fixture = DialerPasswordQueryFixture { _ in (status, nil) }
            DialerPassword.useKeychainForTesting(fixture.copy)
            let setup = account()
            for _ in 0..<20 {
                XCTAssertNil(DialerPassword.read(setup, allowCredentialPrompt: true))
                XCTAssertNil(DialerPassword.read(setup))
            }
            XCTAssertEqual(fixture.queries.count, 1)
            XCTAssertEqual(fixture.interactiveCount, 1)
        }
    }

    func testPresenceQueryForbidsUIAndNeverRequestsPasswordData() {
        let fixture = DialerPasswordQueryFixture { _ in (errSecSuccess, nil) }
        DialerPassword.useKeychainForTesting(fixture.copy)
        XCTAssertTrue(DialerPassword.kept(account()))
        XCTAssertEqual(fixture.queries.count, 1)
        XCTAssertNil(fixture.queries[0][kSecReturnData as String])
        XCTAssertEqual(fixture.queries[0][kSecUseAuthenticationUI as String] as? String,
                       kSecUseAuthenticationUIFail as String)
    }

    func testPendingApprovalDoesNotBlockOrDuplicateMainThreadReads() async throws {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let fixture = DialerPasswordQueryFixture { _ in
            _ = release.wait(timeout: .now() + 4)
            return (errSecSuccess, Data("synthetic-approved".utf8))
        }
        DialerPassword.useKeychainForTesting(fixture.copy)
        let setup = account()
        let pending = Task.detached { DialerPassword.read(setup, allowCredentialPrompt: true) }
        try await until { fixture.interactiveCount == 1 }
        await MainActor.run {
            let start = Date()
            for _ in 0..<20 {
                XCTAssertNil(DialerPassword.read(setup))
                XCTAssertNil(DialerPassword.read(setup, allowCredentialPrompt: true))
                XCTAssertFalse(DialerPassword.kept(setup))
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        }
        XCTAssertEqual(fixture.queries.count, 1)
        release.signal()
        let approved = await pending.value
        XCTAssertEqual(approved, "synthetic-approved")
        XCTAssertEqual(DialerPassword.read(setup), "synthetic-approved")
    }

    func testLateApprovalCannotResurrectForgottenPassword() async throws {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let fixture = DialerPasswordQueryFixture { _ in
            _ = release.wait(timeout: .now() + 4)
            return (errSecSuccess, Data("synthetic-old-password".utf8))
        }
        DialerPassword.useKeychainForTesting(fixture.copy)
        let setup = account()
        let pending = Task.detached { DialerPassword.read(setup, allowCredentialPrompt: true) }
        try await until { fixture.interactiveCount == 1 }
        XCTAssertTrue(DialerPassword.forget(setup))
        release.signal()
        let old = await pending.value
        XCTAssertNil(old)
        XCTAssertNil(DialerPassword.read(setup))
        XCTAssertNil(DialerPassword.read(setup, allowCredentialPrompt: true))
        XCTAssertFalse(DialerPassword.kept(setup))
        XCTAssertEqual(fixture.queries.count, 1)
    }

    func testSaveInvalidatesLateRead() async throws {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let fixture = DialerPasswordQueryFixture { _ in
            _ = release.wait(timeout: .now() + 4)
            return (errSecSuccess, Data("synthetic-old-password".utf8))
        }
        DialerPassword.useKeychainForTesting(fixture.copy)
        let setup = account()
        let pending = Task.detached { DialerPassword.read(setup, allowCredentialPrompt: true) }
        try await until { fixture.interactiveCount == 1 }
        XCTAssertTrue(DialerPassword.save("synthetic-new-password", for: setup))
        release.signal()
        let old = await pending.value
        XCTAssertNil(old)
        XCTAssertEqual(DialerPassword.read(setup), "synthetic-new-password")
        XCTAssertEqual(DialerPassword.read(setup, allowCredentialPrompt: true), "synthetic-new-password")
        XCTAssertEqual(fixture.queries.count, 1)
        XCTAssertTrue(DialerPassword.forget(setup))
    }

    func testSaveReplacesCachedRefusalWithoutAnotherQuery() {
        let fixture = DialerPasswordQueryFixture { _ in (errSecUserCanceled, nil) }
        DialerPassword.useKeychainForTesting(fixture.copy)
        let setup = account()
        XCTAssertNil(DialerPassword.read(setup, allowCredentialPrompt: true))
        XCTAssertTrue(DialerPassword.save("synthetic-new-password", for: setup))
        XCTAssertEqual(DialerPassword.read(setup), "synthetic-new-password")
        XCTAssertEqual(DialerPassword.read(setup, allowCredentialPrompt: true), "synthetic-new-password")
        XCTAssertEqual(fixture.queries.count, 1)
        XCTAssertTrue(DialerPassword.forget(setup))
    }
}

private final class DialerPasswordQueryFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [[String: Any]] = []
    private let answer: ([String: Any]) -> (OSStatus, Data?)

    init(_ answer: @escaping ([String: Any]) -> (OSStatus, Data?)) { self.answer = answer }

    var queries: [[String: Any]] { lock.withLock { captured } }
    var interactiveCount: Int { queries.filter(Self.interactive).count }

    static func interactive(_ query: [String: Any]) -> Bool {
        query[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIAllow as String
    }

    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        lock.withLock { captured.append(query) }
        return answer(query)
    }
}
