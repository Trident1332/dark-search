import Foundation
import Combine

/// Optional semantic reads through Serena's free LSP backend. Source files
/// remain read-only; all configuration/index writes stay in private scratch.
@MainActor
final class AISerena: ObservableObject {
    @Published private(set) var status = "Serena has not started."
    private(set) var available = false
    private(set) var languageServers: [String] = []
    private let workspace: URL
    let scratch: URL
    private var client: AIMCP?
    private var tools: [String: AIMCP.Tool] = [:]
    private var loaded = false
    static let allowed: Set<String> = ["get_symbols_overview", "find_symbol", "find_referencing_symbols",
        "find_implementations", "find_declaration", "get_diagnostics_for_file", "get_diagnostics_for_symbol",
        "search_for_pattern", "get_current_config"]

    init(workspace: URL, target: URL? = nil) {
        self.workspace = workspace.resolvingSymlinksInPath().standardizedFileURL
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("search-serena-\(UUID().uuidString)", isDirectory: true)
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Search/Tools/python/serena-agent", isDirectory: true)
        let executable = root.appendingPathComponent("bin/serena")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            status = "The optional local Serena LSP backend is not installed. No package was downloaded."
            return
        }
        do {
            let files = FileManager.default
            try files.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let config = scratch.appendingPathComponent("config", isDirectory: true)
            let project = scratch.appendingPathComponent("project-data", isDirectory: true)
            try files.createDirectory(at: config, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try files.createDirectory(at: project, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let configuration: [String: Any] = ["language_backend": "LSP", "agent_interface": "tools",
                "project_serena_folder_location": project.path, "projects": [self.workspace.path],
                "trusted_project_path_patterns": [String](), "token_count_estimator": "CHAR_COUNT",
                "web_dashboard": false, "web_dashboard_open_on_launch": false, "gui_log_window": false,
                "default_modes": ["planning", "no-onboarding", "no-memories"]]
            try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys]).write(to: config.appendingPathComponent("serena_config.yml"), options: .atomic)
            // Pre-create a host-controlled configuration so a project's own
            // .serena file cannot select a paid backend or activation command.
            languageServers = Self.languages(workspace: self.workspace, target: target)
            let projectConfig: [String: Any] = ["project_name": "Search selected workspace",
                "language_backend": "LSP", "agent_interface": "tools", "read_only": true,
                "language_servers": languageServers,
                "activation_command": NSNull(), "ls_specific_settings": [String: Any](),
                "ls_workspace_folders": ["."], "ignore_all_files_in_gitignore": true]
            try JSONSerialization.data(withJSONObject: projectConfig, options: [.sortedKeys]).write(to: project.appendingPathComponent("project.yml"), options: .atomic)
            let pythonRoot = root.appendingPathComponent("bin/python").resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            let developer = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer")
            let toolchain = developer.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr")
            let sourcekit = toolchain.appendingPathComponent("bin/sourcekit-lsp")
            let inProcess = toolchain.appendingPathComponent("lib/sourcekitdInProc.framework/sourcekitdInProc")
            var wrappers: [URL] = []
            var environment = ["SERENA_HOME": config.path]
            if files.isExecutableFile(atPath: sourcekit.path), files.fileExists(atPath: inProcess.path) {
                let bin = scratch.appendingPathComponent("bin", isDirectory: true)
                try files.createDirectory(at: bin, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let wrapper = bin.appendingPathComponent("sourcekit-lsp")
                // SourceKit's default XPC service runs outside this process.
                // Its supported in-process library preserves the same file
                // and network sandbox for all Swift semantic work.
                let view = scratch.appendingPathComponent("swift-toolchain", isDirectory: true)
                let viewBin = view.appendingPathComponent("usr/bin", isDirectory: true)
                let viewLib = view.appendingPathComponent("usr/lib", isDirectory: true)
                try files.createDirectory(at: viewLib, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try files.createSymbolicLink(at: viewBin, withDestinationURL: toolchain.appendingPathComponent("bin"))
                for library in try files.contentsOfDirectory(at: toolchain.appendingPathComponent("lib"), includingPropertiesForKeys: nil) where library.lastPathComponent != "sourcekitd.framework" {
                    try files.createSymbolicLink(at: viewLib.appendingPathComponent(library.lastPathComponent), withDestinationURL: library)
                }
                // Older Apple toolchains look only for sourcekitd.framework.
                // Keep that ABI path while loading the same trusted in-process
                // implementation, rather than the XPC proxy framework.
                let compatibleFramework = viewLib.appendingPathComponent("sourcekitd.framework", isDirectory: true)
                try files.createDirectory(at: compatibleFramework, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try files.createSymbolicLink(at: compatibleFramework.appendingPathComponent("sourcekitd"), withDestinationURL: inProcess)
                environment["SOURCEKIT_TOOLCHAIN_PATH"] = view.path
                let script = "#!/bin/sh\nexec \(Self.quote(sourcekit.path)) --default-workspace-type compilationDatabase --scratch-path \(Self.quote(scratch.appendingPathComponent("swift-build").path)) --generated-files-path \(Self.quote(scratch.appendingPathComponent("swift-generated").path)) \"$@\"\n"
                try script.write(to: wrapper, atomically: true, encoding: .utf8)
                try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
                wrappers = [bin]
            }
            let languageBins = (wrappers + [root.appendingPathComponent("bin"), toolchain.appendingPathComponent("bin")]).filter {
                var directory: ObjCBool = false
                return files.fileExists(atPath: $0.path, isDirectory: &directory) && directory.boolValue
            }
            let compilerRoots = files.fileExists(atPath: developer.path) ? [developer.deletingLastPathComponent()] : []
            client = AIMCP(executable: executable, arguments: ["start-mcp-server", "--project", self.workspace.path,
                "--context", "ide", "--language-backend", "LSP", "--agent-interface", "tools",
                "--transport", "stdio", "--enable-web-dashboard", "false", "--open-web-dashboard", "false",
                "--enable-gui-log-window", "false", "--log-level", "ERROR", "--tool-timeout", "60"],
                workspace: self.workspace, scratch: scratch,
                environment: environment,
                extraReadRoots: [root, pythonRoot] + compilerRoots, searchPaths: languageBins)
            available = true
            status = "Serena is installed. Semantic reads use the free LSP backend."
        } catch { status = "Serena could not prepare its private local workspace: \(error.localizedDescription)" }
    }
    init(workspace: URL, client: AIMCP, scratch: URL) {
        self.workspace = workspace.resolvingSymlinksInPath().standardizedFileURL
        self.client = client; self.scratch = scratch; available = true
    }
    func definitions() async -> [[String: Any]] {
        if !loaded, let client {
            do {
                tools = Dictionary(uniqueKeysWithValues: try await client.start().filter { Self.allowed.contains($0.name) }.map { ($0.name, $0) })
                loaded = true; status = "Serena connected through its free, read-only LSP backend."
            } catch { status = "Serena LSP could not connect: \(error.localizedDescription)" }
        }
        var result: [[String: Any]] = [["name": "serena__status", "description": "Report the local Serena LSP backend status.",
            "parameters": ["type": "object", "properties": [String: Any](), "additionalProperties": false]]]
        result += tools.values.sorted { $0.name < $1.name }.map {
            ["name": "serena__" + $0.name, "description": $0.description + " Search allows read-only semantic analysis inside the selected workspace. Paid backends, project switching, shell commands and source editing are disabled.", "parameters": $0.inputSchema] as [String: Any]
        }
        return result
    }
    func call(name: String, arguments: [String: Any]) async -> String {
        if name == "serena__status" { return Self.json(["available": available, "status": status, "backend": "LSP", "languageServers": languageServers, "readOnly": true, "network": "blocked"]) }
        guard name.hasPrefix("serena__") else { return Self.json(["error": "Unknown Serena tool."]) }
        let operation = String(name.dropFirst(8))
        guard Self.allowed.contains(operation) else { return Self.json(["error": "This Serena operation is not enabled in Search."]) }
        if !loaded { _ = await definitions() }
        guard let client, tools[operation] != nil else { return Self.json(["error": status]) }
        do {
            try validate(arguments)
            let result = try await client.call(name: operation, arguments: arguments)
            status = "Serena finished \(operation.replacingOccurrences(of: "_", with: " "))."
            return result
        } catch is CancellationError { stop(); status = "Serena analysis cancelled."; return Self.json(["error": status]) }
        catch { status = error.localizedDescription; return Self.json(["error": status]) }
    }
    func stop() { client?.stop(); tools = [:]; loaded = false; status = "Serena stopped." }
    var diagnostic: String { client?.diagnostic ?? "" }

    private func validate(_ object: Any, key: String = "") throws {
        if let object = object as? [String: Any] { for (key, value) in object { try validate(value, key: key) } }
        else if let array = object as? [Any] { for value in array { try validate(value, key: key) } }
        else if let value = object as? String, key.lowercased().contains("path") {
            guard !value.hasPrefix("/"), !value.contains("://"), !value.contains("\0") else { throw AIMCP.Failure(message: "Use a relative file path inside the selected workspace.") }
            let url = workspace.appendingPathComponent(value).resolvingSymlinksInPath().standardizedFileURL
            guard url.path == workspace.path || url.path.hasPrefix(workspace.path + "/") else { throw AIMCP.Failure(message: "This file is outside the selected workspace.") }
        }
    }
    private static func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8), as: UTF8.self)
    }
    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func languages(workspace: URL, target: URL?) -> [String] {
        let known = ["swift": "swift", "py": "python_jedi", "rs": "rust", "go": "go", "js": "typescript", "jsx": "typescript", "ts": "typescript", "tsx": "typescript", "c": "cpp", "h": "cpp", "cpp": "cpp", "java": "java"]
        if let target, let language = known[target.pathExtension.lowercased()] { return [language] }
        var languages: [String: Int] = [:], checked = 0
        let files = FileManager.default.enumerator(at: workspace, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = files?.nextObject() as? URL, checked < 2_000 {
            checked += 1
            if ["node_modules", "vendor", "build", "dist"].contains(url.lastPathComponent) { files?.skipDescendants(); continue }
            if let language = known[url.pathExtension.lowercased()] { languages[language, default: 0] += 1 }
        }
        // Start one language server rather than failing the whole project
        // because an unrelated secondary language needs an uninstalled server.
        return [languages.keys.sorted { a, b in
            if languages[a] == languages[b] { return a < b }
            return languages[a, default: 0] > languages[b, default: 0]
        }.first ?? "python_jedi"]
    }
    deinit {
        if let client { Task { @MainActor in client.dispose() } }
        else { try? FileManager.default.removeItem(at: scratch) }
    }
}
