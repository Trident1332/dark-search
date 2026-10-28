import AppKit
import Foundation
import Network
import WebKit
import XCTest
@testable import Search

/// Real WebKit contexts with disposable stores and local HTML. No browser
/// windows, user cookies, proxy accounts, or external requests are involved.
@MainActor
final class ProxyTimeZoneTests: XCTestCase {
    private var views: [WKWebView] = []
    private var activationPolicy: NSApplication.ActivationPolicy?

    override func setUp() async throws {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        try await super.setUp()
    }

    override func tearDown() async throws {
        let pools = views.map { $0.configuration.processPool }
        for view in views { ProxyTimeZone.close(view) }
        _ = await ProxyTimeZone.restartWorkers(in: pools)
        views.removeAll()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        try await super.tearDown()
    }

    func testIdentifiersAcceptKnownZonesAndUTCOnly() {
        XCTAssertEqual(ProxyTimeZone.identifier(" Europe/Berlin\n"), "Europe/Berlin")
        XCTAssertEqual(ProxyTimeZone.identifier("America/New_York"), "America/New_York")
        XCTAssertEqual(ProxyTimeZone.identifier("UTC"), "UTC")
        for value in [nil, "", "  ", "Mars/Olympus", "Europe/Not_A_Zone", "GMT+04:00", "UTC;alert(1)"] as [String?] {
            XCTAssertNil(ProxyTimeZone.identifier(value))
        }
        XCTAssertNil(ProxyTimeZone.pool(for: "not-a-time-zone"))
    }

    func testPageFrameAndWorkerAgreeAndKeepCorrectUTC() async throws {
        try XCTSkipUnless(ProxyTimeZone.isSupported, "Native time-zone capabilities unavailable")
        let view = try await page("Europe/Berlin")
        let result = try await observe(view)
        for name in ["main", "frame", "worker"] {
            let context = try XCTUnwrap(result[name] as? [String: Any])
            XCTAssertEqual(context["zone"] as? String, "Europe/Berlin", name)
            XCTAssertEqual((context["winterOffset"] as? NSNumber)?.intValue, -60, name)
            XCTAssertEqual((context["summerOffset"] as? NSNumber)?.intValue, -120, name)
            XCTAssertEqual(context["iso"] as? String, "2026-01-15T12:00:00.000Z", name)
        }
        let native = try XCTUnwrap(result["nativeNow"] as? NSNumber).doubleValue
        for name in ["main", "worker"] {
            let context = try XCTUnwrap(result[name] as? [String: Any])
            let now = try XCTUnwrap(context["now"] as? NSNumber).doubleValue
            XCTAssertLessThan(abs(now - native), 5_000, "UTC time is real, not a fake local clock")
        }
    }

    func testSeparatePoolsCanUseDifferentZonesOnTheSameStore() async throws {
        try XCTSkipUnless(ProxyTimeZone.isSupported, "Native time-zone capabilities unavailable")
        let store = WKWebsiteDataStore.nonPersistent()
        let berlin = try await page("Europe/Berlin", store: store)
        let tokyo = try await page("Asia/Tokyo", store: store)
        for (view, zone, offset) in [(berlin, "Europe/Berlin", -60), (tokyo, "Asia/Tokyo", -540)] {
            let result = try await observe(view)
            for name in ["main", "frame", "worker"] {
                let context = try XCTUnwrap(result[name] as? [String: Any])
                XCTAssertEqual(context["zone"] as? String, zone)
                XCTAssertEqual((context["winterOffset"] as? NSNumber)?.intValue, offset)
            }
        }
        let first = try XCTUnwrap(ProxyTimeZone.pool(for: "Europe/Berlin"))
        XCTAssertTrue(first === ProxyTimeZone.pool(for: "Europe/Berlin"), "The same native pool is reused for a zone")
    }

    func testClosedPoolCanRestartWorkersWithoutRemovingItsStore() async throws {
        try XCTSkipUnless(ProxyTimeZone.isSupported, "Native time-zone capabilities unavailable")
        let store = WKWebsiteDataStore.nonPersistent()
        let old = try await page("America/New_York", store: store)
        let pool = try XCTUnwrap(ProxyTimeZone.pool(for: "America/New_York"))
        ProxyTimeZone.close(old)
        let stopped = await ProxyTimeZone.restartWorkers(in: [pool, pool])
        XCTAssertTrue(stopped)
        let fresh = try await page("Asia/Tokyo", store: store)
        let result = try await observe(fresh)
        let main = try XCTUnwrap(result["main"] as? [String: Any])
        XCTAssertEqual(main["zone"] as? String, "Asia/Tokyo")
    }

