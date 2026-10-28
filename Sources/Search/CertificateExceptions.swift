import Foundation
import Security
import WebKit

/// A certificate accepted for this launch belongs only to that certificate,
/// origin and website data store. Profiles and private tabs use separate
/// stores, so accepting a warning in one never dismisses another's warning.
@MainActor
final class CertificateExceptions {
    private struct Identity: Hashable {
        let host: String
        let port: Int
        let scheme: String?
        let proxy: Bool
        let certificate: Data

        init?(trust: SecTrust, space: URLProtectionSpace) {
            guard !space.host.isEmpty,
                  let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first else { return nil }
            host = space.host.lowercased()
            port = space.port
            scheme = space.protocol?.lowercased()
            proxy = space.isProxy()
            certificate = SecCertificateCopyData(leaf) as Data
        }
    }

    private struct Scope {
        weak var store: WKWebsiteDataStore?
        var accepted: Set<Identity>
    }

    private var scopes: [ObjectIdentifier: Scope] = [:]

    func contains(_ trust: SecTrust, for space: URLProtectionSpace, in store: WKWebsiteDataStore) -> Bool {
        guard let identity = Identity(trust: trust, space: space),
              let scope = scopes[ObjectIdentifier(store)], scope.store === store else { return false }
        return scope.accepted.contains(identity)
    }

    @discardableResult
    func accept(_ trust: SecTrust, for space: URLProtectionSpace, in store: WKWebsiteDataStore) -> Bool {
        guard let identity = Identity(trust: trust, space: space) else { return false }
        // A released private store cannot leave an exception for a later
        // object that happens to be allocated at the same address.
        scopes = scopes.filter { $0.value.store != nil }
        let id = ObjectIdentifier(store)
        var scope = scopes[id] ?? Scope(store: store, accepted: [])
        scope.accepted.insert(identity)
        scopes[id] = scope
        return true
    }
}
