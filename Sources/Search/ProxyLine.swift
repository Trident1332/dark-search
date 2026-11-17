import Foundation
import Network

/// A transient paste, never encoded into settings or a saved connection.
struct ProxyLine {
    let kind: ProxyKind
    let host: String
    let port: String
    let user: String
    let password: String?

    enum Invalid: LocalizedError {
        case format, host, port, credentials, scheme
        var errorDescription: String? {
            switch self {
            case .format: return "Use host:port or host:port:username:password. Put IPv6 addresses in brackets."
            case .host: return "Enter a server address without a path or spaces."
            case .port: return "The port must be a number from 1 to 65535."
            case .credentials: return "Include both the username and password."
            case .scheme: return "Use http://, https:// or socks5://, or choose the type below."
            }
        }
    }

    static func parse(_ text: String, kind fallback: ProxyKind) throws -> Self {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.contains(where: { $0.isNewline }) else { throw Invalid.format }
        var kind = fallback
        if let separator = raw.range(of: "://"), !raw[..<separator.lowerBound].contains(":") {
            guard let supplied = ProxyKind(rawValue: raw[..<separator.lowerBound].lowercased()) else { throw Invalid.scheme }
            kind = supplied
            raw = String(raw[separator.upperBound...])
        }
        let host: String
        let rest: String
        if raw.hasPrefix("[") {
            guard let close = raw.firstIndex(of: "]"), raw[close...].hasPrefix("]:") else { throw Invalid.format }
            host = String(raw[raw.index(after: raw.startIndex)..<close])
            guard IPv6Address(host) != nil else { throw Invalid.host }
            rest = String(raw[raw.index(close, offsetBy: 2)...])
        } else {
            guard let colon = raw.firstIndex(of: ":") else { throw Invalid.format }
            host = String(raw[..<colon])
            guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || "/?#@[]\\".contains($0) }) else { throw Invalid.host }
            rest = String(raw[raw.index(after: colon)...])
        }
        // Only the port and username delimiters are structural. Commas in the
        // username and any remaining colons in the password belong to the provider.
        let fields = rest.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard let port = fields.first, !port.isEmpty,
              port.allSatisfy({ $0.isASCII && $0.isNumber }), let number = UInt16(port), number > 0 else { throw Invalid.port }
        if fields.count == 1 {
            return Self(kind: kind, host: host, port: String(number), user: "", password: nil)
        }
        guard fields.count == 3, !fields[1].isEmpty, !fields[2].isEmpty else { throw Invalid.credentials }
        return Self(kind: kind, host: host, port: String(number), user: String(fields[1]), password: String(fields[2]))
    }

    func filling(_ connection: SavedProxy) -> SavedProxy {
        var filled = connection
        filled.kind = kind; filled.host = host; filled.port = port
        filled.user = user; filled.signsIn = password != nil
        return filled
    }
}
