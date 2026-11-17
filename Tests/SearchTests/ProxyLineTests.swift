import XCTest
@testable import Search

final class ProxyLineTests: XCTestCase {
    func testProviderUsernameIsPreservedVerbatim() throws {
        let user = "account,mobile,unitedstates,newyork,newyork,6167,unique,samecarrier,-,-,session,udp"
        let line = try ProxyLine.parse("proxy.example:1080:\(user):synthetic-password", kind: .socks5)
        XCTAssertEqual(line.host, "proxy.example")
        XCTAssertEqual(line.port, "1080")
        XCTAssertEqual(line.user, user)
        XCTAssertEqual(line.password, "synthetic-password")
        XCTAssertEqual(line.kind, .socks5)
    }

    func testPasswordsKeepColonsAndURLCharacters() throws {
        for password in ["first:second:third", "https://example.test/a?#@,%", "a b", "p%40ss"] {
            let line = try ProxyLine.parse("proxy.example:1080:user:\(password)", kind: .http)
            XCTAssertEqual(line.password, password)
            XCTAssertEqual(line.kind, .http)
        }
    }

    func testExplicitSchemeOverridesSelectedType() throws {
        for kind in ProxyKind.allCases {
            let line = try ProxyLine.parse("\(kind.rawValue.uppercased())://proxy.example:1234:user:password", kind: .http)
            XCTAssertEqual(line.kind, kind)
        }
    }

    func testEndpointWithoutAuthenticationAndOuterWhitespace() throws {
        let line = try ProxyLine.parse(" \nproxy.example:08080\r\n", kind: .https)
        XCTAssertEqual(line.host, "proxy.example")
        XCTAssertEqual(line.port, "8080")
        XCTAssertNil(line.password)
        XCTAssertEqual(line.user, "")
        XCTAssertFalse(line.filling(SavedProxy(signsIn: true, user: "old")).signsIn)
    }

    func testBracketedIPv6() throws {
        let line = try ProxyLine.parse("socks5://[2001:db8::1]:1080:user:p:a:ss", kind: .http)
        XCTAssertEqual(line.host, "2001:db8::1")
        XCTAssertEqual(line.password, "p:a:ss")
    }

    func testInvalidInputNeverEchoesCredentialsInErrors() {
        for input in ["", "proxy.example", ":1080", "bad host:1080", "host/path:1080", "host@other:1080", "[invalid]:1080", "[::1]1080", "host:0", "host:65536", "host:-1", "host:1.5", "host:abc", "host:١٢", "host:1080:user", "host:1080::secret", "host:1080:user:", "ftp://host:1080:user:secret", "host:1080:user:secret\nhost:1080"] {
            XCTAssertThrowsError(try ProxyLine.parse(input, kind: .socks5), input) { error in
                XCTAssertFalse(error.localizedDescription.contains("secret"))
            }
        }
    }

    func testFillingPreservesSavedNameAndIdentityWithoutEncodingThePassword() throws {
        let original = SavedProxy(name: "My proxy")
        let line = try ProxyLine.parse("host.example:1234:account,mobile:synthetic-secret", kind: .socks5)
        let filled = line.filling(original)
        XCTAssertEqual(filled.id, original.id)
        XCTAssertEqual(filled.name, original.name)
        XCTAssertTrue(filled.signsIn)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(filled), as: UTF8.self).contains("synthetic-secret"))
    }
}
