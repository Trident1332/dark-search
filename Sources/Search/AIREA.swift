import Foundation
import Combine
import CryptoKit

/// The only REA backend Search advertises. No MCP registration, download,
/// shell command, third-party provider configuration or global setup is read.
@MainActor
final class AIREA: ObservableObject {
    struct Runtime {
        let node: URL
        let package: URL
        let hopper: URL?
        let ghidra: GhidraRuntime?
        var entry: URL { package.appendingPathComponent("scripts/rea.mjs") }
    }
    struct GhidraRuntime {
        let installation: URL
        let javaHome: URL
    }
    @Published private(set) var status = "REA has not started."
    private(set) var available = false
    private(set) var commandDescription = ""
    private let workspace: URL
    private let target: URL?
    let scratch: URL
    private var client: AIMCP?
    private var nativeClients: [String: AIMCP] = [:]
    private var nativeScratch: [String: URL] = [:]
    private var advertised: [String: AIMCP.Tool] = [:]
    private var openTarget: URL?
    private var loaded = false
    private(set) var nativeAvailable = false
    private(set) var defaultNativeProvider: String?
    private(set) var nativeProviders: [String] = []
    private var activeNativeProvider: String?
    private var lastProvider: String?
    private var processInspectors: [(file: URL, scratch: URL)] = []
    private var inspectorReady: Set<URL> = []
    private var preparing: [URL: Task<Void, Error>] = [:]
    private var hopperBroker: AIPinnedHopperBroker?
    private var nativeFailure: String?

