import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Search

/// Only the explicitly injected software provider is used here. The files and
/// values are synthetic; these tests never touch Secure Enclave or Keychain.
final class ConnectionVaultTests: XCTestCase {
    private var base: URL!
    private var directory: URL { base.appendingPathComponent("Vault", isDirectory: true) }
    private var file: URL { directory.appendingPathComponent("connections.vault") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Foundation canonicalizes the system /private/var alias back to /var
        // even after resolvingSymlinksInPath. Use the POSIX physical parent so
        // the backend can keep rejecting symlinks at every path component.
        let resolved = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(resolved) }
        base = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent("search-connection-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        if let base { try FileManager.default.removeItem(at: base) }
        try super.tearDownWithError()
    }

    private func vault(_ provider: VaultTestKeys = VaultTestKeys(), beforeCommit: (() throws -> Void)? = nil) -> ConnectionVault {
        ConnectionVault(directory: directory, keyProvider: provider.provider, beforeCommit: beforeCommit)
    }

    private func replaceFixture(_ bytes: Data) throws {
        try bytes.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func testMissingReadCreatesNothingAndDoesNotRequestAKey() throws {
        let keys = VaultTestKeys()
        keys.unavailable = true
        XCTAssertEqual(try vault(keys).read("proxy:synthetic"), .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(keys.created, 0)
        XCTAssertEqual(keys.restored, 0)
    }

    func testFirstSaveCreatesMissingPrivateParentsButReadDoesNot() throws {
        let parent = base.appendingPathComponent("new-profile", isDirectory: true)
        let nested = parent.appendingPathComponent("data", isDirectory: true).appendingPathComponent("Vault", isDirectory: true)
        let keys = VaultTestKeys()
        let first = ConnectionVault(directory: nested, keyProvider: keys.provider)
        XCTAssertEqual(try first.read("one"), .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
        XCTAssertEqual(keys.created, 0)
        try first.save("synthetic", for: "one")
        let second = ConnectionVault(directory: nested, keyProvider: VaultTestKeys().provider)
        XCTAssertEqual(try second.read("one"), .value("synthetic"))
        for directory in [parent, parent.appendingPathComponent("data"), nested] {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
    }

    func testTwoInstancesPersistIndependentValuesWithPrivateEncryptedFiles() throws {
        let first = vault(), second = vault()
        let secret = "SYNTHETIC-VAULT-SECRET-52CF2589"
        try first.save(secret, for: "proxy:synthetic-user@example.test")
        try second.save("SYNTHETIC-DIALER-SECRET", for: "dialer:synthetic-seat")
        let relaunched = vault()
        XCTAssertEqual(try relaunched.read("proxy:synthetic-user@example.test"), .value(secret))
        XCTAssertEqual(try relaunched.read("dialer:synthetic-seat"), .value("SYNTHETIC-DIALER-SECRET"))
        XCTAssertNil(try Data(contentsOf: file).range(of: Data(secret.utf8)))
        XCTAssertNil(try Data(contentsOf: file).range(of: Data("proxy:synthetic-user@example.test".utf8)))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        for name in ["connections.vault", "connections.lock"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testForgetPersistsATombstoneAcrossRelaunchAndOtherWrites() throws {
        try vault().forget("legacy:never-import-this")
        XCTAssertEqual(try vault().read("legacy:never-import-this"), .deleted)
        try vault().save("unrelated", for: "other")
        XCTAssertEqual(try vault().read("legacy:never-import-this"), .deleted)
        try vault().save("replacement", for: "legacy:never-import-this")
        XCTAssertEqual(try vault().read("legacy:never-import-this"), .value("replacement"))
        try vault().forget("legacy:never-import-this")
        XCTAssertEqual(try vault().read("legacy:never-import-this"), .deleted)
    }

    func testCiphertextTamperCannotBeReadOrOverwritten() throws {
        try vault().save("synthetic", for: "one")
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var sealed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["sealed"] as? String)))
        sealed[sealed.count - 1] ^= 1
        envelope["sealed"] = sealed.base64EncodedString()
        try replaceFixture(JSONSerialization.data(withJSONObject: envelope))
        let tampered = try Data(contentsOf: file)
        XCTAssertThrowsError(try vault().read("one"))
        XCTAssertThrowsError(try vault().save("replacement", for: "one"))
        XCTAssertThrowsError(try vault().forget("one"))
        XCTAssertEqual(try Data(contentsOf: file), tampered)
    }

    func testInvalidExistingFileDoesNotGenerateANewKey() throws {
        try vault().save("synthetic", for: "one")
        try replaceFixture(Data("not a vault".utf8))
        let keys = VaultTestKeys()
        XCTAssertThrowsError(try vault(keys).save("new", for: "two"))
        XCTAssertEqual(keys.created, 0)
        XCTAssertEqual(try Data(contentsOf: file), Data("not a vault".utf8))
    }

    func testLockedOrUnavailableExistingKeyPreservesTheFile() throws {
        try vault().save("synthetic", for: "one")
        let original = try Data(contentsOf: file)
        let keys = VaultTestKeys()
        keys.unavailable = true
        XCTAssertThrowsError(try vault(keys).read("one"))
        XCTAssertThrowsError(try vault(keys).save("new", for: "two"))
        XCTAssertEqual(keys.created, 0)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try vault().read("one"), .value("synthetic"))
    }

    func testUnknownVersionFailsClosedAndPreservesTheFile() throws {
        try vault().save("synthetic", for: "one")
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        envelope["version"] = 2
        try replaceFixture(JSONSerialization.data(withJSONObject: envelope))
        let original = try Data(contentsOf: file)
        XCTAssertThrowsError(try vault().read("one"))
        XCTAssertThrowsError(try vault().save("new", for: "two"))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testFailedCommitPreservesPreviousFileAndRemovesTemporaryFile() throws {
        try vault().save("previous", for: "one")
        let original = try Data(contentsOf: file)
        let failing = vault(beforeCommit: { throw VaultTestKeys.Unavailable.blocked })
        XCTAssertThrowsError(try failing.save("replacement", for: "one"))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try vault().read("one"), .value("previous"))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       Set(["connections.vault", "connections.lock"]))
    }

    func testDamagedStagedWritePreservesThePreviousFile() throws {
        try vault().save("previous", for: "one")
        let original = try Data(contentsOf: file)
        let failing = vault(beforeCommit: {
            let staged = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: self.directory,
                includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasSuffix(".tmp") })
            try Data("damaged staged write".utf8).write(to: staged)
        })
        XCTAssertThrowsError(try failing.save("replacement", for: "one"))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try vault().read("one"), .value("previous"))
    }

    func testInsecureFilePermissionsAndHardLinksAreRejected() throws {
        try vault().save("previous", for: "one")
        let original = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try vault().read("one"))
        XCTAssertThrowsError(try vault().save("replacement", for: "one"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let alias = base.appendingPathComponent("hardlink")
        XCTAssertEqual(link(file.path, alias.path), 0)
        XCTAssertThrowsError(try vault().read("one"))
        XCTAssertThrowsError(try vault().forget("one"))
        try FileManager.default.removeItem(at: alias)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try vault().read("one"), .value("previous"))
    }

    func testInsecureDirectoryPermissionsAreNotSilentlyRepaired() throws {
        try vault().save("previous", for: "one")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try vault().read("one"))
        XCTAssertThrowsError(try vault().save("replacement", for: "one"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertEqual(try vault().read("one"), .value("previous"))
    }

    func testSymlinkFileAndDirectoryCannotRedirectOperations() throws {
        try vault().save("previous", for: "one")
        let outside = base.appendingPathComponent("untouched")
        try Data("untouched".utf8).write(to: outside)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        XCTAssertThrowsError(try vault().read("one"))
        XCTAssertThrowsError(try vault().save("replacement", for: "one"))
        XCTAssertEqual(try Data(contentsOf: outside), Data("untouched".utf8))
        let alias = base.appendingPathComponent("directory-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let redirected = ConnectionVault(directory: alias, keyProvider: VaultTestKeys().provider)
        XCTAssertThrowsError(try redirected.read("one"))
        XCTAssertThrowsError(try redirected.save("new", for: "one"))
    }

    func testSymlinkParentIsRejectedBeforeCreatingAnyChild() throws {
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let alias = base.appendingPathComponent("parent-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        let location = alias.appendingPathComponent("child", isDirectory: true).appendingPathComponent("Vault", isDirectory: true)
        let redirected = ConnectionVault(directory: location, keyProvider: VaultTestKeys().provider)
        XCTAssertThrowsError(try redirected.read("one"))
        XCTAssertThrowsError(try redirected.save("synthetic", for: "one"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testDirectorySwapBeforeCommitIsDetectedWithoutWritingTheReplacement() throws {
        try vault().save("previous", for: "one")
        let moved = base.appendingPathComponent("moved", isDirectory: true)
        let replacement = base.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let failing = vault(beforeCommit: {
            try FileManager.default.moveItem(at: self.directory, to: moved)
            try FileManager.default.createSymbolicLink(at: self.directory, withDestinationURL: replacement)
        })
        XCTAssertThrowsError(try failing.save("new", for: "one"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: replacement.path).isEmpty)
        let old = ConnectionVault(directory: moved, keyProvider: VaultTestKeys().provider)
        XCTAssertEqual(try old.read("one"), .value("previous"))
    }

    func testOversizedInputPreservesTheExistingFile() throws {
        try vault().save("previous", for: "one")
        let original = try Data(contentsOf: file)
        XCTAssertThrowsError(try vault().save(String(repeating: "x", count: 65_537), for: "one"))
        XCTAssertThrowsError(try vault().save("new", for: String(repeating: "x", count: 1025)))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}

private final class VaultTestKeys {
    enum Unavailable: Error { case blocked }
    var unavailable = false
    var created = 0
    var restored = 0

    var provider: ConnectionVault.KeyProvider {
        ConnectionVault.KeyProvider(create: {
            self.created += 1
            guard !self.unavailable else { throw Unavailable.blocked }
            return self.material(P256.KeyAgreement.PrivateKey(compactRepresentable: false))
        }, restore: { data in
            self.restored += 1
            guard !self.unavailable else { throw Unavailable.blocked }
            return self.material(try P256.KeyAgreement.PrivateKey(rawRepresentation: data))
        })
    }

    private func material(_ key: P256.KeyAgreement.PrivateKey) -> ConnectionVault.KeyMaterial {
        ConnectionVault.KeyMaterial(representation: key.rawRepresentation, publicKey: key.publicKey,
                                    agreement: { try key.sharedSecretFromKeyAgreement(with: $0) })
    }
}
