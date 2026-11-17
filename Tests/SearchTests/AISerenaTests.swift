import Foundation
import XCTest
@testable import Search

@MainActor
final class AISerenaTests: XCTestCase {
    private var fixture: MCPFixture!
    private var serena: AISerena!
    override func setUp() async throws {
        fixture = try MCPFixture()
        serena = AISerena(workspace: fixture.root, client: fixture.client(family: "serena"), scratch: fixture.scratch)
    }
    override func tearDown() async throws {
        serena.stop(); serena = nil
        try? FileManager.default.removeItem(at: fixture.root); fixture = nil
    }
    func testOnlyReadOnlyLSPToolsAreAdvertised() async throws {
        let definitions = await serena.definitions()
        let names = definitions.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("serena__find_symbol"))
        XCTAssertFalse(names.contains("serena__execute_shell_command"))
        XCTAssertFalse(names.contains("serena__activate_project"))
        let rejected = await serena.call(name: "serena__execute_shell_command", arguments: ["command": "echo forbidden"])
        XCTAssertTrue(rejected.contains("not enabled"))
    }
    func testRelativePathReadsUseTheRealServer() async throws {
        let output = try MCPFixture.object(await serena.call(name: "serena__get_symbols_overview", arguments: ["relative_path": "source.py"]))
        XCTAssertEqual(output["operation"] as? String, "get_symbols_overview")
    }
    func testOutsidePathsAndSymlinksAreRejected() async throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("serena-outside-\(UUID().uuidString)")
        try Data([1]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("escape.py"), withDestinationURL: outside)
        for path in ["../elsewhere.py", "/etc/passwd", "https://example.com/source.py", "escape.py"] {
            let result = await serena.call(name: "serena__find_symbol", arguments: ["relative_path": path])
            XCTAssertTrue(result.contains("error"), path)
        }
    }
    func testStatusDescribesFreeBackendAndNetworkBoundary() async throws {
        let status = try MCPFixture.object(await serena.call(name: "serena__status", arguments: [:]))
        XCTAssertEqual(status["backend"] as? String, "LSP")
        XCTAssertEqual(status["readOnly"] as? Bool, true)
        XCTAssertEqual(status["network"] as? String, "blocked")
    }
    func testInstalledSerenaSymbolsWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["SEARCH_LOCAL_TOOLS_LIVE"] == "1" else { throw XCTSkip("Opt-in installed backend validation") }
        let live = AISerena(workspace: fixture.root, target: fixture.script)
        defer { live.stop() }
        let definitions = await live.definitions()
        XCTAssertTrue(definitions.contains(where: { $0["name"] as? String == "serena__get_symbols_overview" }), "\(live.status): \(live.diagnostic)")
        let result = await live.call(name: "serena__get_symbols_overview", arguments: ["relative_path": "server.py", "depth": 1])
        XCTAssertFalse(result.contains("\"error\":"), "\(result.prefix(1_000)): \(live.diagnostic)")
        XCTAssertTrue(result.contains("send"), String(result.prefix(1_000)))
    }
    func testInstalledSerenaSwiftSymbolsWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["SEARCH_LOCAL_TOOLS_LIVE"] == "1" else { throw XCTSkip("Opt-in installed backend validation") }
        let source = fixture.root.appendingPathComponent("Fixture.swift")
        try "struct SearchSemanticFixture { func answer() -> Int { 42 } }\n".write(to: source, atomically: true, encoding: .utf8)
        let live = AISerena(workspace: fixture.root, target: source)
        defer { live.stop() }
        _ = await live.definitions()
        let result = await live.call(name: "serena__get_symbols_overview", arguments: ["relative_path": "Fixture.swift", "depth": 1])
        XCTAssertFalse(result.contains("\"error\":"), "\(result.prefix(1_000)): \(live.diagnostic)")
        XCTAssertTrue(result.contains("SearchSemanticFixture"), String(result.prefix(1_000)))
    }
}
