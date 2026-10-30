import AppKit
import Foundation
import Security
import WebKit
import XCTest
@testable import Search

/// The complete username-selection flow runs in WebKit against synthetic
/// HTTPS documents and an in-memory password vault. No account or login server is used.
@MainActor
final class LoginContinuationTests: XCTestCase {
    private let origin = URL(string: "https://login.continuation.invalid")!
    private let username = "alice@synthetic.invalid"
    private let password = "Synthetic-Password-42"
    private var browser: Browser!
    private var vault: ContinuationVault!
    private var previousFills = false
    private var previousApple = false
    private var previousSaves = false
    private var previousPolicy = NSApplication.ActivationPolicy.prohibited

    override class func setUp() {
        setenv("SEARCH_PROBE", "login-continuation-tests-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        previousFills = browser.prefs.fillsPasswords
        previousApple = browser.prefs.applePasswords
        previousSaves = browser.prefs.savesPasswords
        browser.prefs.fillsPasswords = true
        browser.prefs.applePasswords = false
        browser.prefs.savesPasswords = false
        vault = ContinuationVault(host: origin.host()!, user: username, password: password)
        Vault.useBackendForTesting(vault.backend)
        WebsitePasswordAuthentication.useForTesting { _, _ in true }
    }

    override func tearDown() async throws {
        browser?.closeAll()
        if let browser {
            browser.prefs.fillsPasswords = previousFills
            browser.prefs.applePasswords = previousApple
            browser.prefs.savesPasswords = previousSaves
        }
        browser = nil
        Vault.useBackendForTesting(nil)
        WebsitePasswordAuthentication.useForTesting(nil)
        vault = nil
        NSApp.setActivationPolicy(previousPolicy)
        try await super.tearDown()
    }

    func testUsernameSelectionThenSameOriginPasswordDocumentFillsOnceWithoutAutofocusOrSubmit() async throws {
        let tab = try await selectUsername()
        XCTAssertEqual(tab.givenName(), username)
        try await load(tab, fields: passwordField(), at: origin.appendingPathComponent("password"))
        try await filled(tab)
        XCTAssertEqual(vault.secretReads, 1)
        XCTAssertNil(browser.suggesting, "The old username widget must not accompany the new document")
        try await assertValue(tab, "document.body.dataset.submits", equals: "0")
        // Repeated form/focus notifications cannot read or apply the selection again.
        tab.foundSignIn()
        tab.fieldFocused(CGRect(x: 20, y: 60, width: 250, height: 30))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(vault.secretReads, 1)
        try await assertValue(tab, "document.getElementById('password').value", equals: password)
        try await assertValue(tab, "document.body.dataset.submits", equals: "0")
    }

    func testUsernameSelectionContinuesIntoPasswordStageBuiltBySPAWithoutAutofocus() async throws {
        let tab = try await selectUsername()
        try await replaceFields(tab, with: passwordField())
        try await filled(tab)
        XCTAssertEqual(vault.secretReads, 1)
        XCTAssertEqual(tab.givenName(), username)
        try await assertValue(tab, "document.body.dataset.submits", equals: "0")
    }

    func testPasswordStageWithoutAccountSelectionDoesNotReadOrFill() async throws {
        let tab = makeTab()
        browser.activeID = tab.id
        try await load(tab, fields: passwordField(), at: origin.appendingPathComponent("password"))
        tab.foundSignIn()
        tab.fieldFocused(CGRect(x: 20, y: 60, width: 250, height: 30))
        try await assertNotFilled(tab)
    }

    func testExistingOrNewOrUnavailablePasswordFieldNeverReadsSelectedSecret() async throws {
        let stages = [
            passwordField(value: "already-typed"),
            passwordField(autocomplete: "new-password"),
            passwordField(extra: "hidden"),
            passwordField(extra: "disabled"),
            passwordField(extra: "readonly")
        ]
        for fields in stages {
            let tab = try await selectUsername()
            try await replaceFields(tab, with: fields)
            // Even a late form notification must preflight the actual DOM.
            tab.foundSignIn()
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(vault.secretReads, 0, fields)
            let contents = try await value(tab, "document.getElementById('password').value") as? String
            XCTAssertNotEqual(contents, password)
            try await assertValue(tab, "document.body.dataset.submits", equals: "0")
        }
    }

    func testDifferentOriginPortOrDowngradeCancelsSelectionBeforeSecretRead() async throws {
        for destination in [URL(string: "https://other.continuation.invalid/password")!,
                            URL(string: "https://login.continuation.invalid:8443/password")!,
                            URL(string: "http://login.continuation.invalid/password")!] {
            let tab = try await selectUsername()
            try await load(tab, fields: passwordField(), at: destination)
            tab.foundSignIn()
            try await assertNotFilled(tab)
        }
    }

    func testLeavingSelectedTabCancelsContinuationEvenAfterReturning() async throws {
        let selected = try await selectUsername()
        let other = makeTab()
        browser.activeID = other.id
        browser.activeID = selected.id
        try await replaceFields(selected, with: passwordField())
        selected.foundSignIn()
        try await assertNotFilled(selected)
    }

    func testClosingSelectedTabCannotContinueInAnotherTab() async throws {
        let selected = try await selectUsername()
        browser.close(selected)
        let replacement = makeTab()
        browser.activeID = replacement.id
        try await load(replacement, fields: passwordField(), at: origin.appendingPathComponent("password"))
        replacement.foundSignIn()
        try await assertNotFilled(replacement)
    }

    func testExplicitSameOriginAddressNavigationCancelsContinuation() async throws {
        let tab = try await selectUsername()
        let blocked = CancelNavigation()
        tab.web.navigationDelegate = blocked
        tab.go(to: origin.appendingPathComponent("unrelated"))
        try await until { blocked.cancelled }
        tab.web.navigationDelegate = browser
        try await load(tab, fields: passwordField(), at: origin.appendingPathComponent("password"))
        tab.foundSignIn()
        try await assertNotFilled(tab)
    }

    private func makeTab() -> Tab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(configuration: configuration)
        browser.prepare(tab)
        browser.insert(tab, at: browser.tabs.count)
        tab.web.frame = CGRect(x: 0, y: 0, width: 900, height: 650)
        return tab
    }

