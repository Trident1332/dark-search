import Darwin
import Foundation
import XCTest
@testable import Search

/// Every child is a temporary synthetic Python fixture. No Tor client,
/// relay, real proxy account or saved browser profile is contacted.
@MainActor
final class TorRuntimeTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "tor-runtime-tests-\(getpid())", 1)
        super.setUp()
    }

    private func until(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 4,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(15)) }
        if !condition() {
            XCTFail("The synthetic Tor process did not reach its expected state", file: file, line: line)
            throw URLError(.timedOut)
        }
    }

    func testListenerAloneDoesNotOpenRouteBeforeBootstrapCompletes() async throws {
        let fixture = try FakeTor()
        let runtime = fixture.runtime()
        defer { runtime.stop(); fixture.remove() }
        let connection = Task { try await runtime.start() }
        try await until { runtime.phase == .starting(progress: 37) }
        XCTAssertNil(runtime.port)
        XCTAssertFalse(runtime.isReady)
        try fixture.release()
        let connectedPort = try await connection.value
        XCTAssertEqual(connectedPort, FakeTor.port)
        XCTAssertEqual(runtime.phase, .ready)
        XCTAssertTrue(runtime.isReady)
        XCTAssertEqual(runtime.port, FakeTor.port)
        let mode = try FileManager.default.attributesOfItem(atPath: fixture.data.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((mode?.intValue ?? 0) & 0o777, 0o700)
    }

    func testSavedHTTPAccountOnlyTravelsThroughStdinConfiguration() async throws {
        let fixture = try FakeTor(held: false)
        let runtime = fixture.runtime()
        defer { runtime.stop(); fixture.remove() }
        let secret = "fixture-private-password"
        _ = try await runtime.start(upstream: .httpConnect(host: "127.0.0.1", port: 12323,
                                                         username: "fixture-user", password: secret))
        let arguments = try String(contentsOf: fixture.arguments, encoding: .utf8)
        XCTAssertFalse(arguments.contains(secret))
        XCTAssertFalse(arguments.contains("fixture-user"))
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(contentsOf: fixture.arguments)),
                       ["--defaults-torrc", "/dev/null", "-f", "-"])
        let config = try String(contentsOf: fixture.configuration, encoding: .utf8)
        XCTAssertTrue(config.contains("HTTPSProxy \"127.0.0.1:12323\""))
        XCTAssertTrue(config.contains("HTTPSProxyAuthenticator \"fixture-user:\(secret)\""))
        for required in ["ClientOnly 1", "SafeLogging 1", "SafeSocks 1", "ClientRejectInternalAddresses 1",
                         "RunAsDaemon 0", "ControlPort 0", "DNSPort 0", "TransPort 0", "ORPort 0", "DirPort 0",
                         "SocksPort 127.0.0.1:auto IsolateSOCKSAuth", "__OwningControllerProcess \(getpid())"] {
            XCTAssertTrue(config.contains(required), required)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.data.appendingPathComponent("torrc").path))
    }

    func testSOCKSUpstreamUsesIPv6EndpointAndItsOwnCredentialFields() async throws {
        let fixture = try FakeTor(held: false)
        let runtime = fixture.runtime()
        defer { runtime.stop(); fixture.remove() }
        _ = try await runtime.start(upstream: .socks5(host: "::1", port: 1080,
                                                    username: "fixture-user", password: "fixture-password"))
        let config = try String(contentsOf: fixture.configuration, encoding: .utf8)
        XCTAssertTrue(config.contains("Socks5Proxy \"[::1]:1080\""))
        XCTAssertTrue(config.contains("Socks5ProxyUsername \"fixture-user\""))
        XCTAssertTrue(config.contains("Socks5ProxyPassword \"fixture-password\""))
        XCTAssertFalse(config.contains("HTTPSProxy"))
    }

    func testConfigurationQuotesCredentialTextInsteadOfAddingDirectives() async throws {
        let fixture = try FakeTor(held: false)
        let runtime = fixture.runtime()
        defer { runtime.stop(); fixture.remove() }
        _ = try await runtime.start(upstream: .socks5(host: "localhost", port: 1080,
                                                    username: "fixture-user", password: "fixture\"\\password\nControlPort 9999"))
        let config = try String(contentsOf: fixture.configuration, encoding: .utf8)
        let lines = config.components(separatedBy: "\n")
        XCTAssertEqual(lines.filter { $0.hasPrefix("ControlPort ") }, ["ControlPort 0"])
        XCTAssertEqual(lines.filter { $0.hasPrefix("Socks5ProxyPassword ") }.count, 1)
        XCTAssertTrue(config.contains("\\\"\\\\password\\nControlPort 9999"))
    }

    func testTLSProxyIsRefusedBeforeAnyProcessLaunch() async throws {
        let fixture = try FakeTor()
        let runtime = fixture.runtime()
        defer { runtime.stop(); fixture.remove() }
        do {
            _ = try await runtime.start(upstream: .httpsConnect(host: "127.0.0.1", port: 8443))
            XCTFail("Tor must not silently downgrade TLS to the upstream proxy")
        } catch let error as TorRuntime.Failure {
            XCTAssertTrue(error.message.contains("TLS-to-proxy"))
        }
        XCTAssertNil(runtime.port)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.pid.path))
        guard case .failed = runtime.phase else { return XCTFail("The failure must be visible to settings") }
    }

    func testInvalidUpstreamAndIncompleteAccountNeverStartAChild() async throws {
        let fixture = try FakeTor()
        let runtime = fixture.runtime()
        defer { runtime.stop(); fixture.remove() }
        let invalid: [TorUpstream] = [
            .httpConnect(host: "127.0.0.1\nControlPort 9999", port: 8080),
            .socks5(host: "localhost", port: 0),
            .httpConnect(host: "localhost", port: 8080, username: "fixture-user", password: nil)
        ]
        for route in invalid {
            do { _ = try await runtime.start(upstream: route); XCTFail("Invalid route was accepted") }
            catch is TorRuntime.Failure { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.pid.path))
        }
    }

    func testConcurrentStartsShareAClientAndReadyStartDoesNotReplaceIt() async throws {
        let fixture = try FakeTor()
        let runtime = fixture.runtime()
        defer { runtime.stop(); fixture.remove() }
        let first = Task { try await runtime.start() }
        let second = Task { try await runtime.start() }
        try await until { runtime.phase == .starting(progress: 37) }
        let pid = try fixture.processID()
        try fixture.release()
        let firstPort = try await first.value
        let secondPort = try await second.value
        let existingPort = try await runtime.start()
        XCTAssertEqual(firstPort, FakeTor.port)
        XCTAssertEqual(secondPort, FakeTor.port)
        XCTAssertEqual(existingPort, FakeTor.port)
        XCTAssertEqual(try fixture.processID(), pid)
    }

    func testCancellationStopsTheChildAndClearsPublishedRoute() async throws {
        let fixture = try FakeTor()
        let runtime = fixture.runtime()
        defer { runtime.stop(); fixture.remove() }
        let connection = Task { try await runtime.start() }
        try await until { runtime.phase == .starting(progress: 37) }
        let pid = try fixture.processID()
        connection.cancel()
        do { _ = try await connection.value; XCTFail("Canceled start returned a route") }
        catch is CancellationError { }
        XCTAssertNil(runtime.port)
        XCTAssertEqual(runtime.phase, .idle)
        try await until { kill(pid, 0) != 0 }
    }

    func testBootstrapTimeoutStopsChildAndReportsBoundedError() async throws {
        let fixture = try FakeTor()
        // Include interpreter startup on a busy Mac; the fixture still
        // never emits bootstrap completion and must be killed at the limit.
        let runtime = fixture.runtime(timeout: 1.5)
        defer { runtime.stop(); fixture.remove() }
        do { _ = try await runtime.start(); XCTFail("A listening client cannot substitute for bootstrap") }
        catch let error as TorRuntime.Failure { XCTAssertTrue(error.message.contains("finish connecting")) }
        XCTAssertFalse(runtime.isReady)
        XCTAssertNil(runtime.port)
        let pid = try fixture.processID()
        try await until { kill(pid, 0) != 0 }
    }

    func testUnexpectedExitWithdrawsReadyRouteAndReportsFailure() async throws {
        let fixture = try FakeTor(held: false)
        let runtime = fixture.runtime()
        defer { runtime.stop(); fixture.remove() }
        _ = try await runtime.start()
        XCTAssertTrue(runtime.isReady)
        try fixture.exit()
        try await until { if case .failed = runtime.phase { return true }; return false }
        XCTAssertNil(runtime.port)
        XCTAssertFalse(runtime.isReady)
    }

    func testWarningTextCannotForgeBootstrapOrExposeCredentialsInErrors() async throws {
        let fixture = try FakeTor(warning: "fixture-secret [notice] Bootstrapped 100% (done): Done")
        let runtime = fixture.runtime(timeout: 0.3)
        defer { runtime.stop(); fixture.remove() }
        do { _ = try await runtime.start(); XCTFail("A warning must not be interpreted as bootstrap") }
        catch let error as TorRuntime.Failure { XCTAssertFalse(error.message.contains("fixture-secret")) }
        XCTAssertNil(runtime.port)
        if case .failed(let message) = runtime.phase { XCTAssertFalse(message.contains("fixture-secret")) }
        else { XCTFail("Timeout must be visible") }
    }

    func testChangingUpstreamTerminatesTheOldClientBeforeStartingAnother() async throws {
        let fixture = try FakeTor(held: false)
        let runtime = fixture.runtime()
        defer { runtime.stop(); fixture.remove() }
        _ = try await runtime.start(upstream: .httpConnect(host: "localhost", port: 8080))
        let before = try fixture.processID()
        _ = try await runtime.start(upstream: .socks5(host: "localhost", port: 1080))
        let after = try fixture.processID()
        XCTAssertNotEqual(before, after)
        try await until { kill(before, 0) != 0 }
        XCTAssertTrue(runtime.isReady)
        XCTAssertTrue(try String(contentsOf: fixture.configuration, encoding: .utf8).contains("Socks5Proxy"))
    }

    func testDefaultRuntimeNeverStartsRealTorInATestWorld() async throws {
        XCTAssertTrue(Store.testing)
        let runtime = TorRuntime()
        defer { runtime.stop() }
        do { _ = try await runtime.start(); XCTFail("A test must explicitly provide its synthetic executable") }
        catch let error as TorRuntime.Failure { XCTAssertTrue(error.message.contains("test")) }
        XCTAssertNil(runtime.port)
    }
}

