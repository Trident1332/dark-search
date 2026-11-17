import XCTest
import Darwin
@testable import Search

@MainActor
final class AILocalToolsTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SearchLocalToolsTests-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        folder = try AIToolProcess.canonicalURL(folder)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at:folder) }
    private func object(_ value: String) throws -> [String:Any] { try XCTUnwrap(JSONSerialization.jsonObject(with:Data(value.utf8)) as? [String:Any]) }
    func testDocumentationSearchReturnsSourceAndLineWithoutReadingOutsideSelection() async throws {
        let docs = folder.appendingPathComponent("docs",isDirectory:true)
        try FileManager.default.createDirectory(at:docs,withIntermediateDirectories:false)
        let guide = docs.appendingPathComponent("guide.md")
        try "Overview\nNative WebKit inspection\nOther content".write(to:guide,atomically:true,encoding:.utf8)
        let tools = AILocalTools(workspace:folder)
        let result = try object(await tools.call("search_documentation",arguments:["path":"docs","query":"webkit"]))
        let matches = try XCTUnwrap(result["matches"] as? [[String:Any]])
        XCTAssertEqual(matches.count,1)
        XCTAssertEqual(matches.first?["line"] as? Int,2)
        XCTAssertEqual(matches.first?["path"] as? String,guide.path)
        XCTAssertEqual(result["network"] as? String,"none")
    }
    func testTraversalAbsolutePathsAndEscapingSymlinksAreRejected() async throws {
        let outside = folder.deletingLastPathComponent().appendingPathComponent("SearchPrivate-\(UUID().uuidString).txt")
        try "must-not-be-read".write(to:outside,atomically:true,encoding:.utf8)
        defer { try? FileManager.default.removeItem(at:outside) }
        try FileManager.default.createSymbolicLink(at:folder.appendingPathComponent("escape.txt"),withDestinationURL:outside)
        let tools = AILocalTools(workspace:folder)
        for path in ["../\(outside.lastPathComponent)",outside.path,"escape.txt","~/private"] {
            let result = try object(await tools.call("search_documentation",arguments:["path":path]))
            XCTAssertNotNil(result["error"],path)
            XCTAssertFalse(String(describing:result).contains("must-not-be-read"))
        }
    }
    func testDirectoryIndexSkipsSymlinksHiddenCredentialsAndOversizedFiles() async throws {
        try "visible needle".write(to:folder.appendingPathComponent("guide.md"),atomically:true,encoding:.utf8)
        try "private needle".write(to:folder.appendingPathComponent("credentials.json"),atomically:true,encoding:.utf8)
        try "hidden needle".write(to:folder.appendingPathComponent(".hidden.md"),atomically:true,encoding:.utf8)
        try String(repeating:"needle",count:40_000).write(to:folder.appendingPathComponent("large.txt"),atomically:true,encoding:.utf8)
        try FileManager.default.createSymbolicLink(at:folder.appendingPathComponent("link.md"),withDestinationURL:folder.appendingPathComponent("guide.md"))
        let result = try object(await AILocalTools(workspace:folder).call("search_documentation",arguments:["query":"needle"]))
        let matches = try XCTUnwrap(result["matches"] as? [[String:Any]])
        XCTAssertEqual(matches.count,1)
        XCTAssertEqual(matches.first?["text"] as? String,"visible needle")
    }
    func testModelCannotPassExecutableShellOrExtraOptions() async throws {
        let tools = AILocalTools(workspace:folder)
        for arguments: [String:Any] in [["query":"test","executable":"/bin/sh"],["query":"test","options":["--network"]]] {
            let result = try object(await tools.call("search_documentation",arguments:arguments))
            XCTAssertNotNil(result["error"])
        }
        let shell = await tools.call("shell",arguments:["command":"echo unsafe"])
        XCTAssertNotNil(try object(shell)["error"])
    }
    func testOfflineDependencyScanRequiresSelectedExistingDatabase() async throws {
        let result = try object(await AILocalTools(workspace:folder).call("scan_dependencies",arguments:["database":"missing"] ))
        XCTAssertNotNil(result["error"])
        XCTAssertEqual(result["completed"] as? Bool,false)
    }
    func testModelPIDDoesNotAuthorizeRuntimeAttachment() async throws {
        let result = try object(await AILocalTools(workspace:folder).call("trace_process",arguments:["pid":NSNumber(value:getpid()),"symbol":"malloc"]))
        XCTAssertTrue((result["error"] as? String ?? "").contains("approve"))
    }
    func testExplicitTargetFileCanBeImportedWithoutGrantingItsSiblingDirectory() async throws {
        let parent = folder.deletingLastPathComponent()
        let selected = parent.appendingPathComponent("SearchSelected-\(UUID().uuidString).md")
        try "selected content".write(to:selected,atomically:true,encoding:.utf8)
        defer { try? FileManager.default.removeItem(at:selected) }
        let tools = AILocalTools(workspace:folder,target:selected)
        let result = try object(await tools.call("search_documentation",arguments:["path":"@target","query":"selected"]))
        XCTAssertEqual((result["matches"] as? [[String:Any]])?.count,1)
        let escaped = await tools.call("search_documentation",arguments:["path":"../"])
        XCTAssertNotNil(try object(escaped)["error"])
    }
    func testInstalledAstGrepSearchesSyntheticSourceOffline() async throws {
        guard AILocalTools.executable("ast-grep") != nil else { throw XCTSkip("ast-grep is not installed") }
        try "function fixture(input) { return eval(input); }".write(to:folder.appendingPathComponent("fixture.js"),atomically:true,encoding:.utf8)
        let result = try object(await AILocalTools(workspace:folder).call("search_code",arguments:["pattern":"eval($X)","language":"javascript"]))
        XCTAssertEqual(result["exitCode"] as? Int,0,String(describing:result))
        XCTAssertTrue((result["output"] as? String ?? "").contains("eval(input)"))
    }
    func testInstalledCodeScannerFindsSyntheticEvalWithBundledOfflineRules() async throws {
        guard AILocalTools.executable("opengrep") != nil || AILocalTools.executable("semgrep") != nil else { throw XCTSkip("No free code scanner is installed") }
        try "function fixture(input) { return eval(input); }".write(to:folder.appendingPathComponent("fixture.js"),atomically:true,encoding:.utf8)
        let result = try object(await AILocalTools(workspace:folder).call("scan_code",arguments:[:]))
        XCTAssertEqual(result["exitCode"] as? Int,0,String(describing:result))
        XCTAssertTrue((result["output"] as? String ?? "").contains("dynamic-eval"))
    }
    func testInstalledGitleaksRedactsSyntheticCredential() async throws {
        guard AILocalTools.executable("gitleaks") != nil else { throw XCTSkip("Gitleaks is not installed") }
        let token = "ghp_" + UUID().uuidString.replacingOccurrences(of:"-",with:"") + "Ab9X"
        try "github_token = '\(token)'".write(to:folder.appendingPathComponent("fixture.txt"),atomically:true,encoding:.utf8)
        let result = try object(await AILocalTools(workspace:folder).call("scan_secrets",arguments:[:]))
        let output = result["output"] as? String ?? ""
        XCTAssertNotNil(result["exitCode"],String(describing:result))
        XCTAssertTrue(output.contains("github-pat"),String(describing:result))
        XCTAssertFalse(output.contains(token),"Reports must redact the complete credential")
        XCTAssertFalse((result["stderr"] as? String ?? "").contains(token))
    }
    func testInstalledSyftInventoriesSyntheticLockfileOffline() async throws {
        guard AILocalTools.executable("syft") != nil else { throw XCTSkip("Syft is not installed") }
        let lock = #"{"name":"search-fixture","version":"1.0.0","lockfileVersion":3,"packages":{"":{"name":"search-fixture","version":"1.0.0","dependencies":{"lodash":"4.17.21"}},"node_modules/lodash":{"version":"4.17.21"}}}"#
        try lock.write(to:folder.appendingPathComponent("package-lock.json"),atomically:true,encoding:.utf8)
        let result = try object(await AILocalTools(workspace:folder).call("inventory_components",arguments:[:]))
        XCTAssertEqual(result["exitCode"] as? Int,0,String(describing:result))
        XCTAssertTrue((result["output"] as? String ?? "").contains("lodash"))
    }
    func testInstalledGrypeUsesManagedOfflineDatabaseWithoutWorkspaceCopy() async throws {
        guard AILocalTools.executable("grype") != nil else { throw XCTSkip("Grype is not installed") }
        let tools = AILocalTools(workspace:folder)
        let status = try object(tools.status())
        guard (status["offlineDatabases"] as? [String:Bool])?["grype"] == true else { throw XCTSkip("Managed Grype database is absent") }
        let lock = #"{"name":"search-fixture","version":"1.0.0","lockfileVersion":3,"packages":{"":{"name":"search-fixture","version":"1.0.0","dependencies":{"lodash":"4.17.20"}},"node_modules/lodash":{"version":"4.17.20"}}}"#
        try lock.write(to:folder.appendingPathComponent("package-lock.json"),atomically:true,encoding:.utf8)
        let result = try object(await tools.call("scan_dependencies",arguments:["engine":"grype"]))
        XCTAssertEqual(result["exitCode"] as? Int,0,String(describing:result))
        XCTAssertTrue((result["output"] as? String ?? "").contains("lodash"))
        XCTAssertEqual(result["network"] as? String,"denied")
    }
    func testStructuralRewriteReturnsPreviewAndPreservesOriginalBytes() async throws {
        guard AILocalTools.executable("ast-grep") != nil else { throw XCTSkip("ast-grep is not installed") }
        let file = folder.appendingPathComponent("fixture.js"), original = "function fixture(input) { return eval(input); }\n"
        try original.write(to:file,atomically:true,encoding:.utf8)
        let result = try object(await AILocalTools(workspace:folder).call("rewrite_code",arguments:["pattern":"eval($X)","rewrite":"String($X)","language":"javascript"]))
        XCTAssertEqual(result["exitCode"] as? Int,0,String(describing:result))
        XCTAssertTrue((result["output"] as? String ?? "").contains("String(input)"))
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),original)
    }
    func testHARImportDoesNotFetchRecordedURLAndBoundsBody() async throws {
        let listener = socket(AF_INET,SOCK_STREAM,0)
        guard listener >= 0 else { return XCTFail("Could not create fixture listener") }
        defer { close(listener) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        XCTAssertEqual(withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(listener,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } },0)
        XCTAssertEqual(listen(listener,1),0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(withUnsafeMutablePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(listener,$0,&size) } },0)
        let recordedURL = "http://127.0.0.1:\(UInt16(bigEndian:address.sin_port))/recorded-only"
        let value: [String:Any] = ["log":["entries":[["request":["url":recordedURL,"method":"GET"],"response":["status":200,"content":["text":"captured-response-only"]]]]]]
        try JSONSerialization.data(withJSONObject:value).write(to:folder.appendingPathComponent("saved.har"))
        let result = try object(await AILocalTools(workspace:folder).call("inspect_network_capture",arguments:["path":"saved.har","bodyLimit":8]))
        let records = try XCTUnwrap(result["records"] as? [[String:Any]])
        XCTAssertEqual(records.first?["url"] as? String,recordedURL)
        XCTAssertEqual((records.first?["responseBody"] as? [String:Any])?["text"] as? String,"captured")
        XCTAssertEqual((records.first?["responseBody"] as? [String:Any])?["truncated"] as? Bool,true)
        XCTAssertEqual((result["sha256"] as? String)?.count,64)
        var pending = pollfd(fd:listener,events:Int16(POLLIN),revents:0)
        XCTAssertEqual(poll(&pending,1,0),0,"Reading a HAR must never contact recorded endpoints")
    }
    func testInstalledMitmproxyReadsSyntheticSavedFlowWithoutLiveProxy() async throws {
        guard let executable = AILocalTools.executable("mitmdump") else { throw XCTSkip("mitmdump is not installed") }
        let scratch = folder.appendingPathComponent("scratch",isDirectory:true)
        try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:false)
        let capture = scratch.appendingPathComponent("fixture.mitm"), generator = scratch.appendingPathComponent("generate.py")
        let pathLiteral = String(data:try JSONSerialization.data(withJSONObject:[capture.path],options:.withoutEscapingSlashes),encoding:.utf8)!
        let source = """
        from mitmproxy import connection,http,io,ctx
        flow=http.HTTPFlow(connection.Client(peername=('127.0.0.1',1234),sockname=('127.0.0.1',8080)),connection.Server(address=('recorded.invalid',443)))
        flow.request=http.Request.make('GET','https://recorded.invalid/saved')
        flow.response=http.Response.make(200,b'recorded-fixture-body',{'Content-Type':'text/plain'})
        with open(\(pathLiteral)[0],'wb') as file:io.FlowWriter(file).add(flow)
        def running():ctx.master.shutdown()
        """
        try source.write(to:generator,atomically:true,encoding:.utf8)
        let generated = try await AIToolProcess.run(executable:executable,arguments:["-n","-q","-s",generator.path],workspace:folder,scratch:scratch,timeout:15)
        XCTAssertEqual(generated.exitCode,0,generated.stderr)
        let result = try object(await AILocalTools(workspace:folder).call("inspect_network_capture",arguments:["path":"scratch/fixture.mitm","format":"mitmproxy"]))
        XCTAssertEqual(result["exitCode"] as? Int,0,String(describing:result))
        let records = try XCTUnwrap(result["records"] as? [[String:Any]])
        let response = try XCTUnwrap(records.first(where: { $0["url"] as? String == "https://recorded.invalid/saved" }))
        let encoded = try XCTUnwrap((response["responseBody"] as? [String:Any])?["base64"] as? String)
        XCTAssertEqual(Data(base64Encoded:encoded),Data("recorded-fixture-body".utf8))
        XCTAssertEqual(result["network"] as? String,"denied")
    }
    func testExplicitRegularPackageFileWorksForInventoryAndOfflineDependencyScan() async throws {
        guard AILocalTools.executable("syft") != nil else { throw XCTSkip("Syft is not installed") }
        let file = folder.appendingPathComponent("package-lock.json")
        let lock = #"{"name":"search-fixture","version":"1.0.0","lockfileVersion":3,"packages":{"":{"name":"search-fixture","version":"1.0.0","dependencies":{"lodash":"4.17.20"}},"node_modules/lodash":{"version":"4.17.20"}}}"#
        try lock.write(to:file,atomically:true,encoding:.utf8)
        let tools = AILocalTools(workspace:folder,target:file)
        let inventory = try object(await tools.call("inventory_components",arguments:[:]))
        XCTAssertEqual(inventory["exitCode"] as? Int,0,String(describing:inventory))
        XCTAssertTrue((inventory["output"] as? String ?? "").contains("lodash"))
        let status = try object(tools.status())
        if AILocalTools.executable("grype") != nil, (status["offlineDatabases"] as? [String:Bool])?["grype"] == true {
            let vulnerabilities = try object(await tools.call("scan_dependencies",arguments:["engine":"grype"]))
            XCTAssertEqual(vulnerabilities["exitCode"] as? Int,0,String(describing:vulnerabilities))
            XCTAssertTrue((vulnerabilities["output"] as? String ?? "").contains("lodash"))
        }
    }
}
