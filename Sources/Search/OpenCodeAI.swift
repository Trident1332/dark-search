import Foundation

/// OpenCode remains the owner of its configuration and credentials. Search
/// reads it only when its model picker or an explicitly requested answer
/// needs it; no OpenCode key is copied into Search's settings or keychain.
enum OpenCodeAI {
    struct Model: Identifiable, Equatable {
        let id: String
        let name: String
        let providerName: String
        let host: String
        let origin: String
    }

    /// A request and its consent use this same immutable destination. Keeping
    /// the wire and key beside the endpoint also prevents a config refresh
    /// from mixing one provider's credentials with another provider's host.
    struct Connection {
        let id: String
        let base: URL
        let wire: AIProvider.Wire
        let model: String
        let key: String?
        let name: String
        let providerName: String
        var host: String { base.host()?.lowercased() ?? "" }
        var origin: String { OpenCodeAI.origin(base) }

        fileprivate init(id: String, base: URL, wire: AIProvider.Wire, model: String, key: String?, name: String, providerName: String) {
            self.id = id
            self.base = base
            self.wire = wire
            self.model = model
            self.key = key
            self.name = name
            self.providerName = providerName
        }
    }

    enum ReadError: LocalizedError, Equatable {
        case missingConfiguration, invalidConfiguration, noModels, unknownModel
        case unsafeEndpoint, missingReference, missingKey, unsupportedAuth

        var errorDescription: String? {
            switch self {
            case .missingConfiguration: return "OpenCode's global configuration wasn't found."
            case .invalidConfiguration: return "OpenCode's configuration couldn't be read. Check its JSON or JSONC format."
            case .noModels: return "OpenCode has no supported text models. Add an OpenAI-compatible or Anthropic provider with its models."
            case .unknownModel: return "This model is no longer in OpenCode's configuration. Choose another model."
            case .unsafeEndpoint: return "The OpenCode endpoint must use HTTPS, or HTTP on this Mac, without credentials, a query or a fragment in its address."
            case .missingReference: return "An OpenCode environment variable or key file couldn't be read."
            case .missingKey: return "This OpenCode provider has no API key. Add it to OpenCode's configuration or API-key credentials."
            case .unsupportedAuth: return "This OpenCode provider uses a sign-in session. Search needs an API key for it."
            }
        }
    }

    private struct Loaded {
        var values: [String: Any] = [:]
        var keyDirectories: [String: URL] = [:]
        var baseDirectories: [String: URL] = [:]
        let directory: URL
    }

    private struct Entry {
        let model: Model
        let base: URL
        let wire: AIProvider.Wire
        let requestModel: String
        let providerID: String
        let options: [String: Any]
        let keyDirectory: URL
    }

    private static let configLimit = 2 * 1024 * 1024
    private static let keyLimit = 16 * 1024

    static var defaultModel: String { (try? configuredDefault()) ?? "" }

    static var defaultEndpoint: URL? {
        let environment = ProcessInfo.processInfo.environment
        guard let loaded = try? load(files: nil, environment: environment),
              let all = try? entries(loaded, environment: environment) else { return nil }
        let chosen = loaded.values["model"] as? String
        return all.first(where: { $0.model.id == chosen })?.base ?? all.first?.base
    }

    static func catalogue(files: [URL]? = nil,
                          environment: [String: String] = ProcessInfo.processInfo.environment) throws -> [Model] {
        try entries(load(files: files, environment: environment), environment: environment).map(\.model)
    }

    static func configuredDefault(files: [URL]? = nil,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        let loaded = try load(files: files, environment: environment)
        let all = try entries(loaded, environment: environment)
        if let selected = loaded.values["model"] as? String, all.contains(where: { $0.model.id == selected }) { return selected }
        return all[0].model.id
    }

    static func hint(for model: String) -> String? {
        (try? connection(for: model)).map { _ in "From OpenCode" }
    }

