import Foundation
import XCTest
@testable import Search

final class DialerRelayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var endpoint: DialerRelayEndpoint { try! DialerRelayEndpoint(wss: "wss://phone.example.invalid:7443") }

    private func ticket(url: String = "turns:phone.example.invalid:5349?transport=tcp",
                        expires: Double = 1_800_003_600, ttl: Int = 3600,
                        username: String = "1800003600:test-seat:nonce", credential: String = "synthetic-only") -> DialerRelayTicket {
        DialerRelayTicket(iceServers: [.init(urls: [url], username: username, credential: credential)], expiresAt: expires, ttl: ttl)
    }

    func testIssuerKeepsTheConfiguredSecurePhoneServerAndFixedPath() throws {
        let endpoint = try DialerRelayEndpoint(wss: "wss://PHONE.example.invalid:7443/a?b=c")
        XCTAssertEqual(endpoint.host, "phone.example.invalid")
        XCTAssertEqual(endpoint.issuer.absoluteString, "https://phone.example.invalid/search-dialer/turn")
    }

    func testInsecureOrCredentialBearingPhoneServersCannotReceiveSavedLogin() {
        for wss in ["ws://phone.example.invalid", "https://phone.example.invalid", "wss://user@phone.example.invalid",
                    "wss://user:password@phone.example.invalid", "wss://phone.example.invalid/#other", "wss://example.onion"] {
            XCTAssertThrowsError(try DialerRelayEndpoint(wss: wss), wss)
        }
    }

    func testValidTicketKeepsCredentialsAndVerifiedRemoteTLSIdentity() throws {
        let result = try ticket().validated(for: endpoint, now: now)
        XCTAssertEqual(result.host, endpoint.host)
        XCTAssertEqual(result.port, 5349)
        XCTAssertEqual(result.username, "1800003600:test-seat:nonce")
        XCTAssertEqual(result.credential, "synthetic-only")
    }

    func testTicketCannotAddAnotherRelayOrStandaloneSTUNServer() {
        let server = DialerRelayTicket.Server(urls: ["turns:phone.example.invalid:5349?transport=tcp"], username: "seat", credential: "test")
        let extra = DialerRelayTicket(iceServers: [server, server], expiresAt: now.timeIntervalSince1970 + 3600, ttl: 3600)
        XCTAssertThrowsError(try extra.validated(for: endpoint, now: now))
        let urls = DialerRelayTicket(iceServers: [.init(urls: server.urls + ["stun:other.example.invalid"], username: "seat", credential: "test")],
                                    expiresAt: now.timeIntervalSince1970 + 3600, ttl: 3600)
        XCTAssertThrowsError(try urls.validated(for: endpoint, now: now))
    }

    func testTicketCannotChangeHostTransportTrustOrDestinationPath() {
        for url in ["stun:phone.example.invalid:5349", "turn:phone.example.invalid:5349?transport=tcp",
                    "turns:other.example.invalid:5349?transport=tcp", "turns:phone.example.invalid.evil:5349?transport=tcp",
                    "turns:user@phone.example.invalid:5349?transport=tcp", "turns:phone.example.invalid:5349/path?transport=tcp",
                    "turns:phone.example.invalid:5349?transport=udp", "turns:phone.example.invalid:5349?transport=tcp&other=1",
                    "turns:phone.example.invalid:5349?transport=tcp#fragment", "turns:phone.example.invalid:0?transport=tcp",
                    "turns:phone.example.invalid:65536?transport=tcp"] {
            XCTAssertThrowsError(try ticket(url: url).validated(for: endpoint, now: now), url)
        }
    }

    func testExpiredOrImplausibleCredentialsCannotStartAnotherCall() {
        for expires in [now.timeIntervalSince1970 - 1, now.timeIntervalSince1970 + 60,
                        now.timeIntervalSince1970 + 14_461, .infinity, .nan] {
            XCTAssertThrowsError(try ticket(expires: expires).validated(for: endpoint, now: now))
        }
        XCTAssertThrowsError(try ticket(ttl: 120).validated(for: endpoint, now: now))
        XCTAssertThrowsError(try ticket(ttl: 14_401).validated(for: endpoint, now: now))
    }

    func testEmptyOrUnboundedCredentialFieldsAreRejected() {
        for value in ["", String(repeating: "a", count: 257), "bad\nvalue", "bad\0value"] {
            XCTAssertThrowsError(try ticket(username: value).validated(for: endpoint, now: now))
            XCTAssertThrowsError(try ticket(credential: value).validated(for: endpoint, now: now))
        }
    }
}
