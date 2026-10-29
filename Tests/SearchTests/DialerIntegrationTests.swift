import AppKit
import AVFoundation
import Network
import WebKit
import XCTest
@testable import Search

/// Browser/window integration with an unconfigured line and a loopback page.
/// No SIP server, microphone, or outside website participates in these checks.
@MainActor
final class DialerIntegrationTests: XCTestCase {
    private var browsers: [Browser] = []
    private var tabs: [Tab] = []
    private var windows: [NSWindow] = []
    private var fixture: DialerBridgeFixture?

    override class func setUp() {
        setenv("SEARCH_PROBE", "dialer-integration-\(getpid())", 1)
        setenv("SEARCH_FEED", "file:///private/tmp/search-dialer-no-update-feed", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        DialerMicrophone.testingGate = nil
        Proxy.shared.automaticTarget = nil
        Onion.shared.stop()
        let prefs = Shared.prefs
        prefs.proxyOn = false
        prefs.dialerOn = false
        prefs.dialerWSS = ""
        prefs.dialerDomain = ""
        prefs.dialerUser = ""
        prefs.dialerSites = []
        Proxy.shared.take(ProxySetup())
        try await until { !Proxy.shared.changingContent }
        try await super.setUp()
    }

    override func tearDown() async throws {
        DialerMicrophone.testingGate = nil
        for browser in browsers { Browsers.discard(browser) }
        browsers.removeAll()
        for tab in tabs { tab.close() }
        tabs.removeAll()
        windows.removeAll()
        fixture?.stop()
        fixture = nil
        Shared.prefs.dialerOn = false
        Shared.prefs.proxyOn = false
        Proxy.shared.take(ProxySetup())
        try await until { !Proxy.shared.changingContent }
        try await super.tearDown()
    }

    private func until(_ condition: @escaping @MainActor () async -> Bool,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard await condition() else {
            XCTFail("The isolated dialer condition did not complete", file: file, line: line)
            throw URLError(.timedOut)
        }
    }

    private func browser() -> Browser {
        let browser = Browser(record: WindowRecord())
        Browsers.register(browser)
        browsers.append(browser)
        return browser
    }

    private func localPage() async throws -> URL {
        let fixture = try DialerBridgeFixture()
        self.fixture = fixture
        return try await fixture.address()
    }

    private func mount(_ web: WKWebView, width: CGFloat = 600, height: CGFloat = 400) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        windows.append(window)
    }

    private func readyDialer() async throws -> (Browser, DialerPage) {
        Shared.prefs.dialerOn = true
        let browser = browser()
        XCTAssertTrue(browser.showDialer())
        let page = try XCTUnwrap(browser.dialerPage)
        mount(page.web)
        try await until { page.ready && page.status.text == "Not configured" }
        return (browser, page)
    }

    func testMicrophonePreflightUsesOSStateAndRequestsOnlyWhenNeeded() async throws {
        var status = AVAuthorizationStatus.authorized
        var requests = 0
        DialerMicrophone.testingGate = .init(status: { status }, request: { requests += 1; return true })
        let (_, page) = try await readyDialer()
        XCTAssertEqual(requests, 0, "Loading the dialer does not request microphone access")
        func permission() async throws -> String? {
            let reply = try await pageScript("return await window.__searchDialer.requestMicrophone();", in: page.web) as? [String: Any]
            return reply?["state"] as? String
        }
        let authorized = try await permission()
        XCTAssertEqual(authorized, "granted")
        XCTAssertEqual(requests, 0)
        status = .denied
        let denied = try await permission()
        XCTAssertEqual(denied, "denied")
        status = .restricted
        let restricted = try await permission()
        XCTAssertEqual(restricted, "denied")
        XCTAssertEqual(requests, 0, "A denied or restricted microphone is not requested again")
        status = .notDetermined
        let prompted = try await permission()
        XCTAssertEqual(prompted, "granted")
        XCTAssertEqual(requests, 1)
    }

