import AppKit
import WebKit
import XCTest
@testable import Search

@MainActor
final class PasskeyAvailabilityTests: XCTestCase {
    private var views: [WKWebView] = []
    private var oldPolicy = NSApplication.ActivationPolicy.prohibited

    override class func setUp() {
        setenv("SEARCH_PROBE", "passkey-availability-\(getpid())", 1)
        super.setUp()
    }
    override func setUp() async throws {
        _ = NSApplication.shared
        oldPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
    }
    override func tearDown() async throws {
        views.forEach { $0.stopLoading() }
        views.removeAll()
        NSApp.setActivationPolicy(oldPolicy)
    }

    func testUnguardedTargetStyleProbeAllowsThePasswordStep() async throws {
        let web = try await page()
        let result = try await run(web, """
        document.querySelector('button').click();
        return await window.flow;
        """)
        XCTAssertEqual(result["step"] as? String, "password")
        XCTAssertEqual(result["visible"] as? Bool, true)
        XCTAssertEqual(result["platform"] as? Bool, false)
    }

    func testHidingTheConstructorReproducesTheReportedTypeError() async throws {
        let web = try await page(policy: "Object.defineProperty(window, 'PublicKeyCredential', { configurable: true, get: function () { return undefined; } });")
        let result = try await run(web, "document.querySelector('button').click(); return await window.flow;")
        XCTAssertEqual(result["step"] as? String, "error")
        XCTAssertEqual(result["error"] as? String, "TypeError")
        XCTAssertEqual(result["visible"] as? Bool, false)
    }

