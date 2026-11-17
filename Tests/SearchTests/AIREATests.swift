import Foundation
import XCTest
import CryptoKit
@testable import Search

@MainActor
final class AIREATests: XCTestCase {
    private var fixture: MCPFixture!
    private var rea: AIREA!
    override func setUp() async throws {
        fixture = try MCPFixture()
        rea = AIREA(workspace: fixture.root, client: fixture.client(family: "native"), scratch: fixture.scratch)
    }
    override func tearDown() async throws {
        rea?.stop(); rea = nil
        try? FileManager.default.removeItem(at: fixture.root)
        fixture = nil
    }
    func testOnlyStaticToolsAreAdvertisedAndCallable() async throws {
        let names = await rea.definitions().compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("rea__binary_session"))
        XCTAssertFalse(names.contains("rea__capture_process_scenario"))
        let output = await rea.call(name: "rea__capture_process_scenario", arguments: ["command": "/bin/sh"])
        XCTAssertTrue(output.contains("not enabled"))
        XCTAssertFalse(try String(contentsOf: fixture.log, encoding: .utf8).contains("/bin/sh"))
    }
    func testDefaultNativeProviderIsFreeHeadlessGhidraAndPaidProvidersAreRejected() async throws {
        let target = fixture.root.appendingPathComponent("sample.bin")
        try Data([1, 2, 3]).write(to: target)
        for provider in ["ida", "kuna", "binary-ninja", "auto"] {
            let rejected = await rea.call(name: "rea__open_binary", arguments: ["path": target.path, "provider_id": provider])
            XCTAssertTrue(rejected.contains("Ghidra"), provider)
        }
        let output = try MCPFixture.object(await rea.call(name: "rea__open_binary", arguments: ["path": target.path]))
        XCTAssertEqual((output["arguments"] as? [String: Any])?["provider_id"] as? String, "ghidra")
    }
    func testOptionalHopperCanBeSelectedExplicitlyAndReportedHonestly() async throws {
        let target = fixture.root.appendingPathComponent("optional.bin")
        try Data([1, 2, 3]).write(to: target)
        let output = try MCPFixture.object(await rea.call(name: "rea__open_binary", arguments: ["path": target.path, "provider_id": "hopper"]))
        XCTAssertEqual((output["arguments"] as? [String: Any])?["provider_id"] as? String, "hopper")
        let status = try MCPFixture.object(await rea.call(name: "rea__status", arguments: [:]))
        XCTAssertEqual(status["nativeProvider"] as? String, "hopper")
        XCTAssertEqual(status["defaultNativeProvider"] as? String, "ghidra")
        XCTAssertEqual(status["nativeProviders"] as? [String], ["ghidra", "hopper"])
    }
    func testProviderSchemaListsOnlyConfiguredLocalEnginesAndGhidraDoesNotRequireHopper() async throws {
        let configured = try MCPFixture()
        let only = AIREA(workspace: configured.root, client: configured.client(family: "native"), scratch: configured.scratch, providers: ["ghidra"])
        defer { only.stop(); try? FileManager.default.removeItem(at: configured.root) }
        let definitions = await only.definitions()
        let open = try XCTUnwrap(definitions.first { $0["name"] as? String == "rea__open_binary" })
        let schema = try XCTUnwrap(open["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual((properties["provider_id"] as? [String: Any])?["enum"] as? [String], ["ghidra"])
        XCTAssertTrue(only.nativeAvailable)
        XCTAssertEqual(only.defaultNativeProvider, "ghidra")
        let target = configured.root.appendingPathComponent("ghidra-only.bin")
        try Data([1]).write(to: target)
        let unavailable = await only.call(name: "rea__open_binary", arguments: ["path": target.path, "provider_id": "hopper"])
        XCTAssertTrue(unavailable.contains("error"))
        let accepted = try MCPFixture.object(await only.call(name: "rea__open_binary", arguments: ["path": target.path]))
        XCTAssertEqual((accepted["arguments"] as? [String: Any])?["provider_id"] as? String, "ghidra")
    }
    func testNoNativeEngineKeepsStaticToolsWithoutAdvertisingInvalidEmptyProviderEnum() async throws {
        let configured = try MCPFixture()
        let staticOnly = AIREA(workspace: configured.root, client: configured.client(family: "native"), scratch: configured.scratch, providers: [])
        defer { staticOnly.stop(); try? FileManager.default.removeItem(at: configured.root) }
        let definitions = await staticOnly.definitions()
        XCTAssertTrue(definitions.contains { $0["name"] as? String == "rea__binary_session" })
        XCTAssertFalse(definitions.contains { $0["name"] as? String == "rea__open_binary" })
        XCTAssertFalse(staticOnly.nativeAvailable)
    }
    func testModelCannotOverrideRuntimeEnvironmentOrExecutablePaths() async throws {
        for injected: [String: Any] in [["environment": ["GHIDRA_INSTALL_DIR": "/tmp/foreign"]], ["java_home": "/tmp/jdk"], ["ghidra_command": "/bin/sh"]] {
            let output = await rea.call(name: "rea__binary_session", arguments: injected)
            XCTAssertTrue(output.contains("selected only by Search"))
        }
        XCTAssertFalse(try String(contentsOf: fixture.log, encoding: .utf8).contains("foreign"))
    }
    func testOutsideWorkspaceAndSymlinkEscapesAreRejected() async throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-rea-\(UUID().uuidString)")
        try Data([1]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = fixture.root.appendingPathComponent("escape.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        for path in [outside.path, link.path, "https://example.com/file", "../outside.bin"] {
            let output = await rea.call(name: "rea__open_binary", arguments: ["path": path])
            XCTAssertTrue(output.contains("error"), path)
        }
        let log = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertFalse(log.contains("\"method\": \"tools/call\""))
    }
    func testNestedPathsCannotReadOutsideWorkspace() async throws {
        let output = await rea.call(name: "rea__inspect_analysis_view", arguments: ["source": ["kind": "evidence-file", "path": "/etc/passwd"]])
        XCTAssertTrue(output.contains("outside"))
    }
    func testEvidenceExportUsesFreshPrivateScratchPath() async throws {
        let output = try MCPFixture.object(await rea.call(name: "rea__export_evidence_bundle", arguments: ["path": fixture.root.appendingPathComponent("original.json").path]))
        let args = try XCTUnwrap(output["arguments"] as? [String: Any])
        XCTAssertTrue((args["path"] as? String)?.hasPrefix(fixture.scratch.path) == true)
        XCTAssertEqual(args["overwrite"] as? Bool, false)
    }
    func testMissingRuntimeStatusIsAnHonestToolResult() async throws {
        let home = fixture.root.appendingPathComponent("empty-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        XCTAssertNil(AIREA.discoverRuntime(home: home))
        let value = try MCPFixture.object(await rea.call(name: "rea__status", arguments: [:]))
        XCTAssertEqual(value["network"] as? String, "blocked")
        XCTAssertEqual(value["nativeProvider"] as? String, "ghidra")
        XCTAssertEqual(value["defaultNativeProvider"] as? String, "ghidra")
    }
    func testFailedOpenDoesNotAuthorizeNativeReads() async throws {
        let target = fixture.root.appendingPathComponent("sample.bin")
        try Data([1, 2, 3]).write(to: target)
        let failure = await rea.call(name: "rea__open_binary", arguments: ["path": target.path, "behavior": "tool-error"])
        XCTAssertTrue(failure.contains("Fixture tool failure"))
        let native = await rea.call(name: "rea__list_procedures", arguments: [:])
        XCTAssertTrue(native.contains("Open a selected workspace binary first"))
    }
    func testNativePatchRequiresEveryExpectedFileAndDetectsTampering() async throws {
        let package = fixture.root.appendingPathComponent("patched-package", isDirectory: true)
        let paths = ["dist/process/HopperLease.js", "dist/hopper/HopperClient.js", "dist/hopper/BridgeLauncher.js", "dist/mcp/main-Cx-Z7m_n.js", "dist/cli-runtime/SharedStartupAttempt-BxKyf3Uv.js", "dist/cli-runtime/binary-CWVNJhAC.js"]
        var hashes: [String: String] = [:]
        for relative in paths {
            let file = package.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data("synthetic \(relative)".utf8)
            try data.write(to: file)
            hashes[relative] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let marker = package.appendingPathComponent(".search-patches/manifest.json")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["format": "search-rea-runtime-1", "version": "6.7.0", "patch": "search-private-hopper-isolation-2", "files": hashes]).write(to: marker)
        XCTAssertTrue(AIREA.validNativePatch(package))
        try Data("modified".utf8).write(to: package.appendingPathComponent(paths[0]))
        XCTAssertFalse(AIREA.validNativePatch(package))
    }
    func testInstalledREACatalogAndStatusWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["SEARCH_LOCAL_TOOLS_LIVE"] == "1" else { throw XCTSkip("Opt-in installed backend validation") }
        let live = AIREA(workspace: fixture.root)
        defer { live.stop() }
        let definitions = await live.definitions()
        XCTAssertTrue(live.nativeAvailable, "The installed native engine must be available: \(live.status)")
        guard definitions.count > 1 else { XCTFail("\(live.status): \(live.diagnostic)"); return }
        let status = await live.call(name: "rea__binary_session", arguments: [:])
        XCTAssertFalse(status.contains("\"error\":"), "\(status.prefix(1_000)): \(live.diagnostic)")
        let app = fixture.root.appendingPathComponent("javascript-app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        try #"{"name":"search-rea-fixture","type":"module","main":"main.js"}"#.write(to: app.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "export function fixtureSum(a, b) { return a + b; }\n".write(to: app.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
        let result = await live.call(name: "rea__analyze_javascript_application", arguments: ["input_path": app.path, "format": "directory", "detail": "complete"])
        let evidence = try MCPFixture.object(result)
        XCTAssertNil(evidence["error"], "\(result.prefix(2_000)): \(live.diagnostic)")
        XCTAssertTrue(result.contains("fixtureSum"), String(result.prefix(2_000)))
        XCTAssertTrue(result.contains("evidence_id"))
    }
}