    func testMicrophonePermissionCannotReviveAHiddenAndReopenedCall() async throws {
        var requests = 0
        var waiting: CheckedContinuation<Bool, Never>?
        DialerMicrophone.testingGate = .init(status: { .notDetermined }, request: {
            requests += 1
            return await withCheckedContinuation { waiting = $0 }
        })
        defer { waiting?.resume(returning: false) }
        let (browser, page) = try await readyDialer()
        let pending = Task { await page.requestMicrophonePermission() }
        try await until { waiting != nil }
        browser.closeSidePanel()
        XCTAssertTrue(browser.showDialer())
        let answer = try XCTUnwrap(waiting)
        waiting = nil
        answer.resume(returning: true)
        let granted = await pending.value
        XCTAssertFalse(granted, "A later OS grant cannot revive a call hidden while permission was pending")
        XCTAssertTrue(page.visible)
        XCTAssertEqual(requests, 1)
    }

    func testMicrophonePermissionIsRejectedWhenProtectionChangesWhilePending() async throws {
        var requests = 0
        var waiting: CheckedContinuation<Bool, Never>?
        DialerMicrophone.testingGate = .init(status: { .notDetermined }, request: {
            requests += 1
            return await withCheckedContinuation { waiting = $0 }
        })
        defer { waiting?.resume(returning: false) }
        let (browser, page) = try await readyDialer()
        let pending = Task { await page.requestMicrophonePermission() }
        try await until { waiting != nil }
        Shared.prefs.proxyHost = "127.0.0.1"
        Shared.prefs.proxyPort = "9"
        Shared.prefs.proxyBlocks = true
        Shared.prefs.proxyOn = true
        XCTAssertTrue(page.released)
        XCTAssertNil(browser.dialerPage)
        XCTAssertNil(page.web.navigationDelegate)
        let answer = try XCTUnwrap(waiting)
        waiting = nil
        answer.resume(returning: true)
        let granted = await pending.value
        XCTAssertFalse(granted)
        XCTAssertEqual(requests, 1)
    }

    func testMicrophoneRecoveryRequiresExplicitApprovalWithAnExistingOSGrant() async throws {
        var requests = 0
        var prompts = 0
        var decision = DialerMicrophone.RecoveryChoice.cancel
        DialerMicrophone.testingGate = .init(status: { .authorized }, request: { requests += 1; return true }, recover: { _ in
            prompts += 1
            return decision
        })
        let (browser, page) = try await readyDialer()
        XCTAssertEqual(prompts, 0, "The retry question is shown only after a media failure")
        let cancelled = try await pageScript("return await window.__searchDialer.recoverMicrophone();", in: page.web) as? [String: Any]
        XCTAssertEqual(cancelled?["state"] as? String, "denied")
        XCTAssertEqual(prompts, 1)
        decision = .allow
        let allowed = try await pageScript("return await window.__searchDialer.recoverMicrophone();", in: page.web) as? [String: Any]
        XCTAssertEqual(allowed?["state"] as? String, "granted")
        XCTAssertEqual(prompts, 2)
        XCTAssertEqual(requests, 0, "An app retry question must not pretend to request a second OS grant")
        browser.closeSidePanel()
        let hidden = await page.recoverMicrophonePermission()
        XCTAssertFalse(hidden)
        XCTAssertEqual(prompts, 2)
    }

    func testMicrophoneRecoveryRequestsRealConsentWhenOSStateIsUndetermined() async throws {
        var requests = 0
        var retryPrompts = 0
        DialerMicrophone.testingGate = .init(status: { .notDetermined }, request: { requests += 1; return true }, recover: { _ in
            retryPrompts += 1
            return .cancel
        })
        let (_, page) = try await readyDialer()
        let allowed = try await pageScript("return await window.__searchDialer.recoverMicrophone();", in: page.web) as? [String: Any]
        XCTAssertEqual(allowed?["state"] as? String, "granted")
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(retryPrompts, 0, "The OS consent question is used when no decision has been made")
    }

    func testMicrophoneRecoveryOffersSettingsInsteadOfFakingDeniedOSAccess() async throws {
        var status = AVAuthorizationStatus.denied
        var decision = DialerMicrophone.RecoveryChoice.openSettings
        var requests = 0
        var settingsOpened = 0
        DialerMicrophone.testingGate = .init(status: { status }, request: { requests += 1; return true },
                                            recover: { _ in decision }, openSettings: { settingsOpened += 1 })
        let (_, page) = try await readyDialer()
        let denied = await page.recoverMicrophonePermission()
        XCTAssertFalse(denied)
        XCTAssertEqual(settingsOpened, 1)
        status = .restricted
        decision = .cancel
        let cancelled = await page.recoverMicrophonePermission()
        XCTAssertFalse(cancelled)
        XCTAssertEqual(settingsOpened, 1)
        decision = .allow
        let invalidGrant = await page.recoverMicrophonePermission()
        XCTAssertFalse(invalidGrant, "An app button cannot override a denied or restricted OS permission")
        XCTAssertEqual(requests, 0)
    }

