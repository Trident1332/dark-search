import AppKit
import Foundation
import WebKit
import XCTest
@testable import Search

/// Native continuation boundaries exercised against synthetic documents,
/// a counted in-memory vault and controlled biometric answers. No real
/// password store, account server or authentication prompt is involved.
@MainActor
final class LoginContinuationBoundaryTests: XCTestCase {
    private let origin = URL(string: "https://login.boundary.invalid")!
    private let username = "selected@synthetic.invalid"
    private let password = "Synthetic-Boundary-Secret-42"
    private var browser: Browser!
    private var vault: BoundaryPasswordVault!
    private var authorizations = 0
    private var pendingApproval: CheckedContinuation<Bool, Never>?
    private var previousPreferences: (Bool, Bool, Bool)!
    private var previousPolicy = NSApplication.ActivationPolicy.prohibited

    override class func setUp() {
        setenv("SEARCH_PROBE", "login-continuation-boundaries-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        previousPreferences = (browser.prefs.fillsPasswords, browser.prefs.applePasswords, browser.prefs.savesPasswords)
        browser.prefs.fillsPasswords = true
        browser.prefs.applePasswords = false
        browser.prefs.savesPasswords = false
        vault = BoundaryPasswordVault(host: origin.host()!, user: username, password: password)
        Vault.useBackendForTesting(vault.backend)
        authorize(approved: true)
    }

    override func tearDown() async throws {
        resolveApproval(false)
        browser?.closeAll()
        try await Task.sleep(for: .milliseconds(40))
        if let browser, let previousPreferences {
            (browser.prefs.fillsPasswords, browser.prefs.applePasswords, browser.prefs.savesPasswords) = previousPreferences
        }
        browser = nil
        WebsitePasswordAuthentication.useForTesting(nil)
        Vault.useBackendForTesting(nil)
        vault = nil
        NSApp.setActivationPolicy(previousPolicy)
        try await super.tearDown()
    }

    func testFreshFullFormUsesExactlyOneApprovalAndOneSecretRead() async throws {
        let tab = makeTab()
        browser.activeID = tab.id
        try await load(tab, fields: usernameField + passwordField, path: "login")
        try await chooseAccount(in: tab, focus: "password", nameOnly: false)
        try await untilValue(tab, expression: "document.getElementById('password').value", equals: password)
        try await assertValue(tab, "document.getElementById('user').value", equals: username)
        XCTAssertEqual(authorizations, 1)
        XCTAssertEqual(vault.secretReads, 1)
        try await noise(tab)
        XCTAssertEqual(authorizations, 1, "Repeated DOM/focus notifications must not ask for another approval")
        XCTAssertEqual(vault.secretReads, 1)
        try await assertValue(tab, "document.body.dataset.submits", equals: "0")
    }

    func testExpiredChosenNameNeverPromptsOrReadsPassword() async throws {
        var now = Date()
        browser.loginContinuationNow = { now }
        let tab = try await selectUsername()
        now = now.addingTimeInterval(61)
        try await replaceFields(tab, with: passwordField)
        try await noise(tab)
        try await assertUntouched(tab)
        XCTAssertEqual(authorizations, 0)
        XCTAssertEqual(vault.secretReads, 0)
    }

    func testEditingOrClearingChosenUsernameCancelsBeforePasswordStage() async throws {
        for changed in ["different@synthetic.invalid", ""] {
            let tab = try await selectUsername()
            try await call(tab, "document.getElementById('user').value = user; return true;", arguments: ["user": changed])
            // This is the native notification emitted for a trusted user
            // edit. Remove the first-step field afterward, as a SPA does,
            // so DOM mismatch checks cannot hide a missing cancellation.
            tab.gaveName(changed)
            try await replaceFields(tab, with: passwordField)
            try await noise(tab)
            try await assertUntouched(tab)
            XCTAssertEqual(authorizations, 0)
            XCTAssertEqual(vault.secretReads, 0)
        }
    }

    func testDeniedApprovalIsConsumedAndLaterDOMEventsCannotReprompt() async throws {
        authorize(approved: false)
        let tab = try await selectUsername()
        try await replaceFields(tab, with: passwordField)
        try await until { self.authorizations == 1 }
        try await noise(tab)
        try await assertUntouched(tab)
        XCTAssertEqual(authorizations, 1, "A denied account choice must not remain armed")
        XCTAssertEqual(vault.secretReads, 0)
    }

    func testCancelledApprovalIsConsumedAndLaterDOMEventsCannotReprompt() async throws {
        deferApproval()
        let tab = try await selectUsername()
        try await replaceFields(tab, with: passwordField)
        try await until { self.pendingApproval != nil }
        resolveApproval(false)
        try await noise(tab)
        try await assertUntouched(tab)
        XCTAssertEqual(authorizations, 1, "Cancelling the prompt must consume the original selection")
        XCTAssertEqual(vault.secretReads, 0)
    }

    func testSwitchingAwayDuringApprovalCancelsEvenAfterReturning() async throws {
        deferApproval()
        let tab = try await selectUsername()
        try await replaceFields(tab, with: passwordField)
        try await until { self.pendingApproval != nil }
        let other = makeTab()
        browser.activeID = other.id
        browser.activeID = tab.id
        resolveApproval(true)
        try await noise(tab)
        try await assertUntouched(tab)
        XCTAssertEqual(authorizations, 1)
        XCTAssertEqual(vault.secretReads, 0, "A cancelled approval task cannot decrypt on its late answer")
    }

    func testExplicitNavigationDuringApprovalCannotFillNewDocument() async throws {
        deferApproval()
        let tab = try await selectUsername()
        try await replaceFields(tab, with: passwordField)
        try await until { self.pendingApproval != nil }
        let refusing = BoundaryNavigationRefusal()
        tab.web.navigationDelegate = refusing
        tab.go(to: origin.appendingPathComponent("unrelated"))
        try await until { refusing.cancelled }
        tab.web.navigationDelegate = browser
        try await load(tab, fields: passwordField, path: "unrelated")
        resolveApproval(true)
        try await noise(tab)
        try await assertUntouched(tab)
        XCTAssertEqual(authorizations, 1)
        XCTAssertEqual(vault.secretReads, 0)
    }

    func testReplacingPasswordFieldDuringApprovalRejectsLateFill() async throws {
        deferApproval()
        let tab = try await selectUsername()
        try await replaceFields(tab, with: passwordField)
        try await until { self.pendingApproval != nil }
        // The new element has the same HTML id, attributes and location.
        // Only its opaque native-preflight identity distinguishes it.
        try await call(tab, "var old = document.getElementById('password'); old.replaceWith(old.cloneNode(true)); return true;")
        resolveApproval(true)
        try await until { self.vault.secretReads == 1 }
        try await noise(tab)
        try await assertUntouched(tab)
        XCTAssertEqual(authorizations, 1)
        XCTAssertEqual(vault.secretReads, 1, "The rejected field must not cause another read or approval")
    }

    private var usernameField: String { "<input id='user' name='username' autocomplete='username'>" }
    private var passwordField: String { "<input id='password' name='password' type='password' autocomplete='current-password'><button type='button'>Sign in</button>" }

    private func authorize(approved: Bool) {
        WebsitePasswordAuthentication.useForTesting { [weak self] _, _ in
            self?.authorizations += 1
            return approved
        }
    }

    private func deferApproval() {
        WebsitePasswordAuthentication.useForTesting { [weak self] _, _ in
            guard let self else { return false }
            authorizations += 1
            return await withCheckedContinuation { self.pendingApproval = $0 }
        }
    }

    private func resolveApproval(_ approved: Bool) {
        let continuation = pendingApproval
        pendingApproval = nil
        continuation?.resume(returning: approved)
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
        try await load(tab, fields: usernameField + "<button type='button'>Next</button>", path: "login")
        try await chooseAccount(in: tab, focus: "user", nameOnly: true)
        try await untilValue(tab, expression: "document.getElementById('user').value", equals: username)
        try await until { tab.givenName() == self.username }
        XCTAssertEqual(authorizations, 0, "Choosing only a name must not request biometric approval")
        XCTAssertEqual(vault.secretReads, 0)
        return tab
    }

    private func chooseAccount(in tab: Tab, focus id: String, nameOnly: Bool) async throws {
        try await call(tab, "document.getElementById(field).focus(); return true;", arguments: ["field": id])
        try await until {
            self.browser.suggesting?.tab == tab.id && self.browser.suggesting?.logins.contains(where: { $0.user == self.username }) == true
        }
        XCTAssertEqual(browser.suggesting?.nameOnly, nameOnly)
        let chosen = try XCTUnwrap(browser.suggesting?.logins.first { $0.user == username })
        try await Task.sleep(for: .milliseconds(550))
        browser.choose(chosen)
    }

    private func load(_ tab: Tab, fields: String, path: String) async throws {
        let stamp = UUID().uuidString
        tab.web.loadHTMLString("""
        <!doctype html><style>input{width:250px;height:30px}</style>
        <body data-stage='\(stamp)' data-submits='0'><form id='login'>\(fields)</form>
        <script>document.getElementById('login').addEventListener('submit',function(e){e.preventDefault();document.body.dataset.submits=String(Number(document.body.dataset.submits)+1)});</script>
        </body>
        """, baseURL: origin.appendingPathComponent(path))
        try await untilValue(tab, expression: "document.body && document.body.dataset.stage", equals: stamp)
        try await untilValue(tab, expression: "String(!!window.__officeForms)", equals: "true")
    }

    private func replaceFields(_ tab: Tab, with fields: String) async throws {
        try await call(tab, "document.getElementById('login').innerHTML = fields; return true;", arguments: ["fields": fields])
        tab.foundSignIn()
    }

    private func noise(_ tab: Tab) async throws {
        for _ in 0..<3 {
            tab.foundSignIn()
            tab.fieldFocused(CGRect(x: 20, y: 60, width: 250, height: 30))
            try await Task.sleep(for: .milliseconds(40))
        }
        try await Task.sleep(for: .milliseconds(200))
    }

    private func assertUntouched(_ tab: Tab, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await assertValue(tab, "document.getElementById('password').value", equals: "", file: file, line: line)
        try await assertValue(tab, "document.body.dataset.submits", equals: "0", file: file, line: line)
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
        guard condition() else { XCTFail("The synthetic boundary did not settle"); throw URLError(.timedOut) }
    }
}

private final class BoundaryNavigationRefusal: NSObject, WKNavigationDelegate {
    var cancelled = false
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        cancelled = true
        decisionHandler(.cancel)
    }
}

private final class BoundaryPasswordVault {
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
