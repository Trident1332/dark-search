import Combine
import Darwin
import Foundation

/// The route Tor itself uses to reach its relays. Credentials are handed to
/// the child over stdin, never through its command line or a saved torrc.
enum TorUpstream: Equatable, Sendable {
    case httpConnect(host: String, port: UInt16, username: String? = nil, password: String? = nil)
    case socks5(host: String, port: UInt16, username: String? = nil, password: String? = nil)
    /// Tor's HTTPSProxy option means HTTP CONNECT; it does not provide TLS
    /// to the proxy. Keep that distinction rather than weakening the route.
    case httpsConnect(host: String, port: UInt16, username: String? = nil, password: String? = nil)
}

/// A Tor client belonging only to Search. Nothing listens outside loopback,
/// and the client is not ready until its own listener and bootstrap agree.
@MainActor
final class TorRuntime: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting(progress: Int)
        case ready
        case failed(String)
    }

    struct Failure: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    static let shared = TorRuntime()
    @Published private(set) var phase = Phase.idle
    @Published private(set) var port: UInt16?
    var isReady: Bool { phase == .ready && port != nil }
    var onStateChanged: (() -> Void)?

    private let executableURL: URL?
    private let dataFolder: URL?
    private let bootstrapTimeout: TimeInterval
    private var process: Process?
    private var output: Pipe?
    private var input: Pipe?
    private var startup: Task<UInt16, Error>?
    private var upstream: TorUpstream?
    private var generation = UUID()
    private var fragment = ""
    private var announcedPort: UInt16?
    private var bootstrapped = false

    init(executableURL: URL? = nil, dataFolder: URL? = nil, bootstrapTimeout: TimeInterval = 120) {
        self.executableURL = executableURL
        self.dataFolder = dataFolder
        self.bootstrapTimeout = max(0.05, bootstrapTimeout)
    }

    deinit {
        output?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if let process, process.isRunning, process.processIdentifier > 0 { kill(process.processIdentifier, SIGKILL) }
    }

    /// Concurrent requests for the same route share one client. Changing a
    /// route first retires the old process and all of its relay connections.
    func start(upstream fresh: TorUpstream? = nil) async throws -> UInt16 {
        try Task.checkCancellation()
        if upstream == fresh, isReady, let port { return port }
        if upstream == fresh, let startup {
            return try await wait(for: startup, generation: generation)
        }
        retire()
        let id = UUID()
        generation = id
        upstream = fresh
        update(.starting(progress: 0))
        let operation = Task<UInt16, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.launch(upstream: fresh, generation: id)
        }
        startup = operation
        do {
            let result = try await wait(for: operation, generation: id)
            if generation == id { startup = nil }
            return result
        } catch {
            if generation == id { startup = nil }
            throw error
        }
    }

    func stop() {
        retire()
        update(.idle)
    }

    private func wait(for operation: Task<UInt16, Error>, generation id: UUID) async throws -> UInt16 {
        try await withTaskCancellationHandler {
            let result = try await operation.value
            try Task.checkCancellation()
            guard generation == id else { throw CancellationError() }
            return result
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                self.stop()
            }
        }
    }

    private func launch(upstream: TorUpstream?, generation id: UUID) async throws -> UInt16 {
        do {
            let executable = try executable()
            let folder = try privateFolder()
            let configuration = try configuration(folder: folder, upstream: upstream)
            try Task.checkCancellation()
            guard generation == id else { throw CancellationError() }

            let child = Process()
            let incoming = Pipe()
            let outgoing = Pipe()
            _ = fcntl(incoming.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            child.executableURL = executable
            child.arguments = ["--defaults-torrc", "/dev/null", "-f", "-"]
            child.standardInput = incoming
            child.standardOutput = outgoing
            child.standardError = outgoing
            // Do not inherit an injected dylib or a caller's Tor settings.
            child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
            let descriptor = outgoing.fileHandleForReading.fileDescriptor
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            outgoing.fileHandleForReading.readabilityHandler = { [weak self] _ in
                var storage = [UInt8](repeating: 0, count: 16_384)
                let count = storage.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                guard count > 0 else { return }
                // Only fixed Tor status notices are interpreted. Raw log text
                // is never retained in a file or surfaced in an error.
                let bounded = Data(storage.prefix(count))
                Task { @MainActor in self?.consume(bounded, generation: id) }
            }
            child.terminationHandler = { [weak self] ended in
                let status = ended.terminationStatus
                Task { @MainActor in self?.exited(status: status, generation: id) }
            }
            process = child
            input = incoming
            output = outgoing
            do { try child.run() }
            catch { throw Failure(message: "Tor could not be launched. Reinstall Search's Tor component and try again") }
            incoming.fileHandleForReading.closeFile()
            outgoing.fileHandleForWriting.closeFile()
            do { try incoming.fileHandleForWriting.write(contentsOf: Data(configuration.utf8)) }
            catch { throw Failure(message: "Tor could not read its private configuration. Try connecting again") }
            try? incoming.fileHandleForWriting.close()

            let deadline = Date().addingTimeInterval(bootstrapTimeout)
            while generation == id {
                try Task.checkCancellation()
                if isReady, let port { return port }
                if case .failed(let message) = phase { throw Failure(message: message) }
                if Date() >= deadline {
                    throw Failure(message: "Tor did not finish connecting in time. Check the proxy or network and try again")
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw CancellationError()
        } catch {
            guard generation == id else { throw CancellationError() }
            if error is CancellationError || Task.isCancelled {
                retire()
                update(.idle)
                throw CancellationError()
            }
            let message = (error as? Failure)?.message ?? "Tor could not connect. Check the proxy and try again"
            retire()
            update(.failed(message))
            throw Failure(message: message)
        }
    }

    private func consume(_ bytes: Data, generation id: UUID) {
        guard generation == id, process?.isRunning == true else { return }
        fragment += String(decoding: bytes, as: UTF8.self)
        while let newline = fragment.firstIndex(of: "\n") {
            let line = String(fragment[..<newline])
            fragment.removeSubrange(...newline)
            consume(line)
        }
        if fragment.utf8.count > 32_768 { fragment = "" }
    }

    private func consume(_ line: String) {
        guard let bracket = line.firstIndex(of: "["),
              line[bracket...].hasPrefix("[notice] ") else { return }
        let notice = line[line.index(bracket, offsetBy: "[notice] ".count)...]
        if notice.hasPrefix("Socks listener listening on port ") {
            let digits = notice.dropFirst("Socks listener listening on port ".count).prefix(while: { $0.isASCII && $0.isNumber })
            if let found = UInt16(digits), found > 0 { announcedPort = found }
        } else if notice.hasPrefix("Opened Socks listener connection (ready) on 127.0.0.1:") {
            let digits = notice.dropFirst("Opened Socks listener connection (ready) on 127.0.0.1:".count).prefix(while: { $0.isASCII && $0.isNumber })
            if let found = UInt16(digits), found > 0 { announcedPort = found }
        }
        if notice.hasPrefix("Bootstrapped ") {
            let suffix = notice.dropFirst("Bootstrapped ".count)
            let digits = suffix.prefix(while: { $0.isASCII && $0.isNumber })
            if suffix.dropFirst(digits.count).hasPrefix("%"), let progress = Int(digits), (0...100).contains(progress) {
                if progress == 100 { bootstrapped = true }
                if case .starting(let before) = phase, progress > before { update(.starting(progress: progress)) }
            }
        }
        if bootstrapped, let announcedPort {
            port = announcedPort
            update(.ready)
        }
    }

    private func exited(status: Int32, generation id: UUID) {
        guard generation == id else { return }
        let wasReady = isReady
        // A starting caller receives this failure from its polling task.
        // Canceling that task here would hide the useful error as cancellation.
        if startup == nil { retire() }
        else {
            port = nil
            output?.fileHandleForReading.readabilityHandler = nil
            process?.terminationHandler = nil
        }
        update(.failed(wasReady
            ? "Tor disconnected. Connect again to continue opening onion sites"
            : "Tor stopped before it finished connecting (code \(status)). Check the proxy and try again"))
    }

    private func update(_ fresh: Phase) {
        guard phase != fresh else { return }
        phase = fresh
        onStateChanged?()
    }

    private func retire() {
        generation = UUID()
        startup?.cancel()
        startup = nil
        port = nil
        announcedPort = nil
        bootstrapped = false
        upstream = nil
        fragment = ""
        output?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if let process, process.isRunning {
            let pid = process.processIdentifier
            process.terminate()
            // A route change must not give an old Tor client time to continue
            // using connections through the previous upstream proxy.
            if pid > 0, process.isRunning { kill(pid, SIGKILL) }
        }
        try? input?.fileHandleForWriting.close()
        try? output?.fileHandleForReading.close()
        input = nil
        output = nil
        process = nil
    }

    private func executable() throws -> URL {
        if let executableURL {
            guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
                throw Failure(message: "The configured Tor component is not executable")
            }
            return executableURL
        }
        guard !Store.testing else {
            throw Failure(message: "A test must provide its own Tor component; the real network client was not started")
        }
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("Tor/tor")]
            + ["/opt/homebrew/bin/tor", "/usr/local/bin/tor",
               "/Applications/Tor Browser.app/Contents/MacOS/Tor/tor"].map { URL(fileURLWithPath: $0) }
        guard let found = candidates.compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw Failure(message: "Tor's network component is unavailable. Reinstall Search or install Tor and try again")
        }
        return found
    }

    private func privateFolder() throws -> URL {
        let folder = dataFolder ?? Store.folder.appendingPathComponent("Tor", isDirectory: true)
        let files = FileManager.default
        if let attributes = try? files.attributesOfItem(atPath: folder.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw Failure(message: "Tor's private data folder must not be a symbolic link")
        }
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        } catch { throw Failure(message: "Tor's private data folder could not be opened") }
        return folder
    }

    private func configuration(folder: URL, upstream: TorUpstream?) throws -> String {
        var lines = ["ClientOnly 1", "RunAsDaemon 0", "AvoidDiskWrites 1", "SafeLogging 1", "SafeSocks 1", "ClientRejectInternalAddresses 1",
                     "SocksPort 127.0.0.1:auto IsolateSOCKSAuth", "SocksPolicy accept 127.0.0.1/8", "SocksPolicy reject *",
                     "ControlPort 0", "DNSPort 0", "TransPort 0", "ORPort 0", "DirPort 0", "Log notice stdout",
                     "DataDirectory \(try quote(folder.path))", "__OwningControllerProcess \(getpid())"]
        switch upstream {
        case .none: break
        case .httpsConnect:
            throw Failure(message: "Tor cannot connect through a TLS-to-proxy HTTPS server. Use an HTTP CONNECT or SOCKS5 proxy for onion sites")
        case let .httpConnect(host, port, user, password):
            lines.append("HTTPSProxy \(try quote(endpoint(host, port)))")
            if let account = try account(user, password) {
                guard !account.user.contains(":") else { throw Failure(message: "Tor cannot use a proxy name containing a colon") }
                lines.append("HTTPSProxyAuthenticator \(try quote(account.user + ":" + account.password))")
            }
        case let .socks5(host, port, user, password):
            lines.append("Socks5Proxy \(try quote(endpoint(host, port)))")
            if let account = try account(user, password) {
                guard account.user.utf8.count <= 255, account.password.utf8.count <= 255 else {
                    throw Failure(message: "Tor's SOCKS5 proxy name and password must each fit in 255 bytes")
                }
                lines.append("Socks5ProxyUsername \(try quote(account.user))")
                lines.append("Socks5ProxyPassword \(try quote(account.password))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func endpoint(_ raw: String, _ port: UInt16) throws -> String {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]%")
        guard !host.isEmpty, host.utf8.count <= 253, port > 0,
              host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw Failure(message: "Enter a valid upstream proxy address and port before starting Tor")
        }
        let rendered = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(rendered):\(port)"
    }

    private func account(_ user: String?, _ password: String?) throws -> (user: String, password: String)? {
        if user == nil, password == nil { return nil }
        guard let user, !user.isEmpty, let password, !password.isEmpty else {
            throw Failure(message: "Enter the upstream proxy's saved name and password before starting Tor")
        }
        return (user, password)
    }

    private func quote(_ value: String) throws -> String {
        guard value.utf8.count <= 8_192, !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw Failure(message: "Tor could not use an upstream proxy setting")
        }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t") + "\""
    }
}
