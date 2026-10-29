import Foundation
import Darwin

/// A dialer grant belongs to one web origin, including its transport and port.
/// A hostname alone in old settings only migrates to HTTPS's default origin;
/// localhost needs an explicit URL so unrelated local applications get no grant.
struct DialerOrigin: Equatable, Hashable {
    let scheme: String
    let host: String
    let port: Int

    init?(scheme: String, host: String, port: Int) {
        let scheme = scheme.lowercased()
        guard scheme == "https" || scheme == "http", let host = Self.canonicalHost(host) else { return nil }
        let port = port == 0 ? (scheme == "https" ? 443 : 80) : port
        guard (1...65535).contains(port), scheme == "https" || Self.loopback(host) else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = port
    }

    var string: String {
        let address = host.contains(":") ? "[\(host)]" : host
        let standard = scheme == "https" ? 443 : 80
        return "\(scheme)://\(address)" + (port == standard ? "" : ":\(port)")
    }

    /// Only origins are accepted: paths, credentials, queries and fragments
    /// are not silently discarded from a grant the user is reviewing.
    static func parse(_ typed: String, allowLegacyHost: Bool = true) -> DialerOrigin? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let explicit = text.contains("://")
        if !explicit {
            guard allowLegacyHost, !text.contains(where: { "/:@?#[]".contains($0) }) else { return nil }
        }
        guard let parts = URLComponents(string: explicit ? text : "https://" + text),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              let scheme = parts.scheme, let host = parts.url?.host,
              let origin = DialerOrigin(scheme: scheme, host: host, port: parts.port ?? 0),
              explicit || !loopback(origin.host)
        else { return nil }
        return origin
    }

    static func normalized(_ grants: [String]) -> [String] {
        var seen = Set<DialerOrigin>()
        return grants.compactMap { value in
            guard let origin = parse(value), seen.insert(origin).inserted else { return nil }
            return origin.string
        }
    }

    static func allows(_ grants: [String], scheme: String, host: String, port: Int) -> Bool {
        guard let origin = DialerOrigin(scheme: scheme, host: host, port: port) else { return false }
        return grants.contains { parse($0) == origin }
    }

    private static func loopback(_ host: String) -> Bool {
        let host = host.hasSuffix(".") ? String(host.dropLast()) : host
        if host == "localhost" || host == "::1" { return true }
        let bytes = host.split(separator: ".", omittingEmptySubsequences: false)
        guard bytes.count == 4, bytes.first == "127" else { return false }
        return bytes.allSatisfy { part in
            !part.isEmpty && part.allSatisfy({ $0.isASCII && $0.isNumber })
                && Int(part).map { (0...255).contains($0) } == true
        }
    }

    private static func canonicalHost(_ raw: String) -> String? {
        let raw = raw.hasPrefix("[") && raw.hasSuffix("]") ? String(raw.dropFirst().dropLast()) : raw
        if raw.contains(":") {
            var address = in6_addr()
            guard raw.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return String(cString: buffer)
        }
        guard raw.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }),
              let host = URL(string: "https://" + raw)?.host?.lowercased(), !host.isEmpty, host.count <= 254,
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
        else { return nil }
        let labels = (host.hasSuffix(".") ? String(host.dropLast()) : host).split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" }) else { return nil }
        return host
    }
}
