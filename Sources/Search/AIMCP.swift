import Foundation
import Combine
import Darwin

/// A private, local stdio connection. Server commands come from Search's
/// integration code, never from an assistant response or a visited page.
@MainActor
final class AIMCP: ObservableObject {
    struct Tool {
        let name: String
        let description: String
        let inputSchema: [String: Any]
    }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    @Published private(set) var progress = ""
    private(set) var tools: [Tool] = []
    private(set) var diagnostic = ""
    private(set) var processID: pid_t = 0
    private(set) var lastExitStatus: Int32?
    private let executable: URL
    private let arguments: [String]
    private let workspace: URL
    private let scratch: URL
    private let environment: [String: String]
    private let extraReadRoots: [URL]
    private let searchPaths: [URL]
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var carry = Data()
    private var generation = UUID()
    private var nextID = 1
    private let writer = DispatchQueue(label: "Search.AIMCP.write", qos: .userInitiated)
    private final class WireEpoch: @unchecked Sendable {
        private let lock = NSLock()
        private var live = true
        func cancel() { lock.lock(); live = false; lock.unlock() }
        var active: Bool { lock.lock(); defer { lock.unlock() }; return live }
    }
    private var wire = WireEpoch()
    private var rootIdentity: AIChildProcesses.Identity?
    private var ownedDescendants = Set<AIChildProcesses.Identity>()
    private var descendantsTimer: Timer?
    private let cleanups = DispatchGroup()
    private var disposed = false
    private var ready = false
    private var starting: Task<[Tool], Error>?
    private struct Pending {
        let continuation: CheckedContinuation<[String: Any], Error>
        let deadline: Task<Void, Never>
    }
    private var pending: [Int: Pending] = [:]
    // REA prepares replies within a ten MiB transport budget. This also
    // bounds unterminated output and non-JSON stdout from a broken child.
    private let frameLimit = 10 * 1024 * 1024
    var requestTimeout: TimeInterval = 180

    init(executable: URL, arguments: [String], workspace: URL, scratch: URL,
         environment: [String: String] = [:], extraReadRoots: [URL] = [], searchPaths: [URL] = []) {
        self.executable = executable; self.arguments = arguments
        self.workspace = workspace; self.scratch = scratch; self.environment = environment
        self.extraReadRoots = extraReadRoots
        self.searchPaths = searchPaths
    }

