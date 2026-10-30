import AppKit
import WebKit
import XCTest
@testable import Search

/// The actual injected capability, on synthetic pages in real WebKit.
/// No password store, account helper, external server or submit is used.
@MainActor
final class FormsPasswordStepTests: XCTestCase {
    private var views: [WKWebView] = []
    private var holding: [AnyObject] = []
    private var previousPolicy = NSApplication.ActivationPolicy.prohibited
    private let secret = "synthetic-password-step-secret"
    private let password = "<input id='password' name='password' type='password' autocomplete='current-password'>"

    override class func setUp() {
        setenv("SEARCH_PROBE", "forms-password-step-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        try await super.setUp()
    }

    override func tearDown() async throws {
        for web in views {
            web.navigationDelegate = nil
            web.configuration.userContentController.removeScriptMessageHandler(forName: FormRelay.name, contentWorld: Web.world)
            ProxyTimeZone.close(web)
        }
        views.removeAll()
        holding.removeAll()
        NSApp.setActivationPolicy(previousPolicy)
        try await super.tearDown()
    }

    func testUsernameFirstWaitsThenFillsRevealedPasswordWithFrameworkEventsWithoutSubmitting() async throws {
        let fixture = try await page("""
        <form id='login'><section id='first'><input id='user' autocomplete='username' value='alice'></section>
        <section id='second' hidden>\(password)</section><button>Sign in</button></form>
        """)
        try await assertStatus("waiting", in: fixture)
        try await call(fixture.web, """
        window.__stepEvents = { input: 0, change: 0, submit: 0 };
        var pass = document.getElementById('password');
        pass.addEventListener('input', function () { window.__stepEvents.input++; });
        pass.addEventListener('change', function () { window.__stepEvents.change++; });
        document.getElementById('login').addEventListener('submit', function (e) { e.preventDefault(); window.__stepEvents.submit++; });
        document.getElementById('first').hidden = true;
        document.getElementById('second').hidden = false;
        return true;
        """)
        let ready = try await probe(fixture)
        XCTAssertEqual(ready.status, "ready")
        XCTAssertFalse(ready.document.isEmpty)
        XCTAssertFalse(ready.field.isEmpty)
        try await assertFill(true, in: fixture, state: ready)
        let value = try await call(fixture.web, """
        return { password: document.getElementById('password').value,
                 user: document.getElementById('user').value,
                 input: window.__stepEvents.input, change: window.__stepEvents.change, submit: window.__stepEvents.submit,
                 attribute: document.getElementById('password').getAttribute('value'),
                 leakedGlobal: Object.keys(window).some(function (key) { try { return window[key] === secret; } catch (e) { return false; } }) };
        """, arguments: ["secret": secret]) as? [String: Any]
        let result = try XCTUnwrap(value)
        XCTAssertEqual(result["password"] as? String, secret)
        XCTAssertEqual(result["user"] as? String, "alice")
        XCTAssertEqual(result["input"] as? Int, 1)
        XCTAssertEqual(result["change"] as? Int, 1)
        XCTAssertEqual(result["submit"] as? Int, 0)
        XCTAssertTrue(result["attribute"] is NSNull, "Filling must use the value property, not an HTML attribute")
        XCTAssertEqual(result["leakedGlobal"] as? Bool, false)
        try await assertStatus("blocked", in: fixture, "A completed fill cannot overwrite its result")
    }

    func testUnmarkedPasswordRequiresClearSignInContext() async throws {
        let login = try await page("<form><input type='password' name='password'><button>Sign in</button></form>", path: "/workspace")
        try await assertStatus("ready", in: login)
        let unrelated = try await page("<form><input type='password' name='password'><button>Save</button></form>", path: "/workspace")
        try await assertStatus("blocked", in: unrelated)
    }

    func testFullLoginFormFillsEmptyUsernameBeforePassword() async throws {
        let fixture = try await page("<form><input id='user' autocomplete='username'>\(password)<button>Sign in</button></form>")
        try await call(fixture.web, """
        window.__fillOrder = [];
        document.addEventListener('input', function (e) { window.__fillOrder.push(e.target.id); });
        return true;
        """)
        let ready = try await probe(fixture)
        try await assertFill(true, in: fixture, state: ready)
        let value = try await call(fixture.web, "return { user: document.getElementById('user').value, password: document.getElementById('password').value, order: window.__fillOrder };")
        let result = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(result["user"] as? String, "alice")
        XCTAssertEqual(result["password"] as? String, secret)
        XCTAssertEqual(result["order"] as? [String], ["user", "password"])
    }

    func testUsernameInputHandlerCannotRedirectPasswordIntoAReplacementField() async throws {
        let fixture = try await page("<form><input id='user' autocomplete='username'>\(password)<button>Sign in</button></form>")
        let ready = try await probe(fixture)
        try await call(fixture.web, """
        document.getElementById('user').addEventListener('input', function () {
          document.getElementById('password').outerHTML = replacement;
        });
        return true;
        """, arguments: ["replacement": password])
        try await assertFill(false, in: fixture, state: ready)
        let value = try await call(fixture.web, "return document.getElementById('password').value;")
        XCTAssertEqual(value as? String, "", "The new password element needs a fresh probe and authorization")
        let replacement = try await probe(fixture)
        XCTAssertNotEqual(replacement.field, ready.field)
    }

    func testSignupOTPAndAmbiguousPasswordFieldsAreBlocked() async throws {
        for body in [
            "<input type='password' autocomplete='new-password'>",
            "<input type='password' autocomplete='one-time-code'>",
            "<input type='text' autocomplete='one-time-code'>",
            "<input type='password' name='verificationCode'>",
            password + "<input type='password' autocomplete='current-password'>",
            password + "<input type='password' autocomplete='new-password'>",
        ] {
            let fixture = try await page(body)
            try await assertStatus("blocked", in: fixture, body)
        }
    }

    func testNonemptyPasswordsAndConflictingRetainedUsernamesAreBlocked() async throws {
        for username in [
            "<input autocomplete='username' value='bob'>",
            "<input type='hidden' autocomplete='username' value='bob'>",
            "<section hidden><input autocomplete='username' value='bob'></section>",
            "<input type='email' name='email' value='bob'>",
        ] {
            let fixture = try await page("<form>\(username)\(password)<button>Sign in</button></form>")
            try await assertStatus("blocked", in: fixture, username)
        }
        let typed = try await page(password)
        try await call(typed.web, "document.getElementById('password').value = 'already typed'; return true;")
        try await assertStatus("blocked", in: typed)
    }

    func testExplicitCurrentPasswordMayBeLabelledAccessCode() async throws {
        let fixture = try await page("""
        <label for='password'>Access code</label>
        <input id='password' name='code' type='password' autocomplete='current-password'>
        """)
        let ready = try await probe(fixture)
        XCTAssertEqual(ready.status, "ready")
        try await assertFill(true, in: fixture, state: ready)
        let value = try await call(fixture.web, "return document.getElementById('password').value;")
        XCTAssertEqual(value as? String, secret)
    }

    func testSameOriginNewDocumentRejectsOldDocumentToken() async throws {
        let fixture = try await page(password)
        let old = try await probe(fixture)
        try await load(fixture.web, body: password, path: "/login/next")
        let current = try await probe(fixture)
        XCTAssertNotEqual(current.document, old.document)
        try await assertFill(false, in: fixture, state: old)
        let value = try await call(fixture.web, "return document.getElementById('password').value;")
        XCTAssertEqual(value as? String, "")
        try await assertFill(true, in: fixture, state: current)
    }

    func testReplacingPasswordElementRejectsOldFieldTokenEvenWithSameHTMLID() async throws {
        let fixture = try await page(password)
        let old = try await probe(fixture)
        try await call(fixture.web, "document.getElementById('password').outerHTML = replacement; return true;", arguments: ["replacement": password])
        let current = try await probe(fixture)
        XCTAssertEqual(current.document, old.document)
        XCTAssertNotEqual(current.field, old.field)
        try await assertFill(false, in: fixture, state: old)
        let value = try await call(fixture.web, "return document.getElementById('password').value;")
        XCTAssertEqual(value as? String, "")
        try await assertFill(true, in: fixture, state: current)
    }

    func testReadinessIsRecheckedImmediatelyBeforeFilling() async throws {
        for change in [
            "pass.value = 'typed after probe'",
            "pass.autocomplete = 'new-password'",
            "pass.disabled = true",
            "pass.style.visibility = 'hidden'",
            "document.body.insertAdjacentHTML('beforeend', '<input type=password>')",
            "document.body.insertAdjacentHTML('beforeend', '<input type=hidden autocomplete=username value=bob>')",
        ] {
            let fixture = try await page(password)
            let ready = try await probe(fixture)
            XCTAssertEqual(ready.status, "ready")
            try await call(fixture.web, "var pass = document.getElementById('password'); \(change); return true;")
            try await assertFill(false, in: fixture, state: ready, change)
            let leaked = try await call(fixture.web, "return Array.from(document.querySelectorAll('input')).some(function (box) { return box.value === secret; });", arguments: ["secret": secret])
            XCTAssertEqual(leaked as? Bool, false, change)
        }
    }

    func testPasswordReplacementNotifiesNativeOnceWithoutMutationSpam() async throws {
        let fixture = try await page(password)
        try await until { fixture.messages.forms > 0 }
        let before = fixture.messages.forms
        try await call(fixture.web, "for (var i = 0; i < 20; i++) document.body.appendChild(document.createElement('p')); return true;")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(fixture.messages.forms, before, "Unrelated mutations must not repeat sign-in readiness")
        try await call(fixture.web, "document.getElementById('password').outerHTML = replacement; return true;", arguments: ["replacement": password])
        try await until { fixture.messages.forms > before }
        XCTAssertEqual(fixture.messages.forms, before + 1, "A new field needs one fresh native readiness signal")
    }

    private struct State {
        let status: String
        let document: String
        let field: String
    }

    private struct Fixture {
        let web: WKWebView
        let messages: Messages
    }

    private func assertStatus(_ expected: String, in fixture: Fixture, _ message: String = "",
                              file: StaticString = #filePath, line: UInt = #line) async throws {
        let state = try await probe(fixture)
        XCTAssertEqual(state.status, expected, message, file: file, line: line)
    }

    private func assertFill(_ expected: Bool, in fixture: Fixture, state: State, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let filled = try await fill(fixture, state: state)
        XCTAssertEqual(filled, expected, message, file: file, line: line)
    }

    private func probe(_ fixture: Fixture, user: String = "alice") async throws -> State {
        let value = try await call(fixture.web, "return window.__officeForms.passwordStep(user);", arguments: ["user": user])
        let result = try XCTUnwrap(value as? [String: Any])
        return State(status: try XCTUnwrap(result["status"] as? String),
                     document: try XCTUnwrap(result["document"] as? String),
                     field: try XCTUnwrap(result["field"] as? String))
    }

    private func fill(_ fixture: Fixture, state: State) async throws -> Bool {
        let result = try await call(fixture.web, "return window.__officeForms.fillPasswordStep(user, password, documentToken, fieldToken);",
            arguments: ["user": "alice", "password": secret, "documentToken": state.document, "fieldToken": state.field])
        return try XCTUnwrap(result as? Bool)
    }

    private func page(_ body: String, path: String = "/login") async throws -> Fixture {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let messages = Messages()
        configuration.userContentController.add(messages, contentWorld: Web.world, name: FormRelay.name)
        configuration.userContentController.addUserScript(WKUserScript(source: FormRelay.script,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 650), configuration: configuration)
        views.append(web)
        holding.append(messages)
        try await load(web, body: body, path: path)
        return Fixture(web: web, messages: messages)
    }

    private func load(_ web: WKWebView, body: String, path: String) async throws {
        let loaded = Loaded()
        holding.append(loaded)
        web.navigationDelegate = loaded
        web.loadHTMLString("<!doctype html><style>input { width: 250px; height: 30px }</style>" + body,
            baseURL: URL(string: "https://password-step-fixture.invalid" + path)!)
        try await until { loaded.finished }
    }

    @discardableResult
    private func call(_ web: WKWebView, _ body: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            var finished = false
            let timeout = DispatchWorkItem {
                guard !finished else { return }
                finished = true
                ProxyTimeZone.close(web)
                continuation.resume(throwing: NSError(domain: "FormsPasswordStepTests", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "WebKit callback timed out in password-step fixture"]))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
            web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: Web.world) { (result: Result<Any, Error>) in
                guard !finished else { return }
                finished = true
                timeout.cancel()
                continuation.resume(with: result.map { $0 is NSNull ? nil : $0 })
            }
        }
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The real WebKit password-step fixture did not settle")
        throw URLError(.timedOut)
    }

    private final class Messages: NSObject, WKScriptMessageHandler {
        var forms = 0
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if (message.body as? [String: Any])?["kind"] as? String == "form" { forms += 1 }
        }
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        var finished = false
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(finished ? .cancel : .allow)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    }
}
