import XCTest
@testable import Search

/// Password lookup contracts use only the isolated, in-memory test store.
/// No real keychain item is read, changed, or printed.
@MainActor
final class ProxyPasswordTests: XCTestCase {
    private static let world = "proxy-password-tests-\(getpid())"
    private var accounts: [ProxySetup] = []

    override class func setUp() {
        setenv("SEARCH_PROBE", world, 1)
        super.setUp()
    }

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(Store.testing, "Password tests require an isolated test world")
    }

    override func tearDown() async throws {
        for account in accounts { ProxyPassword.forget(account) }
        accounts.removeAll()
        try await super.tearDown()
    }

    private func account(_ kind: ProxyKind = .http) -> ProxySetup {
        let setup = ProxySetup(kind: kind, host: "proxy-password.invalid", port: 12323,
                               signsIn: true, user: "synthetic-\(UUID().uuidString)")
        accounts.append(setup)
        return setup
    }

    func testHTTPPasswordCanBeUsedAfterSwitchingToHTTPS() {
        let http = account()
        XCTAssertTrue(ProxyPassword.save("synthetic-http-password", for: http))
        var https = http
        https.kind = .https
        XCTAssertEqual(ProxyPassword.read(https), "synthetic-http-password")
        XCTAssertTrue(ProxyPassword.kept(https))
    }

    func testHTTPSPasswordCanBeUsedAfterSwitchingToHTTP() {
        let https = account(.https)
        XCTAssertTrue(ProxyPassword.save("synthetic-https-password", for: https))
        var http = https
        http.kind = .http
        XCTAssertEqual(ProxyPassword.read(http), "synthetic-https-password")
        XCTAssertTrue(ProxyPassword.kept(http))
    }

    func testSelectedTypePasswordTakesPrecedence() {
        let http = account()
        var https = http
        https.kind = .https
        XCTAssertTrue(ProxyPassword.save("synthetic-http-password", for: http))
        XCTAssertTrue(ProxyPassword.save("synthetic-https-password", for: https))
        XCTAssertEqual(ProxyPassword.read(http), "synthetic-http-password")
        XCTAssertEqual(ProxyPassword.read(https), "synthetic-https-password")
    }

    func testFallbackNeverCrossesHostPortOrUsername() {
        let https = account(.https)
        XCTAssertTrue(ProxyPassword.save("synthetic-password", for: https))
        var http = https
        http.kind = .http
        var otherHost = http
        otherHost.host = "another-proxy.invalid"
        var otherPort = http
        otherPort.port = 12324
        var otherUser = http
        otherUser.user += "-other"
        for setup in [otherHost, otherPort, otherUser] {
            XCTAssertNil(ProxyPassword.read(setup))
            XCTAssertFalse(ProxyPassword.kept(setup))
        }
    }

    func testSOCKSPasswordsAreSeparateFromHTTPAndHTTPS() {
        let socks = account(.socks5)
        XCTAssertTrue(ProxyPassword.save("synthetic-socks-password", for: socks))
        for kind in [ProxyKind.http, .https] {
            var other = socks
            other.kind = kind
            XCTAssertNil(ProxyPassword.read(other))
            XCTAssertFalse(ProxyPassword.kept(other))
        }
        let http = account()
        XCTAssertTrue(ProxyPassword.save("synthetic-http-password", for: http))
        var other = http
        other.kind = .socks5
        XCTAssertNil(ProxyPassword.read(other))
        XCTAssertFalse(ProxyPassword.kept(other))
    }

    func testForgettingEitherHTTPTransportRemovesBothSavedEntries() {
        for kind in [ProxyKind.http, .https] {
            let http = account()
            var https = http
            https.kind = .https
            XCTAssertTrue(ProxyPassword.save("synthetic-http-password", for: http))
            XCTAssertTrue(ProxyPassword.save("synthetic-https-password", for: https))
            var selected = http
            selected.kind = kind
            XCTAssertTrue(ProxyPassword.forget(selected))
            XCTAssertNil(ProxyPassword.read(http))
            XCTAssertNil(ProxyPassword.read(https))
            XCTAssertFalse(ProxyPassword.kept(http))
            XCTAssertFalse(ProxyPassword.kept(https))
        }
    }

    func testSavingEmptyPasswordCannotResurrectAnAlternateEntry() {
        let https = account(.https)
        XCTAssertTrue(ProxyPassword.save("synthetic-password", for: https))
        var http = https
        http.kind = .http
        XCTAssertTrue(ProxyPassword.save("", for: http))
        XCTAssertNil(ProxyPassword.read(http))
        XCTAssertNil(ProxyPassword.read(https))
        XCTAssertFalse(ProxyPassword.kept(http))
    }

    func testForgettingHTTPDoesNotDeleteSOCKSAndViceVersa() {
        let http = account()
        var socks = http
        socks.kind = .socks5
        XCTAssertTrue(ProxyPassword.save("synthetic-http-password", for: http))
        XCTAssertTrue(ProxyPassword.save("synthetic-socks-password", for: socks))
        XCTAssertTrue(ProxyPassword.forget(http))
        XCTAssertEqual(ProxyPassword.read(socks), "synthetic-socks-password")
        XCTAssertTrue(ProxyPassword.save("synthetic-http-password", for: http))
        XCTAssertTrue(ProxyPassword.forget(socks))
        XCTAssertEqual(ProxyPassword.read(http), "synthetic-http-password")
    }
}
