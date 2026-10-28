import Foundation
import XCTest
@testable import Search

@MainActor
final class UpdaterCheckTests: XCTestCase {
    private var previousInstallPolicy: Any?

    override class func setUp() {
        setenv("SEARCH_PROBE", "updater-check-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        previousInstallPolicy = Store.settings.object(forKey: Updater.installKey)
        Store.settings.set(false, forKey: Updater.installKey)
        try await super.setUp()
    }

    override func tearDown() async throws {
        if let previousInstallPolicy {
            Store.settings.set(previousInstallPolicy, forKey: Updater.installKey)
        } else {
            Store.settings.removeObject(forKey: Updater.installKey)
        }
        try await super.tearDown()
    }

    private func release(build: Int, minimum: String? = nil) -> Updater.Release {
        Updater.Release(version: "test", build: build,
                        archive: URL(string: "https://github.com/Trident1332/dark-search/releases/download/test/Search.zip")!,
                        dmg: URL(string: "https://github.com/Trident1332/dark-search/releases/download/test/Search.dmg")!,
                        sha256: nil, notes: nil, minimumSystemVersion: minimum)
    }

    private func check(_ updater: Updater) async -> Updater.CheckResult {
        await withCheckedContinuation { done in
            updater.check { done.resume(returning: $0) }
        }
    }

    func testNetworkFailureIsNotReportedAsUpToDate() async {
        let updater = Updater(fetchFeed: { throw URLError(.notConnectedToInternet) })
        let result = await check(updater)
        guard case .failed = result else { return XCTFail("An unreachable feed must fail the check") }
        XCTAssertNotNil(updater.lastCheckFailure)
        XCTAssertNil(updater.lastChecked, "A failed attempt is not a successful check")
        XCTAssertFalse(updater.checking)
        XCTAssertFalse(result.message?.contains("up to date") ?? true)
    }

    func testUnverifiedFeedIsReportedAsFailure() async {
        let updater = Updater(fetchFeed: {
            let data = try Updater.verifiedFeed(Data("unsigned or damaged feed".utf8))
            return try Updater.release(from: data)
        })
        let result = await check(updater)
        XCTAssertEqual(result, .failed(Updater.FeedFailure.unverified.localizedDescription))
        XCTAssertNil(updater.lastChecked)
    }

    func testMalformedVerifiedFeedIsReportedAsFailure() async {
        let updater = Updater(fetchFeed: { try Updater.release(from: Data(#"{"version":"test"}"#.utf8)) })
        let result = await check(updater)
        XCTAssertEqual(result, .failed(Updater.FeedFailure.malformed.localizedDescription))
        XCTAssertNil(updater.lastChecked)
    }

    func testValidCurrentReleaseIsUpToDate() async {
        let current = release(build: Updater.build)
        let updater = Updater(fetchFeed: { current })
        let result = await check(updater)
        XCTAssertEqual(result, .upToDate)
        XCTAssertEqual(result.message, "Search is up to date")
        XCTAssertNotNil(updater.lastChecked)
        XCTAssertNil(updater.lastCheckFailure)
        XCTAssertEqual(updater.stage, .none)
    }

    func testValidNewReleaseIsStillOffered() async {
        let newer = release(build: Updater.build + 1)
        let updater = Updater(fetchFeed: { newer })
        let result = await check(updater)
        XCTAssertEqual(result, .available(newer))
        XCTAssertEqual(updater.stage, .waiting(newer))
        XCTAssertNotNil(updater.lastChecked)
        XCTAssertNil(result.message, "The available-update path announces its own next step")
    }

    func testReleaseForNewerMacIsNotOffered() async {
        let newer = release(build: Updater.build + 1, minimum: "99.0")
        let updater = Updater(fetchFeed: { newer })
        let result = await check(updater)
        XCTAssertEqual(result, .upToDate)
        XCTAssertEqual(updater.stage, .none)
    }

    func testLaterFailurePreservesKnownUpdateAndSuccessfulTimestamp() async {
        let newer = release(build: Updater.build + 1)
        var shouldFail = false
        let updater = Updater(fetchFeed: {
            if shouldFail { throw URLError(.cannotConnectToHost) }
            return newer
        })
        _ = await check(updater)
        let lastSuccess = updater.lastChecked
        shouldFail = true
        let failed = await check(updater)
        guard case .failed = failed else { return XCTFail("The later network failure must remain distinguishable") }
        XCTAssertEqual(updater.stage, .waiting(newer))
        XCTAssertEqual(updater.lastChecked, lastSuccess)
        XCTAssertNotNil(updater.lastCheckFailure)
    }

    func testManualFailureAnnouncesFailureAndCanRecover() async throws {
        var fail = true
        let current = release(build: Updater.build)
        var messages: [String] = []
        let updater = Updater(fetchFeed: {
            if fail { throw URLError(.timedOut) }
            return current
        }, announce: { messages.append($0) })
        updater.checkByHand()
        try await until { !updater.checking }
        XCTAssertTrue(messages.last?.hasPrefix("Couldn't check for updates.") == true)
        XCTAssertFalse(messages.contains("Search is up to date"))
        fail = false
        updater.checkByHand()
        try await until { !updater.checking }
        XCTAssertEqual(messages.last, "Search is up to date")
        XCTAssertNil(updater.lastCheckFailure)
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The injected check did not finish")
    }
}
