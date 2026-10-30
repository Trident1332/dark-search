import AppKit
import Security
import WebKit
import XCTest
@testable import Search

/// Native field/delegate events use synthetic HTTPS addresses and an idle
/// Apple-helper stand-in. No site, saved password, or real helper is used.
@MainActor
final class AccountSuggestionLifecycleTests: XCTestCase {
    private var browser: Browser!
    private var store: UserDefaults!
    private var suite = ""
    private var previousApple = false
    private var previousFills = false
    private var previousPolicy = NSApplication.ActivationPolicy.prohibited
    private var previousBenchAsks = false
    private var previousBenchHelper: Bool?
    private var helper: StandInLink!
    private let spot = CGRect(x: 40, y: 120, width: 280, height: 30)

    override class func setUp() {
        setenv("SEARCH_PROBE", "account-suggestion-lifecycle-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        suite = "account-suggestion-lifecycle-\(UUID())"
        store = try XCTUnwrap(UserDefaults(suiteName: suite))
        browser = Browser(record: WindowRecord())
        previousApple = browser.prefs.applePasswords
        previousFills = browser.prefs.fillsPasswords
        browser.prefs.applePasswords = false
        browser.prefs.fillsPasswords = true
        previousBenchAsks = ApplePasswordsOffer.benchAsks
        previousBenchHelper = ApplePasswordsOffer.benchHelper
        ApplePasswordsOffer.benchAsks = true
        ApplePasswordsOffer.benchHelper = true
        browser.applePasswordsOffer = ApplePasswordsOffer(store: store)
        let link = StandInLink()
        helper = link
        browser.applePasswords = ApplePasswords(makeLink: { link })
        // No real vault or legacy Keychain item is consulted by this fixture.
        Vault.useBackendForTesting(.init(entries: { [] }, read: { _, _ in throw URLError(.userAuthenticationRequired) },
                                         save: { _, _, _, _, _, _ in }, touch: { _, _ in }, forget: { _ in }))
        KeychainAccess.useBackendForTesting(.init(
            getInteraction: { (errSecSuccess, true) }, setInteraction: { _ in errSecSuccess },
            copyMatching: { _, _ in errSecItemNotFound }, add: { _, _ in errSecInteractionNotAllowed },
            update: { _, _ in errSecInteractionNotAllowed }, delete: { _ in errSecInteractionNotAllowed }))
    }

    override func tearDown() async throws {
        XCTAssertEqual(helper?.starts, 0, "Only the stand-in exists, and no lifecycle event starts pairing")
        browser?.closeAll()
        if let browser {
            browser.prefs.applePasswords = previousApple
            browser.prefs.fillsPasswords = previousFills
        }
        browser = nil
        KeychainAccess.useBackendForTesting(nil)
        Vault.useBackendForTesting(nil)
        ApplePasswordsOffer.benchAsks = previousBenchAsks
        ApplePasswordsOffer.benchHelper = previousBenchHelper
        store?.removePersistentDomain(forName: suite)
        NSApp.setActivationPolicy(previousPolicy)
        try await super.tearDown()
    }

    private func tab(_ host: String = "login.account-lifecycle.invalid") -> Tab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(configuration: configuration)
        tab.setAddressOptimistically(URL(string: "https://\(host)/login")!)
        browser.prepare(tab)
        browser.insert(tab, at: browser.tabs.count)
        return tab
    }

    private func offer(on tab: Tab) {
        browser.activeID = tab.id
        tab.fieldFocused(spot)
        XCTAssertEqual(browser.suggesting?.tab, tab.id)
        XCTAssertNotNil(browser.suggesting?.appleOffer, "The real field handler must put up the offer before leaving it")
    }

    func testProvisionalNavigationClearsOfferEvenWhenURLHasNotChanged() {
        let tab = tab()
        offer(on: tab)
        let address = tab.address
        browser.webView(tab.web, didStartProvisionalNavigation: nil)
        XCTAssertEqual(tab.address, address, "Reloading the same page cannot rely on a host or URL change")
        XCTAssertNil(browser.suggesting)
        XCTAssertEqual(store.integer(forKey: ApplePasswordsOffer.unansweredKey), 1)
        browser.webView(tab.web, didCommit: nil)
        XCTAssertEqual(store.integer(forKey: ApplePasswordsOffer.unansweredKey), 1, "One departing offer is counted once")
    }

