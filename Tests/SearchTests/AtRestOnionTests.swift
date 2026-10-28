import Foundation
import XCTest
@testable import Search

final class AtRestOnionTests: XCTestCase {
    private var host: String { String(repeating: "a", count: 56) + ".onion" }

    func testOnionHTTPNeedsTorContextBeforeLosingThePlainHTTPWarning() throws {
        let url = try XCTUnwrap(URL(string: "http://\(host)/path"))
        let ordinary = try XCTUnwrap(AtRest.make(url))
        XCTAssertEqual(ordinary.kind, .notSecure)
        XCTAssertTrue(ordinary.warns)
        XCTAssertTrue(ordinary.text.hasPrefix("Not secure — "))

        let tor = try XCTUnwrap(AtRest.make(url, tor: true))
        XCTAssertEqual(tor.kind, .onion)
        XCTAssertFalse(tor.warns)
        XCTAssertEqual(tor.text, host)
        XCTAssertFalse(tor.text.contains("Not secure"))
        XCTAssertNil(AtRest.said(url, always: false, tor: true))
        XCTAssertEqual(AtRest.said(url, always: true, tor: true)?.kind, .onion)
        XCTAssertEqual(AtRest.said(url, always: false)?.kind, .notSecure)
    }

    func testClearnetHTTPThroughTorStillWarnsAboutPlaintext() throws {
        let url = try XCTUnwrap(URL(string: "http://example.com/path"))
        let rest = try XCTUnwrap(AtRest.make(url, tor: true))
        XCTAssertEqual(rest.kind, .notSecure)
        XCTAssertTrue(rest.warns)
        XCTAssertEqual(rest.text, "Not secure — example.com")
        XCTAssertEqual(AtRest.said(url, always: false, tor: true), rest)
    }

    func testMalformedOnionNamesNeverReceiveTheOnionConnectionKind() throws {
        for address in ["http://short.onion/", "http://\(host)../", "http://\(host).example/"] {
            let url = try XCTUnwrap(URL(string: address))
            let rest = try XCTUnwrap(AtRest.make(url, tor: true))
            XCTAssertEqual(rest.kind, .notSecure, address)
            XCTAssertTrue(rest.warns, address)
        }
    }

    func testSubdomainCaseRootDotAndNonstandardPortKeepTheFullIdentity() throws {
        let url = try XCTUnwrap(URL(string: "http://SUB.\(host.uppercased()).:8080/path"))
        let rest = try XCTUnwrap(AtRest.make(url, tor: true))
        XCTAssertEqual(rest.kind, .onion)
        XCTAssertEqual(rest.lead, "sub.")
        XCTAssertEqual(rest.name, host)
        XCTAssertEqual(rest.tail, ":8080")
        XCTAssertEqual(rest.text, "sub.\(host):8080")
    }

    func testHTTPSClassificationIsUnchangedByTheTorRoute() throws {
        for address in ["https://\(host)/", "https://example.com/"] {
            let url = try XCTUnwrap(URL(string: address))
            XCTAssertEqual(AtRest.make(url, tor: true), AtRest.make(url), address)
            XCTAssertEqual(AtRest.make(url, tor: true)?.kind, .secure, address)
        }
    }

    func testCacheKeepsTorAndOrdinaryClassificationsSeparateInBothOrders() throws {
        for (index, firstTor) in [false, true].enumerated() {
            let url = try XCTUnwrap(URL(string: "http://\(host)/cache-\(index)"))
            let first = try XCTUnwrap(AtRest.of(url, tor: firstTor))
            let second = try XCTUnwrap(AtRest.of(url, tor: !firstTor))
            XCTAssertEqual(first.kind, firstTor ? .onion : .notSecure)
            XCTAssertEqual(second.kind, firstTor ? .notSecure : .onion)
            XCTAssertEqual(AtRest.of(url, tor: firstTor), first)
            XCTAssertEqual(AtRest.of(url, tor: !firstTor), second)
        }
    }
}
