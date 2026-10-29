import Foundation
import Network
import Security
import XCTest
@testable import Search

/// All sockets terminate on this Mac. Credentials, identity, trust anchor, and
/// TURN-like payloads are synthetic; no microphone, SIP or real server is used.
@MainActor
final class DialerProxyTunnelTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "dialer-proxy-tunnel-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(Store.testing)
    }

    private func until(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 6,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        if !condition() { XCTFail("The local tunnel operation timed out", file: file, line: line); throw URLError(.timedOut) }
    }

    private func proxy(_ fixture: TunnelProxy, port: UInt16) -> ProxyConfiguration {
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        proxy.applyCredential(username: "synthetic-user", password: "synthetic-password")
        // A caller mistake must never turn protected media into a direct path.
        proxy.allowFailover = true
        proxy.excludedDomains = ["turn-proxy-test.invalid"]
        proxy.matchDomains = ["unrelated.invalid"]
        return proxy
    }

    func testSyntheticTLSCertificateHasValidHostnameAndAnchorTrust() throws {
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(try TunnelIdentity.certificate(),
            SecPolicyCreateSSL(true, "turn-proxy-test.invalid" as CFString), &trust), errSecSuccess)
        let evaluated = try XCTUnwrap(trust)
        XCTAssertEqual(SecTrustSetAnchorCertificates(evaluated, [try TunnelIdentity.certificate()] as CFArray), errSecSuccess)
        XCTAssertEqual(SecTrustSetAnchorCertificatesOnly(evaluated, true), errSecSuccess)
        SecTrustSetNetworkFetchAllowed(evaluated, false)
        var error: CFError?
        XCTAssertTrue(SecTrustEvaluateWithError(evaluated, &error), "Synthetic fixture trust failed: \(String(describing: error))")
    }

    func testBinaryForwardingUsesAuthenticatedMandatoryProxyAndTLS() async throws {
        let echo = try TunnelEcho(identity: TunnelIdentity.identity())
        let remotePort = try await echo.start()
        defer { echo.stop() }
        let middle = try TunnelProxy(targetPort: remotePort)
        let proxyPort = try await middle.start()
        defer { middle.stop() }
        var failures: [String] = []
        let tunnel = DialerProxyTunnel(host: "turn-proxy-test.invalid", port: remotePort, proxy: proxy(middle, port: proxyPort),
            onFailure: { failures.append($0) }, testing: .init(trustAnchor: try TunnelIdentity.certificate()))
        defer { tunnel.close() }
        let localPort = try await tunnel.start()
        let repeatedPort = try await tunnel.start()
        XCTAssertEqual(localPort, repeatedPort)
        let client = TunnelClient(port: localPort)
        defer { client.close() }
        try await until { client.ready && echo.accepted > 0 }
        let payload = Data((0..<110_123).map { UInt8($0 % 251) })
        client.send(payload)
        try await until { client.data.count >= payload.count || !failures.isEmpty }
        XCTAssertEqual(client.data, payload, "Chunk boundaries and binary TURN framing must remain unchanged")
        XCTAssertFalse(middle.requests.isEmpty)
        XCTAssertTrue(middle.requests.allSatisfy { $0 == "CONNECT turn-proxy-test.invalid:\(remotePort) HTTP/1.1" })
        XCTAssertLessThanOrEqual(middle.requests.count, 2, "An initial HTTP Basic challenge may precede the single authenticated tunnel")
        XCTAssertEqual(middle.authorized, 1)
        XCTAssertGreaterThan(middle.relayedBytes, payload.count, "The proxy carries TLS records, not plaintext media")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
        XCTAssertEqual(tunnel.activeClients, 1)
        tunnel.close()
        XCTAssertNil(tunnel.port)
        XCTAssertEqual(tunnel.activeClients, 0)
    }

    func testDefaultTrustRejectsUntrustedTLSAndClosesEveryClient() async throws {
        let echo = try TunnelEcho(identity: TunnelIdentity.identity())
        let remotePort = try await echo.start()
        defer { echo.stop() }
        let middle = try TunnelProxy(targetPort: remotePort)
        let proxyPort = try await middle.start()
        defer { middle.stop() }
        var failures: [String] = []
        let tunnel = DialerProxyTunnel(host: "turn-proxy-test.invalid", port: remotePort, proxy: proxy(middle, port: proxyPort)) { failures.append($0) }
        let localPort = try await tunnel.start()
        defer { tunnel.close() }
        let first = TunnelClient(port: localPort)
        let second = TunnelClient(port: localPort)
        defer { first.close(); second.close() }
        try await until { !failures.isEmpty }
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].contains("secure connection"))
        XCTAssertFalse(failures[0].contains("synthetic"))
        XCTAssertNil(tunnel.port)
        XCTAssertEqual(tunnel.activeClients, 0)
        XCTAssertGreaterThan(echo.accepted, 0)
        XCTAssertEqual(echo.received, 0, "No application bytes reach a relay whose certificate is untrusted")
    }

    func testRejectedProxyNeverFallsBackToReachableDestination() async throws {
        let echo = try TunnelEcho(identity: nil)
        let remotePort = try await echo.start()
        defer { echo.stop() }
        let direct = TunnelClient(port: remotePort, host: ProcessInfo.processInfo.hostName)
        defer { direct.close() }
        try await until { direct.ready && echo.accepted == 1 }
        direct.close()
        let baseline = echo.accepted
        let middle = try TunnelProxy(targetPort: remotePort, mode: .reject)
        let proxyPort = try await middle.start()
        defer { middle.stop() }
        var failures: [String] = []
        let tunnel = DialerProxyTunnel(host: ProcessInfo.processInfo.hostName, port: remotePort,
            proxy: proxy(middle, port: proxyPort)) { failures.append($0) }
        defer { tunnel.close() }
        let local = TunnelClient(port: try await tunnel.start())
        defer { local.close() }
        try await until { !failures.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(middle.requests.count, 0)
        XCTAssertEqual(echo.accepted, baseline, "Even a reachable destination cannot bypass a rejected proxy")
        XCTAssertEqual(tunnel.activeClients, 0)
        XCTAssertNil(tunnel.port)
        XCTAssertEqual(failures.count, 1)
    }

    func testStalledProxyTimesOutAndClosesTunnel() async throws {
        let middle = try TunnelProxy(targetPort: 9, mode: .hold)
        let proxyPort = try await middle.start()
        defer { middle.stop() }
        var failures: [String] = []
        let tunnel = DialerProxyTunnel(host: "turn-proxy-test.invalid", port: 5349, proxy: proxy(middle, port: proxyPort),
            onFailure: { failures.append($0) }, testing: .init(connectionTimeout: 0.2))
        defer { tunnel.close() }
        let local = TunnelClient(port: try await tunnel.start())
        defer { local.close() }
        try await until { !failures.isEmpty }
        XCTAssertEqual(middle.authorized, 1)
        XCTAssertTrue(failures[0].contains("in time"))
        XCTAssertEqual(tunnel.activeClients, 0)
        XCTAssertNil(tunnel.port)
    }

    func testClientLimitFailsClosedAndClosesPendingClients() async throws {
        let middle = try TunnelProxy(targetPort: 9, mode: .hold)
        let proxyPort = try await middle.start()
        defer { middle.stop() }
        var failures: [String] = []
        let tunnel = DialerProxyTunnel(host: "turn-proxy-test.invalid", port: 5349, proxy: proxy(middle, port: proxyPort),
            onFailure: { failures.append($0) }, testing: .init(maximumClients: 1))
        defer { tunnel.close() }
        let localPort = try await tunnel.start()
        let first = TunnelClient(port: localPort)
        defer { first.close() }
        try await until { middle.authorized == 1 && tunnel.activeClients == 1 }
        let second = TunnelClient(port: localPort)
        defer { second.close() }
        try await until { !failures.isEmpty }
        XCTAssertTrue(failures[0].contains("connection limit"))
        XCTAssertEqual(tunnel.activeClients, 0)
        XCTAssertNil(tunnel.port)
        XCTAssertEqual(failures.count, 1)
    }

    func testTransferLimitAndIdleDeadlineStopTheWholeRoute() async throws {
        for idle in [false, true] {
            let echo = try TunnelEcho(identity: TunnelIdentity.identity())
            let remotePort = try await echo.start()
            defer { echo.stop() }
            let middle = try TunnelProxy(targetPort: remotePort)
            let proxyPort = try await middle.start()
            defer { middle.stop() }
            var failures: [String] = []
            let settings = DialerProxyTunnel.Testing(trustAnchor: try TunnelIdentity.certificate(),
                maximumBytes: idle ? 1024 : 64, idleTimeout: idle ? 0.1 : 90)
            let tunnel = DialerProxyTunnel(host: "turn-proxy-test.invalid", port: remotePort, proxy: proxy(middle, port: proxyPort),
                onFailure: { failures.append($0) }, testing: settings)
            defer { tunnel.close() }
            let local = TunnelClient(port: try await tunnel.start())
            defer { local.close() }
            try await until { echo.accepted > 0 && middle.authorized == 1 }
            if !idle { local.send(Data(repeating: 0x7f, count: 128)) }
            try await until { !failures.isEmpty }
            XCTAssertTrue(failures[0].contains(idle ? "stopped responding" : "transfer limit"), failures.joined(separator: "; "))
            XCTAssertNil(tunnel.port)
            XCTAssertEqual(tunnel.activeClients, 0)
            if !idle { XCTAssertEqual(echo.received, 0) }
        }
    }

    func testCloseIsFinalAndInvalidEndpointsNeverOpenAListener() async throws {
        var failures: [String] = []
        let proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: 9))
        let tunnel = DialerProxyTunnel(host: "turn-proxy-test.invalid", port: 5349, proxy: proxy) { failures.append($0) }
        _ = try await tunnel.start()
        tunnel.close()
        tunnel.close()
        do { _ = try await tunnel.start(); XCTFail("A closed route cannot be reopened") } catch { }
        XCTAssertTrue(failures.isEmpty, "Explicit close does not report an upstream failure")
        XCTAssertNil(tunnel.port)
        XCTAssertEqual(tunnel.activeClients, 0)
        for host in ["", "turn.invalid\r\nInjected: true", "turn.invalid/path"] {
            let invalid = DialerProxyTunnel(host: host, port: 5349, proxy: proxy) { failures.append($0) }
            do { _ = try await invalid.start(); XCTFail("An invalid endpoint cannot listen") } catch { }
            XCTAssertNil(invalid.port)
            XCTAssertEqual(invalid.activeClients, 0)
        }
        XCTAssertEqual(failures.count, 3)
    }
}

