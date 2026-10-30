import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import XCTest
@testable import Search

/// Software-key injection exercises the real AEAD and private filesystem.
/// A separate hardware smoke uses only synthetic secrets and disables all
/// interaction; no test requests biometrics or touches a real account.
final class WebsitePasswordVaultTests: XCTestCase {
    private var base: URL!
    private var directory: URL { base.appendingPathComponent("Website Passwords", isDirectory: true) }
    private var file: URL { directory.appendingPathComponent("websites.vault") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        base = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent("website-password-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        if let base { try FileManager.default.removeItem(at: base) }
        try super.tearDownWithError()
    }

    private func vault(_ keys: WebsiteTestKeys = WebsiteTestKeys(), beforeCommit: (() throws -> Void)? = nil) -> WebsitePasswordVault {
        WebsitePasswordVault(directory: directory, keyProvider: keys.provider, beforeCommit: beforeCommit)
    }

    private func save(_ vault: WebsitePasswordVault, host: String = "website.invalid", user: String = "synthetic-user",
                      password: String = "SYNTHETIC-WEBSITE-PASSWORD-21F883", notes: String? = nil, clear: Bool = false) throws {
        try vault.save(host: host, user: user, password: password, clear: clear, notes: notes)
    }

    private func entry(_ vault: WebsitePasswordVault, host: String = "website.invalid") throws -> Kept {
        try XCTUnwrap(vault.entries().first { $0.host == host })
    }

    private func replaceFixture(_ bytes: Data) throws {
        try bytes.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func envelope() throws -> WebsiteEnvelopeFixture {
        try JSONDecoder().decode(WebsiteEnvelopeFixture.self, from: Data(contentsOf: file))
    }

    private func write(_ envelope: WebsiteEnvelopeFixture, recomputeChecksum: Bool = true) throws {
        var value = envelope
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if recomputeChecksum { value.checksum = Data(SHA256.hash(data: try encoder.encode(value.body))) }
        try replaceFixture(encoder.encode(value))
    }

    func testMissingListAndReadNeverCreateFilesOrKeys() throws {
        let keys = WebsiteTestKeys(), manager = vault(keys)
        XCTAssertTrue(try manager.entries().isEmpty)
        XCTAssertThrowsError(try manager.read(Kept(host: "website.invalid", user: "synthetic-user"))) {
            XCTAssertEqual($0 as? WebsitePasswordVault.Failure, .missing)
        }
        XCTAssertEqual(keys.created, 0)
        XCTAssertEqual(keys.agreements, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testEncryptedSecretsPersistAcrossInstancesWithPrivatePermissions() throws {
        let manager = vault()
        let password = "SYNTHETIC-WEBSITE-PASSWORD-21F883"
        let notes = "SYNTHETIC-PRIVATE-NOTE-295B7B"
        try save(manager, password: password, notes: notes)
        let relaunched = vault()
        let stored = try entry(relaunched)
        XCTAssertEqual(stored.user, "synthetic-user")
        XCTAssertNotNil(stored.since)
        XCTAssertEqual(try relaunched.read(stored, context: LAContext()), Secret(password: password, notes: notes))
        let bytes = try Data(contentsOf: file)
        for secret in [password, notes] { XCTAssertNil(bytes.range(of: Data(secret.utf8))) }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        for name in ["websites.vault", "websites.lock"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testDeniedOrMissingBiometryCannotDecryptButMetadataAndEncryptionStillWork() throws {
        let keys = WebsiteTestKeys(), manager = vault(keys)
        keys.allowAgreement = false
        try save(manager, notes: "private synthetic note")
        var stored = try entry(manager)
        XCTAssertEqual(keys.agreements, 0, "Save and list must never use the protected private key")
        XCTAssertThrowsError(try manager.read(stored, context: LAContext()))
        keys.allowAgreement = true
        XCTAssertThrowsError(try manager.read(stored)) {
            XCTAssertEqual($0 as? WebsitePasswordVault.Failure, .authenticationRequired)
        }
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        try manager.touch(stored, at: instant)
        stored = try entry(manager)
        XCTAssertEqual(stored.used, instant)
        XCTAssertEqual(try manager.read(stored, context: LAContext()).notes, "private synthetic note")
    }

    func testPasswordUpdatePreservesSealedNotesWithoutDecryptingAndExplicitEmptyClearsThem() throws {
        let keys = WebsiteTestKeys(), manager = vault(keys)
        try save(manager, notes: "private note that must survive")
        let before = try envelope()
        keys.allowAgreement = false
        try save(manager, password: "replacement synthetic password", notes: nil)
        let after = try envelope()
        XCTAssertEqual(keys.agreements, 0)
        XCTAssertEqual(before.body.records.values.first?.notes, after.body.records.values.first?.notes)
        XCTAssertNotEqual(before.body.records.values.first?.password, after.body.records.values.first?.password)
        keys.allowAgreement = true
        XCTAssertEqual(try manager.read(entry(manager), context: LAContext()),
                       Secret(password: "replacement synthetic password", notes: "private note that must survive"))
        keys.allowAgreement = false
        try save(manager, notes: "")
        XCTAssertNil(try envelope().body.records.values.first?.notes)
    }

    func testMetadataTouchDoesNotAlterCiphertextOrRequestBiometry() throws {
        let keys = WebsiteTestKeys(), manager = vault(keys)
        try save(manager, notes: "synthetic note")
        let before = try envelope(), stored = try entry(manager)
        keys.allowAgreement = false
        try manager.touch(stored, at: Date(timeIntervalSince1970: 1234))
        let after = try envelope()
        XCTAssertEqual(keys.agreements, 0)
        XCTAssertEqual(before.body.records.values.first?.password, after.body.records.values.first?.password)
        XCTAssertEqual(before.body.records.values.first?.notes, after.body.records.values.first?.notes)
        XCTAssertEqual(try entry(manager).used, Date(timeIntervalSince1970: 1234))
        try manager.forget(stored)
        XCTAssertTrue(try manager.entries().isEmpty)
        XCTAssertEqual(keys.agreements, 0)
    }

    func testNewInstancesSerializeIndependentUpdatesAndForgetPersists() throws {
        let first = vault(), second = vault()
        try save(first)
        try save(second, host: "other.invalid", password: "second synthetic password")
        XCTAssertEqual(try vault().entries().count, 2)
        try first.forget(entry(first))
        XCTAssertEqual(try vault().entries().map(\.host), ["other.invalid"])
    }

    func testAtomicImportNeverReplacesAnExistingDestination() throws {
        let keys = WebsiteTestKeys(), manager = vault(keys)
        try save(manager, password: "newer own-vault password", notes: "newer own-vault note")
        let kept = try entry(manager), original = try Data(contentsOf: file)
        XCTAssertNil(try vault(keys).insertImported(kept, secret: Secret(password: "old imported password", notes: "old note")))
        XCTAssertEqual(try Data(contentsOf: file), original, "A skipped import must not rewrite or reseal the destination")
        XCTAssertEqual(keys.agreements, 0, "Checking for a duplicate must not unlock anything")
        XCTAssertEqual(try manager.read(kept, context: LAContext()),
                       Secret(password: "newer own-vault password", notes: "newer own-vault note"))
    }

    func testConcurrentImportHasOneWinnerWithoutOverwritingIt() throws {
        let keys = WebsiteTestKeys(), managers = [vault(keys), vault(keys)]
        let kept = Kept(host: "import.invalid", user: "synthetic-user", used: nil, clear: false, since: Date(timeIntervalSince1970: 1234))
        let outcomes = ImportOutcomes()
        DispatchQueue.concurrentPerform(iterations: managers.count) { index in
            do {
                let receipt = try managers[index].insertImported(kept, secret: Secret(password: "synthetic contender \(index)"))
                outcomes.finish(winner: receipt == nil ? nil : index, error: nil)
            } catch { outcomes.finish(winner: nil, error: error) }
        }
        XCTAssertTrue(outcomes.errors.isEmpty, "Concurrent import errors: \(outcomes.errors)")
        let winner = try XCTUnwrap(outcomes.winners.first)
        XCTAssertEqual(outcomes.winners.count, 1, "The absence check and insertion must share the file lock")
        XCTAssertEqual(try managers[0].entries().count, 1)
        XCTAssertEqual(try managers[0].read(kept, context: LAContext()).password, "synthetic contender \(winner)")
        XCTAssertEqual(keys.created, 1)
    }

    func testFailedImportRollbackRemovesOnlyItsExactInsertionAcrossInstances() throws {
        let keys = WebsiteTestKeys(), manager = vault(keys)
        try save(manager, host: "unrelated.invalid")
        let kept = Kept(host: "import.invalid", user: "synthetic-user", used: nil, clear: true,
                        since: Date(timeIntervalSince1970: 1234))
        let receipt = try XCTUnwrap(manager.insertImported(kept, secret: Secret(password: "imported password", notes: "imported note")))
        XCTAssertEqual(try manager.read(kept, context: LAContext()), Secret(password: "imported password", notes: "imported note"))
        let reopened = vault(keys)
        let reads = keys.agreements
        XCTAssertTrue(try reopened.discardImported(receipt))
        XCTAssertEqual(try reopened.entries().map(\.host), ["unrelated.invalid"])
        XCTAssertFalse(try reopened.discardImported(receipt), "Reusing a receipt must be a harmless no-op")
        XCTAssertEqual(keys.agreements, reads, "Rollback compares encrypted state without decrypting it")
    }

    func testImportRollbackPreservesConcurrentSecretEditWithIdenticalMetadata() throws {
        let keys = WebsiteTestKeys(), manager = vault(keys)
        let kept = Kept(host: "import.invalid", user: "synthetic-user", used: nil, clear: false,
                        since: Date(timeIntervalSince1970: 1234))
        let receipt = try XCTUnwrap(manager.insertImported(kept, secret: Secret(password: "imported password", notes: "imported note")))
        let before = try XCTUnwrap(manager.entries().first)
        try vault(keys).save(host: kept.host, user: kept.user, password: "concurrently edited password", notes: nil)
        XCTAssertEqual(try XCTUnwrap(manager.entries().first), before,
                       "This edit deliberately keeps every displayed metadata field identical")
        let original = try Data(contentsOf: file), reads = keys.agreements
        XCTAssertFalse(try manager.discardImported(receipt), "Metadata equality cannot authorize deleting changed ciphertext")
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(keys.agreements, reads)
        XCTAssertEqual(try manager.read(before, context: LAContext()),
                       Secret(password: "concurrently edited password", notes: "imported note"))
    }

    func testImportRollbackPreservesMetadataUpdatesAndRejectsAnotherVault() throws {
        let keys = WebsiteTestKeys(), manager = vault(keys)
        let kept = Kept(host: "import.invalid", user: "synthetic-user", used: nil, clear: false, since: nil)
        let receipt = try XCTUnwrap(manager.insertImported(kept, secret: Secret(password: "imported password")))
        let instant = Date(timeIntervalSince1970: 5000)
        try vault(keys).touch(kept, at: instant)
        XCTAssertFalse(try manager.discardImported(receipt))
        XCTAssertEqual(try manager.entries().first?.used, instant)
        let otherDirectory = base.appendingPathComponent("Other Vault", isDirectory: true)
        let other = WebsitePasswordVault(directory: otherDirectory, keyProvider: keys.provider)
        XCTAssertFalse(try other.discardImported(receipt))
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherDirectory.path), "A foreign receipt must not create or change storage")
    }

    func testProductionEnclaveCanSaveAndListWithoutApprovalButCannotRead() throws {
        guard SecureEnclave.isAvailable else { throw XCTSkip("Secure Enclave is not available on this Mac") }
        // Select production explicitly, even when the test process uses
        // Store.testing. Every production provider context forbids UI.
        let manager = WebsitePasswordVault(directory: directory, keyProvider: .secureEnclave)
        try save(manager, password: "synthetic hardware smoke password", notes: "synthetic hardware smoke note")
        let reopened = WebsitePasswordVault(directory: directory, keyProvider: .secureEnclave)
        let kept = try entry(reopened)
        let before = try Data(contentsOf: file)
        XCTAssertEqual(try reopened.entries().count, 1, "Public-key restoration and metadata listing require no approval")
        XCTAssertThrowsError(try reopened.read(kept)) {
            XCTAssertEqual($0 as? WebsitePasswordVault.Failure, .authenticationRequired)
        }
        let unauthenticated = LAContext()
        unauthenticated.interactionNotAllowed = true
        XCTAssertThrowsError(try reopened.read(kept, context: unauthenticated),
                             "A fresh, unapproved context must not use the protected private key")
        XCTAssertTrue(unauthenticated.interactionNotAllowed)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testChecksumDamageBlocksReadsAndMutationsWithoutReplacingExistingFile() throws {
        let manager = vault()
        try save(manager)
        let stored = try entry(manager)
        var damaged = try envelope()
        let id = try XCTUnwrap(damaged.body.records.keys.first)
        damaged.body.records[id]!.password.sealed[15] ^= 1
        try write(damaged, recomputeChecksum: false)
        let original = try Data(contentsOf: file)
        XCTAssertThrowsError(try manager.entries())
        XCTAssertThrowsError(try manager.read(stored, context: LAContext()))
        XCTAssertThrowsError(try save(manager, password: "replacement"))
        XCTAssertThrowsError(try manager.forget(stored))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testAEADRejectsCiphertextTamperingEvenWithRecomputedChecksum() throws {
        let manager = vault()
        try save(manager)
        let stored = try entry(manager)
        var damaged = try envelope()
        let id = try XCTUnwrap(damaged.body.records.keys.first)
        damaged.body.records[id]!.password.sealed[15] ^= 1
        try write(damaged)
        XCTAssertEqual(try manager.entries().count, 1, "The checksum is not the authentication boundary")
        XCTAssertThrowsError(try manager.read(stored, context: LAContext()))
    }

    func testAEADBindsPasswordsToHostUserTransportAndFieldPurpose() throws {
        let manager = vault()
        try save(manager, notes: "synthetic note")
        try save(manager, host: "other.invalid", password: "other synthetic password")
        let initial = try envelope()
        let firstID = try XCTUnwrap(initial.body.records.first { $0.value.host == "website.invalid" }?.key)
        let otherID = try XCTUnwrap(initial.body.records.first { $0.value.host == "other.invalid" }?.key)
        var swapHost = initial
        swapHost.body.records[otherID]!.password = initial.body.records[firstID]!.password
        try write(swapHost)
        XCTAssertThrowsError(try manager.read(entry(manager, host: "other.invalid"), context: LAContext()))
        var swapPurpose = initial
        swapPurpose.body.records[firstID]!.password = try XCTUnwrap(initial.body.records[firstID]!.notes)
        try write(swapPurpose)
        XCTAssertThrowsError(try manager.read(entry(manager), context: LAContext()))
        var swapTransport = initial
        swapTransport.body.records[firstID]!.clear = true
        try write(swapTransport)
        XCTAssertThrowsError(try manager.read(entry(manager), context: LAContext()))
        var swapUser = initial
        swapUser.body.records[firstID]!.user = "different-user"
        try write(swapUser)
        XCTAssertThrowsError(try manager.entries(), "Record dictionary identities must also match their metadata")
    }

    func testWrongHardwareHandleOrPublicKeyCannotOpenOrOverwriteExistingFile() throws {
        let keys = WebsiteTestKeys(), manager = vault(keys)
        try save(manager)
        let stored = try entry(manager)
        let bytes = try Data(contentsOf: file)
        keys.wrongPublicKey = true
        XCTAssertThrowsError(try manager.entries())
        XCTAssertThrowsError(try save(manager, password: "replacement"))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        keys.wrongPublicKey = false
        keys.wrongAgreement = true
        XCTAssertThrowsError(try manager.read(stored, context: LAContext()))
        keys.wrongAgreement = false
        XCTAssertEqual(try manager.read(stored, context: LAContext()).password, "SYNTHETIC-WEBSITE-PASSWORD-21F883")
    }

    func testUnknownVersionAndInvalidFileNeverGenerateReplacementKeys() throws {
        let keys = WebsiteTestKeys(), manager = vault(keys)
        try save(manager)
        var unknown = try envelope()
        unknown.body.version = 2
        try write(unknown)
        let bytes = try Data(contentsOf: file), count = keys.created
        XCTAssertThrowsError(try manager.entries())
        XCTAssertThrowsError(try save(manager))
        XCTAssertEqual(keys.created, count)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        try replaceFixture(Data("not a website vault".utf8))
        XCTAssertThrowsError(try save(manager))
        XCTAssertEqual(keys.created, count)
        XCTAssertEqual(try Data(contentsOf: file), Data("not a website vault".utf8))
    }

    func testFailedOrDamagedAtomicCommitPreservesPreviousFileAndCleansStage() throws {
        try save(vault())
        let original = try Data(contentsOf: file)
        let failing = vault(beforeCommit: { throw WebsitePasswordVault.Failure.busy })
        XCTAssertThrowsError(try save(failing, password: "replacement"))
        XCTAssertEqual(try Data(contentsOf: file), original)
        let damaged = vault(beforeCommit: {
            let stage = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasSuffix(".tmp") })
            try Data("damaged staged bytes".utf8).write(to: stage)
        })
        XCTAssertThrowsError(try save(damaged, password: "replacement"))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       Set(["websites.vault", "websites.lock"]))
    }

    func testSymlinkHardlinkAndPublicPermissionsAreRejected() throws {
        let manager = vault()
        try save(manager)
        let stored = try entry(manager)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try manager.entries())
        XCTAssertThrowsError(try save(manager))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let alias = base.appendingPathComponent("hardlink")
        XCTAssertEqual(link(file.path, alias.path), 0)
        XCTAssertThrowsError(try manager.read(stored, context: LAContext()))
        try FileManager.default.removeItem(at: alias)
        let original = try Data(contentsOf: file)
        let outside = base.appendingPathComponent("outside")
        try Data("untouched".utf8).write(to: outside)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        XCTAssertThrowsError(try manager.entries())
        XCTAssertThrowsError(try save(manager))
        XCTAssertEqual(try Data(contentsOf: outside), Data("untouched".utf8))
        try FileManager.default.removeItem(at: file)
        try replaceFixture(original)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try manager.entries())
        XCTAssertThrowsError(try manager.forget(stored))
    }

    func testSymlinkedParentsAndDirectorySwapCannotRedirectWrites() throws {
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let alias = base.appendingPathComponent("parent-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        let location = alias.appendingPathComponent("child", isDirectory: true)
        let redirected = WebsitePasswordVault(directory: location, keyProvider: WebsiteTestKeys().provider)
        XCTAssertThrowsError(try save(redirected))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        try save(vault())
        let moved = base.appendingPathComponent("moved", isDirectory: true)
        let failing = vault(beforeCommit: {
            try FileManager.default.moveItem(at: self.directory, to: moved)
            try FileManager.default.createSymbolicLink(at: self.directory, withDestinationURL: outside)
        })
        XCTAssertThrowsError(try save(failing, password: "replacement"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        let old = WebsitePasswordVault(directory: moved, keyProvider: WebsiteTestKeys().provider)
        XCTAssertEqual(try old.read(entry(old), context: LAContext()).password, "SYNTHETIC-WEBSITE-PASSWORD-21F883")
    }

    func testOversizedInputAndTransportChangePreserveExistingNotesAndFile() throws {
        let manager = vault()
        try save(manager, notes: "original note")
        let original = try Data(contentsOf: file)
        XCTAssertThrowsError(try save(manager, password: String(repeating: "x", count: 65_537)))
        XCTAssertThrowsError(try save(manager, notes: String(repeating: "x", count: 262_145)))
        XCTAssertThrowsError(try save(manager, user: String(repeating: "x", count: 4097)))
        XCTAssertThrowsError(try save(manager, notes: nil, clear: true))
        XCTAssertEqual(try Data(contentsOf: file), original)
        try save(manager, notes: "explicit replacement note", clear: true)
        XCTAssertTrue(try entry(manager).clear)
        XCTAssertEqual(try manager.read(entry(manager), context: LAContext()).notes, "explicit replacement note")
    }
}

private final class ImportOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var winningIndices: [Int] = []
    private var failures: [Error] = []
    var winners: [Int] { lock.withLock { winningIndices } }
    var errors: [Error] { lock.withLock { failures } }
    func finish(winner: Int?, error: Error?) {
        lock.withLock {
            if let winner { winningIndices.append(winner) }
            if let error { failures.append(error) }
        }
    }
}

private final class WebsiteTestKeys {
    var created = 0
    var agreements = 0
    var allowAgreement = true
    var wrongPublicKey = false
    var wrongAgreement = false
    var provider: WebsitePasswordVault.KeyProvider {
        WebsitePasswordVault.KeyProvider(create: {
            self.created += 1
            let key = P256.KeyAgreement.PrivateKey(compactRepresentable: false)
            return WebsitePasswordVault.KeyMaterial(representation: key.rawRepresentation, publicKey: key.publicKey)
        }, publicKey: { data in
            if self.wrongPublicKey { return P256.KeyAgreement.PrivateKey().publicKey }
            return try P256.KeyAgreement.PrivateKey(rawRepresentation: data).publicKey
        }, agreement: { data, peer, context in
            self.agreements += 1
            guard self.allowAgreement, context != nil else { throw WebsitePasswordVault.Failure.authenticationRequired }
            if self.wrongAgreement { return try P256.KeyAgreement.PrivateKey().sharedSecretFromKeyAgreement(with: peer) }
            return try P256.KeyAgreement.PrivateKey(rawRepresentation: data).sharedSecretFromKeyAgreement(with: peer)
        })
    }
}

private struct WebsiteEnvelopeFixture: Codable {
    var body: Body
    var checksum: Data
    struct Body: Codable {
        var version: Int
        var wrappedKey: Data
        var publicKey: Data
        var records: [String: Record]
    }
    struct Record: Codable {
        var host: String
        var user: String
        var clear: Bool
        var used: Date?
        var since: Date
        var password: Box
        var notes: Box?
    }
    struct Box: Codable, Equatable {
        var ephemeralPublicKey: Data
        var salt: Data
        var sealed: Data
    }
}
