import Foundation
import XCTest
@testable import Search

/// Entirely synthetic persistent storage and legacy readers. No credential,
/// Security query, approval, Secure Enclave operation, or production file.
final class ConnectionPasswordMigrationTests: XCTestCase {
    private var fixture: MigrationStore!
    private var key: String { ConnectionPasswords.identity(kind: "proxy", components: ["migration.invalid", "8080", "synthetic-user"]) }

    override class func setUp() {
        setenv("SEARCH_PROBE", "connection-migration-\(getpid())", 1)
        super.setUp()
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(Store.testing)
        fixture = MigrationStore()
        ConnectionPasswords.useBackendForTesting(fixture.backend, enabled: true)
    }

    override func tearDown() {
        ConnectionPasswords.useBackendForTesting(nil, enabled: false)
        fixture = nil
        super.tearDown()
    }

    private func relaunch() {
        // Reconstruct the adapter against the same durable fixture, with no
        // per-launch cache, pending-ticket, or in-memory tombstone available.
        ConnectionPasswords.useBackendForTesting(fixture.backend, enabled: true)
    }

    func testIdentitySeparatesKindAndComponentsWithoutDelimiterCollisions() {
        let a = ConnectionPasswords.identity(kind: "proxy", components: ["a@b", "c"])
        XCTAssertEqual(a, ConnectionPasswords.identity(kind: "proxy", components: ["a@b", "c"]))
        XCTAssertNotEqual(a, ConnectionPasswords.identity(kind: "proxy", components: ["a", "b@c"]))
        XCTAssertNotEqual(a, ConnectionPasswords.identity(kind: "dialer", components: ["a@b", "c"]))
        XCTAssertEqual(a.count, 64)
    }

    func testMissingVaultReadDoesNotImportOrCreateARecord() throws {
        XCTAssertEqual(try ConnectionPasswords.read(key), .missing)
        XCTAssertEqual(fixture.saveCount, 0)
        XCTAssertEqual(fixture.forgetCount, 0)
    }

    func testDisabledModeCannotInvokeLegacyReaderOrTouchVault() {
        ConnectionPasswords.setUsesVault(false)
        XCTAssertThrowsError(try ConnectionPasswords.read(key))
        XCTAssertFalse(ConnectionPasswords.save("synthetic", for: key))
        XCTAssertFalse(ConnectionPasswords.forget(key))
        XCTAssertFalse(ConnectionPasswords.importLegacy(key) { XCTFail("Disabled vault may not request legacy approval"); return "synthetic" })
        XCTAssertEqual(fixture.saveCount, 0)
        XCTAssertEqual(fixture.forgetCount, 0)
    }

    func testExplicitImportPersistsVerifiedValueAcrossRelaunch() throws {
        var legacy = "synthetic-legacy"
        var reads = 0
        XCTAssertTrue(ConnectionPasswords.importLegacy(key) { reads += 1; return legacy })
        XCTAssertEqual(try ConnectionPasswords.read(key), .value(legacy))
        relaunch()
        XCTAssertEqual(try ConnectionPasswords.read(key), .value(legacy))
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(legacy, "synthetic-legacy", "Migration must leave its legacy source intact")
        legacy = "synthetic-changed-elsewhere"
        XCTAssertEqual(try ConnectionPasswords.read(key), .value("synthetic-legacy"))
    }

    func testExistingVaultValueSkipsLegacyApproval() throws {
        XCTAssertTrue(ConnectionPasswords.save("synthetic-current", for: key))
        XCTAssertTrue(ConnectionPasswords.importLegacy(key) { XCTFail("Existing vault value must not ask the legacy reader"); return "synthetic-old" })
        XCTAssertEqual(try ConnectionPasswords.read(key), .value("synthetic-current"))
    }

    func testSuccessfulImportIsNotReportedAgainAfterItsStoredRecordDisappears() throws {
        var approvals = 0
        XCTAssertTrue(ConnectionPasswords.importLegacy(key) { approvals += 1; return "synthetic-old" })
        fixture.remove(key)
        XCTAssertFalse(ConnectionPasswords.importLegacy(key) { approvals += 1; return "synthetic-old" })
        XCTAssertEqual(approvals, 1, "An earlier result cannot justify re-prompting or claim a missing record exists")
        XCTAssertEqual(try ConnectionPasswords.read(key), .missing)
    }

