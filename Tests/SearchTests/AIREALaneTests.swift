import Foundation
import XCTest
@testable import Search

@MainActor
final class AIREALaneTests: XCTestCase {
    func testArtifactsStayOnTheirOwningSandboxBeforeAndAfterClose() async throws {
        let files = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/search-rea-lanes-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let ghidraRoot = root.appendingPathComponent("ghidra", isDirectory: true)
        let hopperRoot = root.appendingPathComponent("hopper", isDirectory: true)
        for directory in [root, workspace, ghidraRoot, hopperRoot] {
            try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        defer { try? files.removeItem(at: root) }
        let script = root.appendingPathComponent("server.py")
        try Self.server.write(to: script, atomically: true, encoding: .utf8)
        let target = workspace.appendingPathComponent("selected.bin")
        try Data([1, 2, 3]).write(to: target)
        func client(_ label: String, _ scratch: URL) -> AIMCP {
            AIMCP(executable: URL(fileURLWithPath: "/opt/homebrew/bin/python3"),
                arguments: [script.path, label, scratch.path], workspace: workspace, scratch: scratch, extraReadRoots: [script])
        }
        let ghidra = client("ghidra", ghidraRoot), hopper = client("hopper", hopperRoot)
        let rea = AIREA(workspace: workspace, client: ghidra, scratch: ghidraRoot,
            nativeLanes: ["ghidra": (ghidra, ghidraRoot), "hopper": (hopper, hopperRoot)])
        defer { rea.stop() }
        _ = await rea.definitions()
        func call(_ operation: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
            let result = try MCPFixture.object(await rea.call(name: "rea__" + operation, arguments: args))
            XCTAssertNil(result["error"], "\(operation): \(result)")
            return result
        }
        let first = try await call("export_evidence_bundle")
        let ghidraArtifact = try XCTUnwrap((first["arguments"] as? [String: Any])?["path"] as? String)
        XCTAssertEqual(try AIToolProcess.canonicalURL(URL(fileURLWithPath: ghidraArtifact)).deletingLastPathComponent(), try AIToolProcess.canonicalURL(ghidraRoot))
        XCTAssertTrue(files.fileExists(atPath: ghidraArtifact))

        _ = try await call("open_binary", ["path": target.path, "provider_id": "hopper"])
        _ = try await call("close_binary")
        let exported = try await call("export_evidence_bundle")
        XCTAssertEqual(exported["lane"] as? String, "hopper")
        let hopperArtifact = try XCTUnwrap((exported["arguments"] as? [String: Any])?["path"] as? String)
        XCTAssertEqual(try AIToolProcess.canonicalURL(URL(fileURLWithPath: hopperArtifact)).deletingLastPathComponent(), try AIToolProcess.canonicalURL(hopperRoot))
        XCTAssertTrue(files.fileExists(atPath: hopperArtifact))
        let inspected = try await call("inspect_analysis_view", ["source": ["kind": "evidence-file", "path": hopperArtifact]])
        XCTAssertEqual(inspected["lane"] as? String, "hopper")
        XCTAssertEqual((inspected["data"] as? [String: Any])?["lane"] as? String, "hopper")
        let imported = try await call("import_evidence_bundle", ["path": hopperArtifact])
        XCTAssertEqual(imported["lane"] as? String, "hopper")
        let closedNative = try MCPFixture.object(await rea.call(name: "rea__list_procedures", arguments: [:]))
        XCTAssertNotNil(closedNative["error"], "Retaining evidence context cannot reopen native capabilities.")

        // A private artifact explicitly routes to its owner, even after close
        // or another lane's evidence read. Neither process gains the other's root.
        let otherRead = try await call("inspect_analysis_view", ["source": ["kind": "evidence-file", "path": ghidraArtifact]])
        XCTAssertEqual(otherRead["lane"] as? String, "ghidra")
        let again = try await call("import_evidence_bundle", ["path": hopperArtifact])
        XCTAssertEqual(again["lane"] as? String, "hopper")
        let continuedEvidence = try await call("get_evidence_bundle")
        XCTAssertEqual(continuedEvidence["lane"] as? String, "hopper")
        do {
            _ = try await ghidra.call(name: "import_evidence_bundle", arguments: ["path": hopperArtifact])
            XCTFail("Ghidra sandbox read another lane's private artifact")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("permitted") || error.localizedDescription.contains("denied"), error.localizedDescription)
        }

        let opened = try await call("open_binary", ["path": target.path])
        XCTAssertEqual(opened["lane"] as? String, "ghidra")
        XCTAssertEqual((opened["arguments"] as? [String: Any])?["provider_id"] as? String, "ghidra", "New native opens still default to Ghidra.")
        _ = try await call("inspect_analysis_view", ["source": ["kind": "evidence-file", "path": hopperArtifact]])
        let procedures = try await call("list_procedures")
        XCTAssertEqual(procedures["lane"] as? String, "ghidra", "Artifact reads cannot replace the open binary's engine.")
        _ = try await call("close_binary")
        let mixed = try MCPFixture.object(await rea.call(name: "rea__compare_artifacts", arguments: ["left_path": ghidraArtifact, "right_path": hopperArtifact]))
        XCTAssertTrue((mixed["error"] as? String)?.contains("separate private analysis sessions") == true)
        let outside = root.appendingPathComponent("unselected.json")
        try Data("{}".utf8).write(to: outside)
        let escaped = hopperRoot.appendingPathComponent("escape.json")
        try files.createSymbolicLink(at: escaped, withDestinationURL: outside)
        let denied = try MCPFixture.object(await rea.call(name: "rea__import_evidence_bundle", arguments: ["path": escaped.path]))
        XCTAssertTrue((denied["error"] as? String)?.contains("outside") == true)
    }

    private static let server = #"""
import sys,json,os
lane=sys.argv[1]
scratch=sys.argv[2]
names=['binary_session','open_binary','close_binary','list_procedures','export_evidence_bundle','import_evidence_bundle','inspect_analysis_view','get_evidence_bundle','compare_artifacts']
def result(req,value): print(json.dumps({'jsonrpc':'2.0','id':req['id'],'result':value}),flush=True)
for line in sys.stdin:
 req=json.loads(line)
 method=req.get('method')
 if method=='initialize': result(req,{'protocolVersion':'2025-06-18','capabilities':{'tools':{}},'serverInfo':{'name':'Lane fixture','version':'1'}})
 elif method=='tools/list': result(req,{'tools':[{'name':name,'description':name,'inputSchema':{'type':'object','properties':{}}} for name in names]})
 elif method=='tools/call':
  p=req.get('params',{}); name=p.get('name'); args=p.get('arguments',{})
  value={'lane':lane,'operation':name,'arguments':args,'evidence_id':lane+'-evidence'}
  try:
   if name=='open_binary':
    with open(args['path'],'rb') as file: file.read(32)
   if name=='export_evidence_bundle':
    with open(args['path'],'x') as file: json.dump({'lane':lane,'payload':'synthetic evidence'},file)
    os.chmod(args['path'],0o600)
   if name in ('import_evidence_bundle','inspect_analysis_view'):
    path=args.get('path') or args.get('source',{}).get('path')
    with open(path) as file: value['data']=json.load(file)
   result(req,{'structuredContent':value})
  except Exception as error: result(req,{'isError':True,'content':[{'type':'text','text':str(error)}]})
"""#
}