    func testCommitClearsOfferWithoutDependingOnOldDocumentsBlur() {
        let tab = tab()
        offer(on: tab)
        browser.webView(tab.web, didCommit: nil)
        XCTAssertNil(browser.suggesting, "A new document on the same host retires the old field")
    }

    func testSPAAddressChangeClearsOfferOnTheSameHost() {
        let tab = tab()
        offer(on: tab)
        tab.setAddressOptimistically(URL(string: "https://login.account-lifecycle.invalid/dashboard")!)
        XCTAssertNil(browser.suggesting)
        XCTAssertEqual(store.integer(forKey: ApplePasswordsOffer.unansweredKey), 1)
    }

    func testDirectActiveTabChangeClearsOfferAndOldField() {
        let first = tab(), second = tab("other.account-lifecycle.invalid")
        offer(on: first)
        browser.activeID = second.id // New-tab and space paths can bypass select().
        XCTAssertNil(browser.suggesting)
        browser.activeID = first.id
        browser.applePasswordsOffer.forget()
        NotificationCenter.default.post(name: Passkeys.offeredChanged, object: first.web)
        XCTAssertNil(browser.suggesting, "Returning to a tab must not revive a field that was invalidated when leaving")
    }

    func testBackgroundNavigationDoesNotDismissActiveTabsOffer() {
        let active = tab(), background = tab("background.account-lifecycle.invalid")
        offer(on: active)
        background.fieldFocused(spot.offsetBy(dx: 20, dy: 40))
        browser.webView(background.web, didStartProvisionalNavigation: nil)
        browser.webView(background.web, didCommit: nil)
        background.setAddressOptimistically(URL(string: "https://background.account-lifecycle.invalid/dashboard")!)
        XCTAssertEqual(browser.suggesting?.tab, active.id)
        XCTAssertNotNil(browser.suggesting?.appleOffer)
        XCTAssertEqual(store.integer(forKey: ApplePasswordsOffer.unansweredKey), 0)
    }

    func testLatePasskeyNotificationCannotRecreateRetiredField() {
        let tab = tab()
        offer(on: tab)
        browser.webView(tab.web, didCommit: nil)
        // Allow another offer on this fixture site: a stale field would now
        // visibly recreate it when the real asynchronous notification lands.
        browser.applePasswordsOffer.forget()
        NotificationCenter.default.post(name: Passkeys.offeredChanged, object: tab.web)
        XCTAssertNil(browser.suggesting)
        tab.fieldFocused(spot)
        XCTAssertNotNil(browser.suggesting?.appleOffer, "A newly focused field remains eligible after navigation")
    }

    func testOrdinaryBlurKeepsClickGraceThenDismissesAndCanRefocus() async throws {
        let tab = tab()
        browser.activeID = tab.id
        browser.prefs.applePasswords = true // A connect row is eligible on each focus, unlike the one-time offer.
        tab.fieldFocused(spot)
        XCTAssertTrue(browser.suggesting?.appleConnect == true)
        tab.fieldFocused(nil)
        XCTAssertNotNil(browser.suggesting, "A row click still has the existing delayed-blur grace period")
        try await until { browser.suggesting == nil }
        tab.fieldFocused(spot)
        XCTAssertTrue(browser.suggesting?.appleConnect == true)
    }

    func testRefocusingBeforeBlurGraceEndsDoesNotLoseTheNewList() async throws {
        let tab = tab()
        browser.activeID = tab.id
        browser.prefs.applePasswords = true
        tab.fieldFocused(spot)
        tab.fieldFocused(nil)
        let moved = spot.offsetBy(dx: 12, dy: 20)
        tab.fieldFocused(moved)
        try await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(browser.suggesting?.spot, moved)
        XCTAssertTrue(browser.suggesting?.appleConnect == true)
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard condition() else { XCTFail("The account list did not dismiss after blur"); throw URLError(.timedOut) }
    }
}
