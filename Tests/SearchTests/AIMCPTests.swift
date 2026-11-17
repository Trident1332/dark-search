import Foundation
import XCTest
@testable import Search

/// A real local subprocess, not a mocked JSON parser. The fixture receives
/// Search's initialization, catalog pages, calls and cancellation messages.
@MainActor
final class AIMCPTests: XCTestCase {
    private var fixture: MCPFixture!
    private var client: AIMCP!
    override func setUp() async throws {
        fixture = try MCPFixture()
        client = fixture.client()
    }
    override func tearDown() async throws {
        client?.stop(); client = nil
        try? FileManager.default.removeItem(at: fixture.root)
        fixture = nil
    }
    func testInitializationPaginationProgressAndStructuredEvidence() async throws {
        let tools: [AIMCP.Tool]
        do { tools = try await client.start() }
        catch { XCTFail("\(error.localizedDescription): \(client.diagnostic)"); return }
        XCTAssertEqual(tools.map(\.name), ["binary_session", "open_binary", "capture_process_scenario", "inspect_analysis_view", "export_evidence_bundle"])
        let reply = try await client.call(name: "binary_session", arguments: ["message": "fixture"])
        let value = try MCPFixture.object(reply)
        XCTAssertEqual(value["operation"] as? String, "binary_session")
        XCTAssertEqual((value["arguments"] as? [String: Any])?["message"] as? String, "fixture")
        XCTAssertEqual(client.progress, "Fixture progress")
        let log = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertTrue(log.contains("notifications/initialized"))
        XCTAssertTrue(log.contains("initialize"))
    }
    func testRejectsUnadvertisedOperationBeforeWritingCall() async throws {
        _ = try await client.start()
        do { _ = try await client.call(name: "shell", arguments: [:]); XCTFail("Unadvertised tools must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not advertised")) }
        XCTAssertFalse(try String(contentsOf: fixture.log, encoding: .utf8).contains("shell"))
    }
    func testRequestIDsMatchOutOfOrderReplies() async throws {
        _ = try await client.start()
        async let first = client.call(name: "binary_session", arguments: ["behavior": "defer", "message": "first"])
        try await Task.sleep(for: .milliseconds(40))
        async let second = client.call(name: "binary_session", arguments: ["behavior": "flush", "message": "second"])
        let (a, b) = try await (first, second)
        XCTAssertTrue(a.contains("first")); XCTAssertFalse(a.contains("second"))
        XCTAssertTrue(b.contains("second")); XCTAssertFalse(b.contains("first"))
    }
    func testCancellationReachesServerAndConnectionCanBeStopped() async throws {
        _ = try await client.start()
        let pending = Task { try await client.call(name: "binary_session", arguments: ["behavior": "wait"]) }
        try await Task.sleep(for: .milliseconds(80))
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled call completed") }
        catch is CancellationError {}
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(try String(contentsOf: fixture.log, encoding: .utf8).contains("notifications/cancelled"))
        let child = client.processID
        client.stop()
        XCTAssertEqual(client.processID, 0)
        for _ in 0..<30 where kill(child, 0) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotEqual(kill(child, 0), 0)
    }
    func testTimeoutStopsUnresponsiveProcess() async throws {
        _ = try await client.start()
        client.requestTimeout = 0.1
        do { _ = try await client.call(name: "binary_session", arguments: ["behavior": "wait"]); XCTFail("Call did not time out") }
        catch { XCTAssertTrue(error.localizedDescription.contains("time limit")) }
        XCTAssertEqual(client.processID, 0)
    }
    func testMalformedOutputTerminatesConnection() async throws {
        _ = try await client.start()
        do { _ = try await client.call(name: "binary_session", arguments: ["behavior": "invalid"]); XCTFail("Malformed output was accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("invalid MCP")) }
        XCTAssertEqual(client.processID, 0)
    }
    func testUnterminatedOversizedOutputIsBoundedAndStopsServer() async throws {
        _ = try await client.start()
        do { _ = try await client.call(name: "binary_session", arguments: ["behavior": "oversized"]); XCTFail("Oversized output was accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("exceeded")) }
        XCTAssertEqual(client.processID, 0)
    }
    func testProcessExitResumesWaitingCall() async throws {
        _ = try await client.start()
        do { _ = try await client.call(name: "binary_session", arguments: ["behavior": "exit"]); XCTFail("Exited server returned a value") }
        catch { XCTAssertTrue(error.localizedDescription.contains("ended")) }
        XCTAssertEqual(client.processID, 0)
    }
    func testToolErrorFlagThrowsInsteadOfReturningSuccessfulEvidence() async throws {
        _ = try await client.start()
        do { _ = try await client.call(name: "open_binary", arguments: ["behavior": "tool-error"]); XCTFail("Tool error was treated as success") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Fixture tool failure")) }
    }
    func testUnresponsiveStdinCannotBlockMainActorDeadline() async throws {
        _ = try await client.start()
        client.requestTimeout = 0.2
        let waiting = Task { try await client.call(name: "binary_session", arguments: ["behavior": "freeze-input"]) }
        try await Task.sleep(for: .milliseconds(30))
        let blockedWrite = Task { try await client.call(name: "binary_session", arguments: ["large": String(repeating: "x", count: 1_000_000)]) }
        // This actor-bound continuation can execute even while the pipe's
        // serial writer is blocked behind a child that stopped reading.
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNotEqual(client.processID, 0)
        _ = try? await waiting.value
        _ = try? await blockedWrite.value
        XCTAssertEqual(client.processID, 0)
    }
    func testLargeValidFrameIsReassembledWithoutLosingEvidence() async throws {
        let message = String(repeating: "fragmented-evidence-", count: 20_000)
        let reply = try await client.call(name: "binary_session", arguments: ["message": message])
        let object = try MCPFixture.object(reply)
        XCTAssertEqual((object["arguments"] as? [String: Any])?["message"] as? String, message)
        XCTAssertEqual(object["evidence_id"] as? String, "fixture-evidence")
    }
    func testServerCannotDelegateSamplingBackIntoSearch() async throws {
        _ = try await client.call(name: "binary_session", arguments: ["behavior": "client-request"])
        try await Task.sleep(for: .milliseconds(30))
        let log = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertTrue(log.contains("Client method not supported"))
        XCTAssertTrue(log.contains("-32601"))
    }
    func testPermanentDisposalRemovesScratchAfterProcessCleanup() async throws {
        _ = try await client.start()
        let child = client.processID
        client.dispose()
        for _ in 0..<100 where FileManager.default.fileExists(atPath: fixture.scratch.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.scratch.path))
        XCTAssertNotEqual(kill(child, 0), 0)
        do { _ = try await client.start(); XCTFail("Disposed backend restarted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("disposed")) }
    }
}

@MainActor
final class MCPFixture {
    let root: URL
    let scratch: URL
    let log: URL
    let script: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("search-mcp-fixture-\(UUID().uuidString)", isDirectory: true)
        scratch = root.appendingPathComponent("scratch", isDirectory: true)
        log = scratch.appendingPathComponent("protocol.jsonl")
        script = root.appendingPathComponent("server.py")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.source.write(to: script, atomically: true, encoding: .utf8)
    }
    func client(family: String = "rea") -> AIMCP {
        AIMCP(executable: URL(fileURLWithPath: "/opt/homebrew/bin/python3"), arguments: [script.path, log.path, family], workspace: root, scratch: scratch)
    }
    static func object(_ text: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
    }
    static let source = #"""
import sys,json,os,time
log=sys.argv[1]
family=sys.argv[2] if len(sys.argv)>2 else 'rea'
pending=None
def send(v):
 print(json.dumps(v),flush=True)
def result(req,v):
 send({'jsonrpc':'2.0','id':req['id'],'result':v})
def answer(req):
 p=req.get('params',{})
 result(req,{'structuredContent':{'operation':p.get('name'),'arguments':p.get('arguments',{}),'evidence_id':'fixture-evidence'}})
for line in sys.stdin:
 req=json.loads(line)
 with open(log,'a') as f: f.write(json.dumps(req)+'\n')
 method=req.get('method')
 if method=='initialize': result(req,{'protocolVersion':'2025-06-18','capabilities':{'tools':{}},'serverInfo':{'name':'Fixture','version':'1'}})
 elif method=='tools/list':
  second=bool(req.get('params',{}).get('cursor'))
  if family=='serena': names=['find_symbol','get_current_config'] if second else ['get_symbols_overview','execute_shell_command','activate_project']
  else: names=['inspect_analysis_view','export_evidence_bundle'] if second else ['binary_session','open_binary','list_procedures' if family=='native' else 'capture_process_scenario']
  page={'tools':[{'name':n,'description':n,'inputSchema':{'type':'object','properties':{}}} for n in names]}
  if len(names)==3: page['nextCursor']='second'
  result(req,page)
 elif method=='tools/call':
  p=req.get('params',{}); args=p.get('arguments',{}); behavior=args.get('behavior')
  if behavior=='wait': continue
  if behavior=='freeze-input': time.sleep(30); continue
  if behavior=='defer': pending=req; continue
  if behavior=='flush':
   answer(req)
   if pending: answer(pending); pending=None
   continue
  if behavior=='invalid': print('not JSON',flush=True); continue
  if behavior=='oversized': sys.stdout.write('x'*11000000); sys.stdout.flush(); continue
  if behavior=='exit': sys.exit(3)
  if behavior=='tool-error': result(req,{'isError':True,'content':[{'type':'text','text':'Fixture tool failure'}]}); continue
  if behavior=='client-request': send({'jsonrpc':'2.0','id':'server-sampling','method':'sampling/createMessage','params':{'messages':[]}})
  send({'jsonrpc':'2.0','method':'notifications/progress','params':{'progressToken':p.get('_meta',{}).get('progressToken'),'progress':1,'message':'Fixture progress'}})
  answer(req)
"""#
}