private final class TunnelClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "TunnelTests.client")
    private let lock = NSLock()
    private var isReady = false
    private var received = Data()
    var ready: Bool { lock.withLock { isReady } }
    var data: Data { lock.withLock { received } }

    init(port: UInt16, host: String = "127.0.0.1") {
        let parameters = NWParameters.tcp
        parameters.preferNoProxies = true
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state { self.lock.withLock { self.isReady = true }; self.read() }
        }
        connection.start(queue: queue)
    }
    func close() { connection.cancel() }
    func send(_ data: Data) { connection.send(content: data, completion: .contentProcessed { _ in }) }
    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.lock.withLock { self.received.append(data) } }
            if !complete && error == nil { self.read() }
        }
    }
}

private final class TunnelEcho: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "TunnelTests.echo")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var acceptedCount = 0
    private var receivedCount = 0
    var accepted: Int { lock.withLock { acceptedCount } }
    var received: Int { lock.withLock { receivedCount } }

    init(identity: SecIdentity?) throws {
        let parameters: NWParameters
        if let identity {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
            parameters = NWParameters(tls: tls, tcp: .init())
        } else { parameters = .tcp }
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> UInt16 { try await startLocal(listener, queue: queue) { [weak self] connection in
        guard let self else { connection.cancel(); return }
        self.lock.withLock { self.connections.append(connection); self.acceptedCount += 1 }
        connection.start(queue: self.queue)
        self.read(connection)
    } }
    func stop() { listener.cancel(); lock.withLock { connections }.forEach { $0.cancel() } }
    private func read(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            guard error == nil, let data, !data.isEmpty else { if complete || error != nil { connection.cancel() }; return }
            self.lock.withLock { self.receivedCount += data.count }
            connection.send(content: data, completion: .contentProcessed { error in
                if error == nil && !complete { self.read(connection) } else { connection.cancel() }
            })
        }
    }
}