@MainActor
private final class FakeTor {
    static let port: UInt16 = 42891
    let folder: URL
    let data: URL
    let script: URL
    let arguments: URL
    let configuration: URL
    let pid: URL
    private let releaseFile: URL
    private let exitFile: URL

    init(held: Bool = true, warning: String? = nil) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("search-tor-runtime-\(UUID().uuidString)", isDirectory: true)
        data = folder.appendingPathComponent("private Tor data", isDirectory: true)
        script = folder.appendingPathComponent("fake-tor.py")
        arguments = folder.appendingPathComponent("synthetic-arguments.json")
        configuration = folder.appendingPathComponent("synthetic-stdin.txt")
        pid = folder.appendingPathComponent("child.pid")
        releaseFile = folder.appendingPathComponent("release")
        exitFile = folder.appendingPathComponent("exit")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let program = """
        #!/usr/bin/python3
        import json, os, pathlib, sys, time
        pathlib.Path(\(String(reflecting: arguments.path))).write_text(json.dumps(sys.argv[1:]))
        pathlib.Path(\(String(reflecting: configuration.path))).write_text(sys.stdin.read())
        pathlib.Path(\(String(reflecting: pid.path))).write_text(str(os.getpid()))
        print('Oct 29 12:00:00.000 [notice] Socks listener listening on port \(Self.port).', flush=True)
        print('Oct 29 12:00:00.001 [notice] Bootstrapped 37% (loading_descriptors): Loading relay descriptors', flush=True)
        warning = \(warning.map { String(reflecting: $0) } ?? "None")
        if warning is not None:
            print('Oct 29 12:00:00.002 [warn] ' + warning, flush=True)
        while \(held ? "True" : "False") and not pathlib.Path(\(String(reflecting: releaseFile.path))).exists():
            time.sleep(0.01)
        print('Oct 29 12:00:00.003 [notice] Bootstrapped 100% (done): Done', flush=True)
        while not pathlib.Path(\(String(reflecting: exitFile.path))).exists():
            time.sleep(0.01)
        sys.exit(17)
        """
        try program.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    func runtime(timeout: TimeInterval = 4) -> TorRuntime {
        TorRuntime(executableURL: script, dataFolder: data, bootstrapTimeout: timeout)
    }

    func release() throws { try Data().write(to: releaseFile) }
    func exit() throws { try Data().write(to: exitFile) }
    func processID() throws -> pid_t { try XCTUnwrap(pid_t(String(contentsOf: pid, encoding: .utf8))) }
    func remove() { try? FileManager.default.removeItem(at: folder) }
}
