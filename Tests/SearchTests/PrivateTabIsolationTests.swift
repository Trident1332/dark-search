import AppKit
import Foundation
import Network
import WebKit
import XCTest
@testable import Search

/// Real pages on a disposable loopback origin: no website accounts or user
/// browser data are used to check the boundary between private tabs.
@MainActor
final class PrivateTabIsolationTests: XCTestCase {
    private var browser: Browser!
    private var server: PrivateSessionHTTPServer!
    private var origin: URL!
    private var activationPolicy: NSApplication.ActivationPolicy?

    override class func setUp() {
        setenv("SEARCH_PROBE", "private-tab-isolation-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        _ = Shared.prefs
        Proxy.shared.automaticTarget = nil
        Proxy.shared.take(ProxySetup())
        for _ in 0..<100 where Proxy.shared.changingContent { try await Task.sleep(for: .milliseconds(20)) }
        browser = Browser(record: WindowRecord())
        browser.closeAll()
        server = try PrivateSessionHTTPServer()
        let port = try await server.start()
        origin = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
        try await super.setUp()
    }

    override func tearDown() async throws {
        browser?.closeAll()
        browser = nil
        server?.stop()
        server = nil
        origin = nil
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        try await super.tearDown()
    }

    func testNewPrivateTabAndReopenedTabHaveIndependentWebsiteData() async throws {
        browser.newShyTab()
        let first = try XCTUnwrap(browser.active)
        first.go(to: address("/first"))
        try await loaded(first, path: "/first")
        try await write("first conversation", in: first)

        browser.newShyTab()
        let second = try XCTUnwrap(browser.active)
        XCTAssertTrue(first.shy && second.shy)
        XCTAssertFalse(first.store.isPersistent || second.store.isPersistent)
        XCTAssertFalse(first.store === second.store)
        second.go(to: address("/second"))
        try await loaded(second, path: "/second")
        try await assertSession(nil, in: second)
        try await write("second conversation", in: second)
        try await assertSession("first conversation", in: first)
        try await assertSession("second conversation", in: second)

        browser.close(first)
        browser.openShy(address("/reopened"))
        let reopened = try XCTUnwrap(browser.active)
        XCTAssertFalse(reopened.store === first.store)
        XCTAssertFalse(reopened.store === second.store)
        try await loaded(reopened, path: "/reopened")
        try await assertSession(nil, in: reopened)
        try await assertSession("second conversation", in: second)
    }

    func testPrivateLinkAndDuplicateStartFreshWithoutChangingTheirSource() async throws {
        let source = try await privatePage("/source")
        try await write("source conversation", in: source)

        let linked = browser.open(address("/linked"), foreground: false, from: source)
        XCTAssertTrue(linked.shy)
        XCTAssertFalse(linked.store === source.store)
        try await loaded(linked, path: "/linked")
        try await assertSession(nil, in: linked)
        try await write("linked conversation", in: linked)

        browser.activeID = source.id
        browser.duplicate()
        let duplicate = try XCTUnwrap(browser.active)
        XCTAssertTrue(duplicate.shy)
        XCTAssertFalse(duplicate.store === source.store)
        XCTAssertFalse(duplicate.store === linked.store)
        try await loaded(duplicate, path: "/source")
        try await assertSession(nil, in: duplicate)
        try await assertSession("source conversation", in: source)
        try await assertSession("linked conversation", in: linked)
    }

    func testPrivateSplitStartsFreshAndSameTabReloadAndNavigationKeepItsSession() async throws {
        let source = try await privatePage("/source")
        try await write("source conversation", in: source)
        let oldSplit = browser.prefs.splitView
        browser.prefs.splitView = true
        defer { browser.prefs.splitView = oldSplit }
        browser.startSplit()
        let split = try XCTUnwrap(browser.active)
        XCTAssertNotEqual(split.id, source.id)
        XCTAssertTrue(split.shy)
        XCTAssertFalse(split.store === source.store)
        split.go(to: address("/split"))
        try await loaded(split, path: "/split")
        try await assertSession(nil, in: split)

        let keptStore = source.store
        _ = try await source.web.evaluateJavaScript("document.title = 'Waiting for reload'")
        source.reload()
        try await loaded(source, path: "/source")
        XCTAssertTrue(source.store === keptStore)
        try await assertSession("source conversation", in: source)
        source.go(to: address("/continued"))
        try await loaded(source, path: "/continued")
        XCTAssertTrue(source.store === keptStore)
        try await assertSession("source conversation", in: source)
    }

    func testPrivateReplacementKeepsTheSameTabsSession() async throws {
        let source = try await privatePage("/source")
        try await write("source conversation", in: source)
        let keptStore = source.store
        browser.replace(source, going: address("/replacement"))
        let replacement = try XCTUnwrap(browser.active)
        XCTAssertTrue(replacement.shy)
        XCTAssertTrue(replacement.store === keptStore)
        try await loaded(replacement, path: "/replacement")
        try await assertSession("source conversation", in: replacement, sessionStorage: nil)
    }

    func testPrivateScriptWindowsAndTargetBlankLinksCannotReadTheOpenersSession() async throws {
        let source = try await privatePage("/source")
        try await write("source conversation", in: source)
        source.popupSites.insert("127.0.0.1")
        let oldPopupWindows = browser.prefs.popupWindows
        browser.prefs.popupWindows = false
        defer { browser.prefs.popupWindows = oldPopupWindows }

        let scripts: [(String, String)] = [
            ("/popup", "window.open('/popup', '_blank'); true"),
            ("/sized", "window.open('/sized', '_blank', 'width=420,height=380'); true"),
            ("/target", "const link = document.createElement('a'); link.href = '/target'; link.target = '_blank'; document.body.append(link); link.click(); true")
        ]
        for (path, script) in scripts {
            let previous = Set(browser.tabs.map(\.id))
            _ = try await source.web.evaluateJavaScript(script)
            try await until { self.browser.tabs.contains { !previous.contains($0.id) } }
            let child = try XCTUnwrap(browser.tabs.first { !previous.contains($0.id) })
            XCTAssertTrue(child.shy, path)
            XCTAssertFalse(child.store === source.store, path)
            try await loaded(child, path: path)
            let detached = try await child.web.evaluateJavaScript("window.opener === null") as? Bool
            XCTAssertEqual(detached, true, "A private child must not obtain the opener's storage through its window")
            try await assertSession(nil, in: child)
            try await write("child conversation", in: child)
            try await assertSession("source conversation", in: source)
            browser.close(child)
        }
    }

    func testPrivateTargetBlankFormKeepsItsPostBodyAndStartsWithoutCookies() async throws {
        let source = try await privatePage("/source")
        try await write("source conversation", in: source)
        source.popupSites.insert("127.0.0.1")
        let previous = Set(browser.tabs.map(\.id))
        _ = try await source.web.evaluateJavaScript("""
        const form = document.createElement('form');
        form.action = '/posted'; form.method = 'POST'; form.target = '_blank';
        const field = document.createElement('input');
        field.name = 'conversation'; field.value = 'fresh chat';
        form.append(field); document.body.append(form); form.submit(); true;
        """)
        try await until { self.browser.tabs.contains { !previous.contains($0.id) } }
        let child = try XCTUnwrap(browser.tabs.first { !previous.contains($0.id) })
        try await loaded(child, path: "/posted")
        let request = try XCTUnwrap(server.requests.last { $0.path == "/posted" })
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.body, Data("conversation=fresh+chat".utf8))
        XCTAssertNil(request.headers["cookie"], "The opener's cookies must not accompany its private child")
        try await assertSession(nil, in: child)
        try await assertSession("source conversation", in: source)
    }