    func start() async throws -> [Tool] {
        guard !disposed else { throw Failure(message: "This local tool connection has been disposed.") }
        if ready, processID != 0 { return tools }
        if let starting { return try await starting.value }
        let work = Task { @MainActor in try await self.connect() }
        starting = work
        defer { starting = nil }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: {
            work.cancel()
            Task { @MainActor [weak self] in self?.stop() }
        })
    }

    private func connect() async throws -> [Tool] {
        await withCheckedContinuation { continuation in cleanups.notify(queue: .global(qos: .utility)) { continuation.resume() } }
        try Task.checkCancellation()
        guard !disposed else { throw CancellationError() }
        try launch()
        let run = generation
        do {
            let initialized = try await request("initialize", params: [
                "protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                "clientInfo": ["name": "Search", "version": "1"]
            ])
            guard generation == run, processID != 0 else { throw CancellationError() }
            guard initialized["protocolVersion"] is String else {
                throw Failure(message: "The local tool server did not complete MCP initialization.")
            }
            try notify("notifications/initialized", params: [:])
            var catalogue: [Tool] = [], names = Set<String>(), cursors = Set<String>()
            var cursor: String?
            repeat {
                try Task.checkCancellation()
                var params: [String: Any] = [:]
                if let cursor { params["cursor"] = cursor }
                let page = try await request("tools/list", params: params)
                guard generation == run, processID != 0 else { throw CancellationError() }
                guard let records = page["tools"] as? [[String: Any]] else {
                    throw Failure(message: "The local tool server returned an invalid tool catalogue.")
                }
                for record in records {
                    guard let name = record["name"] as? String,
                          name.range(of: #"^[A-Za-z0-9_.-]{1,128}$"#, options: .regularExpression) != nil,
                          names.insert(name).inserted,
                          let schema = record["inputSchema"] as? [String: Any] else {
                        throw Failure(message: "The local tool catalogue contains an invalid or duplicate tool.")
                    }
                    catalogue.append(Tool(name: name, description: record["description"] as? String ?? "", inputSchema: schema))
                }
                guard catalogue.count <= 4_000, cursors.count < 100 else {
                    throw Failure(message: "The local tool catalogue exceeded Search's limit.")
                }
                cursor = page["nextCursor"] as? String
                if let cursor, !cursors.insert(cursor).inserted {
                    throw Failure(message: "The local tool catalogue repeated a page.")
                }
            } while cursor != nil
            guard generation == run, processID != 0 else { throw CancellationError() }
            tools = catalogue; ready = true
            return catalogue
        } catch { stop(); throw error }
    }

    func call(name: String, arguments: [String: Any]) async throws -> String {
        try Task.checkCancellation()
        _ = try await start()
        guard tools.contains(where: { $0.name == name }) else {
            throw Failure(message: "This tool was not advertised by the local server.")
        }
        let result = try await request("tools/call", params: ["name": name, "arguments": arguments], progress: true)
        if result["isError"] as? Bool == true {
            let content = result["content"] as? [[String: Any]] ?? []
            let message = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            throw Failure(message: String((message.isEmpty ? "The local analysis tool reported an error." : message).prefix(4_000)))
        }
        if let structured = result["structuredContent"] as? [String: Any] {
            return try Self.json(structured)
        }
        if let content = result["content"] as? [[String: Any]] {
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            if !text.isEmpty { return text }
        }
        return try Self.json(result)
    }

    private func request(_ method: String, params: [String: Any], progress tracksProgress: Bool = false) async throws -> [String: Any] {
        try Task.checkCancellation()
        let id = nextID; nextID += 1
        var params = params
        if tracksProgress { params["_meta"] = ["progressToken": String(id)] }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(max(0.01, self?.requestTimeout ?? 180) * 1_000_000_000)) }
                    catch { return }
                    guard let self, self.pending[id] != nil else { return }
                    self.cancel(id, reason: "The local analysis exceeded its time limit.", error: Failure(message: "The local analysis exceeded its time limit."))
                    self.stop(reason: "The local analysis timed out and was stopped.")
                }
                pending[id] = Pending(continuation: continuation, deadline: deadline)
                do { try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) }
                catch { finish(id, result: .failure(error)) }
                if Task.isCancelled { cancel(id, reason: "The analysis was cancelled.") }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel(id, reason: "The analysis was cancelled.") } })
    }

    private func cancel(_ id: Int, reason: String, error: Error = CancellationError()) {
        guard pending[id] != nil else { return }
        try? notify("notifications/cancelled", params: ["requestId": id, "reason": reason])
        finish(id, result: .failure(error))
    }

    private func notify(_ method: String, params: [String: Any]) throws {
        try send(["jsonrpc": "2.0", "method": method, "params": params])
    }
    private func send(_ object: [String: Any]) throws {
        guard let input, processID != 0 else { throw Failure(message: "The local tool server is stopped.") }
        var data = try JSONSerialization.data(withJSONObject: object)
        guard data.count <= frameLimit else { throw Failure(message: "The local tool request is too large.") }
        data.append(0x0a)
        let encoded = data
        let run = generation
        let wire = wire
        // A server that stops reading stdin must not block the browser's
        // main actor or prevent the request deadline from stopping it.
        writer.async { [weak self] in
            guard wire.active else { return }
            do { try input.write(contentsOf: encoded) }
            catch { Task { @MainActor in
                guard let self, self.generation == run else { return }
                self.stop(reason: "The local tool server stopped accepting requests.")
            } }
        }
    }
    private static func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }

    private func receive(_ bytes: Data, run: UUID) {
        guard run == generation, processID != 0 else { return }
        carry.append(bytes)
        while let newline = carry.firstIndex(of: 0x0a) {
            let frame = carry.prefix(upTo: newline)
            guard frame.count <= frameLimit else { stop(reason: "The local tool response exceeded Search's limit."); return }
            carry.removeSubrange(...newline)
            if frame.isEmpty { continue }
            guard let value = try? JSONSerialization.jsonObject(with: frame) as? [String: Any], value["jsonrpc"] as? String == "2.0" else {
                stop(reason: "The local tool server returned invalid MCP output."); return
            }
            if let method = value["method"] as? String {
                if let requestID = value["id"] {
                    // No sampling, shell commands, elicitation or filesystem
                    // requests can be delegated back into Search.
                    try? send(["jsonrpc": "2.0", "id": requestID, "error": ["code": -32601, "message": "Client method not supported"]])
                } else if method == "notifications/progress", let params = value["params"] as? [String: Any] {
                    let message = params["message"] as? String ?? "Working"
                    progress = String(message.prefix(500))
                }
                continue
            }
            guard let id = value["id"] as? Int else { continue }
            if let error = value["error"] as? [String: Any] {
                finish(id, result: .failure(Failure(message: String((error["message"] as? String ?? "The local tool request failed.").prefix(2_000)))))
            } else if let result = value["result"] as? [String: Any] {
                finish(id, result: .success(result))
            } else { finish(id, result: .failure(Failure(message: "The local tool server returned an invalid reply."))) }
        }
        if carry.count > frameLimit { stop(reason: "The local tool response exceeded Search's limit.") }
    }
    private func finish(_ id: Int, result: Result<[String: Any], Error>) {
        guard let waiter = pending.removeValue(forKey: id) else { return }
        waiter.deadline.cancel(); waiter.continuation.resume(with: result)
    }

    private func launch() throws {
        guard processID == 0 else { return }
        let plan = try AIToolProcess.launchPlan(executable: executable, arguments: arguments,
                                               workspace: workspace, scratch: scratch, environment: environment,
                                               extraReadRoots: extraReadRoots, searchPaths: searchPaths)
        let toChild = Pipe(), fromChild = Pipe(), fromErrors = Pipe()
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, toChild.fileHandleForReading.fileDescriptor, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, fromChild.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, fromErrors.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        posix_spawn_file_actions_addchdir_np(&actions, plan.currentDirectory.path)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var argv = ([plan.executable.path] + plan.arguments).map { strdup($0) } + [nil]
        var envp = plan.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var child: pid_t = 0
        let status = posix_spawn(&child, plan.executable.path, &actions, &attributes, &argv, &envp)
        toChild.fileHandleForReading.closeFile(); fromChild.fileHandleForWriting.closeFile(); fromErrors.fileHandleForWriting.closeFile()
        guard status == 0 else { throw Failure(message: "The local tool server could not be started (\(status)).") }
        guard let identity = AIChildProcesses.captureRoot(child) else {
            kill(-child, SIGKILL); kill(child, SIGKILL)
            let failedChild = child
            DispatchQueue.global(qos: .utility).async {
                var code: Int32 = 0
                while waitpid(failedChild, &code, 0) < 0 && errno == EINTR {}
            }
            throw Failure(message: "The local tool process ownership could not be verified.")
        }
        generation = UUID(); let run = generation
        processID = child
        rootIdentity = identity; wire = WireEpoch(); ownedDescendants = []
        descendantsTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == run, let root = self.rootIdentity else { return }
                self.ownedDescendants.formUnion(AIChildProcesses.descendants(of: root))
                if self.ownedDescendants.count > 1_024 {
                    self.ownedDescendants = Set(self.ownedDescendants.filter(AIChildProcesses.matches).prefix(1_024))
                }
            }
        }
        lastExitStatus = nil
        input = toChild.fileHandleForWriting; output = fromChild.fileHandleForReading; errors = fromErrors.fileHandleForReading
        _ = fcntl(input!.fileDescriptor, F_SETNOSIGPIPE, 1)
        for handle in [output!, errors!] { _ = fcntl(handle.fileDescriptor, F_SETFL, fcntl(handle.fileDescriptor, F_GETFL) | O_NONBLOCK) }
        carry = Data(); progress = ""; diagnostic = ""
        output?.readabilityHandler = { [weak self] handle in
            // FileHandle.read(upToCount:) may wait for the requested count on
            // a persistent pipe. One POSIX read consumes only the ready bytes.
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                let bytes = Data(buffer.prefix(count))
                Task { @MainActor in self?.receive(bytes, run: run) }
            } else if count == 0 { handle.readabilityHandler = nil }
        }
        // Drain stderr so an engine cannot deadlock the protocol. Tool data
        // and diagnostics are never copied to application logs.
        errors?.readabilityHandler = { [weak self] handle in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
            if count == 0 { handle.readabilityHandler = nil }
            else if count > 0 {
                let bytes = Data(buffer.prefix(count))
                Task { @MainActor in
                guard let self, self.generation == run else { return }
                self.diagnostic = String((self.diagnostic + String(decoding: bytes, as: UTF8.self)).suffix(4_000))
            } }
        }
        let spawned = child
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var exit: Int32 = 0
            while waitpid(spawned, &exit, 0) < 0 && errno == EINTR {}
            let status = exit
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(40))
                guard let self, self.generation == run else { return }
                self.lastExitStatus = status
                let signal = status & 0x7f
                let description = signal == 0 ? "exit \((status >> 8) & 0xff)" : "signal \(signal)"
                self.stop(reason: "The local tool server ended (\(description)).")
            }
        }
    }

    func stop() { stop(reason: "The local tool connection was stopped.") }
    /// Permanent disposal belongs to the native backend that owns this private
    /// scratch directory. Ordinary stop leaves it available for reconnection.
    func dispose() {
        guard !disposed else { return }
        disposed = true
        stop()
        let scratch = scratch
        cleanups.notify(queue: .global(qos: .utility)) { try? FileManager.default.removeItem(at: scratch) }
    }
    private func stop(reason: String) {
        generation = UUID()
        processID = 0
        let root = rootIdentity
        var descendants = ownedDescendants
        if let root { descendants.formUnion(AIChildProcesses.descendants(of: root)) }
        rootIdentity = nil; ownedDescendants = []
        descendantsTimer?.invalidate(); descendantsTimer = nil
        wire.cancel()
        ready = false; tools = []; carry.removeAll(); progress = ""
        output?.readabilityHandler = nil; errors?.readabilityHandler = nil
        if let input { writer.async { try? input.close() } }
        try? output?.close(); try? errors?.close()
        input = nil; output = nil; errors = nil
        if let root {
            let cleanups = cleanups
            cleanups.enter()
            AIChildProcesses.stop(root: root, descendants: Array(descendants)) { cleanups.leave() }
        }
        let waiters = pending; pending.removeAll()
        for waiter in waiters.values {
            waiter.deadline.cancel()
            waiter.continuation.resume(throwing: Failure(message: reason))
        }
    }
    deinit {
        wire.cancel(); descendantsTimer?.invalidate()
        let root = rootIdentity
        let descendants = Array(ownedDescendants)
        let input = input
        writer.async { try? input?.close() }
        if let root { AIChildProcesses.stop(root: root, descendants: descendants) }
        output?.readabilityHandler = nil; errors?.readabilityHandler = nil
    }
}