    func testMicrophoneRecoveryCancelsStaleApprovalAfterHidingAndRejectsDuplicates() async throws {
        var prompts = 0
        var waiting: CheckedContinuation<DialerMicrophone.RecoveryChoice, Never>?
        DialerMicrophone.testingGate = .init(status: { .authorized }, request: { false }, recover: { _ in
            prompts += 1
            return await withCheckedContinuation { waiting = $0 }
        })
        defer { waiting?.resume(returning: .cancel) }
        let (browser, page) = try await readyDialer()
        let pending = Task { await page.recoverMicrophonePermission() }
        try await until { waiting != nil }
        let duplicate = await page.recoverMicrophonePermission()
        XCTAssertFalse(duplicate)
        XCTAssertEqual(prompts, 1)
        browser.closeSidePanel()
        XCTAssertTrue(browser.showDialer())
        let answer = try XCTUnwrap(waiting)
        waiting = nil
        answer.resume(returning: .allow)
        let stale = await pending.value
        XCTAssertFalse(stale)
    }

    func testMicrophoneRecoveryCancelsPendingApprovalWhenProtectionTurnsOn() async throws {
        var waiting: CheckedContinuation<DialerMicrophone.RecoveryChoice, Never>?
        DialerMicrophone.testingGate = .init(status: { .authorized }, request: { false }, recover: { _ in
            await withCheckedContinuation { waiting = $0 }
        })
        defer { waiting?.resume(returning: .cancel) }
        let (browser, page) = try await readyDialer()
        let pending = Task { await page.recoverMicrophonePermission() }
        try await until { waiting != nil }
        Shared.prefs.proxyHost = "127.0.0.1"
        Shared.prefs.proxyPort = "9"
        Shared.prefs.proxyBlocks = true
        Shared.prefs.proxyOn = true
        XCTAssertTrue(page.released)
        XCTAssertNil(browser.dialerPage)
        XCTAssertNil(page.web.navigationDelegate)
        let answer = try XCTUnwrap(waiting)
        waiting = nil
        answer.resume(returning: .allow)
        let stale = await pending.value
        XCTAssertFalse(stale)
    }

    func testMicrophoneRecoveryRejectsAnOSGrantRevokedWhileQuestionIsOpen() async throws {
        var status = AVAuthorizationStatus.authorized
        DialerMicrophone.testingGate = .init(status: { status }, request: { true }, recover: { _ in
            status = .denied
            return .allow
        })
        let (_, page) = try await readyDialer()
        let allowed = await page.recoverMicrophonePermission()
        XCTAssertFalse(allowed, "An app retry approval cannot replace a revoked OS permission")
    }

    func testMicrophoneRecoveryCancelsForConfigurationLineAndHangupChanges() async throws {
        var waiting: CheckedContinuation<DialerMicrophone.RecoveryChoice, Never>?
        DialerMicrophone.testingGate = .init(status: { .authorized }, request: { false }, recover: { _ in
            await withCheckedContinuation { waiting = $0 }
        })
        let oldSelection = Dialer.shared.pageValue("numeroLine")
        defer {
            waiting?.resume(returning: .cancel)
            if let oldSelection { Dialer.shared.set(["numeroLine": oldSelection]) }
            else { Dialer.shared.remove(["numeroLine"]) }
        }
        let (_, page) = try await readyDialer()
        for change in ["configuration", "line", "hangup"] {
            let pending = Task { await page.recoverMicrophonePermission() }
            try await until { waiting != nil }
            if change == "configuration" { page.settingsChanged(["numeroUS"]) }
            else if change == "line" {
                _ = try await pageScript("await chrome.storage.local.set({ numeroLine: 'ca' }); return true;", in: page.web)
            } else { page.hangUp() }
            let answer = try XCTUnwrap(waiting)
            waiting = nil
            answer.resume(returning: .allow)
            let stale = await pending.value
            XCTAssertFalse(stale, "A stale retry approval survived a \(change) change")
        }
    }