    func testTransferredPrivatePostStripsInheritedCredentialsAndKeepsItsBody() async throws {
        browser.newShyTab()
        let child = try XCTUnwrap(browser.active)
        var request = URLRequest(url: address("/transferred"))
        request.httpMethod = "POST"
        request.httpBody = Data("conversation=fresh%20chat".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("kept", forHTTPHeaderField: "X-Private-Fixture")
        for name in ["Cookie", "Cookie2", "Authorization", "Proxy-Authorization", "Referer"] {
            request.setValue("fixture-inherited-value", forHTTPHeaderField: name)
        }
        child.openPrivatePopup(request)
        try await loaded(child, path: "/transferred")
        let received = try XCTUnwrap(server.requests.last { $0.path == "/transferred" })
        XCTAssertEqual(received.method, "POST")
        XCTAssertEqual(received.body, request.httpBody)
        XCTAssertEqual(received.headers["content-type"], "application/x-www-form-urlencoded")
        XCTAssertEqual(received.headers["x-private-fixture"], "kept")
        for name in ["cookie", "cookie2", "authorization", "proxy-authorization", "referer"] {
            XCTAssertNil(received.headers[name], name)
        }
    }

    private func address(_ path: String) -> URL { origin.appendingPathComponent(String(path.dropFirst())) }

    private func privatePage(_ path: String) async throws -> Tab {
        browser.openShy(address(path))
        let tab = try XCTUnwrap(browser.active)
        try await loaded(tab, path: path)
        return tab
    }

    private func until(_ predicate: @escaping @MainActor () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw URLError(.timedOut)
    }

    private func loaded(_ tab: Tab, path: String) async throws {
        try await until {
            guard !tab.web.isLoading, tab.web.url?.path == path else { return false }
            return (try? await tab.web.evaluateJavaScript("document.title") as? String) == "Private fixture \(path)"
        }
    }

    private func write(_ value: String, in tab: Tab) async throws {
        _ = try await tab.web.callAsyncJavaScript(#"""
        document.cookie = 'privateSession=' + encodeURIComponent(value) + '; Path=/; SameSite=Lax';
        localStorage.setItem('conversation', value);
        sessionStorage.setItem('conversation', value);
        const db = await new Promise((resolve, reject) => {
            const request = indexedDB.open('private-conversation', 1);
            request.onupgradeneeded = () => request.result.createObjectStore('values');
            request.onsuccess = () => resolve(request.result);
            request.onerror = () => reject(request.error);
        });
        try {
            await new Promise((resolve, reject) => {
                const transaction = db.transaction('values', 'readwrite');
                transaction.oncomplete = resolve;
                transaction.onerror = () => reject(transaction.error);
                transaction.onabort = () => reject(transaction.error);
                transaction.objectStore('values').put(value, 'conversation');
            });
        } finally { db.close(); }
        return true;
        """#, arguments: ["value": value], in: nil, contentWorld: .page)
    }

    private func assertSession(_ expected: String?, in tab: Tab, sessionStorage expectedSession: String? = "same",
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await tab.web.callAsyncJavaScript(#"""
        const db = await new Promise((resolve, reject) => {
            const request = indexedDB.open('private-conversation', 1);
            request.onupgradeneeded = () => request.result.createObjectStore('values');
            request.onsuccess = () => resolve(request.result);
            request.onerror = () => reject(request.error);
        });
        let indexed;
        try {
            indexed = await new Promise((resolve, reject) => {
                const request = db.transaction('values').objectStore('values').get('conversation');
                request.onsuccess = () => resolve(request.result ?? null);
                request.onerror = () => reject(request.error);
            });
        } finally { db.close(); }
        return {cookie: document.cookie.split('; ').find(part => part.startsWith('privateSession='))?.slice('privateSession='.length) ?? null,
            local: localStorage.getItem('conversation'), session: sessionStorage.getItem('conversation'), indexed};
        """#, arguments: [:], in: nil, contentWorld: .page)
        let data = try XCTUnwrap(result as? [String: Any], file: file, line: line)
        let cookie = (data["cookie"] as? String)?.removingPercentEncoding
        XCTAssertEqual(cookie, expected, "Cookies must belong to this tab", file: file, line: line)
        XCTAssertEqual(data["local"] as? String, expected, "Local storage must belong to this tab", file: file, line: line)
        XCTAssertEqual(data["session"] as? String, expectedSession == "same" ? expected : expectedSession,
                       "Session storage must belong to this tab", file: file, line: line)
        XCTAssertEqual(data["indexed"] as? String, expected, "IndexedDB must belong to this tab", file: file, line: line)
    }
}

private final class PrivateSessionHTTPServer: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }
    private var received: [Request] = []
    var requests: [Request] { lock.withLock { received } }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "PrivateTabIsolationTests.http")
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
                    if self.takeStart() {
                        if let port = self.listener.port?.rawValue { continuation.resume(returning: port) }
                        else { continuation.resume(throwing: URLError(.cannotConnectToHost)) }
                    }
                case .failed(let error):
                    if self.takeStart() { continuation.resume(throwing: error) }
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

    private func takeStart() -> Bool {
        lock.withLock { let first = starting; starting = false; return first }
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
            let lines = header.components(separatedBy: "\r\n")
            let first = (lines.first ?? "").split(separator: " ")
            let method = first.first.map(String.init) ?? "GET"
            let path = first.dropFirst().first.map(String.init) ?? "/"
            let headers = Dictionary(lines.dropFirst().compactMap { line -> (String, String)? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return (String(line[..<colon]).lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }, uniquingKeysWith: { _, last in last })
            let length = Int(headers["content-length"] ?? "0") ?? 0
            guard buffer.count >= end.upperBound + length else {
                if error == nil, !complete, buffer.count < 65_536 { self.read(connection, buffer: buffer) }
                else { connection.cancel() }
                return
            }
            let requestBody = Data(buffer[end.upperBound..<(end.upperBound + length)])
            self.lock.withLock { self.received.append(Request(method: method, path: path, headers: headers, body: requestBody)) }
            let body = "<!doctype html><html><head><title>Private fixture \(path)</title></head><body>Private session fixture</body></html>"
            let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)".utf8)
            connection.send(content: response, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