    /// Explicit files are fixture-friendly: they never fall back to the
    /// user's real config or auth files. Normal reads merge json then jsonc,
    /// just as OpenCode merges its configuration instead of replacing it.
    static func connection(for model: String, files: [URL]? = nil,
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           authFile: URL? = nil) throws -> Connection {
        let loaded = try load(files: files, environment: environment)
        let all = try entries(loaded, environment: environment)
        let configured = loaded.values["model"] as? String
        let fallback = all.first(where: { $0.model.id == configured })?.model.id ?? all[0].model.id
        let wanted = model.isEmpty ? fallback : model
        guard let selected = all.first(where: { $0.model.id == wanted }) else { throw ReadError.unknownModel }
        var key: String?
        if let raw = selected.options["apiKey"] as? String {
            key = try reference(raw, directory: selected.keyDirectory, environment: environment)
        } else {
            let credentialFile = authFile ?? (files == nil ? defaultAuthFile(environment) : nil)
            if let credentialFile, FileManager.default.fileExists(atPath: credentialFile.path) {
                let auth = try object(data(at: credentialFile, limit: configLimit))
                if let value = auth[selected.providerID] as? [String: Any] {
                    if value["type"] as? String == "api" { key = value["key"] as? String }
                    else { throw ReadError.unsupportedAuth }
                }
            }
        }
        key = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key, key.isEmpty || key.utf8.count > keyLimit || key.rangeOfCharacter(from: .controlCharacters) != nil {
            throw ReadError.missingKey
        }
        guard key != nil || isLoopback(selected.base) else { throw ReadError.missingKey }
        return Connection(id: selected.model.id, base: selected.base, wire: selected.wire, model: selected.requestModel,
                          key: key, name: selected.model.name, providerName: selected.model.providerName)
    }

    private static func load(files: [URL]?, environment: [String: String]) throws -> Loaded {
        let directory = configDirectory(environment)
        var locations = files ?? [directory.appendingPathComponent("opencode.json"), directory.appendingPathComponent("opencode.jsonc")]
        if files == nil, let extra = environment["OPENCODE_CONFIG"], !extra.isEmpty {
            locations.append(expanded(extra, directory: directory, environment: environment))
        }
        var loaded = Loaded(directory: directory), found = false
        for file in locations where FileManager.default.fileExists(atPath: file.path) {
            let value = try object(data(at: file, limit: configLimit))
            loaded.values = merge(loaded.values, value)
            for (providerID, raw) in value["provider"] as? [String: Any] ?? [:] {
                let options = (raw as? [String: Any])?["options"] as? [String: Any] ?? [:]
                if options["apiKey"] != nil { loaded.keyDirectories[providerID] = file.deletingLastPathComponent() }
                if options["baseURL"] != nil { loaded.baseDirectories[providerID] = file.deletingLastPathComponent() }
            }
            found = true
        }
        guard found else { throw ReadError.missingConfiguration }
        return loaded
    }