    private func selectUsername() async throws -> Tab {
        let tab = makeTab()
        browser.activeID = tab.id
        try await load(tab, fields: "<input id='user' name='username' autocomplete='username'><button type='button'>Next</button>",
                       at: origin.appendingPathComponent("login"))
        try await call(tab, "document.getElementById('user').focus(); return true;")
        try await until { browser.suggesting?.tab == tab.id && browser.suggesting?.logins.contains(where: { $0.user == username }) == true }
        XCTAssertTrue(browser.suggesting?.nameOnly == true)
        let selected = try XCTUnwrap(browser.suggesting?.logins.first { $0.user == username })
        try await Task.sleep(for: .milliseconds(550))
        browser.choose(selected)
        try await untilValue(tab, expression: "document.getElementById('user').value", equals: username)
        try await until { tab.givenName() == username }
        XCTAssertEqual(vault.secretReads, 0, "Choosing a username-only stage must not read the secret yet")
        return tab
    }

    private func passwordField(value: String = "", autocomplete: String = "current-password", extra: String = "") -> String {
        "<input id='password' name='password' type='password' autocomplete='\(autocomplete)' value='\(value)' \(extra)><button type='button'>Sign in</button>"
    }

    private func load(_ tab: Tab, fields: String, at url: URL) async throws {
        let stamp = UUID().uuidString
        tab.web.loadHTMLString("""
        <!doctype html><style>input{width:250px;height:30px}</style>
        <body data-stage='\(stamp)' data-submits='0'><form id='login'>\(fields)</form>
        <script>document.getElementById('login').addEventListener('submit',function(e){e.preventDefault();document.body.dataset.submits=String(Number(document.body.dataset.submits)+1)});</script>
        </body>
        """, baseURL: url)
        try await untilValue(tab, expression: "document.body && document.body.dataset.stage", equals: stamp)
        try await untilValue(tab, expression: "String(!!window.__officeForms)", equals: "true")
        XCTAssertEqual(tab.pageAddress?.scheme, url.scheme)
        XCTAssertEqual(tab.pageAddress?.host(), url.host())
        XCTAssertEqual(tab.pageAddress?.port, url.port)
    }

    private func replaceFields(_ tab: Tab, with fields: String) async throws {
        try await call(tab, "document.getElementById('login').innerHTML = fields; return true;", arguments: ["fields": fields])
    }

    private func filled(_ tab: Tab) async throws {
        try await untilValue(tab, expression: "document.getElementById('password').value", equals: password)
    }

    private func assertNotFilled(_ tab: Tab) async throws {
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(vault.secretReads, 0)
        try await assertValue(tab, "document.getElementById('password').value", equals: "")
        try await assertValue(tab, "document.body.dataset.submits", equals: "0")
    }

    private func assertValue(_ tab: Tab, _ expression: String, equals expected: String,
                             file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await value(tab, expression) as? String
        XCTAssertEqual(actual, expected, expression, file: file, line: line)
    }

    @discardableResult
    private func call(_ tab: Tab, _ body: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await withCheckedThrowingContinuation { completion in
            tab.web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: Web.world) { (result: Result<Any, Error>) in
                completion.resume(with: result.map { $0 is NSNull ? nil : $0 })
            }
        }
    }

    private func value(_ tab: Tab, _ expression: String) async throws -> Any? { try await call(tab, "return \(expression);") }

    private func untilValue(_ tab: Tab, expression: String, equals expected: String) async throws {
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if (try? await value(tab, expression)) as? String == expected { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTFail("The synthetic document did not produce the expected value for \(expression)")
        throw URLError(.timedOut)
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(6)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(15)) }
        guard condition() else { XCTFail("The synthetic login continuation did not settle"); throw URLError(.timedOut) }
    }
}

private final class CancelNavigation: NSObject, WKNavigationDelegate {
    var cancelled = false
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        cancelled = true
        decisionHandler(.cancel)
    }
}

private final class ContinuationVault {
    let host: String
    let user: String
    let password: String
    private(set) var secretReads = 0

    init(host: String, user: String, password: String) {
        self.host = host; self.user = user; self.password = password
    }

    var backend: Vault.Backend {
        .init(entries: { [self] in [Kept(host: host, user: user, used: nil, clear: false, since: nil)] },
              read: { [self] kept, context in
                  guard kept.host == host, kept.user == user, context != nil else { throw URLError(.userAuthenticationRequired) }
                  secretReads += 1
                  return Secret(password: password)
              }, save: { _, _, _, _, _, _ in }, touch: { _, _ in }, forget: { _ in })
    }
}
