import XCTest
import JavaScriptCore
@testable import Search

final class DialerOriginTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "dialer-origins-\(getpid())", 1)
        super.setUp()
    }

    func testPublicGrantIsOneHTTPSOrigin() {
        let grants = ["https://otto.example.com"]
        XCTAssertTrue(DialerOrigin.allows(grants, scheme: "https", host: "otto.example.com", port: 443))
        XCTAssertTrue(DialerOrigin.allows(grants, scheme: "https", host: "otto.example.com", port: 0))
        XCTAssertFalse(DialerOrigin.allows(grants, scheme: "http", host: "otto.example.com", port: 80))
        XCTAssertFalse(DialerOrigin.allows(grants, scheme: "https", host: "otto.example.com", port: 8443))
        XCTAssertFalse(DialerOrigin.allows(grants, scheme: "https", host: "sub.otto.example.com", port: 443))
        XCTAssertFalse(DialerOrigin.allows(grants, scheme: "https", host: "otto.example.com.evil.test", port: 443))
    }

    func testLegacyPublicHostMigratesOnlyToDefaultHTTPS() {
        XCTAssertEqual(DialerOrigin.parse("Otto.Example.com")?.string, "https://otto.example.com")
        XCTAssertNil(DialerOrigin.parse("otto.example.com", allowLegacyHost: false))
        XCTAssertNil(DialerOrigin.parse("localhost"))
        XCTAssertNil(DialerOrigin.parse("127.0.0.1"))
        XCTAssertNil(DialerOrigin.parse("127.0.0.2"))
        XCTAssertNil(DialerOrigin.parse("[::1]"))
        XCTAssertNil(DialerOrigin.parse("localhost:8000"))
    }

    func testExplicitLocalGrantDoesNotAuthorizeAnotherPort() {
        let grants = ["http://localhost:8000", "http://127.0.0.1:8001", "http://[::1]:8002"]
        XCTAssertTrue(DialerOrigin.allows(grants, scheme: "http", host: "localhost", port: 8000))
        XCTAssertTrue(DialerOrigin.allows(grants, scheme: "http", host: "127.0.0.1", port: 8001))
        XCTAssertTrue(DialerOrigin.allows(grants, scheme: "http", host: "::1", port: 8002))
        XCTAssertFalse(DialerOrigin.allows(grants, scheme: "http", host: "localhost", port: 8001))
        XCTAssertFalse(DialerOrigin.allows(grants, scheme: "https", host: "localhost", port: 8000))
        XCTAssertFalse(DialerOrigin.allows(grants, scheme: "http", host: "127.0.0.2", port: 8001))
        XCTAssertFalse(DialerOrigin.allows(grants, scheme: "http", host: "::1", port: 80))
    }

    func testHTTPRequiresLoopback() {
        XCTAssertNotNil(DialerOrigin.parse("http://localhost:8000"))
        XCTAssertNotNil(DialerOrigin.parse("http://127.0.0.2:8000"))
        XCTAssertNotNil(DialerOrigin.parse("http://[0:0:0:0:0:0:0:1]:8000"))
        XCTAssertNil(DialerOrigin.parse("http://otto.example.com"))
        XCTAssertNil(DialerOrigin.parse("http://192.168.1.1:8000"))
        XCTAssertNil(DialerOrigin.parse("http://localhost.evil.test:8000"))
        XCTAssertNil(DialerOrigin.parse("http://2130706433:8000"))
    }

    func testGrantDoesNotSilentlyDiscardSensitiveURLParts() {
        for text in ["https://user:secret@otto.example.com", "https://otto.example.com/leads",
                     "https://otto.example.com?x=1", "https://otto.example.com#leads",
                     "wss://otto.example.com", "file:///tmp/dialer", "https://*.example.com",
                     "https://otto.example.com:0", "https://otto.example.com:65536",
                     "https://otto..example.com", "https://-otto.example.com"] {
            XCTAssertNil(DialerOrigin.parse(text), text)
        }
        XCTAssertNil(DialerOrigin(scheme: "https", host: "otto.example.com/path", port: 443))
        XCTAssertNil(DialerOrigin(scheme: "https", host: "user@otto.example.com", port: 443))
    }

    func testCanonicalGrantsRoundTripAndDeduplicate() {
        let inputs = [" HTTPS://Otto.Example.com:443/ ", "otto.example.com", "https://otto.example.com:8443",
                      "http://localhost:80", "http://[0:0:0:0:0:0:0:1]:8000", "https://täst.de"]
        let expected = ["https://otto.example.com", "https://otto.example.com:8443", "http://localhost",
                        "http://[::1]:8000", "https://xn--tst-qla.de"]
        XCTAssertEqual(DialerOrigin.normalized(inputs), expected)
        XCTAssertEqual(DialerOrigin.normalized(expected), expected)
    }

    @MainActor func testPreferencesPersistAndApplyNormalizedGrants() {
        let prefs = Shared.prefs
        let old = prefs.dialerSetup
        defer { prefs.dialerSites = old.sites; prefs.dialerOn = old.on }
        prefs.dialerOn = true
        prefs.dialerSites = ["Otto.Example.com", "localhost", "127.0.0.1"]
        let grants = ["https://otto.example.com"]
        XCTAssertEqual(prefs.dialerSites, grants)
        XCTAssertEqual(Dialer.shared.setup.sites, grants)
        XCTAssertEqual(Store.settings.stringArray(forKey: "dialer.sites"), grants)
        XCTAssertTrue(Dialer.shared.allows(scheme: "https", host: "otto.example.com", port: 443))

        prefs.dialerSites = ["localhost", "127.0.0.1"]
        XCTAssertEqual(prefs.dialerSites, [])
        XCTAssertEqual(Dialer.shared.setup.sites, [])
        XCTAssertEqual(Store.settings.stringArray(forKey: "dialer.sites"), [])
        XCTAssertFalse(Dialer.shared.allows(scheme: "https", host: "otto.example.com", port: 443))
        XCTAssertFalse(Dialer.shared.allows(scheme: "http", host: "localhost", port: 80))
    }

    /// The real bridge script can be refreshed in an already open page. Old
    /// handlers and outstanding replies become inert when its grant is removed.
    func testBridgeRefreshReplacesItsListenerAndRevokesOldReferences() throws {
        let context = try bridgeContext(origin: "https://otto.example.com")
        let script = DialerSiteRelay.script(hosts: ["https://otto.example.com"])
        context.evaluateScript(script)
        XCTAssertEqual(context.evaluateScript("listeners.length")?.toInt32(), 1)
        context.evaluateScript("var retired = window.__searchDialerSite;")
        context.evaluateScript(script)
        XCTAssertEqual(context.evaluateScript("listeners.length")?.toInt32(), 1)
        context.evaluateScript("retired.calls([{id:'old'}]);")
        XCTAssertEqual(context.evaluateScript("posted.length")?.toInt32(), 2) // each installation's ready message
        context.evaluateScript("var current = window.__searchDialerSite;")
        context.evaluateScript(DialerSiteRelay.script(hosts: []))
        XCTAssertEqual(context.evaluateScript("listeners.length")?.toInt32(), 0)
        XCTAssertTrue(context.evaluateScript("window.__searchDialerSite === undefined")?.toBool() == true)
        context.evaluateScript("current.calls([{id:'revoked'}]);")
        XCTAssertEqual(context.evaluateScript("posted.length")?.toInt32(), 2)
        XCTAssertNil(context.exception)
    }

    func testBridgeChecksSchemeAndPortBeforeInstalling() throws {
        for origin in ["http://otto.example.com", "https://otto.example.com:8443", "http://localhost:9001"] {
            let context = try bridgeContext(origin: origin)
            context.evaluateScript(DialerSiteRelay.script(hosts: ["https://otto.example.com", "http://localhost:9000"]))
            XCTAssertEqual(context.evaluateScript("listeners.length")?.toInt32(), 0, origin)
            XCTAssertNil(context.exception)
        }
        let allowed = try bridgeContext(origin: "http://localhost:9000")
        allowed.evaluateScript(DialerSiteRelay.script(hosts: ["http://localhost:9000"]))
        XCTAssertEqual(allowed.evaluateScript("listeners.length")?.toInt32(), 1)
        XCTAssertNil(allowed.exception)
    }

    func testBridgeRejectsMessagesWithAnotherOrigin() throws {
        let context = try bridgeContext(origin: "https://otto.example.com")
        context.evaluateScript(DialerSiteRelay.script(hosts: ["https://otto.example.com"]))
        context.evaluateScript("listeners[0]({source:window, origin:'https://evil.example', data:{source:'otto',type:'getConfig'}});")
        XCTAssertEqual(context.evaluateScript("nativeCalls")?.toInt32(), 0)
        context.evaluateScript("listeners[0]({source:window, origin:location.origin, data:{source:'otto',type:'getConfig'}});")
        XCTAssertEqual(context.evaluateScript("nativeCalls")?.toInt32(), 1)
        XCTAssertNil(context.exception)
    }

    private func bridgeContext(origin: String) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        let data = try JSONSerialization.data(withJSONObject: [origin])
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        context.evaluateScript("""
        var window = this, location = {origin: \(encoded)[0]}, listeners = [], posted = [], nativeCalls = 0;
        window.location = location;
        var document = {documentElement:{setAttribute:function(){},removeAttribute:function(){}}};
        window.webkit = {messageHandlers:{officeDialerSite:{postMessage:function(){nativeCalls++;return Promise.resolve({ok:true});}}}};
        window.addEventListener = function(type, fn){if(type === 'message')listeners.push(fn);};
        window.removeEventListener = function(type, fn){if(type === 'message')listeners=listeners.filter(function(f){return f !== fn;});};
        window.postMessage = function(message, origin){posted.push({message:message,origin:origin});};
        """)
        XCTAssertNil(context.exception)
        return context
    }
}
