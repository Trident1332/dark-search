import Foundation
import Network
import Security

/// A loopback TURN/TCP endpoint whose only upstream is authenticated TLS through
/// one mandatory proxy. TURN framing and media remain opaque to this bridge.
@MainActor
final class DialerProxyTunnel {
    struct Testing {
        var trustAnchor: SecCertificate?
        var maximumClients = 4
        var maximumBytes: UInt64 = 512 * 1024 * 1024
        var connectionTimeout: TimeInterval = 12
        var idleTimeout: TimeInterval = 90
    }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }

    private final class Client {
        let local: NWConnection
        let remote: NWConnection
        var ready = false
        var lastActivity = Date()
        var bytes: UInt64 = 0
        var timeout: Task<Void, Never>?
        init(local: NWConnection, remote: NWConnection) { self.local = local; self.remote = remote }
    }

    private let host: String
    private let destinationPort: UInt16
    private let proxy: ProxyConfiguration
    private let onFailure: @MainActor (String) -> Void
    private let testing: Testing?
    private let queue = DispatchQueue(label: "Search.DialerProxyTunnel", qos: .userInitiated)
    private var listener: NWListener?
    private var context: NWParameters.PrivacyContext?
    private var clients: [UUID: Client] = [:]
    private var waiters: [CheckedContinuation<UInt16, Error>] = []
    private var startTimeout: Task<Void, Never>?
    private var idleWatch: Task<Void, Never>?
    private var totalBytes: UInt64 = 0
    private var closed = false
    private var failure: String?
    private(set) var port: UInt16?
    var activeClients: Int { clients.count }

    init(host: String, port: UInt16, proxy: ProxyConfiguration,
         onFailure: @escaping @MainActor (String) -> Void, testing: Testing? = nil) {
        self.host = host
        destinationPort = port
        var mandatory = proxy
        mandatory.allowFailover = false
        mandatory.excludedDomains = []
        mandatory.matchDomains = []
        self.proxy = mandatory
        self.onFailure = onFailure
        self.testing = Store.testing ? testing : nil
    }

    deinit {
        startTimeout?.cancel()
        idleWatch?.cancel()
        listener?.cancel()
        for client in clients.values {
            client.timeout?.cancel()
            client.local.cancel()
            client.remote.cancel()
        }
    }

    func start() async throws -> UInt16 {
        if closed { throw Failure.message(failure ?? "The protected-call connection is closed") }
        if let port { return port }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { done in
                if Task.isCancelled { done.resume(throwing: CancellationError()); close(); return }
                waiters.append(done)
                guard listener == nil else { return }
                guard destinationPort > 0, !host.isEmpty, host.utf8.count <= 253,
                      host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:").contains($0) })
                else { fail("The protected-call server address is invalid"); return }
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    parameters.preferNoProxies = true
                    let made = try NWListener(using: parameters)
                    listener = made
                    made.newConnectionHandler = { [weak self] connection in
                        Task { @MainActor in
                            guard let self else { connection.cancel(); return }
                            self.accept(connection)
                        }
                    }
                    made.stateUpdateHandler = { [weak self] state in
                        Task { @MainActor in self?.listenerChanged(state) }
                    }
                    made.start(queue: queue)
                    startTimeout = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(5))
                        guard !Task.isCancelled, let self, self.port == nil else { return }
                        self.fail("The protected-call connection could not start")
                    }
                } catch { fail("The protected-call connection could not start") }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.close() }
        }
    }

    /// Closing is final. A route change must create a new tunnel, never reuse
    /// an old TLS session or a proxy configuration from the previous revision.
    func close() { finish() }

    private func listenerChanged(_ state: NWListener.State) {
        guard !closed else { return }
        switch state {
        case .ready:
            guard let bound = listener?.port?.rawValue, bound > 0 else {
                fail("The protected-call connection could not start"); return
            }
            port = bound
            startTimeout?.cancel()
            startTimeout = nil
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume(returning: bound) }
            watchIdleClients()
        case .failed, .waiting:
            fail("The protected-call connection is unavailable")
        case .cancelled:
            fail("The protected-call connection closed unexpectedly")
        default: break
        }
    }

    private func accept(_ local: NWConnection) {
        guard !closed, port != nil else { local.cancel(); return }
        guard clients.count < max(1, testing?.maximumClients ?? 4) else {
            local.cancel()
            fail("The protected-call connection reached its connection limit")
            return
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
        host.withCString { sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, $0) }
        if let anchor = testing?.trustAnchor {
            // Rehearsal-only certificate trust; no Keychain or system-trust
            // mutation, no blanket acceptance, and hostname checks stay on.
            let expectedHost = host
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, offered, complete in
                let trust = sec_trust_copy_ref(offered).takeRetainedValue()
                SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, expectedHost as CFString))
                SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, true)
                SecTrustSetNetworkFetchAllowed(trust, false)
                complete(SecTrustEvaluateWithError(trust, nil))
            }, queue)
        }
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let privacy: NWParameters.PrivacyContext
        if let context { privacy = context }
        else {
            privacy = NWParameters.PrivacyContext(description: "Search protected call")
            privacy.disableLogging()
            privacy.proxyConfigurations = [proxy]
            context = privacy
        }
        parameters.setPrivacyContext(privacy)
        let remote = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: destinationPort)!, using: parameters)
        let id = UUID()
        let client = Client(local: local, remote: remote)
        clients[id] = client
        local.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.clients[id] != nil else { return }
                switch state { case .failed, .cancelled: self.remove(id); default: break }
            }
        }
        remote.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.remoteChanged(state, id: id) }
        }
        local.start(queue: queue)
        remote.start(queue: queue)
        let timeout = max(0.01, testing?.connectionTimeout ?? 12)
        client.timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self, self.clients[id]?.ready == false else { return }
            self.fail("The proxy could not reach the protected-call relay in time")
        }
    }

    private func remoteChanged(_ state: NWConnection.State, id: UUID) {
        guard !closed, let client = clients[id] else { return }
        switch state {
        case .ready:
            guard !client.ready else { return }
            client.ready = true
            client.lastActivity = Date()
            client.timeout?.cancel()
            client.timeout = nil
            pump(id, upstream: true)
            pump(id, upstream: false)
        case .failed(let error), .waiting(let error):
            if case .tls = error { fail("The protected-call relay's secure connection could not be verified") }
            else { fail("The proxy could not reach the protected-call relay. Check Proxy settings") }
        case .cancelled:
            fail("The protected-call relay connection closed unexpectedly")
        default: break
        }
    }

    private func pump(_ id: UUID, upstream: Bool) {
        guard !closed, let client = clients[id], client.ready else { return }
        let source = upstream ? client.local : client.remote
        source.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.closed, let current = self.clients[id] else { return }
                if error != nil {
                    if upstream { self.remove(id) }
                    else { self.fail("The protected-call relay connection ended") }
                    return
                }
                guard let data, !data.isEmpty else {
                    if complete {
                        if upstream { self.remove(id) }
                        else { self.fail("The protected-call relay connection ended") }
                    } else { self.pump(id, upstream: upstream) }
                    return
                }
                let limit = self.testing?.maximumBytes ?? 512 * 1024 * 1024
                let count = UInt64(data.count)
                guard current.bytes <= limit, count <= limit - current.bytes,
                      self.totalBytes <= limit, count <= limit - self.totalBytes else {
                    self.fail("The protected-call connection reached its transfer limit"); return
                }
                current.bytes += count
                self.totalBytes += count
                current.lastActivity = Date()
                let destination = upstream ? current.remote : current.local
                destination.send(content: data, completion: .contentProcessed { [weak self] error in
                    Task { @MainActor in
                        guard let self, !self.closed, self.clients[id] != nil else { return }
                        if error != nil {
                            if upstream { self.fail("The protected-call relay connection ended") }
                            else { self.remove(id) }
                        } else if complete {
                            if upstream { self.remove(id) }
                            else { self.fail("The protected-call relay connection ended") }
                        } else { self.pump(id, upstream: upstream) }
                    }
                })
            }
        }
    }

    private func watchIdleClients() {
        guard idleWatch == nil else { return }
        idleWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, !self.closed else { return }
                let limit = max(0.1, self.testing?.idleTimeout ?? 90)
                if self.clients.values.contains(where: { $0.ready && Date().timeIntervalSince($0.lastActivity) > limit }) {
                    self.fail("The protected-call relay stopped responding"); return
                }
            }
        }
    }

    private func remove(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.timeout?.cancel()
        client.local.stateUpdateHandler = nil
        client.remote.stateUpdateHandler = nil
        client.local.cancel()
        client.remote.cancel()
    }

    private func fail(_ message: String) {
        guard !closed else { return }
        failure = message
        finish()
        onFailure(message)
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        port = nil
        startTimeout?.cancel()
        startTimeout = nil
        idleWatch?.cancel()
        idleWatch = nil
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        for id in Array(clients.keys) { remove(id) }
        context?.flushCache()
        context = nil
        let pending = waiters
        waiters.removeAll()
        let error: Error = failure.map { Failure.message($0) as Error } ?? CancellationError()
        pending.forEach { $0.resume(throwing: error) }
    }
}
