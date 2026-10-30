import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import Search

/// Facade policy uses an in-memory store, synthetic approval and a spy for
/// the legacy Keychain. No real biometric, credential, or file is accessed.
@MainActor
final class WebsitePasswordFacadeTests: XCTestCase {
    private var store: PasswordMemoryStore!
    private var legacy: PasswordLegacySpy!
    private var approvals = 0
    private var reasons: [String] = []
    private var previousAsk: Bool?
    private let kept = Kept(host: "login.website-fixture.invalid", user: "fixture-user")
    private let secret = Secret(password: "synthetic-secret", notes: "synthetic-note")

    override class func setUp() {
        setenv("SEARCH_PROBE", "website-password-facade-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        try await super.setUp()
        previousAsk = Ask.testing
        Ask.testing = nil
        store = PasswordMemoryStore()
        legacy = PasswordLegacySpy(kept: kept, secret: secret)
        Vault.useBackendForTesting(store.backend)
        KeychainAccess.useBackendForTesting(legacy.backend)
        approve(true)
    }

    override func tearDown() async throws {
        Vault.revokeAccess()
        Vault.useBackendForTesting(nil)
        WebsitePasswordAuthentication.useForTesting(nil)
        KeychainAccess.useBackendForTesting(nil)
        Ask.testing = previousAsk
        store = nil
        legacy = nil
        try await super.tearDown()
    }

    private func approve(_ answer: Bool) {
        WebsitePasswordAuthentication.useForTesting { [weak self] _, reason in
            self?.approvals += 1
            self?.reasons.append(reason)
            return answer
        }
    }

    func testBiometricAvailabilityMessagesDistinguishLockoutEnrollmentAndHardware() {
        func reason(_ code: LAError.Code) -> String {
            WebsitePasswordAuthentication.explanation(for: NSError(domain: LAErrorDomain, code: code.rawValue)).lowercased()
        }
        let locked = reason(.biometryLockout)
        XCTAssertTrue(locked.contains("temporarily locked"))
        XCTAssertTrue(locked.contains("unlock your mac"))
        XCTAssertFalse(locked.contains("set up"), "An enrolled but locked sensor does not need enrolling again")
        XCTAssertTrue(reason(.biometryNotEnrolled).contains("set up touch id"))
        XCTAssertTrue(reason(.biometryNotAvailable).contains("not available"))
        XCTAssertFalse(locked.contains("use password"), "There is no in-app Mac-password fallback")
    }

    func testMetadataAndWritesNeverReadSecretsOrLegacyKeychain() throws {
        XCTAssertTrue(Vault.save(host: kept.host, user: kept.user, password: secret.password, notes: secret.notes))
        XCTAssertEqual(Vault.all().count, 1)
        XCTAssertEqual(Vault.kept(for: kept.host).count, 1)
        XCTAssertEqual(Vault.kept(matching: kept.host).count, 1)
        Vault.touch(kept)
        XCTAssertTrue(Vault.save(host: kept.host, user: kept.user, password: "replacement", notes: nil))
        XCTAssertEqual(store.secret(for: kept)?.notes, secret.notes, "Password updates preserve notes without decrypting them")
        XCTAssertEqual(store.reads, 0)
        XCTAssertEqual(approvals, 0)
        XCTAssertEqual(legacy.queries, 0)
        XCTAssertTrue(Vault.forget(host: kept.host, user: kept.user))
        XCTAssertTrue(Vault.all().isEmpty)
        XCTAssertEqual(store.reads, 0)
        XCTAssertEqual(legacy.queries, 0)
    }

    func testEveryWebsiteInsertionRequiresFreshBiometricApproval() async throws {
        store.seed(kept, secret)
        let first = await Vault.loginForFill(kept)
        let second = await Vault.loginForFill(kept)
        XCTAssertEqual(first?.password, secret.password)
        XCTAssertEqual(second?.password, secret.password)
        XCTAssertEqual(approvals, 2)
        XCTAssertEqual(store.reads, 2)
        XCTAssertEqual(store.contexts.count, 2)
        XCTAssertFalse(store.contexts[0] === store.contexts[1], "No unlock or approval is reused for another insertion")
        XCTAssertTrue(reasons.allSatisfy { $0.contains(kept.host) })
        XCTAssertEqual(legacy.queries, 0)
    }

    func testRefusedBiometricsDoNotDecryptOrTryLegacyFallback() async {
        store.seed(kept, secret)
        approve(false)
        let result = await Vault.loginForFill(kept)
        XCTAssertNil(result)
        XCTAssertEqual(approvals, 1)
        XCTAssertEqual(store.reads, 0)
        XCTAssertEqual(legacy.queries, 0)
        XCTAssertNotNil(Vault.lastFailure)
    }

    func testCancelledPendingProofCannotReadOrRetryAfterLateApproval() async throws {
        store.seed(kept, secret)
        var reply: CheckedContinuation<Bool, Never>?
        WebsitePasswordAuthentication.useForTesting { [weak self] _, _ in
            self?.approvals += 1
            return await withCheckedContinuation { reply = $0 }
        }
        let insertion = Task { await Vault.loginForFill(kept) }
        try await until { reply != nil }
        insertion.cancel()
        let pending = try XCTUnwrap(reply)
        reply = nil
        pending.resume(returning: true)
        let result = await insertion.value
        XCTAssertNil(result)
        XCTAssertEqual(approvals, 1)
        XCTAssertEqual(store.reads, 0)
        XCTAssertEqual(legacy.queries, 0)
    }

    func testMissingOrUnreadableOwnAccountNeverReadsOldKeychain() async {
        let missing = await Vault.loginForFill(kept)
        XCTAssertNil(missing)
        XCTAssertEqual(approvals, 0, "A deleted account does not prompt unnecessarily")
        store.seed(kept, secret)
        store.refuseRead = true
        let unreadable = await Vault.loginForFill(kept)
        XCTAssertNil(unreadable)
        XCTAssertEqual(approvals, 1)
        XCTAssertEqual(store.reads, 1)
        XCTAssertEqual(legacy.queries, 0)
    }

    func testChangedCleartextEligibilityIsRejectedBeforeApprovalOrRead() async {
        var selectedOnHTTP = kept
        selectedOnHTTP.clear = true
        store.seed(kept, secret) // The current record is now HTTPS-only.
        let result = await Vault.loginForFill(selectedOnHTTP)
        XCTAssertNil(result)
        XCTAssertEqual(approvals, 0)
        XCTAssertEqual(store.reads, 0)
        XCTAssertEqual(legacy.queries, 0)
        XCTAssertNotNil(Vault.lastFailure)
    }

    func testManagerUnlockAndLockControlSynchronousSecretsButNotFillApproval() async {
        store.seed(kept, secret)
        XCTAssertNil(Vault.details(of: kept))
        XCTAssertEqual(store.reads, 0)
        let unlocked = await withCheckedContinuation { completion in
            Vault.prove("open your passwords") { completion.resume(returning: $0) }
        }
        XCTAssertTrue(unlocked)
        XCTAssertEqual(Vault.details(of: kept), secret)
        XCTAssertEqual(store.reads, 1)
        let fill = await Vault.loginForFill(kept)
        XCTAssertNotNil(fill)
        XCTAssertEqual(approvals, 2, "An open manager does not exempt website insertion from Touch ID")
        Vault.revokeAccess()
        XCTAssertNil(Vault.secret(of: kept))
        XCTAssertEqual(store.reads, 2)
    }

    func testExpiredManagerProofCannotBeRevivedByExtendingItsClock() async {
        store.seed(kept, secret)
        let unlocked = await withCheckedContinuation { completion in
            Vault.prove("open your passwords") { completion.resume(returning: $0) }
        }
        XCTAssertTrue(unlocked)
        Vault.extendAccess(until: Date().addingTimeInterval(-1))
        Vault.extendAccess(until: Date().addingTimeInterval(300))
        XCTAssertNil(Vault.details(of: kept))
        XCTAssertEqual(store.reads, 0)
    }

    func testRevokingAccessDuringPendingProofRejectsItsLateApproval() async throws {
        store.seed(kept, secret)
        var reply: CheckedContinuation<Bool, Never>?
        var completed: [Bool] = []
        WebsitePasswordAuthentication.useForTesting { _, _ in
            await withCheckedContinuation { reply = $0 }
        }
        let proof = Vault.prove("open your passwords") { completed.append($0) }
        try await until { reply != nil }
        Vault.revokeAccess()
        let pending = try XCTUnwrap(reply)
        reply = nil
        pending.resume(returning: true)
        await proof.value
        XCTAssertEqual(completed, [false])
        XCTAssertNil(Vault.details(of: kept))
        XCTAssertEqual(store.reads, 0)
    }

    func testLegacyCountIsMetadataOnlyAndExplicitImportVerifiesWithoutDeletingOriginal() async {
        XCTAssertEqual(Vault.legacyCount, 1)
        XCTAssertEqual(legacy.secretReads, 0)
        XCTAssertEqual(approvals, 0)
        let imported = await Vault.importLegacyLogins()
        XCTAssertEqual(imported.kept, 1)
        XCTAssertEqual(imported.skipped, 0)
        XCTAssertEqual(legacy.secretReads, 1)
        XCTAssertEqual(legacy.deletes, 0)
        XCTAssertEqual(approvals, 1)
        XCTAssertEqual(store.reads, 1, "The new encrypted copy is read back under the approved context")
        XCTAssertEqual(store.secret(for: kept), secret)
        XCTAssertEqual(Vault.legacyCount, 0)
        let repeated = await Vault.importLegacyLogins()
        XCTAssertEqual(repeated.kept, 0)
        XCTAssertEqual(repeated.skipped, 0)
        XCTAssertEqual(legacy.secretReads, 1)
        XCTAssertEqual(legacy.deletes, 0)
        XCTAssertEqual(approvals, 1)
    }

    func testExistingOwnLoginIsNeverOverwrittenOrReadFromLegacy() async {
        let newer = Secret(password: "newer-own-password", notes: "keep-own-notes")
        store.seed(kept, newer)
        legacy = PasswordLegacySpy(kept: Kept(host: kept.host.uppercased(), user: kept.user), secret: secret)
        KeychainAccess.useBackendForTesting(legacy.backend)
        XCTAssertEqual(Vault.legacyCount, 0)
        let result = await Vault.importLegacyLogins()
        XCTAssertEqual(result.kept, 0)
        XCTAssertEqual(legacy.secretReads, 0)
        XCTAssertEqual(approvals, 0)
        XCTAssertEqual(store.secret(for: kept), newer)
        XCTAssertEqual(legacy.deletes, 0)
    }

    func testRefusedImportDoesNotReadOldSecretOrWriteOwnCopy() async {
        approve(false)
        let result = await Vault.importLegacyLogins()
        XCTAssertEqual(result.kept, 0)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(legacy.secretReads, 0)
        XCTAssertEqual(legacy.deletes, 0)
        XCTAssertTrue(Vault.all().isEmpty)
    }

    func testFailedImportVerificationPreservesOriginalAndReportsFailure() async {
        store.refuseRead = true
        let result = await Vault.importLegacyLogins()
        XCTAssertEqual(result.kept, 0)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(legacy.deletes, 0)
        XCTAssertNil(store.secret(for: kept), "The unverified newly inserted copy must be rolled back")
        XCTAssertEqual(Vault.legacyCount, 1, "The preserved legacy item remains available for another explicit import")
        XCTAssertNotNil(Vault.lastFailure)
    }

    func testFailedImportVerificationNeverRollsBackAConcurrentNewerPassword() async {
        let newer = Secret(password: "concurrently-updated-password", notes: "newer-note")
        store.beforeRead = { [store, kept] _ in store?.seed(kept, newer) }
        let result = await Vault.importLegacyLogins()
        XCTAssertEqual(result.kept, 0)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(store.secret(for: kept), newer, "Rollback belongs only to the import's exact ciphertext generation")
        XCTAssertEqual(legacy.deletes, 0)
        XCTAssertEqual(Vault.legacyCount, 0, "A newer own-vault login still owns the identity")
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard condition() else { XCTFail("Synthetic authentication did not begin"); throw URLError(.timedOut) }
    }
}

private final class PasswordMemoryStore {
    private var values: [String: (Kept, Secret)] = [:]
    private var versions: [String: UUID] = [:]
    private(set) var reads = 0
    private(set) var contexts: [LAContext] = []
    var refuseRead = false
    var beforeRead: ((Kept) -> Void)?