    func testMicrophoneNativeHookRejectsAnotherDocument() async throws {
        var requests = 0
        var recoveries = 0
        DialerMicrophone.testingGate = .init(status: { .notDetermined }, request: { requests += 1; return true }, recover: { _ in
            recoveries += 1
            return .allow
        })
        let (_, page) = try await readyDialer()
        page.web.load(URLRequest(url: URL(string: "about:blank")!))
        try await until { !page.web.isLoading && page.web.url?.absoluteString == "about:blank" }
        let rejected = try await pageScript("""
        for (var op of ['microphone.request', 'microphone.recover']) {
          try {
            await window.webkit.messageHandlers.dialer.postMessage({ op: op });
            return false;
          } catch (error) {}
        }
        return true;
        """, in: page.web) as? Bool
        XCTAssertEqual(rejected, true)
        XCTAssertEqual(requests, 0, "Only the bundled dialer document can request OS microphone permission")
        XCTAssertEqual(recoveries, 0)
    }

    func testBundledFileBootsThroughItsNativeBridge() async throws {
        Shared.prefs.dialerOn = true
        let browser = browser()
        XCTAssertTrue(browser.showDialer())
        let page = try XCTUnwrap(browser.dialerPage)
        mount(page.web)
        try await until { page.ready && page.status.text == "Not configured" }
        XCTAssertTrue(page.visible)
        XCTAssertEqual(page.web.url?.standardizedFileURL, Dialer.page?.standardizedFileURL)
        let state = try await page.web.evaluateJavaScript("window.__searchDialer.state()") as? [String: Any]
        XCTAssertEqual(state?["status"] as? String, "Not configured")
        browser.closeSidePanel()
        XCTAssertFalse(page.visible)
    }

    func testShippedSIPSessionDescriptionUsesMockMediaWithoutNetwork() async throws {
        Shared.prefs.dialerOn = true
        let browser = browser()
        XCTAssertTrue(browser.showDialer())
        let page = try XCTUnwrap(browser.dialerPage)
        guard page.web.configuration.preferences.responds(to: NSSelectorFromString("_setMockCaptureDevicesEnabled:")) else {
            throw XCTSkip("WebKit mock capture devices are unavailable")
        }
        mount(page.web)
        try await until { page.ready && page.status.text == "Not configured" }
        var result: Result<Any, Error>?
        page.web.callAsyncJavaScript("""
        var phases = [], handler = null;
        var logger = { debug: function () {}, log: function () {}, warn: function () {},
                       error: function () { phases.push('sdh-error'); } };
        var session = { userAgent: { getLogger: function () { return logger; } } };
        try {
          phases.push('factory-enter');
          var factory = SIP.Web.defaultSessionDescriptionHandlerFactory(async function (constraints) {
            phases.push('mock-media-requested');
            var stream = await navigator.mediaDevices.getUserMedia(constraints);
            phases.push('mock-media-acquired');
            return stream;
          });
          handler = factory(session, { iceGatheringTimeout: 250,
                                      peerConnectionConfiguration: { iceServers: [] } });
          phases.push('factory-returned');
          var outcome = await Promise.race([
            handler.getDescription({ constraints: { audio: true, video: false } }).then(function (description) {
              phases.push('description-ready');
              return { ok: true, audio: /^m=audio /m.test(description.body), contentType: description.contentType };
            }, function (error) { return { ok: false, error: String(error && error.message || error) }; }),
            new Promise(function (resolve) { setTimeout(function () { resolve({ ok: false, timeout: true }); }, 3000); })
          ]);
          outcome.phases = phases;
          return outcome;
        } finally {
          if (handler) handler.close();
        }
        """, arguments: [:], in: nil, in: .page) { result = $0 }
        try await until { result != nil }
        let observed = try XCTUnwrap(try XCTUnwrap(result).get() as? [String: Any])
        XCTAssertEqual(observed["ok"] as? Bool, true, String(describing: observed))
        XCTAssertEqual(observed["audio"] as? Bool, true)
        XCTAssertEqual(observed["contentType"] as? String, "application/sdp")
        XCTAssertEqual(observed["phases"] as? [String],
                       ["factory-enter", "factory-returned", "mock-media-requested", "mock-media-acquired", "description-ready"])
    }

