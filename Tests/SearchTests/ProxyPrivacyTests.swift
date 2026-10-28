import AppKit
import CoreLocation
import Darwin
import WebKit
import XCTest
@testable import Search

/// No location service, saved account, or installed native host is used.
@MainActor
final class ProxyPrivacyTests: XCTestCase {
    private static let world = "proxy-privacy-tests-\(getpid())"

    override class func setUp() {
        setenv("SEARCH_PROBE", world, 1)
        super.setUp()
    }

    override class func tearDown() {
        Disk.drain()
        if Store.world == world {
            try? FileManager.default.removeItem(at: Store.folder)
            let domain = "com.officecommun.search.test.\(world)"
            UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        }
        super.tearDown()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        _ = Shared.prefs
        Proxy.shared.automaticTarget = nil
        Proxy.shared.take(ProxySetup())
        try await super.setUp()
    }

    override func tearDown() async throws {
        Proxy.shared.take(ProxySetup())
        for _ in 0..<100 where Proxy.shared.changingContent {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(Proxy.shared.changingContent)
        try await super.tearDown()
    }

    private func protect() {
        Proxy.shared.take(ProxySetup(on: true, kind: .http, host: "proxy-privacy.invalid", blocks: true, matchesTimeZone: false))
    }

    /// Use a real WebKit manager rather than handing its C API a fake pointer.
    private func manager() throws -> (WKProcessPool, UnsafeRawPointer) {
        let framework = dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_NOW)
        guard let symbol = dlsym(framework, "WKContextGetGeolocationManager") else {
            throw XCTSkip("WebKit geolocation provider is unavailable")
        }
        typealias GetManager = @convention(c) (UnsafeRawPointer) -> UnsafeRawPointer?
        let getManager = unsafeBitCast(symbol, to: GetManager.self)
        let pool = WKProcessPool()
        guard let manager = getManager(UnsafeRawPointer(Unmanaged.passUnretained(pool).toOpaque())) else {
            throw XCTSkip("WebKit did not create a geolocation manager")
        }
        return (pool, manager)
    }

    func testPersistentModeDoesNotCreateOrAskForCoreLocation() throws {
        let (pool, manager) = try manager()
        defer { withExtendedLifetime(pool) {} }
        let location = SiteLocation()
        var creations = 0
        location.makeLocator = { creations += 1; return FakeLocator() }
        protect()
        location.start(manager)
        XCTAssertEqual(creations, 0)
        location.stop(manager)
    }

    func testPersistentTransitionStopsExistingLocationAndRejectsLateCallbacks() throws {
        let (pool, manager) = try manager()
        defer { withExtendedLifetime(pool) {} }
        let location = SiteLocation()
        let locator = FakeLocator()
        var refusals = 0
        location.makeLocator = { locator }
        location.refused = { refusals += 1 }
        location.start(manager)
        XCTAssertEqual(locator.starts, 1)
        protect()
        location.proxyChanged()
        XCTAssertEqual(locator.stops, 1)
        locator.statusChanged?()
        locator.found?(CLLocation(latitude: 1, longitude: 2))
        locator.failed?(CLError(.denied))
        XCTAssertEqual(locator.starts, 1, "Late authorization must not restart the locator")
        XCTAssertEqual(locator.stops, 4, "Every late answer is stopped before it can reach a page")
        XCTAssertEqual(refusals, 0, "Proxy protection is not a macOS permission refusal")
        location.stop(manager)
    }

    @available(macOS 15.4, *)
    func testPersistentModeRejectsNativeHostBeforeResolvingItsManifest() async throws {
        protect()
        do {
            _ = try await ExtensionNative.send(["fixture": true], to: "invalid/host", from: "fixture-extension")
            XCTFail("An external native host must not launch in persistent mode")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Persistent connection"))
            XCTAssertFalse(error.localizedDescription.contains("Invalid native messaging host"))
        }
    }

    @available(macOS 15.4, *)
    func testPrivacyStopImmediatelyKillsAHostThatIgnoresTermination() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pidFile = folder.appendingPathComponent("host.pid")
        let script = folder.appendingPathComponent("host.py")
        try """
        #!/usr/bin/python3
        import os, signal, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        open(\(String(reflecting: pidFile.path)), "w").write(str(os.getpid()))
        time.sleep(60)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let pipe = HostPipe(program: script, origin: "chrome-extension://fixture/")
        defer { pipe.stopImmediately() }
        try pipe.start()
        var pid: pid_t?
        for _ in 0..<100 {
            pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0) }
            if pid != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let running = try XCTUnwrap(pid, "The synthetic host should finish its startup handshake")
        XCTAssertEqual(kill(running, 0), 0)
        pipe.stopImmediately()
        for _ in 0..<50 {
            if kill(running, 0) != 0 { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("A privacy transition must not give a native host the normal termination grace")
    }

    private final class FakeLocator: Locating {
        var status: CLAuthorizationStatus = .authorizedAlways
        var precise = false
        var starts = 0
        var stops = 0
        var asks = 0
        var statusChanged: (() -> Void)?
        var found: ((CLLocation) -> Void)?
        var failed: ((Error) -> Void)?
        func ask() { asks += 1 }
        func start() { starts += 1 }
        func stop() { stops += 1 }
    }
}
