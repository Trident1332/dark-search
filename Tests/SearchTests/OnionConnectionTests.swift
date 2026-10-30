import AppKit
import Foundation
import XCTest
@testable import Search

/// A temporary child announces synthetic Tor startup. No relay or public
/// destination is contacted; a file releases the controlled bootstrap.
@MainActor
final class OnionConnectionTests: XCTestCase {
    private var previousSetup: ProxySetup!
    private var previousTarget: URL?

    override class func setUp() {
        setenv("SEARCH_PROBE", "onion-connection-tests-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        previousSetup = Proxy.shared.setup
        previousTarget = Proxy.shared.automaticTarget
        Proxy.shared.automaticTarget = nil
        Proxy.shared.take(ProxySetup())
        for _ in 0..<100 where Proxy.shared.changingContent { try await Task.sleep(for: .milliseconds(20)) }
    }

    override func tearDown() async throws {
        Proxy.shared.automaticTarget = previousTarget
        Proxy.shared.take(previousSetup)
        for _ in 0..<100 where Proxy.shared.changingContent { try await Task.sleep(for: .milliseconds(20)) }
        try await super.tearDown()
    }

    func testCancellingCreatorKeepsSurvivingTabsSharedRouteReady() async throws {
        try await checkCancelledWaiter(creator: true)
    }

    func testCancellingJoinerKeepsCreatorsSharedRouteReady() async throws {
        try await checkCancelledWaiter(creator: false)
    }

    private func checkCancelledWaiter(creator: Bool) async throws {
        let fixture = try ConnectionTorFixture()
        let runtime = fixture.runtime()
        let onion = Onion(runtime: runtime)
        defer { onion.stop(); fixture.remove() }
        let first = Task { try await onion.connect() }
        try await until { runtime.phase == .starting(progress: 37) }
        var joined = false
        let second = Task { joined = true; return try await onion.connect() }
        try await until { joined }
        let cancelled = creator ? first : second
        let surviving = creator ? second : first
        cancelled.cancel()
        try fixture.release()
        do { _ = try await cancelled.value; XCTFail("A cancelled tab must not receive a route") }
        catch is CancellationError { }
        let port = try await surviving.value
        XCTAssertEqual(port, ConnectionTorFixture.port)
        XCTAssertTrue(runtime.isReady)
        XCTAssertTrue(onion.ready, "One tab's cancelled wait cannot withdraw another tab's route")
        XCTAssertEqual(onion.port, ConnectionTorFixture.port)
        let reused = try await onion.connect()
        XCTAssertEqual(reused, port, "The published route stays available to later tabs")
        XCTAssertFalse(onion.isConnecting)
    }

    func testFailedSharedBootstrapDoesNotPublishARoute() async throws {
        let fixture = try ConnectionTorFixture(fails: true)
        let runtime = fixture.runtime()
        let onion = Onion(runtime: runtime)
        defer { onion.stop(); fixture.remove() }
        let first = Task { try await onion.connect() }
        try await until { runtime.phase == .starting(progress: 37) }
        var joined = false
        let second = Task { joined = true; return try await onion.connect() }
        try await until { joined }
        try fixture.release()
        for waiter in [first, second] {
            do { _ = try await waiter.value; XCTFail("Failed bootstrap must not return a route") }
            catch is TorRuntime.Failure { }
        }
        XCTAssertFalse(onion.ready)
        XCTAssertNil(onion.port)
        XCTAssertFalse(runtime.isReady)
        XCTAssertFalse(onion.isConnecting)
    }

    func testStoppingSharedStartupCancelsAllWaitersAndKeepsRouteClosed() async throws {
        let fixture = try ConnectionTorFixture()
        let runtime = fixture.runtime()
        let onion = Onion(runtime: runtime)
        defer { onion.stop(); fixture.remove() }
        let first = Task { try await onion.connect() }
        try await until { runtime.phase == .starting(progress: 37) }
        var joined = false
        let second = Task { joined = true; return try await onion.connect() }
        try await until { joined }
        onion.stop()
        for waiter in [first, second] {
            do { _ = try await waiter.value; XCTFail("Stopping Tor must cancel all waiters") }
            catch is CancellationError { }
        }
        XCTAssertFalse(onion.ready)
        XCTAssertNil(onion.port)
        XCTAssertEqual(runtime.phase, .idle)
        XCTAssertFalse(onion.isConnecting)
    }

    private func until(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard condition() else { XCTFail("Synthetic Tor did not reach its expected state"); throw URLError(.timedOut) }
    }
}

@MainActor
private final class ConnectionTorFixture {
    static let port: UInt16 = 42891
    let folder: URL
    private let script: URL
    private let releaseFile: URL

    init(fails: Bool = false) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("onion-connection-fixture-\(UUID())")
        script = folder.appendingPathComponent("fake-tor.py")
        releaseFile = folder.appendingPathComponent("release")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let source = """
        #!/usr/bin/python3
        import pathlib, sys, time
        sys.stdin.read()
        print('Oct 30 00:00:00.000 [notice] Socks listener listening on port \(Self.port).', flush=True)
        print('Oct 30 00:00:00.001 [notice] Bootstrapped 37% (loading_descriptors): Fixture', flush=True)
        while not pathlib.Path(\(String(reflecting: releaseFile.path))).exists():
            time.sleep(0.01)
        if \(fails ? "True" : "False"):
            sys.exit(17)
        print('Oct 30 00:00:00.002 [notice] Bootstrapped 100% (done): Done', flush=True)
        while True:
            time.sleep(0.01)
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    func runtime() -> TorRuntime {
        TorRuntime(executableURL: script, dataFolder: folder.appendingPathComponent("data"), bootstrapTimeout: 8)
    }
    func release() throws { try Data().write(to: releaseFile) }
    func remove() { try? FileManager.default.removeItem(at: folder) }
}
