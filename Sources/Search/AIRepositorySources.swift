import Foundation

/// Public repository evidence fetched by Search itself, through the current
/// proxy route. No token, browser cookie, remote MCP service, or paid plan.
@MainActor
final class AIRepositorySources {
    struct Repository: Equatable {
        let owner: String
        let name: String
        var label: String { owner + "/" + name }
        init(_ value: String) throws {
            var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("https://github.com/") { text = String(text.dropFirst(19)) }
            if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
            let parts = text.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.count <= 100 && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }) }) else {
                throw AIError.unreachable("Enter a GitHub repository as owner/name or https://github.com/owner/name.")
            }
            owner = String(parts[0]); name = String(parts[1])
        }
    }
    let repository: Repository
    init(repository: Repository) { self.repository = repository }
    static let definition: [String: Any] = ["name": "repository_read", "description": "Read public GitHub evidence from the repository selected in Search: metadata, a file, issues, pull requests, releases or workflow runs. Search sends this read through its proxy; no browser cookies or credentials are copied. Private repositories need a separate authorized integration and are not available here.", "parameters": ["type": "object", "properties": ["section": ["type": "string", "enum": ["info", "file", "issues", "pull_requests", "releases", "workflow_runs"]], "path": ["type": "string", "maxLength": 2048], "ref": ["type": "string", "maxLength": 200], "page": ["type": "integer", "minimum": 1, "maximum": 20]], "required": ["section"], "additionalProperties": false]]

    static func url(repository: Repository, arguments: [String: Any]) throws -> URL {
        let section = arguments["section"] as? String ?? "info"
        let suffix: String
        switch section {
        case "info": suffix = ""
        case "issues": suffix = "/issues"
        case "pull_requests": suffix = "/pulls"
        case "releases": suffix = "/releases"
        case "workflow_runs": suffix = "/actions/runs"
        case "file":
            guard let path = arguments["path"] as? String, !path.isEmpty, path.count <= 2048, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
                  path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw AIError.unreachable("Choose a relative file path in this repository.") }
            suffix = "/contents/" + path
        default: throw AIError.unreachable("Unsupported repository section.")
        }
        var url = URLComponents()
        url.scheme = "https"; url.host = "api.github.com"; url.path = "/repos/" + repository.label + suffix
        var query: [URLQueryItem] = []
        if section == "file", let ref = arguments["ref"] as? String {
            guard !ref.isEmpty, ref.count <= 200, !ref.contains("\0") else { throw AIError.unreachable("Invalid repository ref.") }
            query.append(URLQueryItem(name: "ref", value: ref))
        }
        if !["info", "file"].contains(section) {
            let page = arguments["page"] as? Int ?? 1
            guard (1...20).contains(page) else { throw AIError.unreachable("Repository page must be between 1 and 20.") }
            query += [URLQueryItem(name: "per_page", value: "20"), URLQueryItem(name: "page", value: String(page))]
        }
        if !query.isEmpty { url.queryItems = query }
        guard let result = url.url else { throw AIError.refusedHost }
        return result
    }

    func call(_ arguments: [String: Any]) async -> String {
        do {
            let url = try Self.url(repository: repository, arguments: arguments)
            let revision = Proxy.routesRevision
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("DarkSearch-AskAI", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 30
            let (bytes, response) = try await AIClient.shared.session.proxyBytes(for: request, delegate: AIClient.shared)
            guard let http = response as? HTTPURLResponse else { throw AIError.unreadable }
            guard http.statusCode == 200 else {
                return AIToolSession.json(["error": "GitHub returned \(http.statusCode). This connector reads public repositories without credentials; rate limits and private repository restrictions apply.", "source": url.absoluteString])
            }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard revision == Proxy.routesRevision else { throw CancellationError() }
                guard data.count < 2_000_000 else { throw AIError.unreachable("Repository response exceeded two MB. Request a smaller file or another page.") }
                data.append(byte)
            }
            var result = try JSONSerialization.jsonObject(with: data)
            if var file = result as? [String: Any], file["encoding"] as? String == "base64", let encoded = file["content"] as? String,
               let content = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), let text = String(data: content, encoding: .utf8) {
                file["content"] = text; file["encoding"] = "utf-8"; result = file
            }
            return AIToolSession.json(["source": url.absoluteString, "repository": repository.label,
                                       "observedAt": ISO8601DateFormatter().string(from: Date()), "data": result])
        } catch is CancellationError { return AIToolSession.json(["error": "Repository read cancelled or the proxy route changed."]) }
        catch { return AIToolSession.json(["error": error.localizedDescription]) }
    }
}
