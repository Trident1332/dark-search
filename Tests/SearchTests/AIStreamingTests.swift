import AppKit
import Foundation
import Network
import XCTest
@testable import Search

/// Exercises real HTTP and SSE parsing on loopback. Provider definitions,
/// credentials and page text are synthetic; no user configuration is read.
@MainActor
final class AIStreamingTests: XCTestCase {
    private var folder: URL!
    private var client: AIClient!
    private var servers: [AIStreamHTTPServer] = []

    override class func setUp() {
        setenv("SEARCH_PROBE", "ai-streaming-tests-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        _ = Shared.prefs
        Proxy.shared.automaticTarget = nil
        Proxy.shared.take(ProxySetup())
        for _ in 0..<100 where Proxy.shared.changingContent { try await Task.sleep(for: .milliseconds(20)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        client = AIClient(configuration: configuration)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ai-streaming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await super.setUp()
    }

    override func tearDown() async throws {
        client?.session.invalidateAndCancel()
        client = nil
        servers.forEach { $0.stop() }
        servers.removeAll()
        if let folder { try FileManager.default.removeItem(at: folder) }
        folder = nil
        try await super.tearDown()
    }

    func testCapturedOpenCodeConnectionsStreamAllThreeProtocolsWithTheirOwnAuthentication() async throws {
        let server = try await server { request in
            switch request.path {
            case "/gpt/v1/responses":
                return .events([
                    ["type": "response.reasoning_summary_text.delta", "delta": "Internal fixture reasoning"],
                    ["type": "response.output_text.delta", "delta": "GPT "],
                    ["type": "response.output_text.delta", "delta": "answer"],
                    ["type": "response.completed"]
                ])
            case "/claude/v1/messages":
                return .events([
                    ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "Claude "]],
                    ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "answer"]],
                    ["type": "message_stop"]
                ])
            case "/compatible/v1/chat/completions":
                return .events([
                    ["choices": [["delta": ["content": "Compatible "]]]],
                    ["choices": [["delta": ["content": "answer"]]]]
                ], done: true)
            default: return .json(status: 404, ["error": ["message": "Unexpected fixture path"]])
            }
        }
        for (provider, package, expected, header) in [
            ("gpt", "@ai-sdk/openai", "GPT answer", "authorization"),
            ("claude", "@ai-sdk/anthropic", "Claude answer", "x-api-key"),
            ("compatible", "@ai-sdk/openai-compatible", "Compatible answer", "authorization")
        ] {
            let key = "synthetic-\(provider)-stream-key"
            let connection = try connection(provider: provider, package: package, base: server.url.appendingPathComponent("\(provider)/v1"), key: key)
            let pieces = try await collect(connection)
            XCTAssertEqual(pieces.count, 2, "Only answer deltas should leave the stream parser")
            XCTAssertEqual(pieces.joined(), expected)
            let received = try XCTUnwrap(server.requests.last)
            XCTAssertEqual(received.method, "POST")
            XCTAssertEqual(received.headers["content-type"], "application/json")
            XCTAssertEqual(received.headers["accept"], "text/event-stream")
            XCTAssertEqual(received.headers[header], header == "authorization" ? "Bearer \(key)" : key)
            XCTAssertNil(received.headers[header == "authorization" ? "x-api-key" : "authorization"])
            XCTAssertNil(received.headers["cookie"])
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: received.body) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, "fixture-model")
            XCTAssertEqual(body["stream"] as? Bool, true)
            XCTAssertFalse(String(decoding: received.body, as: UTF8.self).contains(key))
            if provider == "gpt" {
                XCTAssertEqual(body["instructions"] as? String, "Synthetic system instruction")
                XCTAssertEqual(body["store"] as? Bool, false)
                XCTAssertEqual((body["input"] as? [[String: String]])?.first?["content"], "Synthetic page question")
            } else if provider == "claude" {
                XCTAssertEqual(body["system"] as? String, "Synthetic system instruction")
                XCTAssertEqual(received.headers["anthropic-version"], "2023-06-01")
                XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["content"], "Synthetic page question")
            } else {
                let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
                XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
                XCTAssertEqual(messages.last?["content"], "Synthetic page question")
            }
        }
        XCTAssertEqual(server.requests.map(\.path), ["/gpt/v1/responses", "/claude/v1/messages", "/compatible/v1/chat/completions"])
    }

    func testProviderRedirectIsNotFollowedOrForwardedWithItsCredential() async throws {
        let destination = try await server { _ in .events([["type": "response.output_text.delta", "delta": "Should not be reached"]]) }
        let target = destination.url.appendingPathComponent("capture-credential")
        let redirect = try await server { _ in .redirect(target) }
        let connection = try connection(provider: "gpt", package: "@ai-sdk/openai", base: redirect.url.appendingPathComponent("v1"), key: "synthetic-redirect-key")
        do {
            _ = try await collect(connection)
            XCTFail("A provider redirect must stop the answer")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("307"))
            XCTAssertFalse(error.localizedDescription.contains("synthetic-redirect-key"))
        }
        XCTAssertEqual(redirect.requests.count, 1)
        XCTAssertEqual(destination.requests.count, 0, "The second origin must receive neither a request nor the API key")
    }

    func testHTTPErrorsHideTheCapturedOpenCodeCredential() async throws {
        let key = "synthetic-http-error-secret"
        let server = try await server { _ in .json(status: 401, ["error": ["message": "Denied credential \(key)"]]) }
        let connection = try connection(provider: "gpt", package: "@ai-sdk/openai", base: server.url.appendingPathComponent("v1"), key: key)
        do {
            _ = try await collect(connection)
            XCTFail("The HTTP error must reach the panel")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401"))
            XCTAssertTrue(error.localizedDescription.contains("Denied credential"))
            XCTAssertTrue(error.localizedDescription.contains("••••"))
            XCTAssertFalse(error.localizedDescription.contains(key))
        }
    }

    func testResponsesStreamFailuresHideTheCapturedOpenCodeCredential() async throws {
        let key = "synthetic-sse-error-secret"
        let server = try await server { _ in
            .events([["type": "response.failed", "response": ["error": ["message": "Denied credential \(key)"]]]])
        }
        let connection = try connection(provider: "gpt", package: "@ai-sdk/openai", base: server.url.appendingPathComponent("v1"), key: key)
        do {
            _ = try await collect(connection)
            XCTFail("An SSE error must not be presented as an empty successful answer")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Denied credential"))
            XCTAssertTrue(error.localizedDescription.contains("••••"))
            XCTAssertFalse(error.localizedDescription.contains(key))
        }
    }

    private func server(_ response: @escaping @Sendable (AIStreamHTTPServer.Request) -> AIStreamHTTPServer.Response) async throws -> AIStreamHTTPServer {
        let server = try AIStreamHTTPServer(response: response)
        _ = try await server.start()
        servers.append(server)
        return server
    }

    private func connection(provider: String, package: String, base: URL, key: String) throws -> OpenCodeAI.Connection {
        let file = folder.appendingPathComponent("\(provider)-\(UUID().uuidString).json")
        let config: [String: Any] = ["model": "\(provider)/fixture-model", "provider": [provider: [
            "npm": package, "options": ["baseURL": base.absoluteString, "apiKey": key],
            "models": ["fixture-model": ["name": "Synthetic model"]]
        ]]]
        try JSONSerialization.data(withJSONObject: config).write(to: file)
        return try OpenCodeAI.connection(for: "\(provider)/fixture-model", files: [file], environment: [:])
    }

    private func collect(_ connection: OpenCodeAI.Connection) async throws -> [String] {
        var pieces: [String] = []
        for try await piece in client.stream(.openCode, model: connection.id, system: "Synthetic system instruction",
                                             messages: [AIMessage(role: .user, text: "Synthetic page question")], key: nil,
                                             connection: connection) { pieces.append(piece) }
        return pieces
    }
}