private final class TunnelProxy: @unchecked Sendable {
    enum Mode { case relay, reject, hold }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "TunnelTests.proxy")
    private let lock = NSLock()
    private let targetPort: UInt16
    private let mode: Mode
    private var connections: [NWConnection] = []
    private var requestLines: [String] = []
    private var authorizedCount = 0
    private var byteCount = 0
    var requests: [String] { lock.withLock { requestLines } }
    var authorized: Int { lock.withLock { authorizedCount } }
    var relayedBytes: Int { lock.withLock { byteCount } }
    init(targetPort: UInt16, mode: Mode = .relay) throws {
        self.targetPort = targetPort
        self.mode = mode
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> UInt16 { try await startLocal(listener, queue: queue) { [weak self] connection in
        guard let self else { connection.cancel(); return }
        self.lock.withLock { self.connections.append(connection) }
        connection.start(queue: self.queue)
        self.header(connection)
    } }
    func stop() { listener.cancel(); lock.withLock { connections }.forEach { $0.cancel() } }
    private func header(_ connection: NWConnection, previous: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var bytes = previous
            if let data { bytes.append(data) }
            guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if bytes.count < 8192 && !complete && error == nil { self.header(connection, previous: bytes) }
                else { connection.cancel() }
                return
            }
            let text = String(decoding: bytes[..<end.lowerBound], as: UTF8.self)
            self.lock.withLock { self.requestLines.append(text.components(separatedBy: "\r\n")[0]) }
            let expected = "basic " + Data("synthetic-user:synthetic-password".utf8).base64EncodedString().lowercased()
            let authorized = text.components(separatedBy: "\r\n").contains { line in
                guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == "proxy-authorization" else { return false }
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased() == expected
            }
            guard authorized, self.mode != .reject else {
                let rejected = Data("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"Synthetic Tunnel\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: rejected, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            self.lock.withLock { self.authorizedCount += 1 }
            guard self.mode == .relay else { return }
            let parameters = NWParameters.tcp
            parameters.preferNoProxies = true
            let remote = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: self.targetPort)!, using: parameters)
            self.lock.withLock { self.connections.append(remote) }
            remote.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    remote.stateUpdateHandler = nil
                    connection.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { error in
                        guard error == nil else { connection.cancel(); remote.cancel(); return }
                        self.pump(connection, remote)
                        self.pump(remote, connection)
                    })
                case .failed, .cancelled: connection.cancel()
                default: break
                }
            }
            remote.start(queue: self.queue)
        }
    }
    private func pump(_ source: NWConnection, _ destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, complete, error in
            guard let self else { source.cancel(); destination.cancel(); return }
            guard error == nil, let data, !data.isEmpty else { source.cancel(); destination.cancel(); return }
            self.lock.withLock { self.byteCount += data.count }
            destination.send(content: data, completion: .contentProcessed { error in
                if error == nil && !complete { self.pump(source, destination) }
                else { source.cancel(); destination.cancel() }
            })
        }
    }
}

