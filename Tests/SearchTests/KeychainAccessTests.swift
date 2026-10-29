import Foundation
import Security
import XCTest
@testable import Search

/// The driver models a legacy Keychain that ignores modern query UI flags.
/// Every operation below stays in memory and never accesses a real item.
final class KeychainAccessTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "keychain-access-\(getpid())", 1)
        super.setUp()
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(Store.testing)
    }

    override func tearDown() {
        KeychainAccess.useBackendForTesting(nil)
        super.tearDown()
    }

    private var dataQuery: CFDictionary { [kSecReturnData as String: true] as CFDictionary }
    private var metadataQuery: CFDictionary { [kSecReturnAttributes as String: true] as CFDictionary }

    func testQuietQueriesDisableLegacyUIForTheActualReadAndRestoreIt() {
        let queries: [[String: Any]] = [
            [:],
            [kSecReturnAttributes as String: true, kSecUseAuthenticationUI as String: kSecUseAuthenticationUIAllow],
            [kSecReturnData as String: false],
            [kSecReturnData as String: true, kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail],
            [kSecReturnData as String: true, kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip],
            [kSecReturnData as String: true, kSecUseNoAuthenticationUI as String: true]
        ]
        for query in queries {
            let fixture = KeychainDriver()
            KeychainAccess.useBackendForTesting(fixture.backend)
            XCTAssertEqual(KeychainAccess.copyMatching(query as CFDictionary, nil), errSecSuccess)
            XCTAssertEqual(fixture.observations, ["copy:false"])
            XCTAssertEqual(fixture.changes, [false, true])
            XCTAssertTrue(fixture.allowed)
        }
    }

    func testExplicitDataReadsAndMutationsPreserveInteractiveBehavior() {
        let fixture = KeychainDriver()
        KeychainAccess.useBackendForTesting(fixture.backend)
        var result: CFTypeRef?
        XCTAssertEqual(KeychainAccess.copyMatching(dataQuery, &result), errSecSuccess)
        XCTAssertNotNil(result)
        XCTAssertEqual(KeychainAccess.add([:] as CFDictionary, nil), errSecSuccess)
        XCTAssertEqual(KeychainAccess.update([:] as CFDictionary, [:] as CFDictionary), errSecSuccess)
        XCTAssertEqual(KeychainAccess.delete([:] as CFDictionary), errSecSuccess)
        XCTAssertEqual(fixture.observations, ["copy:true", "add:true", "update:true", "delete:true"])
        XCTAssertTrue(fixture.changes.isEmpty, "An explicit operation must not change global interaction policy")
    }

    func testAnAlreadyDisabledPolicyIsNeverEnabledByAnyOperation() {
        let fixture = KeychainDriver(allowed: false)
        KeychainAccess.useBackendForTesting(fixture.backend)
        XCTAssertEqual(KeychainAccess.copyMatching(metadataQuery, nil), errSecSuccess)
        XCTAssertEqual(KeychainAccess.copyMatching(dataQuery, nil), errSecSuccess)
        XCTAssertEqual(KeychainAccess.add([:] as CFDictionary, nil), errSecSuccess)
        XCTAssertEqual(KeychainAccess.update([:] as CFDictionary, [:] as CFDictionary), errSecSuccess)
        XCTAssertEqual(KeychainAccess.delete([:] as CFDictionary), errSecSuccess)
        XCTAssertEqual(fixture.observations, ["copy:false", "copy:false", "add:false", "update:false", "delete:false"])
        XCTAssertTrue(fixture.changes.isEmpty)
        XCTAssertFalse(fixture.allowed)
    }

    func testQuietOperationRestoresPolicyForEverySecurityResultAndClearsFailedOutput() {
        for status in [errSecSuccess, errSecItemNotFound, errSecAuthFailed, errSecUserCanceled] {
            let fixture = KeychainDriver()
            fixture.operationStatus = status
            KeychainAccess.useBackendForTesting(fixture.backend)
            var result: CFTypeRef? = "stale" as CFString
            XCTAssertEqual(KeychainAccess.copyMatching(metadataQuery, &result), status)
            XCTAssertEqual(fixture.changes, [false, true])
            XCTAssertTrue(fixture.allowed)
            if status != errSecSuccess { XCTAssertNil(result) }
        }
    }

    func testUnreadableInteractionPolicyPreventsQuietRead() {
        let fixture = KeychainDriver()
        fixture.getStatus = errSecNotAvailable
        KeychainAccess.useBackendForTesting(fixture.backend)
        var result: CFTypeRef? = "stale" as CFString
        XCTAssertEqual(KeychainAccess.copyMatching(metadataQuery, &result), errSecNotAvailable)
        XCTAssertNil(result)
        XCTAssertTrue(fixture.observations.isEmpty)
        XCTAssertTrue(fixture.changes.isEmpty)
    }

    func testFailedUISuppressionNeverReadsAndStillRestoresPreviousPolicy() {
        let fixture = KeychainDriver()
        fixture.disableStatus = errSecAuthFailed
        KeychainAccess.useBackendForTesting(fixture.backend)
        var result: CFTypeRef? = "stale" as CFString
        XCTAssertEqual(KeychainAccess.copyMatching(metadataQuery, &result), errSecAuthFailed)
        XCTAssertNil(result)
        XCTAssertTrue(fixture.observations.isEmpty)
        XCTAssertEqual(fixture.changes, [false, true])
        XCTAssertTrue(fixture.allowed)
    }

    func testRestorationFailureIsReportedAndCannotReturnCredentialData() {
        let fixture = KeychainDriver()
        fixture.restoreStatus = errSecNotAvailable
        KeychainAccess.useBackendForTesting(fixture.backend)
        var result: CFTypeRef?
        XCTAssertEqual(KeychainAccess.copyMatching(metadataQuery, &result), errSecNotAvailable)
        XCTAssertNil(result)
        XCTAssertEqual(fixture.changes, [false, true])
        XCTAssertEqual(fixture.observations, ["copy:false"])
        // The operation lock is released even when restoring the OS flag fails.
        XCTAssertEqual(KeychainAccess.delete([:] as CFDictionary), errSecSuccess)
    }

    func testQuietReadDoesNotWaitBehindAnInteractiveApproval() {
        let fixture = KeychainDriver()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        fixture.during = { operation in
            guard operation == "copy" else { return }
            entered.signal()
            _ = release.wait(timeout: .now() + 3)
        }
        KeychainAccess.useBackendForTesting(fixture.backend)
        let query = dataQuery
        DispatchQueue.global().async {
            _ = KeychainAccess.copyMatching(query, nil)
            finished.signal()
        }
        defer { release.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        var result: CFTypeRef? = "stale" as CFString
        let start = Date()
        XCTAssertEqual(KeychainAccess.copyMatching(metadataQuery, &result), errSecInteractionNotAllowed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertNil(result)
        XCTAssertEqual(fixture.observations, ["copy:true"])
        XCTAssertTrue(fixture.changes.isEmpty)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
    }

    func testInteractiveOperationsFromDifferentCallersAreSerialized() {
        let fixture = KeychainDriver()
        let firstEntered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let firstFinished = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        fixture.during = { operation in
            if operation == "copy" { firstEntered.signal(); _ = release.wait(timeout: .now() + 3) }
            if operation == "add" { secondEntered.signal() }
        }
        KeychainAccess.useBackendForTesting(fixture.backend)
        let query = dataQuery
        DispatchQueue.global().async { _ = KeychainAccess.copyMatching(query, nil); firstFinished.signal() }
        defer { release.signal() }
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            secondStarted.signal()
            _ = KeychainAccess.add([:] as CFDictionary, nil)
            secondFinished.signal()
        }
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 0.05), .timedOut)
        release.signal()
        XCTAssertEqual(firstFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(fixture.observations, ["copy:true", "add:true"])
        XCTAssertTrue(fixture.changes.isEmpty)
    }

    func testSameThreadReentryFailsClosedWithoutDeadlockOrPolicyChange() {
        let fixture = KeychainDriver()
        var nestedRead: OSStatus?
        var nestedMutation: OSStatus?
        fixture.during = { _ in
            nestedRead = KeychainAccess.copyMatching([kSecReturnData as String: true] as CFDictionary, nil)
            nestedMutation = KeychainAccess.delete([:] as CFDictionary)
        }
        KeychainAccess.useBackendForTesting(fixture.backend)
        XCTAssertEqual(KeychainAccess.copyMatching(metadataQuery, nil), errSecSuccess)
        XCTAssertEqual(nestedRead, errSecInteractionNotAllowed)
        XCTAssertEqual(nestedMutation, errSecInteractionNotAllowed)
        XCTAssertEqual(fixture.observations, ["copy:false"])
        XCTAssertEqual(fixture.changes, [false, true])
        XCTAssertTrue(fixture.allowed)
    }
}

