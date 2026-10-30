import AppKit
import Foundation
import Security
import WebKit
import XCTest
@testable import Search

/// A held trustd stand-in and idle native tabs. No network, live browser,
/// certificate dialog, or installed profile is used by these regressions.
@MainActor
final class CertificateTrustResponsivenessTests: XCTestCase {
    private var browser: Browser!
    private var evaluator: HeldTrustEvaluator!
    private var previousPolicy = NSApplication.ActivationPolicy.prohibited
    private var previousQuestions: [String] = []
    private let host = "certificate-exception.example.invalid"

    override class func setUp() {
        setenv("SEARCH_PROBE", "certificate-trust-responsiveness-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        previousQuestions = Dialogs.askedInTest
        Dialogs.askedInTest = []
        Vault.useBackendForTesting(.init(entries: { [] }, read: { _, _ in throw URLError(.userAuthenticationRequired) },
                                         save: { _, _, _, _, _, _ in }, touch: { _, _ in }, forget: { _ in }))
        browser = Browser(record: WindowRecord())
        let evaluator = HeldTrustEvaluator()
        self.evaluator = evaluator
        CertificateTrustEvaluation.useForTesting(evaluator.evaluate)
    }

    override func tearDown() async throws {
        browser?.closeAll()
        browser = nil
        evaluator?.finish(false)
        await Task.yield()
        CertificateTrustEvaluation.useForTesting(nil)
        Vault.useBackendForTesting(nil)
        Dialogs.askedInTest = previousQuestions
        NSApp.setActivationPolicy(previousPolicy)
        try await super.tearDown()
    }

    private func tab(address: String? = nil) -> Tab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(configuration: configuration)
        if let address { tab.setAddressOptimistically(URL(string: address)!) }
        browser.prepare(tab)
        browser.insert(tab, at: browser.tabs.count)
        return tab
    }