    func testOwnedPhoneNumbersMenuKeepsNumeroAndTelicallSeparate() async throws {
        let prefs = Shared.prefs
        let dialer = Dialer.shared
        let before = (prefs.dialerNumeroUS, prefs.dialerNumeroCA, prefs.dialerTelicallUK)
        let oldSelection = dialer.pageValue("numeroLine")
        let oldProvider = dialer.pageValue("provider")
        defer {
            prefs.dialerNumeroUS = before.0
            prefs.dialerNumeroCA = before.1
            prefs.dialerTelicallUK = before.2
            if let oldSelection { dialer.set(["numeroLine": oldSelection]) }
            else { dialer.remove(["numeroLine"]) }
            if let oldProvider { dialer.set(["provider": oldProvider]) }
            else { dialer.remove(["provider"]) }
        }
        prefs.dialerNumeroUS = "(202) 555-0123"
        prefs.dialerNumeroCA = "+1 (877) 555-0123"
        prefs.dialerTelicallUK = "+44 20 7946 0958"
        prefs.dialerOn = true
        let browser = browser()
        XCTAssertTrue(browser.showDialer())
        let page = try XCTUnwrap(browser.dialerPage)
        mount(page.web, width: 360, height: 640)
        try await until { page.ready && page.status.text == "Not configured" }
        let menu = try await pageScript("""
        window.__numeroIntegrationInstance = 'same-page';
        document.getElementById('provider').click();
        await new Promise(resolve => setTimeout(resolve, 220));
        var menu = document.getElementById('providerMenu'), rect = menu.getBoundingClientRect();
        return { hidden: menu.hidden, left: rect.left, right: rect.right, viewport: innerWidth,
                 us: document.getElementById('numeroUS').textContent,
                 ca: document.getElementById('numeroCA').textContent,
                 uk: document.getElementById('telicallUK').textContent };
        """, in: page.web) as? [String: Any]
        XCTAssertEqual(menu?["hidden"] as? Bool, false)
        XCTAssertEqual(menu?["us"] as? String, "Numero US · +12025550123")
        XCTAssertEqual(menu?["ca"] as? String, "Numero Canada · +18775550123")
        XCTAssertEqual(menu?["uk"] as? String, "Telicall UK · +442079460958")
        let left = try XCTUnwrap(menu?["left"] as? Double)
        let right = try XCTUnwrap(menu?["right"] as? Double)
        let viewport = try XCTUnwrap(menu?["viewport"] as? Double)
        XCTAssertLessThanOrEqual(viewport, 360)
        XCTAssertGreaterThanOrEqual(left, -1)
        XCTAssertLessThanOrEqual(right, viewport + 1, "The Number menu fits a narrow side panel")
        _ = try await pageScript("document.getElementById('numeroCA').click(); return true;", in: page.web)
        try await until { dialer.pageValue("numeroLine") as? String == "ca" }
        let selected = try await page.web.evaluateJavaScript("document.getElementById('providerLbl').textContent") as? String
        XCTAssertEqual(selected, "Canada")

        prefs.dialerNumeroUS = "+14155550123"
        prefs.dialerNumeroCA = "+16045550123"
        try await until {
            (try? await page.web.evaluateJavaScript("document.getElementById('provider').title")) as? String == "Numero Canada · +16045550123"
        }
        let updated = try await pageScript("""
        return { instance: window.__numeroIntegrationInstance, status: window.__searchDialer.state().status,
                 us: document.getElementById('numeroUS').textContent,
                 ca: document.getElementById('numeroCA').textContent };
        """, in: page.web) as? [String: Any]
        XCTAssertEqual(updated?["instance"] as? String, "same-page", "Owned-line edits do not reload the dialer")
        XCTAssertEqual(updated?["status"] as? String, "Not configured")
        XCTAssertEqual(updated?["us"] as? String, "Numero US · +14155550123")
        XCTAssertEqual(updated?["ca"] as? String, "Numero Canada · +16045550123")
        XCTAssertTrue(page.ready)
        XCTAssertTrue(browser.dialerPage === page)
        _ = try await pageScript("document.getElementById('provider').click(); document.getElementById('telicallUK').click(); return true;", in: page.web)
        try await until { dialer.pageValue("provider") as? String == "telicall" }
        let ukSelected = try await page.web.evaluateJavaScript("document.getElementById('providerLbl').textContent") as? String
        XCTAssertEqual(ukSelected, "UK")
        prefs.dialerTelicallUK = "+447700900123"
        try await until {
            (try? await page.web.evaluateJavaScript("document.getElementById('provider').title")) as? String == "Telicall UK · +447700900123"
        }
        XCTAssertTrue(page.ready)
    }

