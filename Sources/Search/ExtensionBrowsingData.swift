import Foundation
import CoreFoundation
import Darwin
import WebKit

/// Validate the whole removal before touching a store. WebKit's public
/// records group storage by registrable domain, not by origin, so they
/// cannot implement a scheme/port-scoped cache or storage deletion safely.
@MainActor
enum ExtensionBrowsingData {
    struct Refused: LocalizedError {
        let why: String
        var errorDescription: String? { why }
    }

    /// Bridging NSNumber to Bool also accepts numeric 0/1. Extension API
    /// selections require actual booleans, and one invalid member must
    /// reject the whole request before any valid member deletes data.
    nonisolated static func booleans(_ raw: Any?, named name: String) throws -> [String: Bool] {
        guard let dictionary = raw as? [String: Any] else {
            throw Refused(why: "\(name) must be an object containing booleans")
        }
        var parsed: [String: Bool] = [:]
        for (key, value) in dictionary {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw Refused(why: "\(name) must contain only booleans")
            }
            parsed[key] = number.boolValue
        }
        return parsed
    }

    private static let types: [String: Set<String>] = [
        "cache": [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache],
        "cacheStorage": [WKWebsiteDataTypeFetchCache], "appcache": [WKWebsiteDataTypeOfflineWebApplicationCache],
        "cookies": [WKWebsiteDataTypeCookies],
        "localStorage": [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage],
        "indexedDB": [WKWebsiteDataTypeIndexedDBDatabases], "serviceWorkers": [WKWebsiteDataTypeServiceWorkerRegistrations],
        "webSQL": [WKWebsiteDataTypeWebSQLDatabases], "fileSystems": [WKWebsiteDataTypeFileSystem],
    ]

    struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int

        init(_ text: String) throws {
            guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), let host = url.host(), !host.isEmpty,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/",
                  url.port.map({ (1...65535).contains($0) }) ?? true else {
                throw Refused(why: "browsingData requires HTTP or HTTPS origins without credentials, paths, queries or fragments")
            }
            let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !normalized.isEmpty, !host.hasPrefix("."), !host.contains(".."),
                  !host.contains("*"), !host.contains("%"), !host.contains(where: \.isWhitespace) else {
                throw Refused(why: "browsingData requires a valid origin hostname")
            }
            self.scheme = scheme
            self.host = Self.canonicalHost(normalized)
            port = url.port ?? (scheme == "https" ? 443 : 80)
        }

        private static func canonicalHost(_ host: String) -> String {
            let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let capacity = socklen_t(buffer.count)
            var address4 = in_addr()
            if inet_aton(bare, &address4) == 1,
               inet_ntop(AF_INET, &address4, &buffer, capacity) != nil { return String(cString: buffer) }
            var address6 = in6_addr()
            if inet_pton(AF_INET6, bare, &address6) == 1,
               inet_ntop(AF_INET6, &address6, &buffer, capacity) != nil { return String(cString: buffer) }
            return host
        }
    }

    struct Plan {
        let since: Date
        let removesHistory: Bool
        let dataTypes: Set<String>
        let origins: [Origin]?
        let excludes: Bool

        init(_ what: [String: Bool], options: [String: Any]) throws {
            let requested = Set(what.filter(\.value).map(\.key))
            let unsupported = requested.subtracting(Set(ExtensionBrowsingData.types.keys).union(["history"]))
            guard unsupported.isEmpty else {
                throw Refused(why: "browsingData cannot remove \(unsupported.sorted().joined(separator: ", ")) in Search")
            }
            if let raw = options["originTypes"] {
                // Omitted originTypes defaults to ordinary sites, but an
                // explicit dictionary starts with no selected origin types
                // in Chromium. Never broaden {} or false-only selections.
                let selection = try ExtensionBrowsingData.booleans(raw, named: "browsingData.originTypes")
                guard Set(selection.keys).isSubset(of: ["unprotectedWeb", "protectedWeb", "extension"]),
                      selection["unprotectedWeb"] == true,
                      selection["protectedWeb"] != true, selection["extension"] != true else {
                    throw Refused(why: "browsingData supports only ordinary website data in Search")
                }
            }
            let milliseconds: Double
            if let value = options["since"] {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, number.doubleValue >= 0 else {
                    throw Refused(why: "browsingData.since must be a nonnegative timestamp")
                }
                milliseconds = number.doubleValue
            } else { milliseconds = 0 }
            since = Date(timeIntervalSince1970: milliseconds / 1000)
            guard options["origins"] == nil || options["excludeOrigins"] == nil else {
                throw Refused(why: "browsingData cannot combine origins and excludeOrigins")
            }
            let key = options["origins"] != nil ? "origins" : "excludeOrigins"
            excludes = key == "excludeOrigins"
            if let raw = options[key] {
                guard let values = raw as? [String], key != "origins" || !values.isEmpty else {
                    throw Refused(why: "browsingData.\(key) must be an array of origins")
                }
                let parsed = try values.map(Origin.init)
                origins = parsed.isEmpty ? nil : parsed
            } else { origins = nil }
            dataTypes = requested.reduce(into: Set<String>()) { $0.formUnion(ExtensionBrowsingData.types[$1] ?? []) }
            removesHistory = requested.contains("history")
            if origins != nil {
                guard dataTypes.isSubset(of: [WKWebsiteDataTypeCookies]), !removesHistory else {
                    throw Refused(why: "Search cannot safely scope cache, storage or history removal to exact origins; no data was removed")
                }
                guard milliseconds == 0 else {
                    throw Refused(why: "Search cannot combine an origin filter with time-scoped cookie removal; no data was removed")
                }
            }
        }

        func remove(from stores: [WKWebsiteDataStore]) async throws {
            guard !dataTypes.isEmpty else { return }
            guard let origins else {
                for store in stores { await store.removeData(ofTypes: dataTypes, modifiedSince: since) }
                return
            }
            // For cookies, Chrome scopes both inclusions and exclusions to
            // the entire registrable domain. Query the cookie store itself:
            // ephemeral stores can have cookies without website-data records.
            // Without a suffix classifier, matching only the original host
            // could delete an excluded site's siblings or miss included ones.
            guard let suffix = Passkeys.publicSuffix else {
                throw Refused(why: "Search could not determine cookie site boundaries safely; no data was removed")
            }
            let isSuffix: (String) -> Bool = { suffix($0 as CFString) }
            func site(_ value: String) throws -> String {
                let domain = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                // Cookie domains may be bare IPv6 addresses; origins need
                // brackets. Reuse origin parsing for canonical host spelling.
                let authority = domain.contains(":") && !domain.hasPrefix("[") ? "[\(domain)]" : domain
                let host = try Origin("https://\(authority)/").host
                return Registrable.domain(of: host, isSuffix: isSuffix)
            }
            let scopedSites = Set(try origins.map { try site($0.host) })
            // Collect and validate all stores before deleting, so an invalid
            // cookie domain cannot leave a partially applied request.
            var batches: [(WKHTTPCookieStore, [HTTPCookie])] = []
            for store in stores {
                let cookieStore = store.httpCookieStore
                let cookies: [HTTPCookie] = await withCheckedContinuation { done in
                    cookieStore.getAllCookies { done.resume(returning: $0) }
                }
                var selected: [HTTPCookie] = []
                for cookie in cookies {
                    let matches = scopedSites.contains(try site(cookie.domain))
                    if matches != excludes { selected.append(cookie) }
                }
                batches.append((cookieStore, selected))
            }
            for (cookieStore, cookies) in batches {
                for cookie in cookies {
                    await withCheckedContinuation { done in cookieStore.delete(cookie) { done.resume() } }
                }
            }
        }
    }
}