    private static func entries(_ loaded: Loaded, environment: [String: String]) throws -> [Entry] {
        let providers = loaded.values["provider"] as? [String: Any] ?? [:]
        let disabled = Set(loaded.values["disabled_providers"] as? [String] ?? [])
        let enabled = loaded.values["enabled_providers"] as? [String]
        var result: [Entry] = []
        for providerID in providers.keys.sorted() {
            guard !disabled.contains(providerID), enabled?.contains(providerID) ?? true,
                  !providerID.isEmpty, providerID.utf8.count <= 256, !providerID.contains("/"),
                  let provider = providers[providerID] as? [String: Any]
            else { continue }
            let options = provider["options"] as? [String: Any] ?? [:]
            let package = provider["npm"] as? String ?? provider["package"] as? String ?? ""
            let models = provider["models"] as? [String: Any] ?? [:]
            // An unrelated OpenCode provider (AWS, a signed-in account, a
            // custom package) needn't prevent its supported providers here.
            guard models.values.contains(where: { raw in
                let definition = raw as? [String: Any] ?? [:]
                let override = definition["provider"] as? [String: Any] ?? [:]
                return wire(override["npm"] as? String ?? override["package"] as? String ?? package, providerID: providerID) != nil
            }) else { continue }
            let baseString = options["baseURL"] as? String ?? defaultBase(providerID)
            guard let baseString else { continue }
            let baseDirectory = loaded.baseDirectories[providerID] ?? loaded.directory
            let base = try endpoint(reference(baseString, directory: baseDirectory, environment: environment))
            let providerName = String((provider["name"] as? String ?? providerID).prefix(160))
            let blacklist = Set(provider["blacklist"] as? [String] ?? [])
            let whitelist = provider["whitelist"] as? [String]
            for modelID in models.keys.sorted() {
                guard !modelID.isEmpty, modelID.utf8.count <= 512, modelID.rangeOfCharacter(from: .controlCharacters) == nil,
                      !blacklist.contains(modelID), whitelist?.contains(modelID) ?? true,
                      let definition = models[modelID] as? [String: Any]
                else { continue }
                let override = definition["provider"] as? [String: Any] ?? [:]
                guard let wire = wire(override["npm"] as? String ?? override["package"] as? String ?? package, providerID: providerID) else { continue }
                let requestModel = definition["id"] as? String ?? modelID
                guard !requestModel.isEmpty, requestModel.utf8.count <= 1024,
                      requestModel.rangeOfCharacter(from: .controlCharacters) == nil else { continue }
                let model = Model(id: providerID + "/" + modelID,
                                  name: String((definition["name"] as? String ?? modelID).prefix(200)),
                                  providerName: providerName, host: base.host()?.lowercased() ?? "", origin: origin(base))
                result.append(Entry(model: model, base: base, wire: wire, requestModel: requestModel, providerID: providerID,
                                    options: options, keyDirectory: loaded.keyDirectories[providerID] ?? loaded.directory))
            }
        }
        guard !result.isEmpty else { throw ReadError.noModels }
        return result
    }

    private static func wire(_ package: String, providerID: String) -> AIProvider.Wire? {
        switch package {
        case "@ai-sdk/openai", "@opencode/ai/providers/openai": return .responses
        case "@ai-sdk/openai-compatible", "@opencode/ai/providers/openai-compatible": return .openAI
        case "@ai-sdk/anthropic", "@opencode/ai/providers/anthropic", "@opencode/ai/providers/anthropic-compatible": return .anthropic
        case "@ai-sdk/google", "@opencode/ai/providers/google": return .gemini
        case "":
            switch providerID {
            case "openai": return .responses
            case "anthropic": return .anthropic
            case "google", "gemini": return .gemini
            case "openrouter", "ollama", "lmstudio": return .openAI
            default: return nil
            }
        default: return nil
        }
    }

    private static func defaultBase(_ providerID: String) -> String? {
        switch providerID {
        case "openai": return "https://api.openai.com/v1"
        case "anthropic": return "https://api.anthropic.com/v1"
        case "google", "gemini": return "https://generativelanguage.googleapis.com/v1beta"
        case "openrouter": return "https://openrouter.ai/api/v1"
        case "ollama": return "http://127.0.0.1:11434/v1"
        case "lmstudio": return "http://127.0.0.1:1234/v1"
        default: return nil
        }
    }

    static func endpoint(_ raw: String) throws -> URL {
        guard let parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              let url = parts.url, scheme == "https" || (scheme == "http" && isLoopback(url))
        else { throw ReadError.unsafeEndpoint }
        return url
    }

    static func origin(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        parts.path = ""; parts.query = nil; parts.fragment = nil
        return parts.string ?? ""
    }

    private static func isLoopback(_ url: URL) -> Bool {
        ["127.0.0.1", "::1", "[::1]", "localhost"].contains(url.host()?.lowercased() ?? "")
    }