private func startLocal(_ listener: NWListener, queue: DispatchQueue,
                        accepted: @escaping (NWConnection) -> Void) async throws -> UInt16 {
    try await withCheckedThrowingContinuation { done in
        listener.newConnectionHandler = accepted
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                listener.stateUpdateHandler = nil
                done.resume(returning: listener.port!.rawValue)
            case .failed(let error):
                listener.stateUpdateHandler = nil
                done.resume(throwing: error)
            default: break
            }
        }
        listener.start(queue: queue)
    }
}

private enum TunnelIdentity {
    // A short-lived certificate generated for this run avoids both expired
    // fixtures and TLS maximum-validity exceptions. All import stays in RAM.
    private static let fixture: Result<(certificate: Data, identity: Data), Error> = Result {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("search-tunnel-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let configuration = """
        [req]
        distinguished_name=dn
        x509_extensions=ext
        prompt=no
        [dn]
        CN=turn-proxy-test.invalid
        [ext]
        subjectAltName=DNS:turn-proxy-test.invalid
        basicConstraints=critical,CA:TRUE
        keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign
        extendedKeyUsage=serverAuth
        """
        try configuration.write(to: folder.appendingPathComponent("cert.conf"), atomically: true, encoding: .utf8)
        func openssl(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.currentDirectoryURL = folder
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw NSError(domain: "SyntheticTunnelIdentity", code: Int(process.terminationStatus)) }
        }
        try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "key.pem", "-out", "cert.pem", "-days", "2", "-config", "cert.conf"])
        try openssl(["x509", "-in", "cert.pem", "-outform", "DER", "-out", "cert.der"])
        try openssl(["pkcs12", "-export", "-inkey", "key.pem", "-in", "cert.pem", "-out", "identity.p12", "-passout", "pass:synthetic-tunnel-fixture"])
        return (try Data(contentsOf: folder.appendingPathComponent("cert.der")), try Data(contentsOf: folder.appendingPathComponent("identity.p12")))
    }

    static func certificate() throws -> SecCertificate {
        guard let certificate = SecCertificateCreateWithData(nil, try fixture.get().certificate as CFData) else { throw URLError(.cannotDecodeContentData) }
        return certificate
    }

    static func identity() throws -> SecIdentity {
        guard #available(macOS 15, *) else { throw XCTSkip("In-memory PKCS#12 import requires macOS 15") }
        var imported: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: "synthetic-tunnel-fixture", kSecImportToMemoryOnly as String: true]
        let status = SecPKCS12Import(try fixture.get().identity as CFData, options as CFDictionary, &imported)
        guard status == errSecSuccess, let items = imported as? [[String: Any]], let identity = items.first?[kSecImportItemIdentity as String] else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return identity as! SecIdentity
    }
}