    func seed(_ kept: Kept, _ secret: Secret) { values[kept.id] = (kept, secret); versions[kept.id] = UUID() }
    func secret(for kept: Kept) -> Secret? { values[kept.id]?.1 }

    var backend: Vault.Backend {
        .init(entries: { [self] in values.values.map(\.0) }, read: { [self] kept, context in
            reads += 1
            beforeRead?(kept)
            guard !refuseRead, let context, let entry = values[kept.id] else { throw URLError(.userAuthenticationRequired) }
            contexts.append(context)
            return entry.1
        }, save: { [self] host, user, password, used, clear, notes in
            let kept = Kept(host: host, user: user, used: used, clear: clear, since: Date())
            let note = notes ?? values[kept.id]?.1.notes ?? ""
            seed(kept, Secret(password: password, notes: note))
        }, touch: { [self] kept, date in
            if var entry = values[kept.id] { entry.0.used = date; seed(entry.0, entry.1) }
        }, forget: { [self] kept in values.removeValue(forKey: kept.id); versions.removeValue(forKey: kept.id) },
              importNew: { [self] kept, secret in
                  guard values[kept.id] == nil else { return nil }
                  seed(kept, secret)
                  let version = versions[kept.id]
                  return { [self] in
                      guard versions[kept.id] == version else { return }
                      values.removeValue(forKey: kept.id)
                      versions.removeValue(forKey: kept.id)
                  }
              })
    }
}

private final class PasswordLegacySpy: @unchecked Sendable {
    private let lock = NSLock()
    private let kept: Kept
    private let secret: Secret
    private var copies = 0, secrets = 0, removed = 0
    var queries: Int { lock.withLock { copies } }
    var secretReads: Int { lock.withLock { secrets } }
    var deletes: Int { lock.withLock { removed } }

    init(kept: Kept, secret: Secret) { self.kept = kept; self.secret = secret }

    var backend: KeychainAccess.Backend {
        .init(getInteraction: { (errSecSuccess, true) }, setInteraction: { _ in errSecSuccess },
              copyMatching: { [self] query, result in
                  lock.withLock { copies += 1 }
                  let query = query as NSDictionary
                  if query[kSecReturnData as String] as? Bool == true {
                      lock.withLock { secrets += 1 }
                      if let data = secret.packed { result?.pointee = data as NSData }
                  } else {
                      result?.pointee = [[kSecAttrServer as String: kept.host, kSecAttrAccount as String: kept.user,
                                          kSecAttrProtocol as String: kSecAttrProtocolHTTPS as String]] as NSArray
                  }
                  return errSecSuccess
              }, add: { _, _ in errSecSuccess }, update: { _, _ in errSecSuccess },
              delete: { [self] _ in lock.withLock { removed += 1 }; return errSecSuccess })
    }
}
