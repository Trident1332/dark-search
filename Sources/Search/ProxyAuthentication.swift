import Foundation

/// The credentials belonging to one route, captured when its session is
/// made. An old request must not use a replacement server's credentials.
struct ProxyCredentials: Sendable {
    let setup: ProxySetup
    let revision: Int
    let password: String?
}

/// Completion-handler and async URLSession requests don't reliably deliver
/// didCompleteWithError to their delegate. Report transport authentication
/// failures at the await boundary as well as in authentication callbacks.
extension URLSession {
    func proxyData(for request: URLRequest, delegate: URLSessionTaskDelegate? = nil) async throws -> (Data, URLResponse) {
        do { return try await data(for: request, delegate: delegate) }
        catch { Proxy.authenticationError(error, in: self); throw error }
    }

    func proxyData(from url: URL, delegate: URLSessionTaskDelegate? = nil) async throws -> (Data, URLResponse) {
        try await proxyData(for: URLRequest(url: url), delegate: delegate)
    }

    func proxyBytes(for request: URLRequest, delegate: URLSessionTaskDelegate? = nil) async throws -> (URLSession.AsyncBytes, URLResponse) {
        do { return try await bytes(for: request, delegate: delegate) }
        catch { Proxy.authenticationError(error, in: self); throw error }
    }

    func proxyBytes(from url: URL, delegate: URLSessionTaskDelegate? = nil) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await proxyBytes(for: URLRequest(url: url), delegate: delegate)
    }

    func proxyDownload(for request: URLRequest, delegate: URLSessionTaskDelegate? = nil) async throws -> (URL, URLResponse) {
        do { return try await download(for: request, delegate: delegate) }
        catch { Proxy.authenticationError(error, in: self); throw error }
    }

    func proxyDownload(from url: URL, delegate: URLSessionTaskDelegate? = nil) async throws -> (URL, URLResponse) {
        try await proxyDownload(for: URLRequest(url: url), delegate: delegate)
    }
}

/// Handles only Search's proxy challenges. Origin authentication and TLS
/// trust keep their existing handling; proxy failures never ask macOS to
/// display a password dialog or save another system credential.
final class ProxyAuthentication: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let missing = "Enter the proxy's name and password in Settings › Proxy"
    static let rejected = "The proxy didn't accept the saved name or password. Update them in Settings › Proxy"

    let credentials: ProxyCredentials?
    let reportsFailures: Bool
    weak var session: URLSession?
    private let lock = NSLock()
    private var problem: String?
    var failure: String? { lock.withLock { problem } }

    init(credentials: ProxyCredentials?, reportsFailures: Bool = true) {
        self.credentials = credentials
        self.reportsFailures = reportsFailures
    }

    @discardableResult
    func respond(to challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) -> Bool {
        let space = challenge.protectionSpace
        guard space.isProxy(), space.authenticationMethod != NSURLAuthenticationMethodServerTrust,
              let credentials else { return false }
        let setup = credentials.setup
        let host = space.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        let expected = setup.trimmedHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        let failure: String?
        if credentials.revision != Proxy.routesRevision {
            failure = "Proxy settings changed. Test the connection again"
        } else if host != expected || space.port != Int(setup.portOrUsual) {
            failure = "The authentication request didn't match the configured proxy"
        } else if challenge.previousFailureCount > 0 {
            failure = Self.rejected
        } else if !setup.signsIn || setup.user.isEmpty || credentials.password?.isEmpty != false {
            failure = Self.missing
        } else if ![NSURLAuthenticationMethodDefault, NSURLAuthenticationMethodHTTPBasic,
                    NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM,
                    NSURLAuthenticationMethodNegotiate].contains(space.authenticationMethod) {
            failure = "The proxy's authentication method isn't supported"
        } else {
            // proxyType can say HTTPS for an ordinary HTTP CONNECT proxy
            // carrying an HTTPS page. Host and port establish the endpoint.
            completionHandler(.useCredential, URLCredential(user: setup.user, password: credentials.password!, persistence: .none))
            return true
        }
        if let failure {
            lock.withLock { problem = failure }
            if reportsFailures {
                Task { @MainActor in
                    Proxy.shared.authenticationFailed(failure, revision: credentials.revision)
                }
            }
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
        return true
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if !respond(to: challenge, completionHandler: completionHandler) { completionHandler(.performDefaultHandling, nil) }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if !respond(to: challenge, completionHandler: completionHandler) { completionHandler(.performDefaultHandling, nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { Proxy.authenticationError(error, in: session) }
    }
}