    func testForgottenMissingIdentitySurvivesRelaunchAndBlocksOldCredential() throws {
        XCTAssertTrue(ConnectionPasswords.forget(key))
        relaunch()
        XCTAssertEqual(try ConnectionPasswords.read(key), .deleted)
        XCTAssertFalse(ConnectionPasswords.importLegacy(key) { XCTFail("A durable forget must not resurrect legacy credentials"); return "synthetic-old" })
        XCTAssertTrue(ConnectionPasswords.save("synthetic-reentered", for: key))
        XCTAssertEqual(try ConnectionPasswords.read(key), .value("synthetic-reentered"))
    }

    func testForgetIsScopedToOneConnectionIdentityAcrossRelaunch() throws {
        let other = ConnectionPasswords.identity(kind: "dialer", components: ["migration.invalid", "synthetic-user"])
        XCTAssertTrue(ConnectionPasswords.save("synthetic-proxy", for: key))
        XCTAssertTrue(ConnectionPasswords.save("synthetic-dialer", for: other))
        XCTAssertTrue(ConnectionPasswords.forget(key))
        relaunch()
        XCTAssertEqual(try ConnectionPasswords.read(key), .deleted)
        XCTAssertEqual(try ConnectionPasswords.read(other), .value("synthetic-dialer"))
    }

    func testRefusedLegacyReadDoesNotWriteOrDeleteAnything() throws {
        XCTAssertFalse(ConnectionPasswords.importLegacy(key) { nil })
        XCTAssertEqual(try ConnectionPasswords.read(key), .missing)
        XCTAssertEqual(fixture.saveCount, 0)
        XCTAssertEqual(fixture.forgetCount, 0)
    }

    func testWriteFailureLeavesLegacyAvailableAndReportsNoMigration() throws {
        fixture.configure(failSave: true)
        let legacy = "synthetic-legacy"
        XCTAssertFalse(ConnectionPasswords.importLegacy(key) { legacy })
        XCTAssertEqual(fixture.entry(key), .missing)
        XCTAssertEqual(legacy, "synthetic-legacy")
        XCTAssertEqual(fixture.forgetCount, 0)
    }

    func testFailedReadbackCannotReportSuccessfulMigrationOrForgetLegacy() {
        fixture.configure(wrongReadback: true)
        let legacy = "synthetic-legacy"
        XCTAssertFalse(ConnectionPasswords.importLegacy(key) { legacy })
        XCTAssertEqual(legacy, "synthetic-legacy")
        XCTAssertEqual(fixture.forgetCount, 0)
    }

    func testUnreadableVaultFailsClosedBeforeAnyLegacyApproval() {
        fixture.configure(failRead: true)
        XCTAssertThrowsError(try ConnectionPasswords.read(key))
        XCTAssertFalse(ConnectionPasswords.importLegacy(key) { XCTFail("Unreadable is not permission to import into a replacement vault"); return "synthetic-old" })
        XCTAssertEqual(fixture.saveCount, 0)
    }

    func testLateApprovalCannotUndoForgetAcrossRelaunch() throws {
        interruptedImport { XCTAssertTrue(ConnectionPasswords.forget(self.key)) }
        relaunch()
        XCTAssertEqual(try ConnectionPasswords.read(key), .deleted)
        XCTAssertFalse(ConnectionPasswords.importLegacy(key) { XCTFail("Old approval must not survive a forget"); return "synthetic-old" })
    }

    func testLateApprovalCannotOverwriteNewManualPasswordAcrossRelaunch() throws {
        interruptedImport { XCTAssertTrue(ConnectionPasswords.save("synthetic-new", for: self.key)) }
        relaunch()
        XCTAssertEqual(try ConnectionPasswords.read(key), .value("synthetic-new"))
    }

    func testStorageModeOffThenOnStillInvalidatesEarlierApproval() throws {
        interruptedImport {
            ConnectionPasswords.setUsesVault(false)
            ConnectionPasswords.setUsesVault(true)
        }
        XCTAssertEqual(try ConnectionPasswords.read(key), .missing)
        XCTAssertEqual(fixture.saveCount, 0)
    }

    func testBackendReplacementInvalidatesEarlierApproval() throws {
        interruptedImport { self.relaunch() }
        XCTAssertEqual(try ConnectionPasswords.read(key), .missing)
        XCTAssertEqual(fixture.saveCount, 0)
    }

    func testFailedForgetStillCancelsAnAlreadyPendingApproval() {
        fixture.configure(failForget: true)
        interruptedImport { XCTAssertFalse(ConnectionPasswords.forget(self.key)) }
        XCTAssertEqual(fixture.entry(key), .missing)
        XCTAssertEqual(fixture.saveCount, 0)
    }

    func testFailedManualSaveStillCancelsAnAlreadyPendingApproval() {
        fixture.configure(failSave: true)
        interruptedImport { XCTAssertFalse(ConnectionPasswords.save("synthetic-new", for: self.key)) }
        XCTAssertEqual(fixture.entry(key), .missing)
        XCTAssertEqual(fixture.saveCount, 1, "Only the explicit manual attempt is permitted")
    }

