import Foundation
import WebKit

/// A short-lived auxiliary fetch for a Tor tab. Its entire route uses Tor,
/// including a clearnet image and every permitted redirect it follows.
@MainActor
enum OnionSession {
    static func make(for store: WKWebsiteDataStore? = nil) -> URLSession? {
        guard let port = Onion.shared.port else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        let route = store.map { Onion.shared.configuration(for: $0, port: port) }
            ?? OnionNetwork.configuration(port: port)
        return Proxy.makeSession(configuration: configuration, delegate: OnionRedirects.shared,
                                 route: route, reportsAuthenticationFailures: false)
    }
}

/// Tor's local listener never needs the ordinary proxy's saved credentials.
/// Recheck redirects before Foundation can reach any excluded local address.
final class OnionRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = OnionRedirects()

    static func redirect(_ request: URLRequest) -> URLRequest? {
        guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              OnionNetwork.permits(url) else { return nil }
        var next = request
        next.httpShouldHandleCookies = false
        next.setValue(nil, forHTTPHeaderField: "Cookie")
        next.setValue(nil, forHTTPHeaderField: "Authorization")
        next.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        next.setValue(nil, forHTTPHeaderField: "Referer")
        return next
    }

    static func disposition(for space: URLProtectionSpace) -> URLSession.AuthChallengeDisposition {
        guard !space.isProxy(), space.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            return .cancelAuthenticationChallenge
        }
        return .performDefaultHandling
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.redirect(request))
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(Self.disposition(for: challenge.protectionSpace), nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(Self.disposition(for: challenge.protectionSpace), nil)
    }
}
