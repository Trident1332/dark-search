import AppKit
import CoreServices
import CryptoKit
import Darwin
import Foundation
import Security

/// Native-only AppleEvent bridge. The MCP process has no AppleEvent entitlement
/// in its Seatbelt profile. A socket token alone is never authority: the kernel
/// peer, pinned code, process ancestry, child lifetime and exact bootstrap are
/// all checked before Search sends one fixed event to its owned Hopper child.
@MainActor
final class AIPinnedHopperBroker {
    nonisolated static let vendorBridgeSHA256 = "97ec963352ae396de2e2e331eac84738836a336b57288e0a2c0b2d93fbb82a45"
    static func validTrustedBridge(_ package: URL) -> Bool {
        guard let bytes = try? Data(contentsOf: package.appendingPathComponent("bridge/hopper_bridge.py")), bytes.count < 2_000_000 else { return false }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == vendorBridgeSHA256
    }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    struct Identity: Equatable, Sendable {
        let pid: pid_t
        let parent: pid_t
        let user: uid_t
        let seconds: UInt64
        let microseconds: UInt64
        let executable: String
        static func read(_ pid: pid_t) -> Identity? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_pid == UInt32(pid), info.pbi_uid == getuid(), info.pbi_status != 5 else { return nil }
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
            return Identity(pid: pid, parent: pid_t(info.pbi_ppid), user: info.pbi_uid,
                            seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec,
                            executable: String(cString: path))
        }
    }
    struct Request {
        let helperPID: pid_t
        let hopperPID: pid_t
        let hopperSeconds: UInt64
        let hopperMicroseconds: UInt64
        let target: String
        let bridge: String
        let analysis: Bool
        let loaders: [String]
        let architecture: String?
        static func parse(_ data: Data, token: String) throws -> Request {
            guard data.count <= 16_384,
                  let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(value.keys).isSubset(of: ["version", "token", "helperPID", "hopperPID", "hopperStartedSec", "hopperStartedUsec", "targetPath", "bridgePath", "analysis", "loaders", "architecture"]),
                  integer(value["version"]) == 1,
                  let supplied = value["token"] as? String, secureEqual(supplied, token),
                  let helper = integer(value["helperPID"]), helper > 1, helper <= UInt64(Int32.max),
                  let hopper = integer(value["hopperPID"]), hopper > 1, hopper <= UInt64(Int32.max),
                  let seconds = integer(value["hopperStartedSec"]),
                  let microseconds = integer(value["hopperStartedUsec"]), microseconds < 1_000_000,
                  let target = value["targetPath"] as? String, target.utf8.count < 4096,
                  let bridge = value["bridgePath"] as? String, bridge.utf8.count < 4096,
                  let analysis = value["analysis"] as? NSNumber, CFGetTypeID(analysis) == CFBooleanGetTypeID(),
                  let loaders = value["loaders"] as? [String], loaders.count <= 2,
                  loaders.allSatisfy({ ["Mach-O", "FAT", "ELF", "WinPE"].contains($0) }) else {
                throw Failure(message: "The Hopper control request is invalid or unauthenticated.")
            }
            let architecture = value["architecture"] as? String
            guard value["architecture"] == nil || architecture.map({ ["--intel-32", "--intel-64", "--armv7", "--aarch64"].contains($0) }) == true else {
                throw Failure(message: "The Hopper architecture option is unsupported.")
            }
            return Request(helperPID: pid_t(helper), hopperPID: pid_t(hopper), hopperSeconds: seconds,
                hopperMicroseconds: microseconds, target: target, bridge: bridge, analysis: analysis.boolValue,
                loaders: loaders, architecture: architecture)
        }
        private static func integer(_ value: Any?) -> UInt64? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !number.stringValue.contains("."), !number.stringValue.contains("-"),
                  let result = UInt64(number.stringValue) else { return nil }
            return result
        }
        private static func secureEqual(_ a: String, _ b: String) -> Bool {
            let left = Array(a.utf8), right = Array(b.utf8)
            guard left.count == 64, right.count == 64 else { return false }
            return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
        }
    }
    private final class Permit: @unchecked Sendable {
        private let lock = NSLock()
        private var enabled = true
        func revoke() { lock.lock(); enabled = false; lock.unlock() }
        var valid: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
    }
    private struct CodePin {
        let executable: String
        let hash: Data
        let cdHash: Data
        init(_ url: URL) throws {
            executable = try Self.canonical(url.path)
            let bytes = try Data(contentsOf: URL(fileURLWithPath: executable), options: .mappedIfSafe)
            guard bytes.count <= 100_000_000 else { throw Failure(message: "The pinned native helper is too large.") }
            hash = Data(SHA256.hash(data: bytes))
            var code: SecStaticCode?
            let created = SecStaticCodeCreateWithPath(URL(fileURLWithPath: executable) as CFURL, [], &code)
            guard created == errSecSuccess, let code else { throw Failure(message: "The native executable's code identity is unavailable (\(created)).") }
            let valid = SecStaticCodeCheckValidity(code, [], nil)
            guard valid == errSecSuccess, let value = Self.signingHash(code) else { throw Failure(message: "The native executable's code signature is invalid (\(valid)): \(url.lastPathComponent).") }
            cdHash = value
        }
        func matches(_ process: Identity) -> Bool {
            guard process.executable == executable,
                  let bytes = try? Data(contentsOf: URL(fileURLWithPath: executable), options: .mappedIfSafe),
                  Data(SHA256.hash(data: bytes)) == hash else { return false }
            var code: SecCode?
            guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: process.pid] as CFDictionary, [], &code) == errSecSuccess,
                  let code, SecCodeCheckValidity(code, [], nil) == errSecSuccess,
                  let runningHash = Self.runningHash(code) else { return false }
            return runningHash == cdHash
        }
        private static func runningHash(_ code: SecCode) -> Data? {
            var value: SecStaticCode?
            guard SecCodeCopyStaticCode(code, [], &value) == errSecSuccess, let value else { return nil }
            return signingHash(value)
        }
        private static func signingHash(_ code: SecStaticCode) -> Data? {
            var info: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
            return (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
        }
        private static func canonical(_ path: String) throws -> String { try AIPinnedHopperBroker.canonical(path) }
    }

    let socketURL: URL
    let readRoot: URL
    let token: String
    private let workspace: String
    private let scratch: String
    private let helper: CodePin
    private let hopper: CodePin
    private let trustedBridgePath: String
    private let trustedBridge: Data
    private var root: Identity?
    private var permit = Permit()
    nonisolated private let lifetime = Permit()
    private var launches = 0
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]
    private var busy = false
    private var generation: UInt64 = 0

    init(workspace: URL, scratch: URL, helper: URL, hopperApplication: URL, package: URL, bridgeDigest: String = vendorBridgeSHA256) throws {
        self.workspace = try Self.canonical(workspace.path)
        self.scratch = try Self.canonical(scratch.path)
        self.helper = try CodePin(helper)
        self.hopper = try CodePin(hopperApplication.appendingPathComponent("Contents/MacOS/Hopper Disassembler"))
        trustedBridgePath = try Self.canonical(package.appendingPathComponent("bridge/hopper_bridge.py").path)
        trustedBridge = try Data(contentsOf: URL(fileURLWithPath: trustedBridgePath))
        guard trustedBridge.count > 1000, trustedBridge.count < 2_000_000, SHA256.hash(data: trustedBridge).map({ String(format: "%02x", $0) }).joined() == bridgeDigest else { throw Failure(message: "The trusted Hopper bridge is unavailable.") }
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw Failure(message: "The private Hopper channel could not create a nonce.") }
        token = random.map { String(format: "%02x", $0) }.joined()
        socketURL = URL(fileURLWithPath: self.scratch).appendingPathComponent("hopper-events.sock")
        readRoot = URL(fileURLWithPath: "/private/tmp/search-ae-\(UUID().uuidString.prefix(12))", isDirectory: true)
        try FileManager.default.createDirectory(at: readRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try trustedBridge.write(to: readRoot.appendingPathComponent("hopper_bridge.py"), options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: readRoot.appendingPathComponent("hopper_bridge.py").path)
            try bindSocket()
        } catch {
            try? FileManager.default.removeItem(at: readRoot)
            throw error
        }
    }
    /// Activated only after Search's own MCP handshake has completed. A stopped
    /// or reused PID cannot lend authority to a newly arrived socket peer.
    func activate(processID: pid_t) throws {
        guard lifetime.valid, let value = Identity.read(processID), value.parent == getpid() else { throw Failure(message: "The REA supervisor identity is unavailable.") }
        permit.revoke(); permit = Permit()
        root = value; generation &+= 1
    }
    /// May run directly from an owner's deinit before asynchronous subprocess
    /// disposal. An outstanding TCC request can never restore this authority.
    nonisolated func invalidate() { lifetime.revoke() }
    func deactivate() {
        permit.revoke(); root = nil; generation &+= 1
        for connection in Array(connections.values) { connection.drop() }
        connections = [:]
    }
    private func bindSocket() throws {
        var directory = stat()
        guard lstat(scratch, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
              directory.st_uid == getuid(), directory.st_mode & 0o077 == 0,
              !FileManager.default.fileExists(atPath: socketURL.path) else { throw Failure(message: "The Hopper control directory is not private.") }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(message: "The private Hopper socket could not be created.") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let room = MemoryLayout.size(ofValue: address.sun_path)
        guard socketURL.path.utf8.count < room else { close(fd); throw Failure(message: "The Hopper control socket path is too long.") }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: room) { _ = strlcpy($0, socketURL.path, room) }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(socketURL.path, 0o600) == 0, listen(fd, 4) == 0 else {
            close(fd); unlink(socketURL.path); throw Failure(message: "The private Hopper socket could not be bound.")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.accept() }
        self.source = source; source.resume()
    }
    private func accept() {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        var uid: uid_t = 0, gid: gid_t = 0, pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard lifetime.valid, connections.count < 4, root != nil,
              getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0,
              length == MemoryLayout<pid_t>.size,
              let peer = Identity.read(pid), helper.matches(peer) else { close(fd); return }
        let connection = Connection(fd: fd) { [weak self] data, reply in
            guard let self else { reply(false, "The Hopper session ended."); return }
            self.handle(data, peer: peer, reply: reply)
        } gone: { [weak self] in self?.connections[fd] = nil }
        connections[fd] = connection
    }
    private func handle(_ data: Data, peer: Identity, reply: @escaping (Bool, String?) -> Void) {
        do {
            guard lifetime.valid, !busy, let root else { throw Failure(message: "The Hopper session is inactive or busy.") }
            guard launches < 128 else { throw Failure(message: "Select the analysis folder again to renew the bounded native bridge session.") }
            let request = try Request.parse(data, token: token)
            let child = try Self.authorize(request, peer: peer, root: root, helperExecutable: helper.executable,
                                           hopperExecutable: hopper.executable, lookup: Identity.read)
            guard helper.matches(peer), hopper.matches(child) else { throw Failure(message: "The native process code identity changed.") }
            let target = try Self.canonical(request.target), bridge = try Self.canonical(request.bridge)
            guard target == request.target, bridge == request.bridge,
                  Self.contains(workspace, target) || Self.contains(scratch, target),
                  Self.contains(scratch, bridge), bridge.hasSuffix(".py") else { throw Failure(message: "The native target or bridge left the selected workspace.") }
            try Self.regular(target)
            let bytes = try Self.readBootstrap(bridge)
            let bootstrap = try Self.validateBootstrap(bytes, scratch: scratch, target: target, trustedBridge: trustedBridgePath,
                replacementBridge: readRoot.appendingPathComponent("hopper_bridge.py").path)
            let immutable = readRoot.appendingPathComponent("bootstrap-\(UUID().uuidString).py")
            try Data(bootstrap.utf8).write(to: immutable, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: immutable.path)
            let currentGeneration = generation
            let permit = self.permit, lifetime = self.lifetime
            launches += 1
            busy = true
            // TCC can wait for the user. The UI and MCP pipe reader remain
            // responsive while Search performs this bounded native request.
            Task.detached(priority: .userInitiated) { [self] in
                let result: String?
                do { try Self.dispatch(request, child: child, peer: peer, root: root, immutableBridge: immutable.path, permit: permit, lifetime: lifetime); result = nil }
                catch { result = String(error.localizedDescription.prefix(2_000)) }
                await MainActor.run {
                    self.busy = false
                    guard self.generation == currentGeneration, self.root == root else { reply(false, "The Hopper session ended."); return }
                    reply(result == nil, result)
                }
            }
        } catch { reply(false, String(error.localizedDescription.prefix(2_000))) }
    }
    nonisolated static func authorize(_ request: Request, peer: Identity, root: Identity,
                                     helperExecutable: String, hopperExecutable: String,
                                     lookup: (pid_t) -> Identity?) throws -> Identity {
        guard peer.pid == request.helperPID, peer.user == root.user, peer.executable == helperExecutable,
              lookup(peer.pid) == peer, lookup(root.pid) == root,
              let child = lookup(request.hopperPID), child.parent == peer.pid, child.user == peer.user,
              child.seconds == request.hopperSeconds, child.microseconds == request.hopperMicroseconds,
              child.executable == hopperExecutable else { throw Failure(message: "The Hopper request does not name its live owned child.") }
        var next = peer.parent, seen: Set<pid_t> = [peer.pid, child.pid]
        for _ in 0..<12 {
            if next == root.pid { return child }
            guard seen.insert(next).inserted, let ancestor = lookup(next), ancestor.user == root.user else { break }
            next = ancestor.parent
        }
        throw Failure(message: "The Hopper helper is outside this REA process tree.")
    }
    /// Never map/read a model-influenced file before checking the same open
    /// descriptor's type, link count and size. O_NONBLOCK avoids FIFO/device
    /// hangs if an attacker changes the path; O_NOFOLLOW rejects link swaps.
    nonisolated static func readBootstrap(_ path: String) throws -> Data {
        let limit = 16_384
        guard !path.contains("\0") else { throw Failure(message: "The Hopper bootstrap path is invalid.") }
        let fd = try openBootstrapWithoutSymlinks(path)
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_size >= 0, before.st_size <= limit else { throw Failure(message: "The Hopper bootstrap must be a regular file no larger than 16 KiB.") }
        var result = Data()
        result.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, min(buffer.count, limit + 1 - result.count))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw Failure(message: "The Hopper bootstrap could not be read.") }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= limit else { throw Failure(message: "The Hopper bootstrap exceeds 16 KiB.") }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_mode & S_IFMT == S_IFREG, after.st_nlink == 1,
              after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              after.st_size >= 0, after.st_size <= limit else { throw Failure(message: "The Hopper bootstrap changed while it was being read.") }
        return result
    }

    /// O_NOFOLLOW on the leaf alone cannot protect writable scratch parents.
    /// Walk from a pinned root descriptor and reject every symbolic component.
    nonisolated private static func openBootstrapWithoutSymlinks(_ path: String) throws -> Int32 {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard path.hasPrefix("/"), !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." }) else { throw Failure(message: "The Hopper bootstrap path is invalid.") }
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure(message: "The Hopper bootstrap directory is unavailable.") }
        defer { close(directory) }
        for component in parts.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Failure(message: "The Hopper bootstrap directory cannot contain symbolic links.") }
            close(directory); directory = next
        }
        let file = openat(directory, parts.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw Failure(message: "The Hopper bootstrap must be a bounded regular file, not a symbolic link.") }
        return file
    }

    /// Parse the exact REA 6.7 bootstrap grammar. JSON strings are parsed as
    /// data, never Python source. Search emits a fresh canonical bootstrap
    /// against an immutable host snapshot instead of forwarding scratch code.
    nonisolated static func validateBootstrap(_ data: Data, scratch: String, target: String,
                                              trustedBridge: String, replacementBridge: String) throws -> String {
        guard data.count < 16_384, let text = String(data: data, encoding: .utf8) else { throw Failure(message: "The Hopper bridge bootstrap is too large.") }
        let lines = text.components(separatedBy: "\n")
        guard lines.count == 8, lines[7].isEmpty else { throw Failure(message: "The Hopper bootstrap has unexpected Python statements.") }
        func string(_ index: Int, _ key: String) throws -> String {
            let prefix = key + " = "
            guard lines[index].hasPrefix(prefix), let bytes = String(lines[index].dropFirst(prefix.count)).data(using: .utf8),
                  let value = try JSONSerialization.jsonObject(with: bytes, options: .fragmentsAllowed) as? String,
                  !value.contains("\0"), !value.contains("\n"), !value.contains("\r") else { throw Failure(message: "The Hopper bootstrap string is invalid.") }
            return value
        }
        let socket = try string(0, "REA_SOCKET"), nonce = try string(1, "REA_TOKEN")
        let runID = try string(2, "REA_RUN_ID"), loaded = try string(3, "REA_TARGET_PATH")
        guard socket.hasPrefix(scratch + "/"), socket.hasSuffix("/bridge.sock"),
              let socketParent = try? canonical(URL(fileURLWithPath: socket).deletingLastPathComponent().path),
              contains(scratch, socketParent), socket == socketParent + "/bridge.sock",
              nonce.count == 64, nonce.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              UUID(uuidString: runID) != nil, loaded == target,
              lines[4] == "REA_OWNS_PROCESS_LIFETIME = True",
              lines[5] == "REA_RECONNECT_TIMEOUT_SECONDS = 30",
              lines[6] == "exec(compile(open(\(quote(trustedBridge)), 'rb').read(), \(quote(trustedBridge)), 'exec'))" else {
            throw Failure(message: "The Hopper bridge does not match Search's trusted REA bootstrap.")
        }
        return ["REA_SOCKET = \(quote(socket))", "REA_TOKEN = \(quote(nonce))", "REA_RUN_ID = \(quote(runID))",
                "REA_TARGET_PATH = \(quote(loaded))", lines[4], lines[5],
                "exec(compile(open(\(quote(replacementBridge)), 'rb').read(), \(quote(replacementBridge)), 'exec'))", ""].joined(separator: "\n")
    }
    nonisolated private static func quote(_ value: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("\"\"".utf8), as: UTF8.self)
    }
    nonisolated private static func canonical(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0"), let pointer = realpath(path, nil) else { throw Failure(message: "A native analysis path is unavailable.") }
        defer { free(pointer) }; return String(cString: pointer)
    }
    nonisolated private static func contains(_ root: String, _ path: String) -> Bool { path == root || path.hasPrefix(root + "/") }
    nonisolated private static func regular(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw Failure(message: "Native analysis requires a regular file with one link.") }
    }
    deinit {
        lifetime.revoke(); permit.revoke()
        source?.cancel()
        if listener >= 0 { close(listener) }
        unlink(socketURL.path)
        try? FileManager.default.removeItem(at: readRoot)
    }

    nonisolated private static func code(_ text: String) -> UInt32 { text.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    nonisolated private static func objectSpecifier(want: UInt32, form: UInt32,
        selection: NSAppleEventDescriptor, container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(selection, forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        guard let value = record.coerce(toDescriptorType: DescType(typeObjectSpecifier)) else { throw Failure(message: "Hopper's CPU query could not be encoded.") }
        return value
    }
    nonisolated private static func cpuOptions(_ flag: String, address: NSAppleEventDescriptor) throws -> (String, String, String) {
        let all = try objectSpecifier(want: code("PCPU"), form: code("indx"), selection: NSAppleEventDescriptor(enumCode: code("all ")), container: NSAppleEventDescriptor.null())
        let properties = try objectSpecifier(want: code("prop"), form: code("prop"), selection: NSAppleEventDescriptor(typeCode: code("pALL")), container: all)
        let event = NSAppleEventDescriptor(eventClass: code("core"), eventID: code("getd"), targetDescriptor: address,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(properties, forKeyword: AEKeyword(keyDirectObject))
        let reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 3)
        guard (reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value ?? 0) == 0,
              let values = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)), values.numberOfItems <= 1000 else { throw Failure(message: "Hopper's installed CPU metadata is unavailable.") }
        let names = ["--intel-32": "x86 (32 bits)", "--intel-64": "x86 (64 bits)", "--armv7": "ARM v7", "--aarch64": "AArch64"]
        if values.numberOfItems > 0 {
            for index in 1...values.numberOfItems {
                guard let item = values.atIndex(index), let name = item.forKeyword(code("CNam"))?.stringValue,
                      let family = item.forKeyword(code("CFam"))?.stringValue,
                      let variant = item.forKeyword(code("CSFa"))?.stringValue else { continue }
                if item.forKeyword(code("CIde"))?.stringValue == String(flag.dropFirst(2)) || name == names[flag] { return (name, family, variant) }
            }
        }
        throw Failure(message: "Hopper does not report an installed CPU matching this architecture.")
    }
    /// TCC authorization is bundle-scoped. Only its preflight uses the fixed
    /// Hopper identifier; every real event stays pinned to the owned child PID.
    nonisolated static func targetDescriptors(ownedPID: pid_t) -> (permission: NSAppleEventDescriptor, event: NSAppleEventDescriptor) {
        (NSAppleEventDescriptor(bundleIdentifier: "com.cryptic-apps.hopper-web-4"),
         NSAppleEventDescriptor(processIdentifier: ownedPID))
    }
    nonisolated private static func dispatch(_ request: Request, child: Identity, peer: Identity, root: Identity, immutableBridge: String, permit: Permit, lifetime: Permit) throws {
        func live() throws {
            guard lifetime.valid, permit.valid, Identity.read(root.pid) == root, Identity.read(peer.pid) == peer,
                  Identity.read(child.pid) == child, child.parent == peer.pid else { throw Failure(message: "The native analysis process ended before the AppleEvent was sent.") }
        }
        try live()
        let targets = targetDescriptors(ownedPID: child.pid)
        let address = targets.event
        var permission: OSStatus = -600
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        repeat {
            try live()
            permission = AEDeterminePermissionToAutomateTarget(targets.permission.aeDesc, code("Hopp"), code("OpEx"), true)
            if permission == -600 || permission == -609 { Thread.sleep(forTimeInterval: 0.05) }
            else { break }
        } while ProcessInfo.processInfo.systemUptime < deadline
        guard permission == noErr else {
            throw Failure(message: "Search needs Automation permission for Hopper (macOS \(permission)). Approve Search in System Settings > Privacy & Security > Automation, then retry. No analysis was completed.")
        }
        try live()
        let event = NSAppleEventDescriptor(eventClass: code("Hopp"), eventID: code("OpEx"), targetDescriptor: address,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(fileURL: URL(fileURLWithPath: request.target)), forKeyword: AEKeyword(keyDirectObject))
        event.setParam(NSAppleEventDescriptor(boolean: request.analysis), forKeyword: code("STAN"))
        event.setParam(NSAppleEventDescriptor(fileURL: URL(fileURLWithPath: immutableBridge)), forKeyword: code("EXPY"))
        if !request.loaders.isEmpty {
            let options = NSAppleEventDescriptor.list()
            let cpu = try request.architecture.map { try cpuOptions($0, address: address) }
            for (offset, loader) in request.loaders.enumerated() {
                let record = NSAppleEventDescriptor.record()
                record.setDescriptor(NSAppleEventDescriptor(string: loader), forKeyword: code("LoLo"))
                if offset == request.loaders.count - 1, let value = cpu {
                    record.setDescriptor(NSAppleEventDescriptor(string: value.0), forKeyword: code("OCPP"))
                    record.setDescriptor(NSAppleEventDescriptor(string: value.1), forKeyword: code("OCPF"))
                    record.setDescriptor(NSAppleEventDescriptor(string: value.2), forKeyword: code("OCPS"))
                }
                options.insert(record, at: offset + 1)
            }
            event.setParam(options, forKeyword: code("OPTS"))
        }
        let sendDeadline = ProcessInfo.processInfo.systemUptime + 15
        while true {
            try live()
            do {
                let reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 2)
                let status = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value ?? 0
                if (status == -600 || status == -609) && ProcessInfo.processInfo.systemUptime < sendDeadline { Thread.sleep(forTimeInterval: 0.05); continue }
                guard status == 0 else { throw Failure(message: "Hopper rejected Search's fixed open/bridge event (macOS \(status)).") }
                try live()
                return
            } catch {
                let status = (error as NSError).code
                if (status == -600 || status == -609) && ProcessInfo.processInfo.systemUptime < sendDeadline { Thread.sleep(forTimeInterval: 0.05); continue }
                throw error
            }
        }
    }

    @MainActor private final class Connection {
        let fd: Int32
        private let source: DispatchSourceRead
        private var timer: DispatchSourceTimer?
        private var bytes = Data()
        private var closed = false
        private var handling = false
        private let handle: (Data, @escaping (Bool, String?) -> Void) -> Void
        private let gone: () -> Void
        init(fd: Int32, handle: @escaping (Data, @escaping (Bool, String?) -> Void) -> Void, gone: @escaping () -> Void) {
            self.fd = fd; self.handle = handle; self.gone = gone
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var noSIGPIPE: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self] in self?.read() }; source.resume()
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 5)
            timer.setEventHandler { [weak self] in self?.drop() }; timer.resume(); self.timer = timer
        }
        private func read() {
            guard !closed, !handling else { return }
            var chunk = [UInt8](repeating: 0, count: 16_385)
            let count = Darwin.read(fd, &chunk, chunk.count)
            guard count > 0 else { if count == 0 || (errno != EAGAIN && errno != EINTR) { drop() }; return }
            bytes.append(contentsOf: chunk.prefix(count))
            guard bytes.count <= 16_385 else { answer(false, "The Hopper request exceeds its limit."); return }
            guard let newline = bytes.firstIndex(of: 10) else { return }
            guard newline == bytes.count - 1 else { answer(false, "Only one Hopper request is permitted per connection."); return }
            handling = true; source.cancel()
            timer?.schedule(deadline: .now() + 125)
            handle(Data(bytes.prefix(upTo: newline))) { [weak self] ok, error in self?.answer(ok, error) }
        }
        private func answer(_ ok: Bool, _ error: String?) {
            guard !closed else { return }
            var object: [String: Any] = ["version": 1, "ok": ok]
            if let error { object["error"] = String(error.prefix(2_000)) }
            var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            data.append(10)
            // Replies are < 2 KiB and fit in an empty local socket send buffer.
            _ = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            drop()
        }
        func drop() {
            guard !closed else { return }; closed = true
            source.cancel(); timer?.cancel(); timer = nil; close(fd); gone()
        }
        deinit { source.cancel(); timer?.cancel(); if !closed { close(fd) } }
    }
}