    func testNativeConstructorAndSerializationStayAvailableWhileCapabilitiesReportFalse() async throws {
        let web = try await page()
        let result = try await run(web, """
        const p = PublicKeyCredential;
        return { same: p === window.nativeConstructor, type: typeof p,
                 platform: await p.isUserVerifyingPlatformAuthenticatorAvailable(),
                 conditional: await p.isConditionalMediationAvailable(),
                 capabilities: await p.getClientCapabilities(),
                 parsed: p.parseRequestOptionsFromJSON({fixture:true}).fixture,
                 nativeCalls: window.nativeCalls };
        """)
        XCTAssertEqual(result["same"] as? Bool, true)
        XCTAssertEqual(result["type"] as? String, "function")
        XCTAssertEqual(result["platform"] as? Bool, false)
        XCTAssertEqual(result["conditional"] as? Bool, false)
        XCTAssertEqual(result["parsed"] as? Bool, true)
        XCTAssertEqual(result["nativeCalls"] as? Int, 0)
        let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Bool])
        XCTAssertFalse(capabilities.isEmpty)
        XCTAssertTrue(capabilities.values.allSatisfy { !$0 })
    }

    func testPublicKeyOperationsAndCredentialSignalsRemainRefused() async throws {
        let web = try await page()
        let result = try await run(web, """
        const errors = [];
        for (const operation of [
          () => navigator.credentials.get({publicKey:{challenge:new Uint8Array(16)}}),
          () => navigator.credentials.create({publicKey:{challenge:new Uint8Array(16)}}),
          () => PublicKeyCredential.signalUnknownCredential({}),
          () => PublicKeyCredential.signalAllAcceptedCredentials({}),
          () => PublicKeyCredential.signalCurrentUserDetails({})
        ]) { try { await operation(); errors.push('unexpected success'); } catch(e) { errors.push(e.name); } }
        return { errors, nativeCalls: window.nativeCalls };
        """)
        XCTAssertEqual(result["errors"] as? [String], Array(repeating: "NotAllowedError", count: 5))
        XCTAssertEqual(result["nativeCalls"] as? Int, 0)
    }

    func testPasswordCredentialOperationsKeepTheirOriginalReceiver() async throws {
        let web = try await page()
        let result = try await run(web, """
        return { get: await navigator.credentials.get({password:true}),
                 create: await navigator.credentials.create({password:{id:'synthetic'}}),
                 receiver: window.nativeReceiver === navigator.credentials };
        """)
        XCTAssertEqual(result["get"] as? String, "password-get")
        XCTAssertEqual(result["create"] as? String, "password-create")
        XCTAssertEqual(result["receiver"] as? Bool, true)
    }

    func testConditionalRequestStaysPendingUntilAborted() async throws {
        let web = try await page()
        let result = try await run(web, """
        const controller = new AbortController();
        let settled = false;
        const pending = navigator.credentials.get({publicKey:{},mediation:'conditional',signal:controller.signal})
          .then(() => {settled=true;return 'unexpected success'}, e => {settled=true;return e.name});
        await Promise.resolve(); const before = settled;
        controller.abort(); return { before, error: await pending, nativeCalls: window.nativeCalls };
        """)
        XCTAssertEqual(result["before"] as? Bool, false)
        XCTAssertEqual(result["error"] as? String, "AbortError")
        XCTAssertEqual(result["nativeCalls"] as? Int, 0)
    }

    func testExtensionOwnedCredentialsKeepTheirProviderAndCapabilityChecks() async throws {
        let web = try await page()
        let result = try await run(web, """
        Object.defineProperty(navigator.credentials,'get',{configurable:true,value:async function(){return 'extension-credential'}});
        return { same: PublicKeyCredential === window.nativeConstructor,
                 platform: await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable(),
                 conditional: await PublicKeyCredential.isConditionalMediationAvailable(),
                 capabilities: await PublicKeyCredential.getClientCapabilities(),
                 credential: await navigator.credentials.get({publicKey:{}}) };
        """)
        XCTAssertEqual(result["same"] as? Bool, true)
        XCTAssertEqual(result["platform"] as? Bool, true)
        XCTAssertEqual(result["conditional"] as? Bool, true)
        XCTAssertEqual(result["credential"] as? String, "extension-credential")
        XCTAssertEqual((result["capabilities"] as? [String: Bool])?["conditionalGet"], true)
    }

    func testARealmWithoutTheNativeApiIsLeftAlone() async throws {
        let web = try await page(setup: "delete window.PublicKeyCredential; window.originalGet = navigator.credentials.get;")
        let result = try await run(web, "return { type: typeof PublicKeyCredential, unchanged: navigator.credentials.get === window.originalGet };")
        XCTAssertEqual(result["type"] as? String, "undefined")
        XCTAssertEqual(result["unchanged"] as? Bool, true)
    }

    func testRealWebKitConstructorRemainsVisibleAndReportsUnavailable() async throws {
        let web = try await page(mock: false)
        let result = try await run(web, """
        if (typeof PublicKeyCredential !== 'function') return {exposed:false};
        return { exposed:true, same:PublicKeyCredential === window.nativeConstructor,
                 platform:await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable() };
        """)
        if result["exposed"] as? Bool != true { throw XCTSkip("This WebKit does not expose WebAuthn for a synthetic document") }
        XCTAssertEqual(result["same"] as? Bool, true)
        XCTAssertEqual(result["platform"] as? Bool, false)
    }

    private func page(policy: String = FormRelay.withoutPasskeys, setup: String = "", mock: Bool = true) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        for script in [mock ? Self.nativeFixture : "window.nativeConstructor = window.PublicKeyCredential;", setup, policy] where !script.isEmpty {
            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        views.append(web)
        web.loadHTMLString("""
        <!doctype html><title>Login capability fixture</title>
        <form><input autocomplete='username' value='synthetic'><section id='password-step' hidden><input type='password'></section><button>Continue</button></form>
        <script>
        document.querySelector('form').addEventListener('submit', function(e) {
          e.preventDefault();
          window.flow = (async function () {
            try {
              const platform = await window?.PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable();
              if (!platform) document.getElementById('password-step').hidden = false;
              return {step:platform?'passkey':'password',platform,visible:!document.getElementById('password-step').hidden};
            } catch(e) { return {step:'error',error:e.name,visible:!document.getElementById('password-step').hidden}; }
          })();
        });
        </script>
        """, baseURL: URL(string: "https://capability-fixture.invalid/login"))
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("document.readyState === 'complete' && !!document.querySelector('button')") as? Bool) == true { return web }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "PasskeyAvailabilityTests", code: 1)
    }

    private func run(_ web: WKWebView, _ code: String) async throws -> [String: Any] {
        let result = try await web.callAsyncJavaScript(code, in: nil, contentWorld: .page)
        return try XCTUnwrap(result as? [String: Any])
    }

    private static let nativeFixture = """
    (function () {
    window.nativeCalls = 0;
    function PublicKeyCredential() {}
    window.nativeConstructor = PublicKeyCredential;
    PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = function(){ window.nativeCalls++; return Promise.resolve(true); };
    PublicKeyCredential.isConditionalMediationAvailable = function(){ window.nativeCalls++; return Promise.resolve(true); };
    PublicKeyCredential.getClientCapabilities = function(){ window.nativeCalls++; return Promise.resolve({conditionalGet:true}); };
    PublicKeyCredential.parseRequestOptionsFromJSON = function(options){ return options; };
    ['signalUnknownCredential','signalAllAcceptedCredentials','signalCurrentUserDetails'].forEach(function(name){
      PublicKeyCredential[name] = function(){ window.nativeCalls++; return Promise.resolve(); };
    });
    Object.defineProperty(window,'PublicKeyCredential',{configurable:true,writable:true,value:PublicKeyCredential});
    function CredentialsContainer() {}
    ['get','create'].forEach(function(name){
      CredentialsContainer.prototype[name] = function(options){ window.nativeReceiver=this; if(options.publicKey)window.nativeCalls++; return Promise.resolve('password-'+name); };
    });
    Object.defineProperty(window,'CredentialsContainer',{configurable:true,writable:true,value:CredentialsContainer});
    Object.defineProperty(navigator,'credentials',{configurable:true,value:new CredentialsContainer()});
    })();
    """
}