    private func fixtureTrust() throws -> SecTrust {
        let data = try XCTUnwrap(Data(base64Encoded: Self.certificate, options: .ignoreUnknownCharacters))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, data as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, host as CFString), &trust), errSecSuccess)
        let made = try XCTUnwrap(trust)
        SecTrustSetNetworkFetchAllowed(made, false)
        return made
    }

    private func challenge(trust: SecTrust, host: String? = nil, port: Int = 443,
                           scheme: String = "https") -> URLAuthenticationChallenge {
        let space = FixtureTrustSpace(trust: trust, host: host ?? self.host, port: port, scheme: scheme)
        return URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
                                          failureResponse: nil, error: nil, sender: FixtureTrustSender())
    }

    func testHeldTrustLeavesMainActorHeartbeatAndTabSelectionResponsiveAndAnswersOnce() async throws {
        let first = tab(address: "https://\(host)/page"), second = tab()
        browser.activeID = first.id
        var answers: [URLSession.AuthChallengeDisposition] = []
        browser.webView(first.web, didReceive: challenge(trust: try fixtureTrust())) { disposition, _ in
            XCTAssertTrue(Thread.isMainThread)
            answers.append(disposition)
        }
        try await until { evaluator.count == 1 }
        XCTAssertEqual(evaluator.wasMainThread, [false], "Even starting a trust evaluation must run away from the UI thread")
        var heartbeat = false
        DispatchQueue.main.async { heartbeat = true }
        browser.select(second, floatPrevious: false)
        try await until { heartbeat }
        XCTAssertEqual(browser.activeID, second.id)
        XCTAssertTrue(answers.isEmpty, "The main actor stays live while trustd has not answered")
        evaluator.finish(true, times: 2)
        try await until { answers.count == 1 }
        await Task.yield()
        XCTAssertEqual(answers, [.performDefaultHandling])
        XCTAssertTrue(Dialogs.askedInTest.isEmpty)
    }

    func testUntrustedTopLevelCertificateKeepsGoBackAndDoesNotCreateException() async throws {
        let tab = tab(address: "https://\(host)/page")
        browser.activeID = tab.id
        let trust = try fixtureTrust(), challenge = challenge(trust: trust)
        var answer: URLSession.AuthChallengeDisposition?
        browser.webView(tab.web, didReceive: challenge) { disposition, credential in
            answer = disposition
            XCTAssertNil(credential)
        }
        try await until { evaluator.count == 1 }
        evaluator.finish(false)
        try await until { answer != nil }
        XCTAssertEqual(answer, .cancelAuthenticationChallenge)
        XCTAssertEqual(Dialogs.askedInTest, ["\(host) can't prove who it is"])
        XCTAssertFalse(Dialogs.excused.contains(trust, for: challenge.protectionSpace, in: tab.store))
    }

    func testAcceptedExactCertificateAndOriginInOriginalStoreStillUsesCredential() async throws {
        let tab = tab(address: "https://\(host)/page")
        browser.activeID = tab.id
        let trust = try fixtureTrust(), challenge = challenge(trust: trust)
        XCTAssertTrue(Dialogs.excused.accept(trust, for: challenge.protectionSpace, in: tab.store))
        var answer: URLSession.AuthChallengeDisposition?
        browser.webView(tab.web, didReceive: challenge) { disposition, credential in
            answer = disposition
            XCTAssertNotNil(credential)
        }
        try await until { evaluator.count == 1 }
        evaluator.finish(false)
        try await until { answer != nil }
        XCTAssertEqual(answer, .useCredential)
        XCTAssertTrue(Dialogs.askedInTest.isEmpty)
    }

    func testAcceptedExceptionDoesNotCrossPortAndOtherOriginSubresourceDoesNotPrompt() async throws {
        let tab = tab(address: "https://\(host)/page")
        browser.activeID = tab.id
        let trust = try fixtureTrust()
        let original = challenge(trust: trust)
        Dialogs.excused.accept(trust, for: original.protectionSpace, in: tab.store)
        var answer: URLSession.AuthChallengeDisposition?
        browser.webView(tab.web, didReceive: challenge(trust: trust, port: 8443)) { disposition, credential in
            answer = disposition
            XCTAssertNil(credential)
        }
        try await until { evaluator.count == 1 }
        evaluator.finish(false)
        try await until { answer != nil }
        XCTAssertEqual(answer, .performDefaultHandling)
        XCTAssertTrue(Dialogs.askedInTest.isEmpty, "A matching hostname at a different origin cannot borrow the page's dialog")
    }

    func testSameURLReloadCancelsHeldChallengeBeforeLateResult() async throws {
        try await checkInvalidation { browser, tab in browser.webView(tab.web, didStartProvisionalNavigation: nil) }
    }

    func testCachedDocumentCommitCancelsHeldChallengeBeforeLateResult() async throws {
        try await checkInvalidation { browser, tab in browser.webView(tab.web, didCommit: nil) }
    }

    func testEarlierTrustResultCannotAnswerNewChallengeAfterSameURLReload() async throws {
        let tab = tab(address: "https://\(host)/page")
        browser.activeID = tab.id
        var first: [URLSession.AuthChallengeDisposition] = [], second: [URLSession.AuthChallengeDisposition] = []
        browser.webView(tab.web, didReceive: challenge(trust: try fixtureTrust())) { disposition, _ in first.append(disposition) }
        try await until { evaluator.count == 1 }
        browser.webView(tab.web, didStartProvisionalNavigation: nil)
        browser.webView(tab.web, didReceive: challenge(trust: try fixtureTrust())) { disposition, _ in second.append(disposition) }
        try await until { evaluator.count == 2 }
        evaluator.finishNext(true, times: 2)
        await settle()
        XCTAssertEqual(first, [.cancelAuthenticationChallenge])
        XCTAssertTrue(second.isEmpty, "A callback from the old document must leave the new challenge pending")
        evaluator.finishNext(false)
        try await until { !second.isEmpty }
        XCTAssertEqual(second, [.cancelAuthenticationChallenge])
        XCTAssertEqual(Dialogs.askedInTest.count, 1, "Only the new request may ask about its certificate")
    }

    func testClosedTabCancelsHeldChallengeWhileOldWebViewIsStillRetained() async throws {
        let tab = tab(address: "https://\(host)/page"), _ = self.tab()
        browser.activeID = tab.id
        let oldWeb = tab.web
        var answers: [URLSession.AuthChallengeDisposition] = []
        browser.webView(oldWeb, didReceive: challenge(trust: try fixtureTrust())) { disposition, _ in answers.append(disposition) }
        try await until { evaluator.count == 1 }
        browser.close(tab)
        XCTAssertEqual(answers, [.cancelAuthenticationChallenge])
        XCTAssertNil(oldWeb.navigationDelegate)
        evaluator.finish(true, times: 2)
        await settle()
        XCTAssertEqual(answers, [.cancelAuthenticationChallenge])
        XCTAssertTrue(Dialogs.askedInTest.isEmpty)
    }

    func testDetachedViewCannotUseOldTrustedResultOrStoredException() async throws {
        let tab = tab(address: "https://\(host)/page")
        browser.activeID = tab.id
        let trust = try fixtureTrust(), challenge = challenge(trust: trust)
        Dialogs.excused.accept(trust, for: challenge.protectionSpace, in: tab.store)
        var answer: URLSession.AuthChallengeDisposition?
        browser.webView(tab.web, didReceive: challenge) { disposition, credential in
            answer = disposition
            XCTAssertNil(credential)
        }
        try await until { evaluator.count == 1 }
        tab.web.navigationDelegate = nil
        evaluator.finish(false)
        try await until { answer != nil }
        XCTAssertEqual(answer, .cancelAuthenticationChallenge)
        XCTAssertTrue(Dialogs.askedInTest.isEmpty)
    }

    func testDeletedStoreCancelsOldChallengeWithRetainedViewAndKeepsOtherStorePending() async throws {
        let deleted = tab(address: "https://\(host)/page"), other = tab(address: "https://\(host)/other")
        browser.activeID = deleted.id
        let oldWeb = deleted.web, oldStore = deleted.store
        var deletedAnswers: [URLSession.AuthChallengeDisposition] = [], otherAnswers: [URLSession.AuthChallengeDisposition] = []
        browser.webView(oldWeb, didReceive: challenge(trust: try fixtureTrust())) { disposition, _ in deletedAnswers.append(disposition) }
        browser.webView(other.web, didReceive: challenge(trust: try fixtureTrust())) { disposition, _ in otherAnswers.append(disposition) }
        try await until { evaluator.count == 2 }
        // A fresh synthetic identifier and two nonpersistent stores cannot
        // address any installed profile. Keep the original objects alive.
        Spaces.eraseStore(oldStore, id: UUID())
        XCTAssertEqual(deletedAnswers, [.cancelAuthenticationChallenge])
        XCTAssertTrue(otherAnswers.isEmpty)
        XCTAssertTrue(oldWeb.configuration.websiteDataStore === oldStore)
        XCTAssertTrue(oldWeb.navigationDelegate === browser)
        evaluator.finish(true, times: 2)
        try await until { !otherAnswers.isEmpty }
        XCTAssertEqual(deletedAnswers, [.cancelAuthenticationChallenge])
        XCTAssertEqual(otherAnswers, [.performDefaultHandling])
    }

    func testTerminatedBackgroundContentProcessCancelsItsPendingTrust() async throws {
        let tab = tab(address: "https://\(host)/page"), foreground = self.tab()
        browser.activeID = foreground.id
        var answers: [URLSession.AuthChallengeDisposition] = []
        browser.webView(tab.web, didReceive: challenge(trust: try fixtureTrust())) { disposition, _ in answers.append(disposition) }
        try await until { evaluator.count == 1 }
        browser.webViewWebContentProcessDidTerminate(tab.web)
        XCTAssertEqual(answers, [.cancelAuthenticationChallenge])
        XCTAssertTrue(tab.stale, "The background page remains recoverable when selected, without starting a network load now")
        evaluator.finish(true, times: 2)
        await settle()
        XCTAssertEqual(answers, [.cancelAuthenticationChallenge])
        XCTAssertTrue(Dialogs.askedInTest.isEmpty)
    }

    func testMissingTrustUsesDefaultHandlingWithoutStartingEvaluation() {
        let tab = tab()
        let space = URLProtectionSpace(host: host, port: 443, protocol: "https", realm: nil,
                                      authenticationMethod: NSURLAuthenticationMethodServerTrust)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
                                                   failureResponse: nil, error: nil, sender: FixtureTrustSender())
        var answer: URLSession.AuthChallengeDisposition?
        browser.webView(tab.web, didReceive: challenge) { disposition, _ in answer = disposition }
        XCTAssertEqual(answer, .performDefaultHandling)
        XCTAssertEqual(evaluator.count, 0)
    }

    func testRealOfflineSecurityEvaluationCompletesOnMainAndKeepsGoBack() async throws {
        CertificateTrustEvaluation.useForTesting(nil)
        let tab = tab(address: "https://\(host)/page")
        browser.activeID = tab.id
        var answer: URLSession.AuthChallengeDisposition?
        browser.webView(tab.web, didReceive: challenge(trust: try fixtureTrust())) { disposition, credential in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNil(credential)
            answer = disposition
        }
        try await until { answer != nil }
        XCTAssertEqual(answer, .cancelAuthenticationChallenge)
        XCTAssertEqual(Dialogs.askedInTest.count, 1)
    }

    private func checkInvalidation(_ invalidate: (Browser, Tab) -> Void) async throws {
        let tab = tab(address: "https://\(host)/page")
        browser.activeID = tab.id
        let address = tab.address
        var answers: [URLSession.AuthChallengeDisposition] = []
        browser.webView(tab.web, didReceive: challenge(trust: try fixtureTrust())) { disposition, _ in answers.append(disposition) }
        try await until { evaluator.count == 1 }
        invalidate(browser, tab)
        XCTAssertEqual(tab.address, address)
        XCTAssertEqual(answers, [.cancelAuthenticationChallenge])
        evaluator.finish(false, times: 2)
        await settle()
        XCTAssertEqual(answers, [.cancelAuthenticationChallenge], "The old trust result is consumed without a new warning or reply")
        XCTAssertTrue(Dialogs.askedInTest.isEmpty)
    }

    private func settle() async { for _ in 0..<5 { await Task.yield() } }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard condition() else { XCTFail("The held trust callback did not advance"); throw URLError(.timedOut) }
    }

    // Public self-signed certificate from CertificateExceptionsTests; no
    // private key is retained and network fetches are disabled above.
    private static let certificate = """
    MIICPDCCAeICAQEwCgYIKoZIzj0EAwIwMDEuMCwGA1UEAwwlY2VydGlmaWNhdGUtZXhjZXB0aW9uLmV4YW1wbGUu
    aW52YWxpZDAeFw0yNjEwMjgyMTExNDFaFw0zNjEwMjUyMTExNDFaMDAxLjAsBgNVBAMMJWNlcnRpZmljYXRlLWV4
    Y2VwdGlvbi5leGFtcGxlLmludmFsaWQwggFLMIIBAwYHKoZIzj0CATCB9wIBATAsBgcqhkjOPQEBAiEA/////wAA
    AAEAAAAAAAAAAAAAAAD///////////////8wWwQg/////wAAAAEAAAAAAAAAAAAAAAD///////////////wEIFrG
    NdiqOpPns+u9VXaYhrxlHQawzFOw9jvOPD4n0mBLAxUAxJ02CIbnBJNqZnjhE50mt4GffpAEQQRrF9Hy4SxCR/i8
    5uVjpEDydwN9gS3rM6D0oTlF2JjClk/jQuL+Gn+bjufrSnwPnhYrzjNXazFezsu2QGg3v1H1AiEA/////wAAAAD/
    /////////7zm+q2nF56E87nKwvxjJVECAQEDQgAEtCpdupTo04vSr8jmkm48RT+WC9LNCk37wEpd7LLumzonvPXS
    1IJEvqn4HC3MNJJsKfU0fVubBGhYLs4XVl9lbjAKBggqhkjOPQQDAgNIADBFAiEAhUsa1ud5VaZHYaZzhPU2ukwW
    wKZJ7S9QUVh/t8I+vjMCIBOiAgoOEEIq//2dyi8Qcg2KlUk7DOYK4qoX35D4lhpq
    """
}

