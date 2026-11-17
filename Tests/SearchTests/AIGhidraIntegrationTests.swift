import AppKit
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Search

/// Opt-in, real REA/Ghidra analysis of a synthetic local Mach-O. It never
/// executes the target, opens a GUI, uses an account, or modifies an engine.
@MainActor
final class AIGhidraIntegrationTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "ghidra-integration-\(getpid())", 1)
        super.setUp()
    }

    func testInstalledHeadlessGhidraImportsListsDecompilesAndStopsOnlyOwnedJava() async throws {
        guard ProcessInfo.processInfo.environment["SEARCH_GHIDRA_LIVE"] == "1" else {
            throw XCTSkip("Opt-in real installed Ghidra integration")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: "/private/tmp/search-ghidra-test-\(UUID().uuidString.prefix(12))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let source = workspace.appendingPathComponent("hello.c"), target = workspace.appendingPathComponent("hello")
        try """
        __attribute__((noinline,used)) int search_fixture_add(int a, int b) { return a + b + 37; }
        int main(int argc, char **argv) { return search_fixture_add(argc, 5); }
        """.write(to: source, atomically: true, encoding: .utf8)
        try compile(URL(fileURLWithPath: "/usr/bin/xcrun"), ["clang", "-O0", "-g", "-fno-inline", source.path, "-o", target.path])
        let originalDigest = try digest(target)

        let javaHome = URL(fileURLWithPath: "/opt/homebrew/Cellar/openjdk/26.0.2.1/libexec/openjdk.jdk/Contents/Home")
        let sentinelSource = root.appendingPathComponent("UnrelatedFixture.java")
        try """
        public final class UnrelatedFixture {
            public static void main(String[] args) throws Exception { Thread.sleep(120000); }
        }
        """.write(to: sentinelSource, atomically: true, encoding: .utf8)
        try compile(javaHome.appendingPathComponent("bin/javac"), ["-d", root.path, sentinelSource.path])
        let unrelated = Process()
        unrelated.executableURL = javaHome.appendingPathComponent("bin/java")
        unrelated.arguments = ["-XX:-UsePerfData", "-cp", root.path, "UnrelatedFixture"]
        unrelated.standardInput = FileHandle.nullDevice
        unrelated.standardOutput = FileHandle.nullDevice
        unrelated.standardError = FileHandle.nullDevice
        try unrelated.run()
        defer {
            if unrelated.isRunning { unrelated.terminate() }
            unrelated.waitUntilExit()
        }
        let unrelatedIdentity = try XCTUnwrap(ProcessIdentity.read(unrelated.processIdentifier))
        let live = AIREA(workspace: workspace, target: target)
        defer { live.stop() }
        let definitions = await live.definitions()
        XCTAssertTrue(live.nativeAvailable, "\(live.status): \(live.diagnostic)")
        let openDefinition = try XCTUnwrap(definitions.first { $0["name"] as? String == "rea__open_binary" })
        let schema = try XCTUnwrap(openDefinition["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let providers = try XCTUnwrap((properties["provider_id"] as? [String: Any])?["enum"] as? [String])
        XCTAssertTrue(providers.contains("ghidra"))
        let status = await live.call(name: "rea__status", arguments: [:])
        let statusObject = try object(status)
        XCTAssertEqual(statusObject["nativeProvider"] as? String, "ghidra")
        XCTAssertEqual(statusObject["network"] as? String, "blocked")
        try record("status", status)

        let opened = await live.call(name: "rea__open_binary", arguments: ["path": target.path])
        try assertSuccess(opened, live: live)
        try record("open", opened)
        let overview = await live.call(name: "rea__binary_overview", arguments: [:])
        let overviewObject = try assertEvidence(overview, operation: "binary_overview", live: live)
        try record("overview", overview)
        XCTAssertTrue(overview.contains("procedure_count"))
        XCTAssertFalse(overview.contains("\"provider_id\":\"hopper\""))
        XCTAssertNotNil(overviewObject["normalized_result"])

        let procedures = await live.call(name: "rea__list_procedures", arguments: [:])
        let procedureEvidence = try assertEvidence(procedures, operation: "list_procedures", live: live)
        try record("procedures", procedures)
        let procedure = try XCTUnwrap(findProcedure(procedureEvidence["normalized_result"] as Any), "Synthetic function missing from actual Ghidra inventory: \(procedures.prefix(2000))")
        let pseudocode = await live.call(name: "rea__procedure_pseudo_code", arguments: ["procedure": procedure])
        let pseudoEvidence = try assertEvidence(pseudocode, operation: "procedure_pseudo_code", live: live)
        try record("pseudocode", pseudocode)
        let code = try XCTUnwrap(pseudoEvidence["normalized_result"] as? String)
        XCTAssertFalse(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(code.contains("37") || code.contains("0x25"), "Decompiler output must recover the fixture's added constant: \(code.prefix(2000))")
        XCTAssertTrue(code.contains("+"))
        XCTAssertEqual(try digest(target), originalDigest, "Analysis must not modify the original target")

        let supervisor = try XCTUnwrap(ProcessIdentity.read(live.processID))
        let descendants = ProcessIdentity.descendants(of: supervisor.pid)
        let ownedJava = descendants.filter { $0.pid != unrelatedIdentity.pid && URL(fileURLWithPath: $0.executable).lastPathComponent == "java" }
        XCTAssertFalse(ownedJava.isEmpty, "A successful headless session must have an owned Java engine to stop")
        XCTAssertEqual(ProcessIdentity.read(unrelatedIdentity.pid), unrelatedIdentity)
        let sockets = (FileManager.default.enumerator(at: live.scratch, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.lastPathComponent == "bridge.sock" }
        XCTAssertFalse(sockets.isEmpty, "The real bridge must use a Unix socket in private analysis scratch")
        for socket in sockets {
            XCTAssertTrue(socket.path.hasPrefix(live.scratch.path + "/"))
            XCTAssertLessThan(socket.path.utf8.count, 104)
        }
        live.stop()
        try await until { !ProcessIdentity.stillAlive(supervisor) && ownedJava.allSatisfy { !ProcessIdentity.stillAlive($0) } }
        XCTAssertTrue(unrelated.isRunning, "Stop must leave a different Java session alive")
        XCTAssertEqual(ProcessIdentity.read(unrelatedIdentity.pid), unrelatedIdentity)
        try record("lifecycle", String(decoding: JSONSerialization.data(withJSONObject: [
            "nativeProvider": "ghidra", "ownedJavaCount": ownedJava.count,
            "ownedJavaStopped": true, "ownedSupervisorStopped": true, "unrelatedJavaSurvived": true,
            "unixSocketCount": sockets.count, "targetSHA256": originalDigest,
            "targetUnchanged": true, "targetExecutionRequested": false, "guiOpened": false, "networkPolicy": "IP denied"
        ], options: [.sortedKeys]), as: UTF8.self))
    }

    private func compile(_ executable: URL, _ arguments: [String]) throws {
        let process = Process(), errors = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = errors
        try process.run(); process.waitUntilExit()
        let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw NSError(domain: "SyntheticFixtureCompiler", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(text.prefix(4000))]) }
    }
    private func digest(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    @discardableResult private func assertSuccess(_ text: String, live: AIREA) throws -> [String: Any] {
        let value = try object(text)
        XCTAssertNil(value["error"], "\(text.prefix(4000)): \(live.diagnostic.prefix(4000))")
        guard value["error"] == nil else { throw NSError(domain: "ActualGhidraFailure", code: 1, userInfo: [NSLocalizedDescriptionKey: String(text.prefix(4000))]) }
        return value
    }
    private func assertEvidence(_ text: String, operation: String, live: AIREA) throws -> [String: Any] {
        let value = try assertSuccess(text, live: live)
        if operation == "binary_overview" {
            XCTAssertEqual((value["provider"] as? [String: Any])?["id"] as? String, "rea-workflow")
            let profile = try XCTUnwrap(value["analysis_profile"] as? [String: Any])
            let parameters = try XCTUnwrap(profile["parameters"] as? [String: Any])
            let upstream = try XCTUnwrap(parameters["upstream_analysis_profile"] as? [String: Any])
            XCTAssertEqual((upstream["provider"] as? [String: Any])?["id"] as? String, "ghidra")
            XCTAssertEqual((upstream["provider"] as? [String: Any])?["version"] as? String, "12.1.4")
        } else {
            XCTAssertEqual((value["provider"] as? [String: Any])?["id"] as? String, "ghidra")
        }
        XCTAssertEqual(value["operation"] as? String, operation)
        XCTAssertNotNil(value["evidence_id"])
        return value
    }
    private func findProcedure(_ value: Any) -> String? {
        if let object = value as? [String: Any] {
            if let address = object["address"] as? String,
               [object["name"], object["value"]].contains(where: { ($0 as? String)?.contains("search_fixture_add") == true }) { return address }
            for child in object.values { if let found = findProcedure(child) { return found } }
        } else if let array = value as? [Any] { for child in array { if let found = findProcedure(child) { return found } } }
        return nil
    }
    private func record(_ name: String, _ text: String) throws {
        guard let path = ProcessInfo.processInfo.environment["SEARCH_GHIDRA_EVIDENCE_DIR"] else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent(name + ".json")
        try Data(text.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func until(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw URLError(.timedOut)
    }
    private struct ProcessIdentity: Equatable {
        let pid: pid_t
        let parent: pid_t
        let seconds: UInt64
        let microseconds: UInt64
        let executable: String
        static func read(_ pid: pid_t) -> ProcessIdentity? {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size),
                  info.pbi_uid == getuid(), info.pbi_status != 5 else { return nil }
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
            return ProcessIdentity(pid: pid, parent: pid_t(info.pbi_ppid), seconds: info.pbi_start_tvsec,
                                   microseconds: info.pbi_start_tvusec, executable: String(cString: path))
        }
        static func stillAlive(_ identity: ProcessIdentity) -> Bool {
            guard let current = read(identity.pid) else { return false }
            return current.pid == identity.pid && current.seconds == identity.seconds && current.microseconds == identity.microseconds && current.executable == identity.executable
        }
        static func descendants(of parent: pid_t) -> [ProcessIdentity] {
            var queue = [parent], found: [ProcessIdentity] = [], seen: Set<pid_t> = [parent], offset = 0
            while offset < queue.count, found.count < 512 {
                let current = queue[offset]; offset += 1
                var children = [pid_t](repeating: 0, count: 512)
                let count = proc_listchildpids(current, &children, Int32(children.count * MemoryLayout<pid_t>.size))
                for pid in children.prefix(max(0, min(Int(count), children.count))) where seen.insert(pid).inserted {
                    if let identity = read(pid), identity.parent == current { found.append(identity); queue.append(pid) }
                }
            }
            return found
        }
    }
}
