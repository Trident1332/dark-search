import AppKit
import CoreServices
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Search

@MainActor
final class AIPinnedHopperBrokerTests: XCTestCase {
    private let nonce = String(repeating: "a", count: 64)
    private var folder: URL!
    override func setUp() async throws {
        folder = URL(fileURLWithPath: "/private/tmp/search-broker-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]) }
    private func value() -> [String: Any] {
        ["version": 1, "token": nonce, "helperPID": 200, "hopperPID": 300,
         "hopperStartedSec": 20, "hopperStartedUsec": 123,
         "targetPath": folder.appendingPathComponent("target").path,
         "bridgePath": folder.appendingPathComponent("bootstrap.py").path,
         "analysis": true, "loaders": ["Mach-O"], "architecture": "--aarch64"]
    }
    func testPermissionPreflightUsesFixedBundleButRealEventTargetRemainsExactPID() throws {
        let selectedPID: pid_t = 12345
        let descriptors = AIPinnedHopperBroker.targetDescriptors(ownedPID: selectedPID)
        XCTAssertEqual(descriptors.permission.descriptorType, typeApplicationBundleID)
        XCTAssertEqual(String(data: descriptors.permission.data, encoding: .utf8), "com.cryptic-apps.hopper-web-4")
        XCTAssertEqual(descriptors.event.descriptorType, typeKernelProcessID)
        XCTAssertEqual(descriptors.event.data.count, MemoryLayout<pid_t>.size)
        let encodedPID = descriptors.event.data.withUnsafeBytes { $0.loadUnaligned(as: pid_t.self) }
        XCTAssertEqual(encodedPID, selectedPID)
        XCTAssertNotEqual(descriptors.event.descriptorType, descriptors.permission.descriptorType)
    }
    func testControlRequestAcceptsOnlyBoundedTypedFixedOptions() throws {
        let request = try AIPinnedHopperBroker.Request.parse(json(value()), token: nonce)
        XCTAssertEqual(request.helperPID, 200)
        XCTAssertEqual(request.loaders, ["Mach-O"])
        XCTAssertEqual(request.architecture, "--aarch64")
        let mutations: [[String: Any]] = [
            ["version": true], ["token": String(repeating: "b", count: 64)], ["helperPID": true], ["hopperPID": -10],
            ["hopperStartedUsec": 1_000_000], ["architecture": "--python=evil"],
            ["loaders": ["Mach-O", "FAT", "ELF"]], ["loaders": ["shell"]],
            ["eventID": "quit"], ["analysis": "true"], ["targetPath": String(repeating: "a", count: 20_000)]
        ]
        for mutation in mutations {
            var object = value(); object.merge(mutation) { _, new in new }
            XCTAssertThrowsError(try AIPinnedHopperBroker.Request.parse(json(object), token: nonce), "\(mutation.keys)")
        }
    }
    private func identity(_ pid: pid_t, _ parent: pid_t, _ executable: String, seconds: UInt64 = 20, user: uid_t = getuid()) -> AIPinnedHopperBroker.Identity {
        .init(pid: pid, parent: parent, user: user, seconds: seconds, microseconds: 123, executable: executable)
    }
    func testProcessAuthorityRequiresPinnedPeerOwnedChildAndActiveAncestry() throws {
        let root = identity(100, getpid(), "/node")
        let helper = identity(200, 150, "/helper")
        let intermediate = identity(150, 100, "/node")
        let hopper = identity(300, 200, "/hopper")
        let request = try AIPinnedHopperBroker.Request.parse(json(value()), token: nonce)
        let processes = [100: root, 150: intermediate, 200: helper, 300: hopper]
        let accepted = try AIPinnedHopperBroker.authorize(request, peer: helper, root: root,
            helperExecutable: "/helper", hopperExecutable: "/hopper", lookup: { processes[Int($0)] })
        XCTAssertEqual(accepted, hopper)
        let mutations = [identity(300, 999, "/hopper"), identity(300, 200, "/different"),
                         identity(300, 200, "/hopper", seconds: 21), identity(300, 200, "/hopper", user: getuid() + 1)]
        for replacement in mutations {
            var changed = processes; changed[300] = replacement
            XCTAssertThrowsError(try AIPinnedHopperBroker.authorize(request, peer: helper, root: root,
                helperExecutable: "/helper", hopperExecutable: "/hopper", lookup: { changed[Int($0)] }))
        }
        var changed = processes
        changed[150] = identity(150, 999, "/node")
        XCTAssertThrowsError(try AIPinnedHopperBroker.authorize(request, peer: helper, root: root,
            helperExecutable: "/helper", hopperExecutable: "/hopper", lookup: { changed[Int($0)] }))
        changed = processes; changed[100] = identity(100, getpid(), "/node", seconds: 99)
        XCTAssertThrowsError(try AIPinnedHopperBroker.authorize(request, peer: helper, root: root,
            helperExecutable: "/helper", hopperExecutable: "/hopper", lookup: { changed[Int($0)] }))
        XCTAssertThrowsError(try AIPinnedHopperBroker.authorize(request, peer: identity(201, 100, "/helper"), root: root,
            helperExecutable: "/helper", hopperExecutable: "/hopper", lookup: { processes[Int($0)] }))
    }
    private func bootstrap(socket: String? = nil, trusted: String = "/trusted/hopper_bridge.py", extra: String = "") throws -> String {
        func quote(_ text: String) throws -> String { String(decoding: try json(text), as: UTF8.self) }
        return try ["REA_SOCKET = \(quote(socket ?? folder.appendingPathComponent("session/bridge.sock").path))",
                    "REA_TOKEN = \(quote(nonce))", "REA_RUN_ID = \(quote(UUID().uuidString))",
                    "REA_TARGET_PATH = \(quote(folder.appendingPathComponent("target").path))",
                    "REA_OWNS_PROCESS_LIFETIME = True", "REA_RECONNECT_TIMEOUT_SECONDS = 30",
                    "exec(compile(open(\(quote(trusted)), 'rb').read(), \(quote(trusted)), 'exec'))", extra].joined(separator: "\n")
    }
    func testBootstrapIsStrictDataGrammarAndRewrittenAgainstHostSnapshot() throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("session"), withIntermediateDirectories: false)
        let source = try bootstrap()
        let result = try AIPinnedHopperBroker.validateBootstrap(Data(source.utf8), scratch: folder.path,
            target: folder.appendingPathComponent("target").path, trustedBridge: "/trusted/hopper_bridge.py", replacementBridge: "/private/host-copy.py")
        XCTAssertTrue(result.contains("open(\"/private/host-copy.py\", 'rb')"))
        XCTAssertFalse(result.contains("/trusted/hopper_bridge.py"))
        let bad = [source + "\nimport os;os.system('anything')", source.replacingOccurrences(of: " = True", with: " = False"),
                   source.replacingOccurrences(of: " = 30", with: " = 999"), try bootstrap(trusted: "/tmp/arbitrary.py"),
                   try bootstrap(socket: "/private/tmp/outside/bridge.sock"), source.replacingOccurrences(of: "REA_TOKEN = ", with: "REA_TOKEN = __import__('os'); ")]
        for text in bad {
            XCTAssertThrowsError(try AIPinnedHopperBroker.validateBootstrap(Data(text.utf8), scratch: folder.path,
                target: folder.appendingPathComponent("target").path, trustedBridge: "/trusted/hopper_bridge.py", replacementBridge: "/private/host-copy.py"))
        }
    }
    func testBootstrapRejectsSocketDirectorySymlinkEscape() throws {
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("session"), withDestinationURL: URL(fileURLWithPath: "/private/tmp"))
        XCTAssertThrowsError(try AIPinnedHopperBroker.validateBootstrap(Data(bootstrap().utf8), scratch: folder.path,
            target: folder.appendingPathComponent("target").path, trustedBridge: "/trusted/hopper_bridge.py", replacementBridge: "/private/host-copy.py"))
    }
    func testBootstrapReadBoundsSparseFilesAndRejectsSymlinksAndMultipleLinks() throws {
        let file = folder.appendingPathComponent("bootstrap.py")
        let contents = Data("# bounded bootstrap fixture\n".utf8)
        try contents.write(to: file)
        XCTAssertEqual(try AIPinnedHopperBroker.readBootstrap(file.path), contents)
        let symbolic = folder.appendingPathComponent("symbolic.py")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: file)
        XCTAssertThrowsError(try AIPinnedHopperBroker.readBootstrap(symbolic.path))
        let hard = folder.appendingPathComponent("hard.py")
        try FileManager.default.linkItem(at: file, to: hard)
        XCTAssertThrowsError(try AIPinnedHopperBroker.readBootstrap(file.path))
        try FileManager.default.removeItem(at: hard)
        let fd = Darwin.open(file.path, O_WRONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { if fd >= 0 { close(fd) } }
        // A sparse GiB file exercises metadata rejection without allocating
        // that amount of memory or storage in this test or the host reader.
        XCTAssertEqual(ftruncate(fd, off_t(1 << 30)), 0)
        XCTAssertThrowsError(try AIPinnedHopperBroker.readBootstrap(file.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("16 KiB"))
        }
        let fifo = folder.appendingPathComponent("pipe.py")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try AIPinnedHopperBroker.readBootstrap(fifo.path))
    }
    func testBootstrapReadRejectsSymlinkInAnyParentComponent() throws {
        let outside = folder.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let file = outside.appendingPathComponent("bootstrap.py")
        try Data("# must not follow scratch parent links\n".utf8).write(to: file)
        let link = folder.appendingPathComponent("swapped-parent", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try AIPinnedHopperBroker.readBootstrap(link.appendingPathComponent("bootstrap.py").path))
        XCTAssertEqual(try AIPinnedHopperBroker.readBootstrap(file.path), Data("# must not follow scratch parent links\n".utf8))
    }
    func testModifiedPackageBridgeCannotBecomeNativePython() throws {
        let bridge = folder.appendingPathComponent("bridge/hopper_bridge.py")
        try FileManager.default.createDirectory(at: bridge.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("print('arbitrary Python')".utf8).write(to: bridge)
        XCTAssertFalse(AIPinnedHopperBroker.validTrustedBridge(folder))
        XCTAssertEqual(AIPinnedHopperBroker.vendorBridgeSHA256, "97ec963352ae396de2e2e331eac84738836a336b57288e0a2c0b2d93fbb82a45")
    }
    func testPrivateSocketRejectsUntrustedKernelPeerEvenWithCorrectTokenAndCleansUp() async throws {
        let app = folder.appendingPathComponent("Hopper Disassembler.app")
        let executable = app.appendingPathComponent("Contents/MacOS/Hopper Disassembler")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        let sign = Process(); sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", executable.path]
        sign.standardError = FileHandle.nullDevice; try sign.run(); sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0)
        let package = folder.appendingPathComponent("package")
        let bridge = package.appendingPathComponent("bridge/hopper_bridge.py")
        try FileManager.default.createDirectory(at: bridge.deletingLastPathComponent(), withIntermediateDirectories: true)
        let trustedBytes = Data(String(repeating: "# trusted fixture\n", count: 100).utf8)
        try trustedBytes.write(to: bridge)
        let bridgeDigest = SHA256.hash(data: trustedBytes).map { String(format: "%02x", $0) }.joined()
        var broker: AIPinnedHopperBroker? = try AIPinnedHopperBroker(workspace: folder, scratch: folder,
            helper: URL(fileURLWithPath: "/usr/bin/true"), hopperApplication: app, package: package, bridgeDigest: bridgeDigest)
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["20"]
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        try broker?.activate(processID: child.processIdentifier)
        let socket = try XCTUnwrap(broker?.socketURL)
        let readRoot = try XCTUnwrap(broker?.readRoot)
        let token = try XCTUnwrap(broker?.token)
        let mode = try FileManager.default.attributesOfItem(atPath: socket.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let response = await Task.detached { () -> Int in
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return -100 }; defer { close(fd) }
            var noSIGPIPE: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            let room = MemoryLayout.size(ofValue: address.sun_path)
            withUnsafeMutablePointer(to: &address.sun_path) { p in p.withMemoryRebound(to: CChar.self, capacity: room) { _ = strlcpy($0, socket.path, room) } }
            let connected = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard connected == 0 else { return -101 }
            let bytes = Data("{\"token\":\"\(token)\"}\n".utf8)
            _ = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            var buffer = [UInt8](repeating: 0, count: 3000)
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            return count < 0 && errno == ECONNRESET ? 0 : count
        }.value
        XCTAssertEqual(response, 0, "An untrusted peer must be closed before any event dispatch.")
        broker?.deactivate(); broker = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: readRoot.path))
    }
}
