import AppKit
import Foundation
import Network
import WebKit
import XCTest
@testable import Search

final class OnionSessionTests: XCTestCase {
    private var onion: String { String(repeating: "a", count: 56) + ".onion" }

    func testRedirectsKeepPermittedRemoteURLsAndRemoveCookiesAndReferrers() throws {
        for address in ["http://\(onion)/image", "https://cdn.example.invalid/image", "https://example.invalid/?q=.onion"] {
            var request = URLRequest(url: try XCTUnwrap(URL(string: address)))
            request.setValue("synthetic=value", forHTTPHeaderField: "Cookie")
            request.setValue("synthetic", forHTTPHeaderField: "Authorization")
            request.setValue("synthetic", forHTTPHeaderField: "Proxy-Authorization")
            request.setValue("http://\(onion)/source", forHTTPHeaderField: "Referer")
            let allowed = try XCTUnwrap(OnionRedirects.redirect(request), address)
            XCTAssertEqual(allowed.url, request.url)
            XCTAssertFalse(allowed.httpShouldHandleCookies)
            for header in ["Cookie", "Authorization", "Proxy-Authorization", "Referer"] {
                XCTAssertNil(allowed.value(forHTTPHeaderField: header), header)
            }
        }
    }

    func testRedirectsCannotReachProxyExemptLocalOrNumericHosts() throws {
        for address in ["http://127.0.0.1/x", "http://[::1]/x", "http://2130706433/x", "http://127.1/x",
                        "http://0x7f000001/x", "http://0x7f.0.0.1/x", "http://localhost./x", "http://device.local/x",
                        "http://router.home.arpa/x", "http://198.51.100.17/x", "file:///tmp/image.png",
                        "data:image/png;base64,AA==", "about:blank", "blob:https://example.invalid/synthetic",
                        "ws://example.invalid/socket", "wss://example.invalid/socket", "http://short.onion/image"] {
            let request = URLRequest(url: try XCTUnwrap(URL(string: address)))
            XCTAssertNil(OnionRedirects.redirect(request), address)
        }
    }

    func testProxyChallengesAlwaysCancelAndOriginTLSKeepsSystemValidation() {
        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodServerTrust] {
            let proxy = URLProtectionSpace(proxyHost: "127.0.0.1", port: 9050, type: NSURLProtectionSpaceSOCKSProxy,
                                           realm: "Synthetic", authenticationMethod: method)
            XCTAssertEqual(OnionRedirects.disposition(for: proxy), .cancelAuthenticationChallenge)
        }
        let tls = URLProtectionSpace(host: "cdn.example.invalid", port: 443, protocol: "https", realm: nil,
                                     authenticationMethod: NSURLAuthenticationMethodServerTrust)
        XCTAssertEqual(OnionRedirects.disposition(for: tls), .performDefaultHandling)
        let password = URLProtectionSpace(host: "cdn.example.invalid", port: 443, protocol: "https", realm: "Synthetic",
                                          authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        XCTAssertEqual(OnionRedirects.disposition(for: password), .cancelAuthenticationChallenge)
    }

    func testFullTorRouteCannotFailOverOrExcludeRemoteDestinations() {
        let route = OnionNetwork.configuration(port: 9050)
        XCTAssertFalse(route.allowFailover)
        var matches: [String] = []
        var exclusions: [String] = []
        nw_proxy_config_enumerate_match_domains(route._nw) { matches.append(String(cString: $0)) }
        nw_proxy_config_enumerate_excluded_domains(route._nw) { exclusions.append(String(cString: $0)) }
        XCTAssertTrue(matches.isEmpty, "Clearnet resources from a Tor tab also need the Tor route")
        XCTAssertTrue(exclusions.isEmpty)
    }
}

@MainActor
final class OnionAuxiliaryTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "onion-auxiliary-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        try await super.setUp()
    }

    func testAutomaticFaviconsNeverBuildViewsForOnionOrTorPages() throws {
        let source = WKWebsiteDataStore.nonPersistent()
        let plainConfiguration = WKWebViewConfiguration()
        plainConfiguration.websiteDataStore = source
        let plain = Tab(configuration: plainConfiguration)
        let address = URL(string: "http://\(String(repeating: "a", count: 56)).onion/")!
        plain.setAddressOptimistically(address)
        XCTAssertFalse(plain.usesTor)
        Favicons().fetch(for: plain)
        XCTAssertNil(plain.built, "An onion hostname must not create a background favicon fetch")

        let torConfiguration = WKWebViewConfiguration()
        torConfiguration.websiteDataStore = Onion.shared.store(for: source)
        let tor = Tab(configuration: torConfiguration)
        tor.setAddressOptimistically(URL(string: "https://ordinary.example.invalid/after-an-onion-redirect")!)
        XCTAssertTrue(tor.usesTor)
        Favicons().fetch(for: tor)
        XCTAssertNil(tor.built, "A Tor tab stays protected after a clearnet redirect")
    }

    func testAuxiliaryTorSessionCannotBeCreatedBeforeTorIsReady() {
        Onion.shared.stop()
        XCTAssertNil(OnionSession.make())
    }
}
