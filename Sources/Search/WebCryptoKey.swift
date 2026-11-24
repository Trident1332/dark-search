import CryptoKit
import Foundation
import Security
import WebKit

/// The key WebKit locks up the CryptoKeys a page keeps (in IndexedDB, say)
/// with, handed over by Search rather than kept by WebKit.
///
/// Left to itself, WebKit keeps that key in the login keychain, as "Dark
/// Search WebCrypto Master Key", and only the build that made it may read it
/// without the Mac's password. A build signed without a Team ID — this fork's
/// own release key, or ad hoc — is a stranger to the keychain after every
/// update, so the first site after one that saved a key asked for the login
/// password, over whatever page was open, with nothing to say why.
///
/// So the stores' delegate answers WebKit's `webCryptoMasterKey:` (macOS 15
/// on) with Search's own key, kept in a vault of its own like the connection
/// passwords: sealed by this Mac's Secure Enclave, asking nobody anything.
/// The first time, WebKit's old key comes across if the keychain gives it up
/// without asking — to the build that made it, or one signed with a Team ID —
/// so what sites kept still opens; otherwise a new key is made, and a site
/// that kept one makes itself another. The old item is left where it is.
/// When the vault can't be read the answer is nil, and WebKit goes back to
/// its keychain item as before.
final class WebCryptoKey: NSObject, @unchecked Sendable {
    static let shared = WebCryptoKey()

    /// As long as WebKit's own: AES-128, for its RFC 3394 key wrap.
    static let size = 16
    static let entry = "webcrypto.master"

    private let lock = NSLock()
    private var kept: Data?
    private var waiting: [(Data?) -> Void] = []

    /// A store left without a delegate — a private tab's — is
    /// given this one, which answers for the key alone. SiteNotifications,
    /// the delegate of every other tab's store, answers the same, and takes
    /// over a store this one had.
    @MainActor static func attach(_ store: WKWebsiteDataStore) {
        let getter = NSSelectorFromString("_delegate"), setter = NSSelectorFromString("set_delegate:")
        guard store.responds(to: getter), store.responds(to: setter),
              store.perform(getter)?.takeUnretainedValue() == nil else { return }
        store.perform(setter, with: shared)
    }

    /// WebKit asks on the main thread, whenever a page saves or opens a
    /// CryptoKey. Read once a run, away from the main thread.
    @objc(webCryptoMasterKey:)
    func masterKey(_ reply: @escaping (Data?) -> Void) {
        lock.lock()
        if let kept {
            lock.unlock()
            return reply(kept)
        }
        waiting.append(reply)
        let first = waiting.count == 1
        lock.unlock()
        guard first else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let key = Self.load(from: Self.vault, legacy: Self.legacy)
            DispatchQueue.main.async {
                self.lock.lock()
                if let key { self.kept = key }
                let replies = self.waiting
                self.waiting = []
                self.lock.unlock()
                replies.forEach { $0(key) }
            }
        }
    }

    private static var vault: ConnectionVault {
        ConnectionVault(directory: Store.folder.appendingPathComponent("WebCrypto Key", isDirectory: true))
    }

    /// The kept key; else WebKit's old one, or a new one, kept from now on.
    /// Nil only when the vault can't be read or written.
    static func load(from vault: ConnectionVault, legacy: () -> Data?,
                     fresh: () -> Data = { SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) } }) -> Data? {
        do {
            if case .value(let text) = try vault.read(entry), let key = Data(base64Encoded: text), key.count == size {
                return key
            }
            let key = legacy() ?? fresh()
            try vault.save(key.base64EncodedString(), for: entry)
            return key
        } catch {
            NSLog("WebCryptoKey: the vault could not keep the key (%@); WebKit keeps its own", String(describing: error))
            return nil
        }
    }

    /// WebKit's own key, if the keychain hands it over without asking. A test
    /// run never reads the real browser's.
    private static func legacy() -> Data? {
        guard !Store.testing else { return nil }
        let app = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        var out: CFTypeRef?
        let status = KeychainAccess.copyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "com.apple.WebKit.WebCrypto.master+\(app)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ] as CFDictionary, &out)
        guard status == errSecSuccess, let stored = out as? Data,
              let key = Data(base64Encoded: stored), key.count == size else { return nil }
        return key
    }
}
