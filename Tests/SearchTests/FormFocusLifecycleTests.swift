import AppKit
import WebKit
import XCTest
@testable import Search

/// Run the actual injected script in WebKit. All documents and credentials
/// are synthetic; neither a login server nor a password helper is involved.
@MainActor
final class FormFocusLifecycleTests: XCTestCase {
    private var holding: [AnyObject] = []
    private var views: [WKWebView] = []
    private var previousPolicy = NSApplication.ActivationPolicy.prohibited

    override class func setUp() {
        setenv("SEARCH_PROBE", "form-focus-lifecycle-\(getpid())", 1)
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

    func testSPAFormRemovalWithoutBlurSendsNoFocusedField() async throws {
        let fixture = try await page()
        try await focus(fixture)
        let count = fixture.messages.focus.count
        try await call(fixture.web, """
        history.pushState({}, '', '/inbox');
        document.getElementById('login').remove();
        return true;
        """)
        try await cleared(fixture, after: count)
        XCTAssertEqual(fixture.messages.latest?["typing"] as? Bool, false)
    }

    func testAncestorVisibilityChangesClearTheFocusedLoginWithoutBlur() async throws {
        for change in ["form.hidden = true", "form.inert = true", "form.style.visibility = 'hidden'",
                       "form.style.opacity = '0'", "form.classList.add('gone')"] {
            let fixture = try await page()
            try await focus(fixture)
            let count = fixture.messages.focus.count
            try await call(fixture.web, "var form = document.getElementById('login'); \(change); return true;")
            try await cleared(fixture, after: count)
            XCTAssertEqual(fixture.messages.latest?["typing"] as? Bool, false, change)
        }
    }

    func testDisabledOrReadOnlyFocusedInputStopsOfferingAccounts() async throws {
        for change in ["disabled", "readOnly"] {
            let fixture = try await page()
            try await focus(fixture)
            let count = fixture.messages.focus.count
            try await call(fixture.web, "document.getElementById('user').\(change) = true; return true;")
            try await cleared(fixture, after: count)
            XCTAssertEqual(fixture.messages.latest?["typing"] as? Bool, false, change)
        }
    }

    func testAutocompleteChangeRejudgesAFieldThatStillHasFocus() async throws {
        let fixture = try await page()
        try await focus(fixture, id: "password")
        let count = fixture.messages.focus.count
        try await call(fixture.web, "document.getElementById('password').autocomplete = 'new-password'; return true;")
        try await cleared(fixture, after: count)
        XCTAssertEqual(fixture.messages.latest?["typing"] as? Bool, true, "It remains editable, but is no longer a saved-account field")
        XCTAssertEqual(fixture.messages.latest?["passwords"] as? Bool, false)
    }

    func testPageHideClearsFocusAndPendingMutationsCannotRestoreIt() async throws {
        let fixture = try await page()
        try await focus(fixture)
        let count = fixture.messages.focus.count
        try await call(fixture.web, """
        window.dispatchEvent(new PageTransitionEvent('pagehide', { persisted: true }));
        document.body.appendChild(document.createElement('p'));
        return true;
        """)
        try await cleared(fixture, after: count)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(fixture.messages.hasField, "The debounced mutation callback must not resurrect a departed document")
        try await call(fixture.web, "window.dispatchEvent(new PageTransitionEvent('pageshow', { persisted: true })); return true;")
        try await until { fixture.messages.hasField }
    }

    func testHistoryEventsRejudgeFirstStepWithoutMovingFocus() async throws {
        let fixture = try await page(firstStep: true)
        try await focus(fixture)
        let count = fixture.messages.focus.count
        try await call(fixture.web, """
        history.pushState({}, '', '/checkout');
        window.dispatchEvent(new PopStateEvent('popstate'));
        return true;
        """)
        try await cleared(fixture, after: count)
        try await call(fixture.web, """
        history.pushState({}, '', '/signin#back');
        window.dispatchEvent(new HashChangeEvent('hashchange'));
        return true;
        """)
        try await until { fixture.messages.hasField }
    }

    func testUnchangedScrollDoesNotPublishFocusOnEveryFrame() async throws {
        let fixture = try await page()
        try await focus(fixture)
        try await Task.sleep(for: .milliseconds(350))
        let count = fixture.messages.focus.count
        let frames = try await call(fixture.web, """
        // WebKit suspends native animation frames for this detached test
        // view. Keep the real moved()/caret() handlers, but give their one
        // scheduled frame a deterministic clock in the script's own world.
        var nativeFrame = window.requestAnimationFrame;
        var scheduled = 0, ran = 0;
        try {
          window.requestAnimationFrame = function (callback) {
            scheduled++;
            return setTimeout(function () { ran++; callback(performance.now()); }, 0);
          };
          for (var i = 0; i < 20; i++) window.dispatchEvent(new Event('scroll'));
          await new Promise(function (resolve) { setTimeout(resolve, 30); });
          return { scheduled: scheduled, ran: ran };
        } finally {
          window.requestAnimationFrame = nativeFrame;
        }
        """)
        let clock = try XCTUnwrap(frames as? [String: Any])
        XCTAssertEqual(clock["scheduled"] as? Int, 1, "A burst of scroll events schedules one caret update")
        XCTAssertEqual(clock["ran"] as? Int, 1, "The real caret path must run, rather than pass on a suspended frame")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.messages.focus.count, count, "An unchanged field must keep the existing scroll deduplication")
        XCTAssertTrue(fixture.messages.hasField)
    }

