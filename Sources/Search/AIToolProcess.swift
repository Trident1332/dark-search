import Foundation
import Darwin

/// A single, offline child process. No shell, inherited credentials, or unsandboxed fallback.
enum AIToolProcess {
    struct Result {
        let output: String
        let stderr: String
        let exitCode: Int32
    }
    struct LaunchPlan {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let currentDirectory: URL
    }
    enum Failure: LocalizedError {
        case unavailable, invalidPath, invalidEnvironment, launch(Int32), timedOut, cancelled, outputLimit
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Offline tool sandbox is unavailable. The tool was not run."
            case .invalidPath: return "The selected tool or workspace path is unavailable or unsafe."
            case .invalidEnvironment: return "The tool requested an unsupported environment setting."
            case .launch: return "The offline tool could not be started."
            case .timedOut: return "The tool exceeded its time limit and was stopped."
            case .cancelled: return "The tool was cancelled."
            case .outputLimit: return "The tool exceeded its output limit and was stopped. Narrow the request."
            }
        }
    }
    static var sandboxAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") }
    static func canonicalURL(_ url: URL) throws -> URL {
        guard let pointer = realpath(url.path,nil) else { throw Failure.invalidPath }
        defer { free(pointer) }
        // Do not call Foundation's resolvingSymlinksInPath/standardizedFileURL:
        // on macOS it can turn the kernel's /private/var back into /var.
        return URL(fileURLWithPath:String(cString:pointer))
    }

    private struct NativeGhidraContext {
        let installation: URL
        let javaHome: URL
    }

    /// The host can select these existing runtimes, but neither the model nor
    /// a provider's environment may expand the filesystem or IPC boundary.
    private static func guardedNativeGhidraContext(_ extra: [String: String], workspace: URL, scratch: URL) throws -> NativeGhidraContext? {
        let keys = ["SEARCH_GHIDRA_ISOLATED", "SEARCH_GHIDRA_WORKSPACE", "GHIDRA_INSTALL_DIR", "JAVA_HOME"]
        guard keys.contains(where: { extra[$0] != nil }) else { return nil }
        let files = FileManager.default, home = files.homeDirectoryForCurrentUser
        let installations = [home.appendingPathComponent("Applications/ghidra_12.1.4_PUBLIC"), URL(fileURLWithPath: "/Applications/ghidra_12.1.4_PUBLIC")]
        let javaHomes = ["/opt/homebrew", "/usr/local"].flatMap { prefix in
            ["openjdk", "openjdk@26"].map { URL(fileURLWithPath: "\(prefix)/opt/\($0)/libexec/openjdk.jdk/Contents/Home") }
        }
        var information = stat()
        guard extra["SEARCH_GHIDRA_ISOLATED"] == "1", extra["REA_ANALYSIS_PROVIDER"] == "ghidra",
              !extra.keys.contains(where: { $0.hasPrefix("SEARCH_HOPPER_") || $0 == "HOPPER_LAUNCHER_PATH" }),
              let selectedWorkspace = extra["SEARCH_GHIDRA_WORKSPACE"],
              try canonicalURL(URL(fileURLWithPath: selectedWorkspace)) == workspace,
              let selectedInstallation = extra["GHIDRA_INSTALL_DIR"],
              let installation = try? canonicalURL(URL(fileURLWithPath: selectedInstallation)),
              installation.lastPathComponent == "ghidra_12.1.4_PUBLIC",
              installations.contains(where: { (try? canonicalURL($0)) == installation }),
              let selectedJava = extra["JAVA_HOME"], let javaHome = try? canonicalURL(URL(fileURLWithPath: selectedJava)),
              javaHome.path.hasPrefix("/opt/homebrew/Cellar/") || javaHome.path.hasPrefix("/usr/local/Cellar/"),
              javaHomes.contains(where: { (try? canonicalURL($0)) == javaHome }),
              files.isExecutableFile(atPath: installation.appendingPathComponent("support/analyzeHeadless").path),
              files.isExecutableFile(atPath: javaHome.appendingPathComponent("bin/java").path),
              lstat(scratch.path, &information) == 0, information.st_mode & S_IFMT == S_IFDIR,
              information.st_uid == getuid(), information.st_mode & 0o777 == 0o700,
              scratch.path.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,47,95].contains($0) })
        else { throw Failure.invalidEnvironment }
        return NativeGhidraContext(installation: installation, javaHome: javaHome)
    }

    /// The MCP host can reuse this plan for its longer-lived stdio connection.
    /// Extra roots and environment are host configuration, never model-supplied options.
    static func launchPlan(executable: URL, arguments: [String], workspace: URL, scratch: URL,
                           environment extra: [String: String] = [:], extraReadRoots: [URL] = [], searchPaths: [URL] = []) throws -> LaunchPlan {
        guard sandboxAvailable else { throw Failure.unavailable }
        let files = FileManager.default
        let workspace = try canonicalURL(workspace)
        let scratch = try canonicalURL(scratch)
        let executable = try canonicalURL(executable)
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: workspace.path, isDirectory: &isDirectory), isDirectory.boolValue,
              files.fileExists(atPath: scratch.path, isDirectory: &isDirectory), isDirectory.boolValue,
              files.isExecutableFile(atPath: executable.path), !arguments.contains(where: { $0.utf8.contains(0) }),
              arguments.count < 256, arguments.reduce(0, { $0 + $1.utf8.count }) < 256_000 else { throw Failure.invalidPath }
        let permitted = Set(["REA_ANALYSIS_PROVIDER", "REA_MCP_TOOL_FAMILIES", "REA_MCP_INPUT_SCHEMA_PROFILE",
            "REA_MCP_OUTPUT_SCHEMA_PROFILE", "REA_HOPPER_COMMAND", "HOPPER_LAUNCHER_PATH", "REA_JADX_MCP_JAR",
            "REA_KUNA_COMMAND", "REA_WABT_BIN_DIRECTORY", "GHIDRA_INSTALL_DIR", "JAVA_HOME", "SERENA_HOME", "SOURCEKIT_TOOLCHAIN_PATH",
            "SEARCH_GHIDRA_ISOLATED", "SEARCH_GHIDRA_WORKSPACE",
            "SEARCH_HOPPER_APPLICATION", "SEARCH_HOPPER_ISOLATED", "SEARCH_HOPPER_WORKSPACE",
            "SEARCH_HOPPER_CONTROL_SOCKET", "SEARCH_HOPPER_CONTROL_TOKEN",
            "GRYPE_DB_CACHE_DIR", "GRYPE_DB_AUTO_UPDATE", "GRYPE_CHECK_FOR_APP_UPDATE", "GRYPE_DB_VALIDATE_AGE",
            "OSV_SCANNER_LOCAL_DB_CACHE_DIRECTORY", "OSV_SCALIBR_LOCAL_DB_CACHE_DIRECTORY"])
        guard extra.allSatisfy({ permitted.contains($0.key) && !$0.value.utf8.contains(0) && $0.value.count < 4096 }) else { throw Failure.invalidEnvironment }
        let ghidra = try guardedNativeGhidraContext(extra, workspace: workspace, scratch: scratch)
        if extra["SEARCH_HOPPER_CONTROL_SOCKET"] != nil || extra["SEARCH_HOPPER_CONTROL_TOKEN"] != nil {
            guard extra["SEARCH_HOPPER_ISOLATED"] == "1" else { throw Failure.invalidEnvironment }
        }
        var hopperProfile = ""
        if let isolated = extra["SEARCH_HOPPER_ISOLATED"] {
            let home = files.homeDirectoryForCurrentUser
            let helpers = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/search-hopper-offline-launcher"),
                home.appendingPathComponent("Library/Application Support/Search/Tools/rea/search-hopper-offline-launcher")]
            let applications = [home.appendingPathComponent("Applications/Hopper Disassembler.app"),URL(fileURLWithPath:"/Applications/Hopper Disassembler.app")]
            var socketInformation = stat()
            guard isolated == "1", let launcher = extra["HOPPER_LAUNCHER_PATH"], let application = extra["SEARCH_HOPPER_APPLICATION"],
                  let selectedWorkspace = extra["SEARCH_HOPPER_WORKSPACE"],
                  let socketPath = extra["SEARCH_HOPPER_CONTROL_SOCKET"],let token = extra["SEARCH_HOPPER_CONTROL_TOKEN"],
                  token.utf8.count == 64,token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  socketPath == scratch.appendingPathComponent("hopper-events.sock").path,
                  lstat(socketPath,&socketInformation) == 0,socketInformation.st_mode & S_IFMT == S_IFSOCK,
                  socketInformation.st_uid == getuid(),socketInformation.st_mode & 0o077 == 0,
                  try canonicalURL(URL(fileURLWithPath:selectedWorkspace)).path == workspace.path,
                  let helper = try? canonicalURL(URL(fileURLWithPath:launcher)),
                  helpers.contains(where: { (try? canonicalURL($0)) == helper }),
                  let app = try? canonicalURL(URL(fileURLWithPath:application)),
                  applications.contains(where: { (try? canonicalURL($0)) == app }),
                  files.isExecutableFile(atPath:helper.path) else { throw Failure.invalidEnvironment }
            // Only the host-selected managed launcher gets GUI startup and its
            // authenticated scratch-only Unix bridge. AppleEvents are denied
            // for Node, the helper, and Hopper; Search owns the fixed event broker.
            hopperProfile = """
            (allow mach-lookup (global-name "com.apple.system.notification_center") (global-name "com.apple.coreservices.launchservicesd") (global-name "com.apple.windowserver.active") (global-name "com.apple.coreservices.appleevents"))
            (deny appleevent-send)
            (deny lsopen)
            (allow network-bind (local unix-socket (subpath \(quote(scratch.path)))))
            (allow network-inbound (local unix-socket (subpath \(quote(scratch.path)))))
            (allow network-outbound (remote unix-socket (subpath \(quote(scratch.path)))))
            """
        }
        let configuredPaths = try searchPaths.map { path -> String in
            let canonical = try canonicalURL(path).path
            var directory: ObjCBool = false
            guard !canonical.contains(":"), !canonical.contains("\n"), !canonical.contains("\r"),
                  files.fileExists(atPath:canonical,isDirectory:&directory), directory.boolValue else { throw Failure.invalidPath }
            return canonical
        }
        var environment = ["PATH":(configuredPaths + ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"]).joined(separator:":"),
            "HOME":scratch.path, "TMPDIR":scratch.path + "/", "XDG_CACHE_HOME":scratch.path,
            "XDG_CONFIG_HOME":scratch.path, "LANG":"en_US.UTF-8", "LC_ALL":"en_US.UTF-8",
            "NO_COLOR":"1", "CI":"true", "PYTHONDONTWRITEBYTECODE":"1", "GIT_CONFIG_NOSYSTEM":"1", "GIT_CONFIG_GLOBAL":"/dev/null",
            "GIT_TERMINAL_PROMPT":"0", "GIT_OPTIONAL_LOCKS":"0", "GIT_NO_REPLACE_OBJECTS":"1", "SEMGREP_SEND_METRICS":"off",
            "SEMGREP_ENABLE_VERSION_CHECK":"0", "SYFT_CHECK_FOR_APP_UPDATE":"false",
            "GRYPE_DB_AUTO_UPDATE":"false", "GRYPE_CHECK_FOR_APP_UPDATE":"false"]
        environment.merge(extra) { _, new in new }
        if ghidra != nil {
            // JVM probes, LaunchSupport and the headless child all inherit the
            // same private home/cache roots. Values are fixed, never supplied
            // as free-form JVM options by a model or the user's environment.
            environment["JAVA_TOOL_OPTIONS"] = "-Duser.home=\(scratch.path) -Djava.io.tmpdir=\(scratch.path) -Djava.util.prefs.userRoot=\(scratch.path)/java-prefs -Djava.util.prefs.systemRoot=\(scratch.path)/java-system-prefs -XX:-UsePerfData"
        }
        let systemRoots = ["/System", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/share", "/bin", "/sbin",
            "/Library/Apple", "/Library/Frameworks", "/Library/Developer", "/private/var/db/dyld",
            "/opt/homebrew/bin", "/opt/homebrew/lib", "/opt/homebrew/Cellar", "/opt/homebrew/opt",
            "/usr/local/bin", "/usr/local/lib", "/usr/local/Cellar", "/usr/local/opt"]
        var executableRoots = [executable.deletingLastPathComponent().path]
        var ancestor = executable.deletingLastPathComponent()
        while ancestor.path != "/" {
            if ancestor.pathExtension.lowercased() == "app" { executableRoots.append(ancestor.path); break }
            ancestor.deleteLastPathComponent()
        }
        let ghidraRoots = ghidra.map { [$0.installation.path, $0.javaHome.path] } ?? []
        let roots = Array(Set(systemRoots + configuredPaths + [workspace.path, scratch.path] + executableRoots + ghidraRoots + (try extraReadRoots.map { try canonicalURL($0).path })))
        let reads = roots.map { "(subpath \(quote($0)))" }.joined(separator: " ")
        let profile = """
        (version 1)
        (deny default)
        (allow process-fork)
        (allow process-exec)
        (allow signal (target children))
        (allow sysctl-read)
        (allow file-read* \(reads))
        ; libSystem initializes by reading the root directory on current macOS.
        ; This literal permits listing /, never descendants or their contents.
        (allow file-read-data (literal "/"))
        (allow file-read-metadata)
        (allow file-read* (literal "/dev/null") (literal "/dev/urandom") (literal "/dev/random") (literal "/private/etc/localtime") (literal "/private/etc/hosts") (literal "/private/etc/resolv.conf"))
        (allow file-write* (subpath \(quote(scratch.path))) (literal "/dev/null"))
        (deny network*)
        (deny appleevent-send)
        (deny lsopen)
        \(hopperProfile)
        \(ghidra == nil ? "" : """
        (allow network-bind (local unix-socket (subpath \(quote(scratch.path)))))
        (allow network-inbound (local unix-socket (subpath \(quote(scratch.path)))))
        (allow network-outbound (remote unix-socket (subpath \(quote(scratch.path)))))
        """)
        """
        return LaunchPlan(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
            arguments: ["-p", profile, executable.path] + arguments, environment: environment, currentDirectory: workspace)
    }
    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }

    static func run(executable: URL, arguments: [String], workspace: URL, scratch: URL,
                    timeout: TimeInterval = 60, maxBytes: Int = 2_000_000,
                    environment: [String: String] = [:], extraReadRoots: [URL] = [], searchPaths: [URL] = []) async throws -> Result {
        let plan = try launchPlan(executable: executable, arguments: arguments, workspace: workspace, scratch: scratch,
                                  environment: environment, extraReadRoots: extraReadRoots, searchPaths:searchPaths)
        let operation = Operation(plan: plan, timeout: min(300, max(0.1, timeout)), limit: min(8_000_000, max(256, maxBytes)))
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { operation.start($0) }
        }, onCancel: { operation.stop(.cancelled) })
    }

    private final class Operation: @unchecked Sendable {
        let plan: LaunchPlan
        let timeout: TimeInterval
        let limit: Int
        let lock = NSLock()
        var pid: pid_t = 0
        var identity: AIChildProcesses.Identity?
        var ownedDescendants = Set<AIChildProcesses.Identity>()
        var terminationScheduled = false
        let cleanupDone = DispatchSemaphore(value:0)
        var failure: Failure?
        var out = Data(), err = Data()
        var continuation: CheckedContinuation<Result, Error>?
        init(plan: LaunchPlan, timeout: TimeInterval, limit: Int) { self.plan = plan; self.timeout = timeout; self.limit = limit }
        func stop(_ reason: Failure) {
            lock.lock(); if failure == nil { failure = reason }; lock.unlock()
            scheduleTermination()
        }
        private func scheduleTermination() {
            lock.lock()
            guard pid > 0, !terminationScheduled, let identity else { lock.unlock(); return }
            terminationScheduled = true
            let captured = Array(ownedDescendants)
            lock.unlock()
            AIChildProcesses.stop(root:identity,descendants:captured) { self.cleanupDone.signal() }
        }
        func start(_ continuation: CheckedContinuation<Result, Error>) {
            lock.lock(); self.continuation = continuation; let cancelled = failure != nil; lock.unlock()
            if cancelled { finish(status: 0); return }
            DispatchQueue.global(qos: .utility).async { self.launch() }
        }
        func launch() {
            let stdout = Pipe(), stderr = Pipe()
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
            let input = open("/dev/null", O_RDONLY)
            defer { if input >= 0 { close(input) }; posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
            guard input >= 0 else { stop(.launch(errno)); finish(status: 0); return }
            posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO)
            posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
            posix_spawn_file_actions_addchdir_np(&actions, plan.currentDirectory.path)
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_START_SUSPENDED))
            posix_spawnattr_setpgroup(&attributes, 0)
            let argv = ([plan.executable.path] + plan.arguments).map { strdup($0) } + [nil]
            let env = plan.environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { argv.forEach { if let p = $0 { free(p) } }; env.forEach { if let p = $0 { free(p) } } }
            var child: pid_t = 0
            let launched = argv.withUnsafeBufferPointer { argv in env.withUnsafeBufferPointer { env in
                posix_spawn(&child, plan.executable.path, &actions, &attributes, UnsafeMutablePointer(mutating: argv.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!))
            } }
            try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
            guard launched == 0 else { stop(.launch(launched)); finish(status: 0); return }
            guard let root = AIChildProcesses.captureRoot(child) else {
                // Still suspended and unreaped: this is the exact child just
                // spawned, so no reused PID or external target can be hit.
                kill(-child,SIGKILL);var status:Int32=0;_ = waitpid(child,&status,0)
                stop(.launch(EPERM));finish(status:status);return
            }
            lock.lock(); pid = child; identity = root; let stopped = failure; lock.unlock()
            kill(child,SIGCONT)
            if let stopped { stop(stopped) }
            let outputFD = stdout.fileHandleForReading.fileDescriptor, errorFD = stderr.fileHandleForReading.fileDescriptor
            _ = fcntl(outputFD, F_SETFL, O_NONBLOCK); _ = fcntl(errorFD, F_SETFL, O_NONBLOCK)
            defer { try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close() }
            var streams = [pollfd(fd: outputFD, events: Int16(POLLIN | POLLHUP), revents: 0), pollfd(fd: errorFD, events: Int16(POLLIN | POLLHUP), revents: 0)]
            var status: Int32 = 0
            var exited = false
            var exitTime: TimeInterval?
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            var lastSnapshot:TimeInterval=0
            while true {
                let now = ProcessInfo.processInfo.systemUptime
                if !exited && now >= deadline { stop(.timedOut) }
                if !exited && now-lastSnapshot >= 0.2 {
                    let captured = AIChildProcesses.descendants(of:root)
                    lock.lock();ownedDescendants = Set(ownedDescendants.filter(AIChildProcesses.matches));ownedDescendants.formUnion(captured);lock.unlock()
                    lastSnapshot=now
                }
                _ = poll(&streams, nfds_t(streams.count), 30)
                for index in streams.indices where streams[index].fd >= 0 {
                    var buffer = [UInt8](repeating: 0, count: 16_384)
                    while true {
                        let count = Darwin.read(streams[index].fd, &buffer, buffer.count)
                        if count == 0 { streams[index].fd = -1; break }
                        if count < 0 { break }
                        lock.lock()
                        let exceeds = out.count + err.count + count > limit
                        if !exceeds { if index == 1 { err.append(contentsOf: buffer.prefix(count)) } else { out.append(contentsOf: buffer.prefix(count)) } }
                        lock.unlock()
                        if exceeds { stop(.outputLimit); break }
                    }
                }
                if !exited {
                    let waited = waitpid(child, &status, WNOHANG)
                    if waited == child || (waited < 0 && errno != EINTR) {
                        exited = true; exitTime = now; scheduleTermination()
                    }
                }
                if exited && (streams.allSatisfy({ $0.fd < 0 }) || now - (exitTime ?? now) > 0.3) { break }
            }
            cleanupDone.wait()
            finish(status: status)
        }
        func finish(status: Int32) {
            lock.lock(); pid = 0; let failure = failure; let continuation = continuation; self.continuation = nil
            let result = Result(output: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self), exitCode: (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)); lock.unlock()
            if let failure { continuation?.resume(throwing: failure) } else { continuation?.resume(returning: result) }
        }
    }
}