private final class KeychainDriver: @unchecked Sendable {
    private let lock = NSLock()
    private var interaction: Bool
    private var recordedChanges: [Bool] = []
    private var recordedObservations: [String] = []
    var getStatus: OSStatus = errSecSuccess
    var disableStatus: OSStatus = errSecSuccess
    var restoreStatus: OSStatus = errSecSuccess
    var operationStatus: OSStatus = errSecSuccess
    var during: ((String) -> Void)?

    init(allowed: Bool = true) { interaction = allowed }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var allowed: Bool { locked { interaction } }
    var changes: [Bool] { locked { recordedChanges } }
    var observations: [String] { locked { recordedObservations } }

    var backend: KeychainAccess.Backend {
        KeychainAccess.Backend(
            getInteraction: { self.locked { (self.getStatus, self.interaction) } },
            setInteraction: { allowed in
                self.locked {
                    self.recordedChanges.append(allowed)
                    // A failed disable can have changed state; the coordinator
                    // must still attempt to restore it before returning.
                    let status = allowed ? self.restoreStatus : self.disableStatus
                    if !allowed || status == errSecSuccess { self.interaction = allowed }
                    return status
                }
            },
            copyMatching: { _, out in self.perform("copy", out) },
            add: { _, out in self.perform("add", out) },
            update: { _, _ in self.perform("update", nil) },
            delete: { _ in self.perform("delete", nil) }
        )
    }

    private func perform(_ name: String, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        let (status, callback): (OSStatus, ((String) -> Void)?) = locked {
            recordedObservations.append("\(name):\(interaction)")
            return (operationStatus, during)
        }
        callback?(name)
        result?.pointee = Data("synthetic-driver-value".utf8) as CFData
        return status
    }
}
