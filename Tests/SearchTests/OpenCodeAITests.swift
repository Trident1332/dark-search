import Foundation
import XCTest
@testable import Search

/// Every configuration and credential here is synthetic and kept in a
/// disposable folder. These tests never read the person's OpenCode setup.
final class OpenCodeAITests: XCTestCase {
    private var folder: URL!

    override class func setUp() {
        setenv("SEARCH_PROBE", "opencode-ai-tests-\(getpid())", 1)
        super.setUp()
    }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-ai-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    func testJSONAndJSONCMergePreservesProvidersAndUsesConfiguredDefault() throws {
        let json = try file("opencode.json", object: configuration())
        let jsonc = try file("opencode.jsonc", text: #"""
        {
          // URLs inside strings must survive comment removal.
          "model": "gpt/gpt-second",
          "provider": {
            "gpt": {
              "options": { "baseURL": "https://updated.fixture.invalid/v2", },
              "models": { "gpt-second": { "name": "Second GPT", }, },
            },
          },
        }
        """#)
        let models = try OpenCodeAI.catalogue(files: [json, jsonc], environment: [:])
        XCTAssertEqual(Set(models.map(\.id)), ["gpt/gpt-fixture", "gpt/gpt-second", "claude/claude-fixture"])
        XCTAssertEqual(try OpenCodeAI.configuredDefault(files: [json, jsonc], environment: [:]), "gpt/gpt-second")
        let connection = try OpenCodeAI.connection(for: "gpt/gpt-fixture", files: [json, jsonc], environment: [:])
        XCTAssertEqual(connection.base.host(), "updated.fixture.invalid")
        XCTAssertEqual(connection.key, "synthetic-gpt-key")
        XCTAssertEqual(models.first { $0.id == "gpt/gpt-second" }?.name, "Second GPT")
        let visible = String(reflecting: models)
        XCTAssertFalse(visible.contains("synthetic-gpt-key"))
        XCTAssertFalse(visible.contains("synthetic-claude-key"))
    }

    func testEachSelectedModelUsesItsOwnEndpointWireAndCredential() throws {
        let config = try file("opencode.json", object: configuration())
        let gpt = try OpenCodeAI.connection(for: "gpt/gpt-fixture", files: [config], environment: [:])
        let claude = try OpenCodeAI.connection(for: "claude/claude-fixture", files: [config], environment: [:])
        XCTAssertEqual(gpt.id, "gpt/gpt-fixture")
        XCTAssertEqual(gpt.model, "gpt-fixture")
        XCTAssertEqual(gpt.base.host(), "gpt.fixture.invalid")
        XCTAssertEqual(gpt.wire, .responses)
        XCTAssertEqual(gpt.key, "synthetic-gpt-key")
        XCTAssertEqual(claude.model, "claude-fixture")
        XCTAssertEqual(claude.base.host(), "claude.fixture.invalid")
        XCTAssertEqual(claude.wire, .anthropic)
        XCTAssertEqual(claude.key, "synthetic-claude-key")
    }

    func testRequestsCarrySecretsOnlyInTheSelectedProvidersAuthenticationHeaders() throws {
        let config = try file("opencode.json", object: configuration())
        for (id, endpoint, header, expected) in [
            ("gpt/gpt-fixture", "https://gpt.fixture.invalid/v1/responses", "Authorization", "Bearer synthetic-gpt-key"),
            ("claude/claude-fixture", "https://claude.fixture.invalid/v1/messages", "x-api-key", "synthetic-claude-key")
        ] {
            let connection = try OpenCodeAI.connection(for: id, files: [config], environment: [:])
            let request = try AIClient.request(.openCode, model: id, system: "Fixture system",
                                               messages: [AIMessage(role: .user, text: "Fixture question")], key: nil,
                                               connection: connection)
            XCTAssertEqual(request.url?.absoluteString, endpoint)
            XCTAssertEqual(request.value(forHTTPHeaderField: header), expected)
            XCTAssertEqual(request.httpMethod, "POST")
            let data = try XCTUnwrap(request.httpBody)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, connection.model)
            XCTAssertEqual(body["stream"] as? Bool, true)
            if connection.wire == .responses {
                XCTAssertEqual(body["instructions"] as? String, "Fixture system")
                XCTAssertNotNil(body["input"])
                XCTAssertEqual(body["store"] as? Bool, false)
                XCTAssertNil(body["messages"])
            }
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("synthetic-gpt-key"))
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("synthetic-claude-key"))
            XCTAssertNil(request.url?.query)
            XCTAssertNil(request.url?.user)
            if connection.wire == .anthropic {
                XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            } else {
                XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
            }
        }
    }

    func testCompatibleProvidersUseChatCompletionsWhileResponsesEventsYieldText() throws {
        var config = configuration()
        var providers = config["provider"] as! [String: Any]
        var gpt = providers["gpt"] as! [String: Any]
        gpt["npm"] = "@ai-sdk/openai-compatible"
        providers["gpt"] = gpt; config["provider"] = providers
        let file = try file("compatible.json", object: config)
        let connection = try OpenCodeAI.connection(for: "gpt/gpt-fixture", files: [file], environment: [:])
        XCTAssertEqual(connection.wire, .openAI)
        let request = try AIClient.request(.openCode, model: connection.id, system: "Fixture",
                                           messages: [AIMessage(role: .user, text: "Question")], key: nil, connection: connection)
        XCTAssertEqual(request.url?.absoluteString, "https://gpt.fixture.invalid/v1/chat/completions")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNotNil(body["messages"])
        XCTAssertNil(body["input"])
        XCTAssertEqual(AIClient.piece(.responses, ["type": "response.output_text.delta", "delta": "Fixture answer"]), "Fixture answer")
        XCTAssertNil(AIClient.piece(.responses, ["type": "response.reasoning_summary_text.delta", "delta": "Private reasoning"]))
    }

    func testResolvedConnectionKeepsItsOriginalCredentialAndEndpointAfterConfigurationChanges() throws {
        let config = try file("opencode.json", object: configuration())
        let connection = try OpenCodeAI.connection(for: "gpt/gpt-fixture", files: [config], environment: [:])
        var changed = configuration()
        var providers = changed["provider"] as! [String: Any]
        var provider = providers["gpt"] as! [String: Any]
        provider["options"] = ["baseURL": "https://new.fixture.invalid/v9", "apiKey": "synthetic-new-key"]
        providers["gpt"] = provider
        changed["provider"] = providers
        _ = try file("opencode.json", object: changed)
        let request = try AIClient.request(.openCode, model: connection.id, system: "Fixture",
                                           messages: [], key: nil, connection: connection)
        XCTAssertEqual(request.url?.host(), "gpt.fixture.invalid")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-gpt-key")
        let refreshed = try OpenCodeAI.connection(for: "gpt/gpt-fixture", files: [config], environment: [:])
        XCTAssertEqual(refreshed.base.host(), "new.fixture.invalid")
        XCTAssertEqual(refreshed.key, "synthetic-new-key")
    }

    func testEnvironmentAndRelativeFileReferencesAreResolvedOnlyForTheSelectedModel() throws {
        _ = try file("fixture-secret.txt", text: "synthetic-file-key\n")
        var config = configuration()
        var providers = config["provider"] as! [String: Any]
        var gpt = providers["gpt"] as! [String: Any]
        var claude = providers["claude"] as! [String: Any]
        gpt["options"] = ["baseURL": "https://gpt.fixture.invalid/v1", "apiKey": "{env:FIXTURE_API_KEY}"]
        claude["options"] = ["baseURL": "https://claude.fixture.invalid/v1", "apiKey": "{file:fixture-secret.txt}"]
        providers["gpt"] = gpt; providers["claude"] = claude
        config["provider"] = providers
        let file = try file("opencode.json", object: config)
        XCTAssertEqual(try OpenCodeAI.catalogue(files: [file], environment: [:]).count, 2,
                       "Listing model names must not require reading all provider secrets")
        XCTAssertEqual(try OpenCodeAI.connection(for: "gpt/gpt-fixture", files: [file], environment: ["FIXTURE_API_KEY": "synthetic-env-key"]).key,
                       "synthetic-env-key")
        XCTAssertEqual(try OpenCodeAI.connection(for: "claude/claude-fixture", files: [file], environment: [:]).key,
                       "synthetic-file-key")
        XCTAssertThrowsError(try OpenCodeAI.connection(for: "gpt/gpt-fixture", files: [file], environment: [:]))
    }

    func testExplicitAuthFileIsUsedWithoutConsultingRealOpenCodeCredentials() throws {
        var config = configuration()
        var providers = config["provider"] as! [String: Any]
        var gpt = providers["gpt"] as! [String: Any]
        gpt["options"] = ["baseURL": "https://gpt.fixture.invalid/v1"]
        providers["gpt"] = gpt; config["provider"] = providers
        let configurationFile = try file("opencode.json", object: config)
        let auth = try file("auth.json", object: ["gpt": ["type": "api", "key": "synthetic-auth-key"]])
        XCTAssertEqual(try OpenCodeAI.connection(for: "gpt/gpt-fixture", files: [configurationFile], environment: [:], authFile: auth).key,
                       "synthetic-auth-key")
        XCTAssertThrowsError(try OpenCodeAI.connection(for: "gpt/gpt-fixture", files: [configurationFile], environment: [:]),
                             "An explicit fixture config must never fall back to the person's real auth file")
    }

    func testUnsafeProviderAddressesAreRefusedBeforeARequestIsBuilt() throws {
        for address in ["http://public.fixture.invalid/v1", "https://fixture-user:fixture-password@gpt.fixture.invalid/v1",
                        "https://gpt.fixture.invalid/v1?api_key=synthetic-query-key", "https://gpt.fixture.invalid/v1#secret",
                        "file:///private/tmp/provider"] {
            var config = configuration()
            var providers = config["provider"] as! [String: Any]
            var gpt = providers["gpt"] as! [String: Any]
            gpt["options"] = ["baseURL": address, "apiKey": "synthetic-gpt-key"]
            providers["gpt"] = gpt; config["provider"] = providers
            let file = try file("unsafe.json", object: config)
            XCTAssertThrowsError(try OpenCodeAI.connection(for: "gpt/gpt-fixture", files: [file], environment: [:]), address)
        }
    }

    func testMalformedAndOversizedConfigurationsFailWithoutEchoingTheirContents() throws {
        let marker = "synthetic-secret-must-not-appear-in-errors"
        let malformed = try file("bad.jsonc", text: "{\"provider\": \"\(marker)\", broken}")
        XCTAssertThrowsError(try OpenCodeAI.catalogue(files: [malformed], environment: [:])) { error in
            XCTAssertFalse(error.localizedDescription.contains(marker))
        }
        let huge = try file("huge.json", text: String(repeating: " ", count: 2_100_000))
        XCTAssertThrowsError(try OpenCodeAI.catalogue(files: [huge], environment: [:]))
    }

    private func configuration() -> [String: Any] {
        ["model": "gpt/gpt-fixture", "provider": [
            "gpt": ["name": "Fixture GPT Provider", "npm": "@ai-sdk/openai",
                    "options": ["baseURL": "https://gpt.fixture.invalid/v1", "apiKey": "synthetic-gpt-key"],
                    "models": ["gpt-fixture": ["name": "Fixture GPT"]]],
            "claude": ["name": "Fixture Claude Provider", "npm": "@ai-sdk/anthropic",
                       "options": ["baseURL": "https://claude.fixture.invalid/v1", "apiKey": "synthetic-claude-key"],
                       "models": ["claude-fixture": ["name": "Fixture Claude"]]]
        ]]
    }

    @discardableResult
    private func file(_ name: String, object: [String: Any]) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url, options: .atomic)
        return url
    }

    @discardableResult
    private func file(_ name: String, text: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }
}