    init(workspace: URL, target: URL? = nil) {
        self.workspace = workspace.resolvingSymlinksInPath().standardizedFileURL
        self.target = target?.resolvingSymlinksInPath().standardizedFileURL
        // Hopper's owned Unix sockets have a short Darwin path limit.
        scratch = URL(fileURLWithPath: "/private/tmp/search-rea-\(UUID().uuidString.prefix(12))", isDirectory: true)
        do { try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { status = "REA could not create its private analysis folder."; return }
        let bin = scratch.appendingPathComponent("bin", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let unprivilegedPS = bin.appendingPathComponent("ps")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ps"), to: unprivilegedPS)
            // macOS ships ps setuid-root, which Seatbelt cannot spawn. A
            // byte-identical private copy needs no elevated identity to
            // inspect this user's own analysis children.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unprivilegedPS.path)
            processInspectors.append((unprivilegedPS, scratch))
        } catch { status = "REA could not prepare its unprivileged process inspector."; return }
        if let runtime = Self.discoverRuntime() {
            available = true
            let developer = URL(fileURLWithPath: "/Applications/Xcode.app/Contents")
            let license = URL(fileURLWithPath: "/Library/Preferences/com.apple.dt.Xcode.plist")
            let compilerRoots = [developer, license].filter { FileManager.default.fileExists(atPath: $0.path) }
            let reads = [runtime.package.deletingLastPathComponent(), runtime.node.deletingLastPathComponent()] + compilerRoots
            let baseEnvironment = ["REA_MCP_INPUT_SCHEMA_PROFILE": "compact", "REA_MCP_OUTPUT_SCHEMA_PROFILE": "off"]
            if let ghidra = runtime.ghidra {
                // These paths come only from fixed host installation discovery.
                // Ghidra's Java bridge uses a private Unix socket, never TCP.
                var environment = baseEnvironment
                environment["REA_ANALYSIS_PROVIDER"] = "ghidra"
                environment["GHIDRA_INSTALL_DIR"] = ghidra.installation.path
                environment["JAVA_HOME"] = ghidra.javaHome.path
                environment["SEARCH_GHIDRA_ISOLATED"] = "1"
                environment["SEARCH_GHIDRA_WORKSPACE"] = self.workspace.path
                let ghidraClient = AIMCP(executable: runtime.node, arguments: [runtime.entry.path, "mcp"],
                    workspace: self.workspace, scratch: scratch, environment: environment,
                    extraReadRoots: reads + [ghidra.installation, ghidra.javaHome], searchPaths: [bin])
                client = ghidraClient; nativeClients["ghidra"] = ghidraClient; nativeScratch["ghidra"] = scratch
                nativeProviders.append("ghidra")
            }
            let launcher = Self.offlineHopperLauncher()
            let hopperConfigured = runtime.hopper != nil && launcher != nil && Self.validNativePatch(runtime.package) && AIPinnedHopperBroker.validTrustedBridge(runtime.package)
            if hopperConfigured, let hopper = runtime.hopper, let launcher {
                // An optional GUI provider never adds Mach/AppleEvents rights
                // to the default headless process. It has its own MCP root,
                // private scratch, lifecycle and strict host AppleEvent broker.
                let separate = client != nil
                let hopperScratch = separate ? URL(fileURLWithPath: "/private/tmp/search-hop-\(UUID().uuidString.prefix(12))", isDirectory: true) : scratch
                do {
                    var hopperBin = bin
                    var additionalInspector: URL?
                    if separate {
                        try FileManager.default.createDirectory(at: hopperScratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                        hopperBin = hopperScratch.appendingPathComponent("bin", isDirectory: true)
                        try FileManager.default.createDirectory(at: hopperBin, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                        let ps = hopperBin.appendingPathComponent("ps")
                        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ps"), to: ps)
                        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ps.path)
                        additionalInspector = ps
                    }
                    let broker = try AIPinnedHopperBroker(workspace: self.workspace, scratch: hopperScratch,
                        helper: launcher, hopperApplication: hopper, package: runtime.package)
                    var environment = baseEnvironment
                    environment["REA_ANALYSIS_PROVIDER"] = "hopper"
                    environment["HOPPER_LAUNCHER_PATH"] = launcher.path
                    environment["SEARCH_HOPPER_APPLICATION"] = hopper.path
                    environment["SEARCH_HOPPER_ISOLATED"] = "1"
                    environment["SEARCH_HOPPER_WORKSPACE"] = self.workspace.path
                    environment["SEARCH_HOPPER_CONTROL_SOCKET"] = broker.socketURL.path
                    environment["SEARCH_HOPPER_CONTROL_TOKEN"] = broker.token
                    let hopperClient = AIMCP(executable: runtime.node, arguments: [runtime.entry.path, "mcp"],
                        workspace: self.workspace, scratch: hopperScratch, environment: environment,
                        extraReadRoots: reads + [hopper, launcher, broker.readRoot], searchPaths: [hopperBin])
                    hopperBroker = broker; nativeClients["hopper"] = hopperClient; nativeScratch["hopper"] = hopperScratch
                    if let additionalInspector { processInspectors.append((additionalInspector, hopperScratch)) }
                    nativeProviders.append("hopper")
                    if client == nil { client = hopperClient }
                } catch {
                    if separate { try? FileManager.default.removeItem(at: hopperScratch) }
                    nativeFailure = "Optional Hopper is unavailable: \(error.localizedDescription)"
                }
            }
            defaultNativeProvider = nativeProviders.first
            nativeAvailable = defaultNativeProvider != nil
            if client == nil {
                var environment = baseEnvironment
                environment["REA_ANALYSIS_PROVIDER"] = "ghidra"
                client = AIMCP(executable: runtime.node, arguments: [runtime.entry.path, "mcp"],
                    workspace: self.workspace, scratch: scratch, environment: environment, extraReadRoots: reads, searchPaths: [bin])
            }
            commandDescription = "Node · REA 6.7.0 · " + (defaultNativeProvider == "ghidra" ? "Ghidra 12.1.4 headless" : defaultNativeProvider == "hopper" ? "optional existing Hopper" : "static analysis")
            if defaultNativeProvider == "ghidra" {
                status = "REA is installed. Free headless Ghidra is the default native engine; analysis runs locally with network access blocked."
            } else if defaultNativeProvider == "hopper" {
                status = "REA is installed. The optional existing Hopper engine may require macOS Automation permission."
            } else {
                status = "REA is installed for static analysis. Native analysis requires a supported local Ghidra/JDK installation or optional Hopper."
            }
        } else {
            status = "REA 6.7.0 and a compatible local Node runtime were not found. No package was downloaded."
        }
    }

    /// Uses the same sandbox and protocol with a synthetic local server in tests.
    init(workspace: URL, target: URL? = nil, client: AIMCP, scratch: URL, providers: [String] = ["ghidra", "hopper"], nativeLanes: [String: (client: AIMCP, scratch: URL)] = [:]) {
        self.workspace = workspace.resolvingSymlinksInPath().standardizedFileURL
        self.target = target?.resolvingSymlinksInPath().standardizedFileURL
        self.client = client; self.scratch = scratch
        available = true; commandDescription = "Local test fixture"
        nativeProviders = ["ghidra", "hopper"].filter { providers.contains($0) }
        defaultNativeProvider = nativeProviders.first
        nativeAvailable = defaultNativeProvider != nil
        for (provider, lane) in nativeLanes where nativeProviders.contains(provider) {
            nativeClients[provider] = lane.client
            nativeScratch[provider] = lane.scratch.resolvingSymlinksInPath().standardizedFileURL
        }
    }

    func definitions() async -> [[String: Any]] {
        if !loaded, let client {
            do {
                try await prepareInspector()
                let tools = try await client.start()
                if defaultNativeProvider == "hopper" { try hopperBroker?.activate(processID: client.processID) }
                advertised = Dictionary(uniqueKeysWithValues: tools.filter { Self.allowed.contains($0.name) }.map { ($0.name, $0) })
                loaded = true
                status = "REA connected. \(advertised.count) local analysis tools available."
            } catch {
                hopperBroker?.deactivate()
                status = "REA could not connect: \(error.localizedDescription)"
            }
        }
        var definitions: [[String: Any]] = [[
            "name": "rea__status", "description": "Report Search's local REA backend availability and workspace. No analysis is started.",
            "parameters": ["type": "object", "properties": [String: Any](), "additionalProperties": false]
        ]]
        definitions += advertised.values.filter { nativeAvailable || $0.name != "open_binary" }.sorted { $0.name < $1.name }.map { tool in
            var schema = tool.inputSchema
            var description = tool.description
            if tool.name == "open_binary" {
                var properties = schema["properties"] as? [String: Any] ?? [:]
                properties["provider_id"] = ["type": "string", "enum": nativeProviders, "description": "Native engine selected from Search's configured local installations. Omit to use \(defaultNativeProvider ?? "no available engine"). Ghidra is free and headless; Hopper is optional and may require Automation permission."]
                schema["properties"] = properties
            } else if tool.name == "export_evidence_bundle" {
                description = "Export this REA session's complete Evidence bundle into a fresh private Search artifact. Search chooses the destination and returns the path."
                schema = ["type": "object", "properties": [String: Any](), "additionalProperties": false]
            }
            return ["name": "rea__" + tool.name,
                    "description": description + " Search restricts local file paths to the selected workspace, uses only configured Ghidra/Hopper native engines, and blocks target execution and network access.",
                    "parameters": schema] as [String: Any]
        }
        return definitions
    }

    func call(name: String, arguments: [String: Any]) async -> String {
        if name == "rea__status" {
            return Self.json(["available": available, "status": status, "backend": commandDescription,
                              "workspace": workspace.path, "target": target?.path ?? "",
                              "network": "blocked", "nativeProvider": activeNativeProvider ?? lastProvider ?? defaultNativeProvider ?? "unavailable",
                              "defaultNativeProvider": defaultNativeProvider ?? "unavailable", "nativeProviders": nativeProviders,
                              "nativeAvailable": nativeAvailable, "paidServices": "excluded", "optionalHopper": nativeFailure ?? (nativeProviders.contains("hopper") ? "Configured; may require macOS Automation permission." : "Not configured.")])
        }
        guard name.hasPrefix("rea__") else { return Self.json(["error": "Unknown REA tool."]) }
        let operation = String(name.dropFirst(5))
        guard Self.allowed.contains(operation) else { return Self.json(["error": "This REA operation is not enabled in Search."]) }
        if !loaded { _ = await definitions() }
        guard advertised[operation] != nil, let client else { return Self.json(["error": status]) }
        do {
            try Task.checkCancellation()
            var args = arguments
            if operation == "open_binary" {
                openTarget = nil; activeNativeProvider = nil
                guard nativeAvailable else {
                    throw AIMCP.Failure(message: "Opening a target requires Search's configured local Ghidra/JDK installation or optional verified Hopper engine.")
                }
                if args["path"] == nil, let target { args["path"] = target.path }
                if let provider = args["provider_id"] as? String, !nativeProviders.contains(provider) {
                    throw AIMCP.Failure(message: "Search enables only configured Ghidra and optional Hopper providers.")
                }
                if args["provider_id"] == nil { args["provider_id"] = defaultNativeProvider }
                guard args["provider_id"] is String else { throw AIMCP.Failure(message: "Choose a configured local native provider.") }
            }
            // Provider document selectors can name unrelated documents in a
            // GUI. Always use this connection's explicitly opened target.
            args.removeValue(forKey: "document")
            let selectedProvider: String?
            if operation == "open_binary" {
                selectedProvider = args["provider_id"] as? String
            } else if Self.artifactOperations.contains(operation), let owner = try artifactOwner(args) {
                selectedProvider = owner
            } else if Self.nativeOperations.contains(operation) || ["close_binary", "binary_overview"].contains(operation) {
                selectedProvider = activeNativeProvider ?? lastProvider ?? defaultNativeProvider
            } else {
                selectedProvider = lastProvider ?? activeNativeProvider ?? defaultNativeProvider
            }
            try validatePaths(args, provider: selectedProvider)
            if Self.nativeOperations.contains(operation), openTarget == nil {
                throw AIMCP.Failure(message: "Open a selected workspace binary first.")
            }
            if operation == "export_evidence_bundle" {
                // The helper can write only in this private analysis scratch
                // directory. Exporting elsewhere is a separate native action.
                args["path"] = (selectedProvider.flatMap { nativeScratch[$0] } ?? scratch).appendingPathComponent("evidence-\(UUID().uuidString).json").path
                args["overwrite"] = false
            }
            let executing = selectedProvider.flatMap { nativeClients[$0] } ?? client
            if executing !== client {
                try await prepareInspector(forHopper: selectedProvider == "hopper")
                _ = try await executing.start()
            }
            if operation == "open_binary", selectedProvider == "hopper" { try hopperBroker?.activate(processID: executing.processID) }
            status = "REA: \(operation.replacingOccurrences(of: "_", with: " "))"
            let output = try await executing.call(name: operation, arguments: args)
            if operation == "open_binary", let path = args["path"] as? String {
                openTarget = try localURL(path, provider: selectedProvider)
                activeNativeProvider = selectedProvider
            } else if operation == "close_binary" { openTarget = nil; activeNativeProvider = nil }
            // Closing a document does not move its evidence into another
            // process. Keep subsequent ID-based reads/exports on this lane;
            // explicit private artifact paths may select only their owner.
            lastProvider = selectedProvider
            status = "REA finished \(operation.replacingOccurrences(of: "_", with: " "))."
            return output
        } catch is CancellationError {
            stop()
            status = "REA analysis cancelled."
            return Self.json(["error": status])
        } catch {
            status = error.localizedDescription
            return Self.json(["error": status])
        }
    }

    func stop() {
        for task in preparing.values { task.cancel() }
        preparing = [:]
        hopperBroker?.deactivate()
        for running in nativeClients.values { running.stop() }
        client?.stop(); loaded = false; advertised = [:]; openTarget = nil; activeNativeProvider = nil; lastProvider = nil
        status = "REA stopped."
    }
    var diagnostic: String {
        let selected = (activeNativeProvider ?? lastProvider).flatMap { nativeClients[$0] } ?? client
        return selected?.diagnostic ?? ""
    }
    var processID: pid_t { client?.processID ?? 0 }
    private func prepareInspector(forHopper: Bool = false) async throws {
        let inspector = forHopper && defaultNativeProvider == "ghidra" ? processInspectors.last : processInspectors.first
        guard let inspector, !inspectorReady.contains(inspector.file) else { return }
        if let preparing = preparing[inspector.file] { return try await preparing.value }
        let work = Task { @MainActor in
            // Relocated Apple platform signatures are AMFI-killed. An ad-hoc
            // signature grants no entitlement or privilege and accesses no
            // signing key, identity, or Keychain entry.
            let result = try await AIToolProcess.run(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--force", "--sign", "-", inspector.file.path], workspace: workspace, scratch: inspector.scratch, timeout: 15)
            guard result.exitCode == 0 else { throw AIMCP.Failure(message: "REA could not prepare its private process inspector: \(result.stderr.prefix(1_000))") }
            inspectorReady.insert(inspector.file)
        }
        preparing[inspector.file] = work
        defer { preparing[inspector.file] = nil }
        try await work.value
    }

    /// Read-only/static workflows only. Runtime launch, browser connections,
    /// ADB, debugger, Frida, settings changes and shell tools are absent even
    /// if a newer server advertises them.
    static let allowed: Set<String> = [
        "binary_session", "open_binary", "close_binary", "binary_overview", "inspect_artifact",
        "analyze_javascript_application", "trace_application_feature", "trace_javascript_semantics",
        "inspect_analysis_view", "get_evidence_bundle", "export_evidence_bundle", "import_evidence_bundle",
        "list_procedures", "list_names", "list_segments", "list_strings", "search_procedures", "search_strings",
        "procedure_address", "procedure_assembly", "procedure_pseudo_code", "procedure_callees", "procedure_callers",
        "procedure_info", "procedure_references", "read_function_instructions", "read_bytes", "xrefs",
        "resolve_containing_procedure", "inspect_native_instruction", "resolve_native_call_targets",
        "analyze_function", "get_call_graph", "trace_call_path", "get_navigation_context", "inspect_address_context",
        "inspect_managed_artifact", "inspect_go_binary", "inspect_rust_binary", "inspect_pe_resources",
        "inspect_sqlite_database", "compare_artifacts", "compare_functions", "compare_bundles",
        "compare_application_versions", "compare_source_to_bundle", "compare_javascript_export_shapes",
        "get_control_flow_graph", "build_call_path", "list_unknowns"
    ]
    private static let nativeOperations: Set<String> = [
        "list_procedures", "list_names", "list_segments", "list_strings", "search_procedures", "search_strings",
        "procedure_address", "procedure_assembly", "procedure_pseudo_code", "procedure_callees", "procedure_callers",
        "procedure_info", "procedure_references", "read_function_instructions", "read_bytes", "xrefs",
        "resolve_containing_procedure", "inspect_native_instruction", "resolve_native_call_targets", "analyze_function",
        "get_call_graph", "trace_call_path", "get_navigation_context", "inspect_address_context", "get_control_flow_graph"
    ]

    private static let artifactOperations: Set<String> = ["import_evidence_bundle", "inspect_analysis_view", "inspect_artifact", "compare_artifacts"]
    private static func isPathKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return lower == "path" || lower.hasSuffix("_path") || lower.hasSuffix("_paths") || lower == "directory" || lower.hasSuffix("_directory")
    }
    /// Route an artifact to its existing owner rather than granting another
    /// engine access to its scratch. Combining private lanes is rejected.
    private func artifactOwner(_ object: Any) throws -> String? {
        var owners: Set<String> = []
        func visit(_ value: Any, key: String = "") {
            if let dictionary = value as? [String: Any] { for (key, value) in dictionary { visit(value, key: key) } }
            else if let array = value as? [Any] { for value in array { visit(value, key: key) } }
            else if let path = value as? String, Self.isPathKey(key), path.hasPrefix("/"), !path.contains("\0") {
                let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
                for (provider, root) in nativeScratch {
                    let root = root.resolvingSymlinksInPath().standardizedFileURL.path
                    if canonical == root || canonical.hasPrefix(root + "/") { owners.insert(provider) }
                }
            }
        }
        visit(object)
        guard owners.count <= 1 else { throw AIMCP.Failure(message: "Files from separate private analysis sessions cannot be combined in one tool call.") }
        return owners.first
    }
    private func validatePaths(_ object: Any, key: String = "", provider: String?) throws {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                if ["environment", "env", "launcher_path", "java_home", "ghidra_install_dir", "ghidra_command", "rea_ghidra_command"].contains(key.lowercased()) {
                    throw AIMCP.Failure(message: "Analysis runtime paths and environment are selected only by Search.")
                }
                if ["provider_id", "provider"].contains(key), let provider = value as? String, !nativeProviders.contains(provider) {
                    throw AIMCP.Failure(message: "This analysis provider is not enabled in Search.")
                }
                try validatePaths(value, key: key, provider: provider)
            }
        } else if let array = object as? [Any] {
            for value in array { try validatePaths(value, key: key, provider: provider) }
        } else if let value = object as? String {
            if Self.isPathKey(key) { _ = try localURL(value, provider: provider) }
        }
    }
    private func localURL(_ path: String, provider: String?) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("://") else {
            throw AIMCP.Failure(message: "Choose an absolute local path inside the selected workspace.")
        }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let selected = workspace.path
        let scratchPath = (provider.flatMap { nativeScratch[$0] } ?? scratch).resolvingSymlinksInPath().path
        guard url.path == selected || url.path.hasPrefix(selected + "/") || url.path == scratchPath || url.path.hasPrefix(scratchPath + "/") else {
            throw AIMCP.Failure(message: "This file is outside the selected analysis workspace.")
        }
        return url
    }
    private static func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8), as: UTF8.self)
    }

    static func discoverRuntime(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Runtime? {
        let files = FileManager.default
        var packages = [
            home.appendingPathComponent("Library/Application Support/Search/Tools/rea/node_modules/rea-agents"),
            home.appendingPathComponent("Library/Application Support/Search/Tools/REA/node_modules/rea-agents"),
            home.appendingPathComponent("Library/Application Support/Search/Tools/REA/rea-agents"),
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/rea-agents"),
            URL(fileURLWithPath: "/usr/local/lib/node_modules/rea-agents")
        ]
        let cache = home.appendingPathComponent(".npm/_npx", isDirectory: true)
        let entries = (try? files.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
        packages += entries.prefix(1_000).sorted { $0.path < $1.path }.map { $0.appendingPathComponent("node_modules/rea-agents") }
        let package = packages.first { package in
            guard let data = try? Data(contentsOf: package.appendingPathComponent("package.json")), data.count < 100_000,
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  meta["name"] as? String == "rea-agents", meta["version"] as? String == "6.7.0" else { return false }
            return files.fileExists(atPath: package.appendingPathComponent("scripts/rea.mjs").path)
                && files.fileExists(atPath: package.appendingPathComponent("dist/mcp/main.js").path)
        }
        guard let package else { return nil }
        var nodes = [home.appendingPathComponent("Library/Application Support/Search/Tools/REA/node/bin/node"), home.appendingPathComponent("Library/Application Support/Search/Tools/rea/node/bin/node")]
        let nodeVersions = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        let versions = (try? files.contentsOfDirectory(at: nodeVersions, includingPropertiesForKeys: nil)) ?? []
        nodes += versions.filter { version in
            let components = version.lastPathComponent.dropFirst().split(separator: ".").compactMap { Int($0) }
            return components.count == 3 && ((components[0] == 24 && components[1] >= 11) || (components[0] == 22 && components[1] >= 19))
        }.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }.map { $0.appendingPathComponent("bin/node") }
        // No executable is resolved from a page, model response or inherited
        // PATH. Installed runtimes have explicit, host-selected paths.
        guard let node = nodes.first(where: { files.isExecutableFile(atPath: $0.path) }) else { return nil }
        let hopper = [home.appendingPathComponent("Applications/Hopper Disassembler.app"), URL(fileURLWithPath: "/Applications/Hopper Disassembler.app")].first { files.fileExists(atPath: $0.path) }
        return Runtime(node: node.resolvingSymlinksInPath(), package: package.resolvingSymlinksInPath(), hopper: hopper, ghidra: discoverGhidra(home: home))
    }
    /// Fixed local installations only; never inherited PATH, environment,
    /// model arguments, global REA configuration or package acquisition.
    static func discoverGhidra(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> GhidraRuntime? {
        let files = FileManager.default
        let installs = [home.appendingPathComponent("Applications/ghidra_12.1.4_PUBLIC"), URL(fileURLWithPath: "/Applications/ghidra_12.1.4_PUBLIC")]
        guard let installation = installs.first(where: { root in
            let properties = root.appendingPathComponent("Ghidra/application.properties")
            guard let data = try? Data(contentsOf: properties), data.count < 100_000,
                  let text = String(data: data, encoding: .utf8), text.components(separatedBy: .newlines).contains("application.version=12.1.4"),
                  files.isExecutableFile(atPath: root.appendingPathComponent("support/analyzeHeadless").path) else { return false }
            #if arch(arm64)
            let native = "mac_arm_64"
            #else
            let native = "mac_x86_64"
            #endif
            return ["Ghidra/Features/Decompiler/build/os/\(native)/decompile", "Ghidra/Features/Decompiler/os/\(native)/decompile"].contains { files.isExecutableFile(atPath: root.appendingPathComponent($0).path) }
        }) else { return nil }
        let homes = ["/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home", "/opt/homebrew/opt/openjdk@26/libexec/openjdk.jdk/Contents/Home", "/usr/local/opt/openjdk/libexec/openjdk.jdk/Contents/Home", "/usr/local/opt/openjdk@26/libexec/openjdk.jdk/Contents/Home"].map { URL(fileURLWithPath: $0) }
        guard let javaHome = homes.first(where: { files.isExecutableFile(atPath: $0.appendingPathComponent("bin/java").path) }) else { return nil }
        return GhidraRuntime(installation: installation.resolvingSymlinksInPath(), javaHome: javaHome.resolvingSymlinksInPath())
    }
    private static func offlineHopperLauncher() -> URL? {
        let locations = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/search-hopper-offline-launcher"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Search/Tools/rea/search-hopper-offline-launcher")]
        return locations.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    deinit {
        hopperBroker?.invalidate()
        let clients = Array(nativeClients.values) + (client.map { [$0] } ?? [])
        if !clients.isEmpty { Task { @MainActor in for client in clients { client.dispose() } } }
        else { try? FileManager.default.removeItem(at: scratch) }
    }
    static func validNativePatch(_ package: URL) -> Bool {
        let marker = package.appendingPathComponent(".search-patches/manifest.json")
        guard let data = try? Data(contentsOf: marker), data.count < 100_000,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["format"] as? String == "search-rea-runtime-1", value["version"] as? String == "6.7.0",
              value["patch"] as? String == "search-private-hopper-isolation-2",
              let hashes = value["files"] as? [String: String] else { return false }
        let expected = ["dist/process/HopperLease.js", "dist/hopper/HopperClient.js", "dist/hopper/BridgeLauncher.js",
            "dist/mcp/main-Cx-Z7m_n.js", "dist/cli-runtime/SharedStartupAttempt-BxKyf3Uv.js", "dist/cli-runtime/binary-CWVNJhAC.js"]
        return expected.allSatisfy { relative in
            guard let expected = hashes[relative], let bytes = try? Data(contentsOf: package.appendingPathComponent(relative)) else { return false }
            return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == expected
        }
    }
}
