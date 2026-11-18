import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Search

/// Software keys stand in for the Secure Enclave; WebKit's keychain item is
/// a closure. Nothing here touches the hardware or the keychain.
final class WebCryptoKeyTests: XCTestCase {
    private var base: URL!
    private var directory: URL { base.appendingPathComponent("WebCrypto Key", isDirectory: true) }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let resolved = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(resolved) }
        base = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent("search-webcrypto-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        if let base { try FileManager.default.removeItem(at: base) }
        try super.tearDownWithError()
    }

    private func vault(unavailable: Bool = false) -> ConnectionVault {
        enum Blocked: Error { case blocked }
        func material(_ key: P256.KeyAgreement.PrivateKey) -> ConnectionVault.KeyMaterial {
            ConnectionVault.KeyMaterial(representation: key.rawRepresentation, publicKey: key.publicKey,
                                        agreement: { try key.sharedSecretFromKeyAgreement(with: $0) })
        }
        return ConnectionVault(directory: directory, keyProvider: ConnectionVault.KeyProvider(create: {
            guard !unavailable else { throw Blocked.blocked }
            return material(P256.KeyAgreement.PrivateKey(compactRepresentable: false))
        }, restore: { data in
            guard !unavailable else { throw Blocked.blocked }
            return material(try P256.KeyAgreement.PrivateKey(rawRepresentation: data))
        }))
    }

    private let old = Data((0..<16).map { UInt8($0) })

    func testWebKitsOldKeyComesAcrossOnceAndIsKept() throws {
        var asked = 0
        let first = WebCryptoKey.load(from: vault(), legacy: { asked += 1; return self.old })
        XCTAssertEqual(first, old)
        let again = WebCryptoKey.load(from: vault(), legacy: { asked += 1; return nil }, fresh: { Data(count: 16) })
        XCTAssertEqual(again, old)
        XCTAssertEqual(asked, 1)
    }

    func testWithoutTheOldKeyANewOneIsMadeAndKept() throws {
        let made = try XCTUnwrap(WebCryptoKey.load(from: vault(), legacy: { nil }))
        XCTAssertEqual(made.count, WebCryptoKey.size)
        XCTAssertEqual(WebCryptoKey.load(from: vault(), legacy: { self.old }), made)
    }

    func testAKeptValueThatIsNotAKeyIsReplaced() throws {
        try vault().save("not a key", for: WebCryptoKey.entry)
        XCTAssertEqual(WebCryptoKey.load(from: vault(), legacy: { self.old }), old)
        XCTAssertEqual(try vault().read(WebCryptoKey.entry), .value(old.base64EncodedString()))
    }

    func testAVaultThatCannotKeepAnythingAnswersNil() {
        XCTAssertNil(WebCryptoKey.load(from: vault(unavailable: true), legacy: { self.old }))
    }
}