    func testReleaseDrainsFinalCallRecordAndHistoryBeforeClosingWebKit() async throws {
        let dialer = Dialer.shared
        let oldHistory = dialer.pageValue("history") ?? []
        let oldOutbox = dialer.outbox
        defer { dialer.set(["history": oldHistory, "callOutbox": oldOutbox]) }
        Shared.prefs.dialerOn = true
        let browser = browser()
        XCTAssertTrue(browser.showDialer())
        let page = try XCTUnwrap(browser.dialerPage)
        mount(page.web)
        try await until { page.ready && page.status.text == "Not configured" }
        let id = "release-fixture-\(UUID().uuidString)"
        let record: [String: Any] = [
            "id": id, "number": "+12025550123", "name": "Offline fixture", "direction": "out",
            "startedAt": 1000, "answeredAt": 2000, "endedAt": 3000, "durationSec": 1, "outcome": "answered",
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
        _ = try await page.web.evaluateJavaScript("""
        window.__searchDialer.shutdown = function () {
          var relay = window.webkit.messageHandlers.dialer;
          relay.postMessage({ op: 'message', msg: { type: 'call-ended', record: \(json) } });
          relay.postMessage({ op: 'set', values: { history: [\(json)] } });
          return true;
        };
        void 0;
        """)
        browser.dropDialer()
        XCTAssertTrue(page.released)
        XCTAssertFalse(page.visible)
        try await until {
            dialer.outbox.contains { $0["id"] as? String == id }
                && (dialer.pageValue("history") as? [[String: Any]])?.first?["id"] as? String == id
        }
        try await until { page.web.navigationDelegate == nil }
    }

    func testExistingDocumentGainsAndRevokesBridgeWithoutRebuilding() async throws {
        let address = try await localPage()
        let prefs = Shared.prefs
        let tab = Tab()
        tabs.append(tab)
        let web = tab.web
        mount(web)
        tab.go(to: address)
        try await until { !web.isLoading && web.url?.host() == "127.0.0.1" }
        let active = "!!(window.__searchDialerSite && window.__searchDialerSite.calls)"
        let initially = try await scriptValue(active, in: web) as? Bool
        XCTAssertEqual(initially, false)

        prefs.dialerSites = [address.absoluteString]
        prefs.dialerOn = true
        try await until { (try? await self.scriptValue(active, in: web)) as? Bool == true }
        prefs.dialerSites = []
        try await until { (try? await self.scriptValue(active, in: web)) as? Bool == false }
        prefs.dialerSites = [address.absoluteString]
        try await until { (try? await self.scriptValue(active, in: web)) as? Bool == true }
        prefs.dialerOn = false
        try await until { (try? await self.scriptValue(active, in: web)) as? Bool == false }
        XCTAssertTrue(tab.built === web, "Grant changes preserve the existing page")
        XCTAssertEqual(web.configuration.userContentController.userScripts.filter {
            $0.source.contains(DialerSiteRelay.scriptMarker)
        }.count, 1, "Refreshing must replace the bridge instead of adding listeners/scripts")
    }

    func testRetiringWindowReleasesItsDialerAndHandlerCycle() async throws {
        Shared.prefs.dialerOn = true
        let browser = browser()
        XCTAssertTrue(browser.showDialer())
        weak var page = browser.dialerPage
        XCTAssertNotNil(page)
        Browsers.discard(browser)
        browsers.removeAll { $0 === browser }
        XCTAssertNil(browser.dialerPage)
        try await until { page == nil }
        Shared.prefs.dialerOn = false
    }

    func testClosingLastWindowAlsoReleasesItsDialer() async throws {
        Shared.prefs.dialerOn = true
        let browser = browser()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        browser.window = window
        XCTAssertTrue(browser.showDialer())
        weak var page = browser.dialerPage
        Browsers.closing(window)
        XCTAssertNil(browser.dialerPage)
        XCTAssertFalse(browser.dialerShown)
        try await until { page == nil }
    }

    func testPersistentProxyGatePreventsCreatingADirectDialer() {
        let prefs = Shared.prefs
        prefs.dialerOn = true
        prefs.proxyHost = "127.0.0.1"
        prefs.proxyPort = "9"
        prefs.proxyBlocks = true
        prefs.proxyOn = true
        XCTAssertTrue(Proxy.shared.waiting)
        let browser = browser()
        XCTAssertFalse(browser.showDialer())
        XCTAssertFalse(browser.call("02079460958"))
        XCTAssertNil(browser.dialerPage)
        XCTAssertNotNil(Dialer.shared.blockedReason)
    }

    func testOptionalProxyAndWebsiteExceptionsCannotMakeDialerFallBackDirectly() async throws {
        let prefs = Shared.prefs
        prefs.proxyHost = "127.0.0.1"
        prefs.proxyPort = "9"
        prefs.proxyBlocks = false
        prefs.proxyBypass = ["phone.example.invalid"]
        prefs.proxyOn = true
        prefs.dialerOn = true
        XCTAssertNil(Dialer.shared.blockedReason)
        let browser = browser()
        XCTAssertTrue(browser.showDialer())
        let page = try XCTUnwrap(browser.dialerPage)
        let routes = page.web.configuration.websiteDataStore.proxyConfigurations
        XCTAssertEqual(routes.count, 1)
        XCTAssertFalse(try XCTUnwrap(routes.first).allowFailover)
        XCTAssertEqual(try XCTUnwrap(routes.first).excludedDomains, [])
        mount(page.web)
        try await until { page.ready && page.status.text == "Not configured" }
    }

    func testEvenAnOptionalProxyTransitionImmediatelyRetiresTheDirectPage() async throws {
        let (browser, page) = try await readyDialer()
        Shared.prefs.proxyHost = "127.0.0.1"
        Shared.prefs.proxyPort = "9"
        Shared.prefs.proxyBlocks = false
        Shared.prefs.proxyOn = true
        XCTAssertNil(Dialer.shared.blockedReason)
        XCTAssertTrue(page.released)
        XCTAssertNil(page.web.navigationDelegate)
        XCTAssertNil(browser.dialerPage)
    }

    func testPhoneServerEditReplacesTheOldWebViewAndItsCredentialBridge() async throws {
        let (_, page) = try await readyDialer()
        let previous = page.web
        Shared.prefs.dialerUser = "a-different-test-seat"
        XCTAssertFalse(page.web === previous)
        XCTAssertNil(previous.navigationDelegate)
        XCTAssertNil(previous.uiDelegate)
        XCTAssertEqual(previous.microphoneCaptureState, .none)
        try await until { page.ready && page.status.text == "Not configured" }
    }

    func testEnablingProxyProtectionReleasesAnExistingDialer() async throws {
        let prefs = Shared.prefs
        prefs.dialerOn = true
        let browser = browser()
        XCTAssertTrue(browser.showDialer())
        let page = try XCTUnwrap(browser.dialerPage)
        prefs.proxyHost = "127.0.0.1"
        prefs.proxyPort = "9"
        prefs.proxyBlocks = true
        prefs.proxyOn = true
        XCTAssertNil(page.web.navigationDelegate, "A protected route closes WebKit without waiting for JavaScript")
        try await until { browser.dialerPage == nil }
        XCTAssertTrue(page.released)
        XCTAssertFalse(page.visible)
        XCTAssertFalse(browser.dialerShown)
    }

    func testReplacingOrClosingPanelMakesDialerHidden() async throws {
        let address = try await localPage()
        let prefs = Shared.prefs
        prefs.dialerOn = true
        prefs.sitesInPanel = true
        let browser = browser()
        XCTAssertTrue(browser.showDialer())
        let page = try XCTUnwrap(browser.dialerPage)
        XCTAssertTrue(page.visible)
        XCTAssertTrue(browser.showSiteInPanel(address))
        XCTAssertFalse(page.visible, "A replacement panel ends any queued or active call")
        XCTAssertFalse(browser.dialerShown)
        XCTAssertTrue(browser.showDialer())
        XCTAssertTrue(page.visible)
        browser.closeSidePanel()
        XCTAssertFalse(page.visible)
    }

    func testNativeBridgeExportsNoPasswordAndRequiresExactNonPrivateOrigin() async throws {
        let address = try await localPage()
        let prefs = Shared.prefs
        prefs.dialerSites = [address.absoluteString]
        prefs.dialerWSS = "wss://dialer-fixture.example.invalid"
        prefs.dialerDomain = "dialer-fixture.example.invalid"
        prefs.dialerUser = "integration-1001"
        prefs.dialerOn = true
        let setup = prefs.dialerSetup
        XCTAssertTrue(DialerPassword.save("synthetic-integration-secret", for: setup))
        defer { DialerPassword.forget(setup) }

        let ordinary = Tab()
        tabs.append(ordinary)
        mount(ordinary.web)
        ordinary.go(to: address)
        try await until { ordinary.web.title == "Dialer fixture" }
        let allowed = try await configReply(ordinary.web)
        XCTAssertEqual(allowed["ok"] as? Bool, true)
        let config = try XCTUnwrap(allowed["config"] as? [String: Any])
        XCTAssertNil(config["password"])
        XCTAssertEqual(config["passwordSaved"] as? Bool, true)
        XCTAssertFalse(String(describing: allowed).contains("synthetic-integration-secret"))

        let otherServer = try DialerBridgeFixture()
        defer { otherServer.stop() }
        let otherAddress = try await otherServer.address()
        ordinary.go(to: otherAddress)
        try await until { !ordinary.web.isLoading && ordinary.web.url?.port == otherAddress.port }
        let unlisted = try await configReply(ordinary.web)
        XCTAssertEqual(unlisted["ok"] as? Bool, false, "A different local port has no grant")
        XCTAssertNil(unlisted["config"])

        let shy = Tab(shy: true)
        tabs.append(shy)
        mount(shy.web)
        shy.go(to: address)
        try await until { shy.web.title == "Dialer fixture" }
        let privateReply = try await configReply(shy.web)
        XCTAssertEqual(privateReply["ok"] as? Bool, false, "Private pages cannot read the shared line")
        XCTAssertNil(privateReply["config"])
    }

    func testEnteringTorContextReleasesAnExistingDirectDialer() async throws {
        Shared.prefs.dialerOn = true
        let browser = browser()
        XCTAssertTrue(browser.showDialer())
        let page = try XCTUnwrap(browser.dialerPage)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Onion.shared.store(for: .nonPersistent())
        var tor: Tab? = Tab(configuration: configuration)
        defer { tor?.close(); tor = nil; Onion.shared.enteredTab() }
        XCTAssertTrue(Onion.shared.hasTabs)
        Onion.shared.enteredTab()
        XCTAssertNil(page.web.navigationDelegate, "Tor protection closes the direct client immediately")
        try await until { browser.dialerPage == nil }
        XCTAssertTrue(page.released)
        XCTAssertFalse(browser.showDialer())
    }

    private func configReply(_ web: WKWebView) async throws -> [String: Any] {
        let value: Any = try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript("return await window.webkit.messageHandlers.officeDialerSite.postMessage({type:'getConfig'});",
                                    arguments: [:], in: nil, in: Web.world) { (result: Result<Any, Error>) in
                continuation.resume(with: result)
            }
        }
        return try XCTUnwrap(value as? [String: Any])
    }

    private func scriptValue(_ script: String, in web: WKWebView) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(script, in: nil, in: Web.world) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func pageScript(_ script: String, in web: WKWebView) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                continuation.resume(with: result)
            }
        }
    }
}

private final class DialerBridgeFixture {
    private let listener: NWListener

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { _, _, _, _ in
                let body = "<!doctype html><title>Dialer fixture</title><p>Offline bridge fixture</p>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
    }

    func address() async throws -> URL {
        for _ in 0..<100 {
            if let port = listener.port, port.rawValue != 0 {
                return URL(string: "http://127.0.0.1:\(port.rawValue)/")!
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw URLError(.timedOut)
    }

    func stop() { listener.cancel() }
}