    private static func configDirectory(_ environment: [String: String]) -> URL {
        if let location = environment["XDG_CONFIG_HOME"], !location.isEmpty { return URL(fileURLWithPath: location).appendingPathComponent("opencode") }
        return homeDirectory(environment).appendingPathComponent(".config/opencode")
    }

    private static func defaultAuthFile(_ environment: [String: String]) -> URL {
        if let location = environment["XDG_DATA_HOME"], !location.isEmpty { return URL(fileURLWithPath: location).appendingPathComponent("opencode/auth.json") }
        return homeDirectory(environment).appendingPathComponent(".local/share/opencode/auth.json")
    }

    private static func homeDirectory(_ environment: [String: String]) -> URL {
        environment["HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private static func expanded(_ path: String, directory: URL, environment: [String: String]) -> URL {
        if path.hasPrefix("~/") { return homeDirectory(environment).appendingPathComponent(String(path.dropFirst(2))) }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return directory.appendingPathComponent(path)
    }

    private static func reference(_ value: String, directory: URL, environment: [String: String]) throws -> String {
        if value.hasPrefix("{env:"), value.hasSuffix("}") {
            let name = String(value.dropFirst(5).dropLast())
            guard !name.isEmpty, let found = environment[name], !found.isEmpty else { throw ReadError.missingReference }
            return found
        }
        if value.hasPrefix("{file:"), value.hasSuffix("}") {
            let path = String(value.dropFirst(6).dropLast())
            guard !path.isEmpty else { throw ReadError.missingReference }
            do {
                let value = try data(at: expanded(path, directory: directory, environment: environment), limit: keyLimit)
                guard let text = String(data: value, encoding: .utf8) else { throw ReadError.missingReference }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch { throw ReadError.missingReference }
        }
        guard !value.contains("{env:"), !value.contains("{file:") else { throw ReadError.missingReference }
        return value
    }

    private static func data(at file: URL, limit: Int) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let value = try handle.read(upToCount: limit + 1) ?? Data()
            guard value.count <= limit else { throw ReadError.invalidConfiguration }
            return value
        } catch { throw ReadError.invalidConfiguration }
    }

    private static func merge(_ first: [String: Any], _ next: [String: Any]) -> [String: Any] {
        var merged = first
        for (key, value) in next {
            if let before = merged[key] as? [String: Any], let after = value as? [String: Any] { merged[key] = merge(before, after) }
            else { merged[key] = value }
        }
        return merged
    }

    /// Strip comments only outside strings, then trailing commas outside
    /// strings. URLs and an escaped quote inside a key remain byte-for-byte.
    private static func object(_ data: Data) throws -> [String: Any] {
        var bytes = Array(data), index = 0, quoted = false, escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 47, index + 1 < bytes.count, bytes[index + 1] == 47 {
                bytes[index] = 32; index += 1
                while index < bytes.count, bytes[index] != 10, bytes[index] != 13 { bytes[index] = 32; index += 1 }
                continue
            } else if byte == 47, index + 1 < bytes.count, bytes[index + 1] == 42 {
                bytes[index] = 32; bytes[index + 1] = 32; index += 2
                var closed = false
                while index + 1 < bytes.count {
                    if bytes[index] == 42, bytes[index + 1] == 47 {
                        bytes[index] = 32; bytes[index + 1] = 32; index += 2; closed = true; break
                    }
                    if bytes[index] != 10, bytes[index] != 13 { bytes[index] = 32 }
                    index += 1
                }
                guard closed else { throw ReadError.invalidConfiguration }
                continue
            }
            index += 1
        }
        quoted = false; escaped = false
        for position in bytes.indices {
            let byte = bytes[position]
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 44 {
                var next = position + 1
                while next < bytes.count, [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                if next < bytes.count, bytes[next] == 93 || bytes[next] == 125 { bytes[position] = 32 }
            }
        }
        guard let value = (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any] else { throw ReadError.invalidConfiguration }
        return value
    }
}