    func testRelayIgnoresMessagesFromAViewNoLongerOwnedByItsTab() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(shy: true, configuration: configuration)
        let current = tab.web
        views.append(current)
        holding += [tab, current]
        var received = 0
        tab.onField = { _, _, _, _, _ in received += 1 }
        let relay = FormRelay()
        relay.tab = tab
        let old = try await page(handler: relay)
        XCTAssertFalse(tab.built === old.web)
        try await call(old.web, "document.getElementById('user').focus(); return true;")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(received, 0, "A queued message from a replaced WKWebView cannot reopen the tab's account list")
    }

    private struct Fixture {
        let web: WKWebView
        let messages: FocusMessages
    }

    private func page(firstStep: Bool = false, handler: WKScriptMessageHandler? = nil) async throws -> Fixture {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let messages = FocusMessages()
        configuration.userContentController.add(handler ?? messages, contentWorld: Web.world, name: FormRelay.name)
        configuration.userContentController.addUserScript(WKUserScript(source: FormRelay.script,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 650), configuration: configuration)
        let loaded = Loaded()
        web.navigationDelegate = loaded
        views.append(web)
        holding += [messages, loaded]
        if let handler { holding.append(handler) }
        let password = firstStep ? "" : "<input id='password' name='password' type='password' autocomplete='current-password'>"
        web.loadHTMLString("""
        <!doctype html><style>input { width: 250px; height: 30px } .gone { visibility: hidden }</style>
        <form id='login'><input id='user' name='username' autocomplete='username'>\(password)<button>Continue</button></form>
        """, baseURL: URL(string: "https://form-lifecycle.invalid/login")!)
        try await until { loaded.finished }
        // Removing or disabling a focused node need not dispatch blur. Block
        // that optional notification so this fixture tests mutation recovery.
        try await call(web, "window.addEventListener('focusout', function (e) { e.stopImmediatePropagation(); }, true); return true;")
        return Fixture(web: web, messages: messages)
    }

    private func focus(_ fixture: Fixture, id: String = "user") async throws {
        try await call(fixture.web, "document.getElementById('\(id)').focus(); return true;")
        try await until { fixture.messages.hasField }
        XCTAssertEqual(fixture.messages.latest?["passwords"] as? Bool, true)
    }

    private func cleared(_ fixture: Fixture, after count: Int) async throws {
        try await until { fixture.messages.focus.count > count && !fixture.messages.hasField }
    }

    @discardableResult
    private func call(_ web: WKWebView, _ body: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            var finished = false
            let timeout = DispatchWorkItem {
                guard !finished else { return }
                finished = true
                ProxyTimeZone.close(web)
                let context = body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)
                continuation.resume(throwing: NSError(domain: "FormFocusLifecycleTests", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "WebKit JavaScript callback timed out: \(context)"]))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
            web.callAsyncJavaScript(body, arguments: [:], in: nil, in: Web.world) { (result: Result<Any, Error>) in
                guard !finished else { return }
                finished = true
                timeout.cancel()
                continuation.resume(with: result.map { $0 is NSNull ? nil : $0 })
            }
        }
    }

    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The real WebKit focus notification did not arrive", file: file, line: line)
        throw URLError(.timedOut)
    }

    private final class FocusMessages: NSObject, WKScriptMessageHandler {
        var focus: [[String: Any]] = []
        var latest: [String: Any]? { focus.last }
        var hasField: Bool { latest?["rect"] as? [String: Any] != nil }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], body["kind"] as? String == "focus" else { return }
            focus.append(body)
        }
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        var finished = false
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(finished ? .cancel : .allow)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    }
}