    func testRegisteredServiceWorkerAdoptsNewZoneAndRetainsCookieAndRegistration() async throws {
        try XCTSkipUnless(ProxyTimeZone.isSupported, "Native time-zone capabilities unavailable")
        let server = try TimeZoneHTTPServer()
        let port = try await server.start()
        defer { server.stop() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/client"))
        let store = WKWebsiteDataStore.nonPersistent()
        let berlin = try await page("Europe/Berlin", store: store, url: url)
        let before = try await serviceWorker(berlin, create: true)
        XCTAssertEqual(before["page"] as? String, "Europe/Berlin")
        XCTAssertEqual((before["existing"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((before["registrations"] as? NSNumber)?.intValue, 1)
        let original = try XCTUnwrap(before["worker"] as? [String: Any])
        XCTAssertEqual(original["zone"] as? String, "Europe/Berlin")
        XCTAssertEqual((original["offset"] as? NSNumber)?.intValue, -60)

        ProxyTimeZone.close(berlin)
        let pool = try XCTUnwrap(ProxyTimeZone.pool(for: "Europe/Berlin"))
        let stopped = await ProxyTimeZone.restartWorkers(in: [pool])
        XCTAssertTrue(stopped)

        let tokyo = try await page("Asia/Tokyo", store: store, url: url)
        // This call deliberately never registers a new worker or rewrites
        // the cookie: both must have survived the process replacement.
        let after = try await serviceWorker(tokyo, create: false)
        XCTAssertEqual(after["page"] as? String, "Asia/Tokyo")
        XCTAssertEqual((after["existing"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((after["registrations"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(after["script"] as? String, before["script"] as? String)
        XCTAssertTrue((after["cookie"] as? String)?.contains("tzprobe=kept") == true)
        let restarted = try XCTUnwrap(after["worker"] as? [String: Any])
        XCTAssertEqual(restarted["zone"] as? String, "Asia/Tokyo")
        XCTAssertEqual((restarted["offset"] as? NSNumber)?.intValue, -540)
        XCTAssertEqual(restarted["iso"] as? String, "2026-01-15T12:00:00.000Z")
        let now = try XCTUnwrap(restarted["now"] as? NSNumber).doubleValue
        XCTAssertLessThan(abs(now - Date().timeIntervalSince1970 * 1_000), 5_000)

        // Repeat immediately into an already cached pool. There is no test
        // delay between closing either page and asking the helper to stop.
        ProxyTimeZone.close(tokyo)
        let tokyoPool = try XCTUnwrap(ProxyTimeZone.pool(for: "Asia/Tokyo"))
        let stoppedAgain = await ProxyTimeZone.restartWorkers(in: [tokyoPool])
        XCTAssertTrue(stoppedAgain)
        let returned = try await page("Europe/Berlin", store: store, url: url)
        let again = try await serviceWorker(returned, create: false)
        XCTAssertEqual((again["existing"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((again["registrations"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(again["script"] as? String, before["script"] as? String)
        XCTAssertTrue((again["cookie"] as? String)?.contains("tzprobe=kept") == true)
        let returnedWorker = try XCTUnwrap(again["worker"] as? [String: Any])
        XCTAssertEqual(returnedWorker["zone"] as? String, "Europe/Berlin")
        XCTAssertEqual((returnedWorker["offset"] as? NSNumber)?.intValue, -60)
    }

    private func page(_ identifier: String, store: WKWebsiteDataStore? = nil, url: URL? = nil) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store ?? .nonPersistent()
        configuration.processPool = try XCTUnwrap(ProxyTimeZone.pool(for: identifier))
        let view = WKWebView(frame: .zero, configuration: configuration)
        views.append(view)
        let navigation = TimeZoneNavigation()
        view.navigationDelegate = navigation
        defer { view.navigationDelegate = nil }
        if let url { view.load(URLRequest(url: url)) }
        else { view.loadHTMLString("<!doctype html><html><body>time-zone test</body></html>", baseURL: URL(string: "https://timezone-probe.invalid/")) }
        for _ in 0..<250 {
            if navigation.finished { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard navigation.finished else { throw URLError(.timedOut) }
        if let error = navigation.error { throw error }
        return view
    }

    private func serviceWorker(_ view: WKWebView, create: Bool) async throws -> [String: Any] {
        let script = #"""
        if (!navigator.serviceWorker) throw new Error('service workers unavailable');
        let timeout;
        try {
            return await Promise.race([(async () => {
                const registrations = await navigator.serviceWorker.getRegistrations();
                if (create) {
                    document.cookie = 'tzprobe=kept;Path=/;SameSite=Lax';
                    await navigator.serviceWorker.register('/sw.js');
                } else if (registrations.length !== 1) {
                    throw new Error('existing registration was lost');
                }
                const registration = await navigator.serviceWorker.ready;
                const channel = new MessageChannel();
                const result = new Promise((resolve, reject) => {
                    channel.port1.onmessage = event => resolve(event.data);
                    channel.port1.onmessageerror = () => reject(new Error('invalid worker response'));
                });
                registration.active.postMessage('observe', [channel.port2]);
                const worker = await result;
                channel.port1.close();
                return {page: Intl.DateTimeFormat().resolvedOptions().timeZone,
                    worker, existing: registrations.length,
                    registrations: (await navigator.serviceWorker.getRegistrations()).length,
                    script: registration.active.scriptURL, cookie: document.cookie};
            })(), new Promise((_, reject) => {
                timeout = setTimeout(() => reject(new Error('service worker timed out')), 5000);
            })]);
        } finally { clearTimeout(timeout); }
        """#
        return try await evaluate(script, arguments: ["create": create], in: view)
    }

    private func observe(_ view: WKWebView) async throws -> [String: Any] {
        let script = #"""
        const inspect = () => ({zone: Intl.DateTimeFormat().resolvedOptions().timeZone,
            winterOffset: new Date('2026-01-15T12:00:00Z').getTimezoneOffset(),
            summerOffset: new Date('2026-07-15T12:00:00Z').getTimezoneOffset(),
            iso: new Date('2026-01-15T12:00:00Z').toISOString(), now: Date.now()});
        const frame = document.createElement('iframe');
        const ready = new Promise(resolve => frame.onload = resolve);
        frame.srcdoc = '<html><body>frame</body></html>';
        document.body.appendChild(frame); await ready;
        const context = frame.contentWindow;
        const frameInfo = {zone: new context.Intl.DateTimeFormat().resolvedOptions().timeZone,
            winterOffset: new context.Date('2026-01-15T12:00:00Z').getTimezoneOffset(),
            summerOffset: new context.Date('2026-07-15T12:00:00Z').getTimezoneOffset(),
            iso: new context.Date('2026-01-15T12:00:00Z').toISOString()};
        const source = 'const inspect=' + inspect.toString() + ';onmessage=()=>postMessage(inspect());';
        const url = URL.createObjectURL(new Blob([source], {type: 'text/javascript'}));
        const worker = new Worker(url);
        const workerInfo = await new Promise((resolve, reject) => {
            const timeout = setTimeout(() => reject(new Error('worker timed out')), 3000);
            worker.onmessage = event => { clearTimeout(timeout); resolve(event.data); };
            worker.onerror = event => { clearTimeout(timeout); reject(new Error(event.message)); };
            worker.postMessage(null);
        });
        worker.terminate(); URL.revokeObjectURL(url); frame.remove();
        return {main: inspect(), frame: frameInfo, worker: workerInfo, nativeNow};
        """#
        let nativeNow = Date().timeIntervalSince1970 * 1000
        return try await evaluate(script, arguments: ["nativeNow": nativeNow], in: view)
    }

    private func evaluate(_ script: String, arguments: [String: Any], in view: WKWebView) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    if let observed = value as? [String: Any] { continuation.resume(returning: observed) }
                    else { continuation.resume(throwing: CocoaError(.coderReadCorrupt)) }
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Only a loopback interface is bound. Each test owns its port, page,
/// service-worker script and ephemeral website store.
private final class TimeZoneHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ProxyTimeZoneTests.http")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var starting = true

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if self.lock.withLock({ let first = self.starting; self.starting = false; return first }) {
                        continuation.resume(returning: self.listener.port!.rawValue)
                    }
                case .failed(let error):
                    if self.lock.withLock({ let first = self.starting; self.starting = false; return first }) {
                        continuation.resume(throwing: error)
                    }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return connection.cancel() }
                self.lock.withLock { self.connections.append(connection) }
                connection.start(queue: self.queue)
                self.read(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        for connection in lock.withLock({ connections }) { connection.cancel() }
    }

    private func read(_ connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if error == nil, !complete, buffer.count < 16_384 { self.read(connection, buffer: buffer) }
                else { connection.cancel() }
                return
            }
            let header = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let path = header.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let body: String
            let type: String
            let status: String
            switch path {
            case "/sw.js":
                status = "200 OK"; type = "application/javascript"
                body = #"""
                self.addEventListener('install', event => event.waitUntil(self.skipWaiting()));
                self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
                self.addEventListener('message', event => event.ports[0].postMessage({
                    zone: Intl.DateTimeFormat().resolvedOptions().timeZone,
                    offset: new Date('2026-01-15T12:00:00Z').getTimezoneOffset(),
                    iso: new Date('2026-01-15T12:00:00Z').toISOString(), now: Date.now()}));
                """#
            case "/client":
                status = "200 OK"; type = "text/html"
                body = "<!doctype html><html><body>service-worker time-zone test</body></html>"
            default:
                status = "404 Not Found"; type = "text/plain"; body = "not found"
            }
            let response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)".utf8)
            connection.send(content: response, contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

@MainActor
private final class TimeZoneNavigation: NSObject, WKNavigationDelegate {
    var finished = false
    var error: Error?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { self.error = error; finished = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { self.error = error; finished = true }
}
