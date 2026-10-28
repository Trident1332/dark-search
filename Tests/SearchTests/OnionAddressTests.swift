import Foundation
import XCTest
@testable import Search

final class OnionAddressTests: XCTestCase {
    /// Shape-valid synthetic names; checksum and network reachability are
    /// deliberately outside these address-parsing tests.
    private let service = String(repeating: "a", count: 56)
    private var host: String { service + ".onion" }

    func testClassificationCannotBeEscapedByCaseOrRootDots() throws {
        XCTAssertEqual(OnionAddress.canonicalHost("SUB.\(host.uppercased())."), "sub.\(host)")
        for value in [host, host.uppercased(), host + ".", host + "..", "sub.\(host)", "onion"] {
            XCTAssertTrue(OnionAddress.isOnionHost(value), value)
        }
        for value in ["onions", "notonion", "onion.example", "\(host).example", "example.com"] {
            XCTAssertFalse(OnionAddress.isOnionHost(value), value)
        }
        XCTAssertTrue(OnionAddress.isOnion(try XCTUnwrap(URL(string: "https://SUB.\(host.uppercased())./x"))))
        XCTAssertTrue(OnionAddress.isOnion(try XCTUnwrap(URL(string: "ftp://\(host)/x"))),
                      "Classification is independent of whether a navigation scheme is supported")
        XCTAssertFalse(OnionAddress.isOnion(try XCTUnwrap(URL(string: "https://example.com/\(host)"))))
    }

    func testV3ShapeAndOptionalSubdomainsAreValidated() {
        for value in [host, host.uppercased(), host + ".", "www.\(host)", "one.two-3.\(host)",
                      String(repeating: "b", count: 63) + "." + host,
                      String(repeating: "ab2", count: 18) + "ab.onion"] {
            XCTAssertTrue(OnionAddress.isValidHost(value), value)
        }
        let invalid = ["onion", ".onion", String(repeating: "a", count: 16) + ".onion",
                       String(repeating: "a", count: 55) + ".onion", String(repeating: "a", count: 57) + ".onion",
                       String(repeating: "1", count: 56) + ".onion", String(repeating: "8", count: 56) + ".onion",
                       String(repeating: "é", count: 56) + ".onion", host + "..", "." + host,
                       "two..\(host)", "-sub.\(host)", "sub-.\(host)", "sub_name.\(host)",
                       String(repeating: "b", count: 64) + "." + host, " \(host)", host + ".example"]
        for value in invalid { XCTAssertFalse(OnionAddress.isValidHost(value), value) }
    }

    func testBareNamesUseHTTPAndExplicitHTTPSStaysHTTPS() throws {
        let bare = " \nSUB.\(host.uppercased())./Page?value=A#Part\n "
        XCTAssertEqual(OnionAddress.url(from: bare)?.absoluteString, "http://sub.\(host)/Page?value=A#Part")
        XCTAssertEqual(OnionAddress.url(from: "HTTPS://SUB.\(host.uppercased())./Page?value=A#Part")?.absoluteString,
                       "https://sub.\(host)/Page?value=A#Part")
        XCTAssertEqual(OnionAddress.url(from: "//\(host):8080/page")?.absoluteString, "http://\(host):8080/page")
        XCTAssertEqual(OnionAddress.url(from: host)?.absoluteString, "http://\(host)")
        XCTAssertEqual(OnionAddress.url(from: "http://\(host):80/page")?.port, 80)
    }

    func testMalformedOnionInputsRemainRecognizedButCannotNavigate() {
        for value in ["ftp://\(host)/", "file://\(host)/", "https://short.onion/", "http://\(host)../",
                      "\(host):0/", "\(host):65536/", "\(host)/a b", "\(host)/a\tb", "\(host)?q=a b",
                      "user@\(host)"] {
            XCTAssertTrue(OnionAddress.hasIntent(value), value)
            XCTAssertNil(OnionAddress.url(from: value), value)
        }
    }

    func testSearchGuardCoversPhrasesMalformedInputsAndPercentEncoding() {
        for value in ["visit short.onion now", "\(host) private words", "ABOUT \(host.uppercased())",
                      "bad.onion://", "abc%2Eonion", "https://abc%2eONION/path"] {
            XCTAssertTrue(OnionAddress.hasIntent(value), value)
        }
        for value in ["onion soup", "Tor websites", "example.com", "", "allium cepa"] {
            XCTAssertFalse(OnionAddress.hasIntent(value), value)
        }
    }
}