private final class AIStreamHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    struct Response: Sendable {
        let status: Int
        let headers: [String: String]
        let chunks: [Data]

        static func events(_ events: [[String: Any]], done: Bool = false) -> Response {
            var chunks = events.map { value in
                let data = try! JSONSerialization.data(withJSONObject: value)
                return Data("data: \(String(decoding: data, as: UTF8.self))\n\n".utf8)
            }
            if done { chunks.append(Data("data: [DONE]\n\n".utf8)) }
            return Response(status: 200, headers: ["Content-Type": "text/event-stream"], chunks: chunks)
        }

        static func json(status: Int, _ value: [String: Any]) -> Response {
            Response(status: status, headers: ["Content-Type": "application/json"], chunks: [try! JSONSerialization.data(withJSONObject: value)])
        }

        static func redirect(_ location: URL) -> Response {
            Response(status: 307, headers: ["Location": location.absoluteString], chunks: [])
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "AIStreamingTests.http")
    private let lock = NSLock()
    private let response: @Sendable (Request) -> Response
    private var connections: [NWConnection] = []
    private var captured: [Request] = []
    private var starting = true

    init(response: @escaping @Sendable (Request) -> Response) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.response = response
    }

    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")! }
    var requests: [Request] { lock.withLock { captured } }

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
        lock.withLock { connections }.forEach { $0.cancel() }
    }

    private func takeStart() -> Bool {
        lock.withLock { let first = starting; starting = false; return first }
    }

    private func read(_ connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count <= 262_144 else { return connection.cancel() }
            guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if error == nil, !complete { self.read(connection, buffer: buffer) } else { connection.cancel() }
                return
            }
            let lines = String(decoding: buffer[..<boundary.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let start = lines.first?.split(separator: " ") ?? []
            guard start.count >= 2 else { return connection.cancel() }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            guard length >= 0, length <= 262_144 else { return connection.cancel() }
            let body = buffer[boundary.upperBound...]
            guard body.count >= length else {
                if error == nil, !complete { self.read(connection, buffer: buffer) } else { connection.cancel() }
                return
            }
            let request = Request(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(body.prefix(length)))
            self.lock.withLock { self.captured.append(request) }
            let response = self.response(request)
            let reason = response.status == 200 ? "OK" : response.status == 307 ? "Temporary Redirect" : "Fixture Error"
            var header = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Length: \(response.chunks.reduce(0) { $0 + $1.count })\r\nConnection: close\r\nCache-Control: no-store\r\n"
            for (name, value) in response.headers { header += "\(name): \(value)\r\n" }
            self.send(connection, chunks: [Data((header + "\r\n").utf8)] + response.chunks)
        }
    }

    private func send(_ connection: NWConnection, chunks: [Data]) {
        guard let first = chunks.first else { return connection.cancel() }
        connection.send(content: first, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
            guard error == nil else { return connection.cancel() }
            self?.send(connection, chunks: Array(chunks.dropFirst()))
        })
    }
}
