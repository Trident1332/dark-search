import AppKit
import Foundation
import XCTest
@testable import Search

/// Synthetic loaders exercise route deferral and stale completions without
/// contacting GitHub, touching real credentials, or installing an update.
@MainActor
final class UpdaterProxyStateTests: XCTestCase {
    private var previousSetup: ProxySetup!
    private var previousTarget: URL?
    private var previousInstallPolicy: Any?
    private var previousPolicy = NSApplication.ActivationPolicy.prohibited

    override class func setUp() {
        setenv("SEARCH_PROBE", "updater-proxy-state-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        _ = Shared.prefs
        previousSetup = Proxy.shared.setup
        previousTarget = Proxy.shared.automaticTarget
        previousInstallPolicy = Store.settings.object(forKey: Updater.installKey)
        Store.settings.set(false, forKey: Updater.installKey)
        Proxy.shared.automaticTarget = nil
        Proxy.shared.take(ProxySetup())
        try await until { !Proxy.shared.changingContent }
    }

    override func tearDown() async throws {
        Proxy.shared.automaticTarget = previousTarget
        Proxy.shared.take(previousSetup)
        try await until { !Proxy.shared.changingContent }
        if let previousInstallPolicy { Store.settings.set(previousInstallPolicy, forKey: Updater.installKey) }
        else { Store.settings.removeObject(forKey: Updater.installKey) }
        NSApp.setActivationPolicy(previousPolicy)
        try await super.tearDown()
    }

    private func release(build: Int = Updater.build) -> Updater.Release {
        Updater.Release(version: "fixture", build: build,
                        archive: URL(string: "https://github.com/Trident1332/dark-search/releases/download/test/Search.zip")!,
                        dmg: URL(string: "https://github.com/Trident1332/dark-search/releases/download/test/Search.dmg")!,
                        sha256: nil, notes: nil, minimumSystemVersion: nil)
    }

    private func check(_ updater: Updater) async -> Updater.CheckResult {
        await withCheckedContinuation { completion in updater.check { completion.resume(returning: $0) } }
    }

    func testIncompleteProxyDefersWithoutFetchingAndResumesWhenTurnedOff() async throws {
        Proxy.shared.take(ProxySetup(on: true, host: "", blocks: false, matchesTimeZone: false))
        let current = release()
        var calls = 0
        let updater = Updater(fetchFeed: { calls += 1; return current })
        let result = await check(updater)
        guard case .deferred(let reason) = result else { return XCTFail("An incomplete route must defer the check") }
        XCTAssertTrue(reason.contains("Enter its address"))
        XCTAssertEqual(calls, 0, "No feed request may reach the placeholder proxy")
        XCTAssertTrue(updater.waitingForConnection)
        XCTAssertFalse(updater.checking, "Waiting for credentials or connection must not leave Checking spinning")
        XCTAssertNil(updater.lastCheckFailure)
        XCTAssertNil(updater.lastChecked)

        Proxy.shared.take(ProxySetup())
        try await until { updater.lastChecked != nil }
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(updater.waitingForConnection)
        XCTAssertFalse(updater.checking)
    }

    func testMissingProxyCredentialsDeferWithCredentialReasonWithoutDNSRequest() async throws {
        let route = ProxySetup(on: true, kind: .http, host: "missing-credential-fixture.invalid", port: 8080,
                               signsIn: true, user: "fixture-\(UUID())", blocks: false, matchesTimeZone: false)
        Proxy.shared.take(route)
        let issue = try XCTUnwrap(Proxy.shared.credentialIssue)
        let current = release()
        var calls = 0
        let updater = Updater(fetchFeed: { calls += 1; return current })
        let result = await check(updater)
        guard case .deferred(let reason) = result else { return XCTFail("Unavailable proxy credentials must defer the check") }
        XCTAssertTrue(reason.contains(issue))
        XCTAssertFalse(reason.contains("missing-proxy.invalid"))
        XCTAssertTrue(updater.waitingForConnection)
        XCTAssertFalse(updater.checking)
        XCTAssertNil(updater.lastCheckFailure)
        NotificationCenter.default.post(name: Proxy.connectionRestored, object: nil)
        await Task.yield()
        XCTAssertEqual(calls, 0, "A recovery signal alone cannot authorize an unavailable route")
        XCTAssertTrue(updater.waitingForConnection)
    }

    func testRealDNSFailureRemainsFailureAndRecoverySignalDoesNotLoop() async throws {
        var calls = 0
        let updater = Updater(fetchFeed: { calls += 1; throw URLError(.cannotFindHost) })
        let result = await check(updater)
        XCTAssertEqual(result, .failed(URLError(.cannotFindHost).localizedDescription))
        XCTAssertNotNil(updater.lastCheckFailure)
        XCTAssertNil(updater.lastChecked)
        XCTAssertFalse(updater.waitingForConnection)
        NotificationCenter.default.post(name: Proxy.connectionRestored, object: nil)
        await Task.yield()
        XCTAssertEqual(calls, 1, "An unrelated recovery signal must not retry a genuine feed failure")
    }

    func testIdleUpdaterDoesNotCheckOnProxyNotifications() async throws {
        var calls = 0
        let current = release()
        let updater = Updater(fetchFeed: { calls += 1; return current })
        NotificationCenter.default.post(name: Proxy.connectionRestored, object: nil)
        NotificationCenter.default.post(name: Proxy.routeChanged, object: nil)
        await Task.yield()
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(updater.checking)
        XCTAssertFalse(updater.waitingForConnection)
    }

    func testRetiredCheckCannotOverwriteFreshRetryOrCompleteItsCallbackTwice() async throws {
        let current = release(), stale = release(build: Updater.build + 1)
        var held: CheckedContinuation<Updater.Release, Never>?
        defer { held?.resume(returning: stale) }
        var calls = 0
        var initialResults: [Updater.CheckResult] = []
        let updater = Updater(fetchFeed: {
            calls += 1
            if calls == 1 { return await withCheckedContinuation { held = $0 } }
            return current
        })
        updater.check { initialResults.append($0) }
        try await until { calls == 1 && held != nil }
        Proxy.shared.take(ProxySetup(on: true, kind: .http, host: "held-proxy-fixture.invalid", port: 8080))
        XCTAssertTrue(updater.waitingForConnection)
        XCTAssertFalse(updater.checking)
        XCTAssertEqual(initialResults.count, 1)
        guard case .some(.deferred(_)) = initialResults.first else { return XCTFail("A changed route must retire its in-flight result") }
        Proxy.shared.take(ProxySetup())
        try await until { updater.lastChecked != nil }
        let checked = updater.lastChecked
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(updater.stage, .none)
        let completion = try XCTUnwrap(held)
        held = nil
        completion.resume(returning: stale)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(initialResults.count, 1, "The old callback is completed only when its attempt is retired")
        XCTAssertEqual(updater.lastChecked, checked)
        XCTAssertEqual(updater.stage, .none, "A late release from the old route must not replace the new check")
        XCTAssertNil(updater.lastCheckFailure)
        XCTAssertFalse(updater.waitingForConnection)
        XCTAssertFalse(updater.checking)
    }
}

private extension UpdaterProxyStateTests {
    func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard condition() else { XCTFail("The isolated updater state did not settle"); throw URLError(.timedOut) }
    }
}
