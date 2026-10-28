import Foundation

/// Address handling only. A recognized onion host must use Tor even when
/// malformed; validating its spelling does not prove a service is running.
enum OnionAddress {
    /// DNS names are case insensitive and may end with a root dot. Strip
    /// every trailing dot for classification, so malformed names cannot
    /// evade the Tor-only rule. Validation below permits at most one.
    static func canonicalHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    static func isOnionHost(_ raw: String) -> Bool {
        let host = canonicalHost(raw)
        return host == "onion" || host.hasSuffix(".onion")
    }

    static func isOnion(_ url: URL) -> Bool {
        url.host().map(isOnionHost) ?? false
    }

    /// A conservative search/suggestion guard, including invalid addresses
    /// and phrases. A failed onion parse must never turn into a web search.
    static func hasIntent(_ text: String) -> Bool {
        if text.range(of: ".onion", options: .caseInsensitive) != nil { return true }
        return text.removingPercentEncoding?.range(of: ".onion", options: .caseInsensitive) != nil
    }

    /// Modern onion names use a 56-character base32 service label. This
    /// validates the address's shape, not its cryptographic checksum or key.
    /// Optional subdomains follow ordinary ASCII DNS-label rules.
    static func isValidHost(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.hasSuffix("..") else { return false }
        let host = canonicalHost(raw)
        guard host.utf8.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.last == "onion" else { return false }
        let service = labels[labels.count - 2]
        guard service.utf8.count == 56,
              service.utf8.allSatisfy({ (97...122).contains($0) || (50...55).contains($0) }) else { return false }
        return labels.dropLast(2).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }

    /// A bare onion address defaults to HTTP. Tor encrypts the connection
    /// to the onion service; a service may also explicitly provide HTTPS.
    /// Explicit HTTPS is preserved, never downgraded after a failure.
    static func url(from typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        let source: String
        if text.range(of: "://") != nil {
            source = text
        } else if text.hasPrefix("//") {
            source = "http:" + text
        } else {
            let head = text.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            guard !head.contains("@") else { return nil }
            source = "http://" + text
        }
        guard var parts = URLComponents(string: source),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, isValidHost(host) else { return nil }
        if let port = parts.port, !(1...65535).contains(port) { return nil }
        parts.scheme = scheme
        parts.host = canonicalHost(host)
        return parts.url
    }
}