private final class HeldTrustEvaluator {
    private let lock = NSLock()
    private var replies: [(Bool) -> Void] = []
    private var threads: [Bool] = []

    var count: Int { lock.lock(); defer { lock.unlock() }; return replies.count }
    var wasMainThread: [Bool] { lock.lock(); defer { lock.unlock() }; return threads }

    func evaluate(_ trust: SecTrust, finish: @escaping (Bool) -> Void) {
        lock.lock()
        threads.append(Thread.isMainThread)
        replies.append(finish)
        lock.unlock()
    }

    func finish(_ trusted: Bool, times: Int = 1) {
        lock.lock()
        let replies = replies
        self.replies = []
        lock.unlock()
        for reply in replies { for _ in 0..<times { reply(trusted) } }
    }

    func finishNext(_ trusted: Bool, times: Int = 1) {
        lock.lock()
        let reply = replies.isEmpty ? nil : replies.removeFirst()
        lock.unlock()
        for _ in 0..<times { reply?(trusted) }
    }
}

private final class FixtureTrustSpace: URLProtectionSpace {
    private let fixture: SecTrust
    init(trust: SecTrust, host: String, port: Int, scheme: String) {
        fixture = trust
        super.init(host: host, port: port, protocol: scheme, realm: nil, authenticationMethod: NSURLAuthenticationMethodServerTrust)
    }
    required init?(coder: NSCoder) { fatalError("This trust fixture is not archived") }
    override var serverTrust: SecTrust? { fixture }
}

private final class FixtureTrustSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
