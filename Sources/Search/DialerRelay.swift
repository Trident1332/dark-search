import Foundation
import Network

/// The relay belongs to the configured phone server. Neither redirects nor a
/// ticket can move the saved SIP password or the TURN connection to another host.
struct DialerRelayEndpoint: Equatable {
    let host: String
    let issuer: URL

    init(wss: String) throws {
        guard let parts = URLComponents(string: wss), parts.scheme?.lowercased() == "wss",
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              !host.hasSuffix(".onion"), host != "onion",
              host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-:").contains($0) })
        else { throw DialerRelayError.message("Protected calls need a secure wss:// phone server") }
        var issuer = URLComponents()
        issuer.scheme = "https"
        issuer.host = host
        issuer.path = "/search-dialer/turn"
        guard let url = issuer.url else { throw DialerRelayError.invalidTicket }
        self.host = host
        self.issuer = url
    }
}

struct DialerRelayTicket: Decodable {
    struct Server: Decodable {
        let urls: [String]
        let username: String
        let credential: String
    }
    let iceServers: [Server]
    let expiresAt: Double
    let ttl: Int

    func validated(for endpoint: DialerRelayEndpoint, now: Date = Date()) throws -> (host: String, port: UInt16, username: String, credential: String) {
        guard iceServers.count == 1, let server = iceServers.first, server.urls.count == 1,
              expiresAt.isFinite, expiresAt > now.timeIntervalSince1970 + 60,
              expiresAt <= now.timeIntervalSince1970 + 14_460,
              (120...14_400).contains(ttl),
              expiresAt <= now.timeIntervalSince1970 + Double(ttl) + 60,
              !server.username.isEmpty, server.username.utf8.count <= 256,
              !server.credential.isEmpty, server.credential.utf8.count <= 256,
              !server.username.contains(where: { $0.isNewline || $0 == "\0" }),
              !server.credential.contains(where: { $0.isNewline || $0 == "\0" })
        else { throw DialerRelayError.invalidTicket }
        // RFC 7065 uses an opaque URI, without the // in an HTTPS URL.
        let raw = server.urls[0]
        guard raw.hasPrefix("turns:"), raw.hasSuffix("?transport=tcp"),
              let parts = URLComponents(string: "turns://" + raw.dropFirst(6)),
              parts.host?.lowercased() == endpoint.host,
              parts.user == nil, parts.password == nil, parts.path.isEmpty,
              parts.fragment == nil, parts.query == "transport=tcp",
              let port = parts.port, let port = UInt16(exactly: port), port > 0
        else { throw DialerRelayError.invalidTicket }
        return (endpoint.host, port, server.username, server.credential)
    }
}

enum DialerRelayError: LocalizedError {
    case invalidTicket
    case message(String)
    var errorDescription: String? {
        switch self {
        case .invalidTicket: return "The phone server returned an invalid protected-call route"
        case .message(let text): return text
        }
    }
}

/// A new session for one route revision. No cookies, stored HTTP credentials,
/// redirects, or interactive authentication. Certificate validation stays with
/// the system; a proxy authentication failure is handled by Search's policy.
final class DialerRelayRequest: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if Proxy.authenticate(challenge, in: session, completionHandler: completionHandler) { return }
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    static func fetch(endpoint: DialerRelayEndpoint, user: String, password: String,
                      proxy: ProxyConfiguration) async throws -> DialerRelayTicket {
        guard !user.isEmpty, user.utf8.count <= 256, !user.contains(":"),
              !user.contains(where: { $0.isNewline || $0 == "\0" }),
              !password.isEmpty, password.utf8.count <= 4096
        else { throw DialerRelayError.message("Save your phone-server login in Dialer settings first") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        var mandatory = proxy
        mandatory.allowFailover = false
        mandatory.excludedDomains = []
        let delegate = DialerRelayRequest()
        let session = Proxy.makeSession(configuration: configuration, delegate: delegate,
                                        route: mandatory, reportsAuthenticationFailures: false)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint.issuer)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Basic " + Data((user + ":" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await session.proxyBytes(for: request)
        guard let response = response as? HTTPURLResponse, response.url == endpoint.issuer else { throw DialerRelayError.invalidTicket }
        guard response.statusCode == 200 else {
            switch response.statusCode {
            case 401, 403: throw DialerRelayError.message("The phone server didn't accept your saved dialer login")
            case 407: throw DialerRelayError.message("The proxy didn't accept the saved proxy login. See Proxy settings")
            case 429: throw DialerRelayError.message("The phone server is busy. Try the dialer again shortly")
            default: throw DialerRelayError.message("The protected-call relay is unavailable (HTTP \(response.statusCode))")
            }
        }
        guard response.expectedContentLength <= 32_768 else { throw DialerRelayError.invalidTicket }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 32_768 else { throw DialerRelayError.invalidTicket }
            data.append(byte)
        }
        return try JSONDecoder().decode(DialerRelayTicket.self, from: data)
    }
}
