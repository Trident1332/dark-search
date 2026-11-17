import Foundation

/// Describe the failed request, without guessing that the whole Mac is offline.
enum NavigationFailure {
    static func destination(_ error: Error, fallback: URL?) -> URL? {
        let info = (error as NSError).userInfo
        if let url = info[NSURLErrorFailingURLErrorKey] as? URL { return url }
        if let text = info[NSURLErrorFailingURLStringErrorKey] as? String,
           let url = URL(string: text) { return url }
        return fallback
    }

    static func message(_ error: Error, destination: URL?) -> String {
        // Only the host belongs in a short error: paths and queries may hold
        // sign-in tokens, and URL user info must never be printed here.
        let site = destination?.host.map { Hosts.display(Hosts.ascii($0)) } ?? "this page"
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return "Couldn't load \(site)." }
        switch error.code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "Couldn't find \(site). Check the address or try again later."
        case NSURLErrorNotConnectedToInternet:
            return "Couldn't reach \(site). Check your network connection and try again."
        case NSURLErrorNetworkConnectionLost:
            return "The connection to \(site) was interrupted."
        case NSURLErrorTimedOut:
            return "\(site) took too long to respond."
        case NSURLErrorCannotConnectToHost:
            return "Couldn't connect to \(site). The site may be unavailable."
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid:
            return "A secure connection to \(site) could not be established."
        default:
            return "Couldn't load \(site)."
        }
    }
}