    func testConcurrentImportsForSameIdentityCannotAskTwiceOrWaitForApproval() throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let firstDone = DispatchSemaphore(value: 0), secondDone = DispatchSemaphore(value: 0)
        let first = MigrationAnswer(), second = MigrationAnswer(), identity = key
        DispatchQueue.global().async {
            first.set(ConnectionPasswords.importLegacy(identity) {
                entered.signal(); _ = release.wait(timeout: .now() + 5)
                return "synthetic-approved"
            })
            firstDone.signal()
        }
        guard entered.wait(timeout: .now() + 2) == .success else {
            release.signal(); XCTFail("Synthetic reader did not start"); return
        }
        DispatchQueue.global().async {
            second.set(ConnectionPasswords.importLegacy(identity) { XCTFail("Duplicate approval was requested"); return "synthetic-duplicate" })
            secondDone.signal()
        }
        let coalesced = secondDone.wait(timeout: .now() + 2)
        release.signal()
        XCTAssertEqual(coalesced, .success, "Duplicate import must return while the original approval is pending")
        XCTAssertEqual(firstDone.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(first.get(), true)
        XCTAssertEqual(second.get(), false)
        XCTAssertEqual(try ConnectionPasswords.read(key), .value("synthetic-approved"))
        XCTAssertEqual(fixture.saveCount, 1)
    }

    /// A stalled approval may not hold the commit gate against forget/save.
    /// Every wait is bounded and the blocked reader is always released.
    private func interruptedImport(_ interrupt: @escaping () -> Void,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0), mutationDone = DispatchSemaphore(value: 0)
        let answer = MigrationAnswer()
        let identity = key
        DispatchQueue.global().async {
            answer.set(ConnectionPasswords.importLegacy(identity) {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
                return "synthetic-stale-approved"
            })
            completed.signal()
        }
        guard entered.wait(timeout: .now() + 2) == .success else {
            release.signal(); XCTFail("Synthetic legacy reader did not start", file: file, line: line); return
        }
        DispatchQueue.global().async { interrupt(); mutationDone.signal() }
        let mutated = mutationDone.wait(timeout: .now() + 2)
        release.signal()
        XCTAssertEqual(mutated, .success, "Pending approval must not block a new save/forget", file: file, line: line)
        XCTAssertEqual(completed.wait(timeout: .now() + 3), .success, file: file, line: line)
        if mutated != .success { _ = mutationDone.wait(timeout: .now() + 3) }
        XCTAssertEqual(answer.get(), false, "A stale approval cannot commit", file: file, line: line)
    }
}

private final class MigrationAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    func set(_ answer: Bool) { lock.lock(); value = answer; lock.unlock() }
    func get() -> Bool? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class MigrationStore: @unchecked Sendable {
    enum Failure: Error { case unavailable }
    private let lock = NSLock()
    private var records: [String: ConnectionVault.Entry] = [:]
    private var saveFailure = false, forgetFailure = false, readFailure = false, badReadback = false
    private var saves = 0, forgets = 0

    var backend: ConnectionPasswords.Backend {
        .init(read: { try self.read($0) }, save: { try self.save($0, for: $1) }, forget: { try self.forget($0) })
    }
    var saveCount: Int { lock.lock(); defer { lock.unlock() }; return saves }
    var forgetCount: Int { lock.lock(); defer { lock.unlock() }; return forgets }
    func entry(_ key: String) -> ConnectionVault.Entry { lock.lock(); defer { lock.unlock() }; return records[key] ?? .missing }
    func remove(_ key: String) { lock.lock(); records.removeValue(forKey: key); lock.unlock() }
    func configure(failSave: Bool = false, failForget: Bool = false, failRead: Bool = false, wrongReadback: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        saveFailure = failSave; forgetFailure = failForget; readFailure = failRead; badReadback = wrongReadback
    }
    private func read(_ key: String) throws -> ConnectionVault.Entry {
        lock.lock(); defer { lock.unlock() }
        if readFailure { throw Failure.unavailable }
        if badReadback, saves > 0 { return .value("synthetic-unexpected-readback") }
        return records[key] ?? .missing
    }
    private func save(_ value: String, for key: String) throws {
        lock.lock(); defer { lock.unlock() }; saves += 1
        if saveFailure { throw Failure.unavailable }
        records[key] = .value(value)
    }
    private func forget(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }; forgets += 1
        if forgetFailure { throw Failure.unavailable }
        records[key] = .deleted
    }
}
