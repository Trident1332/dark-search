import XCTest
import Darwin
@testable import Search

final class AIToolProcessTests: XCTestCase {
    private var workspace: URL!
    private var scratch: URL!
    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("SearchToolRunnerTests-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:false)
        workspace = try AIToolProcess.canonicalURL(workspace)
        scratch = workspace.appendingPathComponent("scratch",isDirectory:true)
        try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at:workspace) }
    private func run(_ arguments: [String], timeout: TimeInterval = 3, maximum: Int = 30_000) async throws -> AIToolProcess.Result {
        try await AIToolProcess.run(executable:URL(fileURLWithPath:"/bin/sh"),arguments:arguments,workspace:workspace,scratch:scratch,timeout:timeout,maxBytes:maximum)
    }
    private final class HopperProfileFixture {
        let scratch:URL
        let socket:URL
        let descriptor:Int32
        let environment:[String:String]
        init(workspace:URL) throws {
            let files=FileManager.default,home=files.homeDirectoryForCurrentUser
            let helpers=[Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/search-hopper-offline-launcher"),home.appendingPathComponent("Library/Application Support/Search/Tools/rea/search-hopper-offline-launcher")]
            let applications=[home.appendingPathComponent("Applications/Hopper Disassembler.app"),URL(fileURLWithPath:"/Applications/Hopper Disassembler.app")]
            guard let helper=helpers.first(where:{files.isExecutableFile(atPath:$0.path)}),let application=applications.first(where:{files.fileExists(atPath:$0.path)}) else { throw XCTSkip("The optional managed Hopper backend is not installed") }
            let directory=URL(fileURLWithPath:"/private/tmp/search-hopper-profile-\(UUID().uuidString.prefix(8))",isDirectory:true)
            try files.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            let socketURL=directory.appendingPathComponent("hopper-events.sock")
            let fd=Darwin.socket(AF_UNIX,SOCK_STREAM,0)
            guard fd >= 0 else { try? files.removeItem(at:directory);throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
            var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX);address.sun_len=UInt8(MemoryLayout<sockaddr_un>.size)
            let bytes=Array(socketURL.path.utf8)+[0]
            guard bytes.count <= MemoryLayout.size(ofValue:address.sun_path) else { close(fd);try? files.removeItem(at:directory);throw NSError(domain:NSPOSIXErrorDomain,code:Int(ENAMETOOLONG)) }
            withUnsafeMutableBytes(of:&address.sun_path) { $0.copyBytes(from:bytes) }
            let status=withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard status == 0,chmod(socketURL.path,0o600) == 0,listen(fd,2) == 0 else { close(fd);try? files.removeItem(at:directory);throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
            scratch=directory;socket=socketURL;descriptor=fd
            environment=["SEARCH_HOPPER_ISOLATED":"1","SEARCH_HOPPER_APPLICATION":application.path,"SEARCH_HOPPER_WORKSPACE":workspace.path,
                "HOPPER_LAUNCHER_PATH":helper.path,"SEARCH_HOPPER_CONTROL_SOCKET":socket.path,"SEARCH_HOPPER_CONTROL_TOKEN":String(repeating:"a",count:64)]
        }
        deinit { close(descriptor);try? FileManager.default.removeItem(at:scratch) }
    }
    private func ghidraEnvironment(scratch: URL) throws -> [String: String] {
        let files = FileManager.default, home = files.homeDirectoryForCurrentUser
        let installations = [home.appendingPathComponent("Applications/ghidra_12.1.4_PUBLIC"), URL(fileURLWithPath: "/Applications/ghidra_12.1.4_PUBLIC")]
        let javaHomes = ["/opt/homebrew", "/usr/local"].flatMap { prefix in
            ["openjdk", "openjdk@26"].map { URL(fileURLWithPath: "\(prefix)/opt/\($0)/libexec/openjdk.jdk/Contents/Home") }
        }
        guard let installation = installations.first(where: { files.isExecutableFile(atPath: $0.appendingPathComponent("support/analyzeHeadless").path) }),
              let javaHome = javaHomes.first(where: { files.isExecutableFile(atPath: $0.appendingPathComponent("bin/java").path) })
        else { throw XCTSkip("The optional pinned Ghidra/JDK runtime is not installed") }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.path)
        return ["REA_ANALYSIS_PROVIDER": "ghidra", "SEARCH_GHIDRA_ISOLATED": "1", "SEARCH_GHIDRA_WORKSPACE": workspace.path,
                "GHIDRA_INSTALL_DIR": installation.path, "JAVA_HOME": javaHome.path]
    }
    func testReadsSelectionButDeniesPrivateSiblingAndWritesOutsideScratch() async throws {
        let outside = workspace.deletingLastPathComponent().appendingPathComponent("SearchToolPrivate-\(UUID().uuidString).txt")
        try "private-fixture-value".write(to:outside,atomically:true,encoding:.utf8)
        defer { try? FileManager.default.removeItem(at:outside) }
        let inside = workspace.appendingPathComponent("selected.txt")
        try "selected-fixture-value".write(to:inside,atomically:true,encoding:.utf8)
        let allowed = try await AIToolProcess.run(executable:URL(fileURLWithPath:"/bin/cat"),arguments:[inside.path],workspace:workspace,scratch:scratch)
        XCTAssertEqual(allowed.exitCode,0,allowed.stderr)
        XCTAssertEqual(allowed.output,"selected-fixture-value")
        let blocked = try await AIToolProcess.run(executable:URL(fileURLWithPath:"/bin/cat"),arguments:[outside.path],workspace:workspace,scratch:scratch)
        XCTAssertNotEqual(blocked.exitCode,0)
        XCTAssertFalse(blocked.output.contains("private-fixture-value"))
        let deniedWrite = try await run(["-c","printf denied > selected.txt"])
        XCTAssertNotEqual(deniedWrite.exitCode,0)
        XCTAssertEqual(try String(contentsOf:inside,encoding:.utf8),"selected-fixture-value")
        let scratchWrite = try await run(["-c","printf allowed > scratch/result.txt"])
        XCTAssertEqual(scratchWrite.exitCode,0,scratchWrite.stderr)
        XCTAssertEqual(try String(contentsOf:scratch.appendingPathComponent("result.txt"),encoding:.utf8),"allowed")
    }
    func testInheritedEnvironmentAndUnsupportedOverridesCannotReachTools() async throws {
        let result = try await AIToolProcess.run(executable:URL(fileURLWithPath:"/usr/bin/env"),arguments:[],workspace:workspace,scratch:scratch)
        XCTAssertEqual(result.exitCode,0,result.stderr)
        XCTAssertFalse(result.output.contains("SSH_AUTH_SOCK="))
        XCTAssertFalse(result.output.contains("OPENAI_API_KEY="))
        XCTAssertFalse(result.output.contains("HTTP_PROXY="))
        XCTAssertTrue(result.output.contains("HOME=\(scratch.path)"))
        XCTAssertThrowsError(try AIToolProcess.launchPlan(executable:URL(fileURLWithPath:"/usr/bin/env"),arguments:[],workspace:workspace,scratch:scratch,environment:["NODE_OPTIONS":"--require /private/file.js"]))
        XCTAssertThrowsError(try AIToolProcess.launchPlan(executable:URL(fileURLWithPath:"/usr/bin/env"),arguments:[],workspace:workspace,scratch:scratch,environment:[
            "SEARCH_HOPPER_ISOLATED":"1","SEARCH_HOPPER_WORKSPACE":workspace.path,
            "SEARCH_HOPPER_APPLICATION":workspace.appendingPathComponent("Invented.app").path,
            "HOPPER_LAUNCHER_PATH":workspace.appendingPathComponent("invented-helper").path
        ]),"An arbitrary tool must not opt itself into Hopper's private IPC permissions")
    }
    func testLiveLoopbackConnectionIsDenied() async throws {
        let listener = socket(AF_INET,SOCK_STREAM,0)
        XCTAssertGreaterThanOrEqual(listener,0)
        guard listener >= 0 else { return }
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(listener,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(bound,0); XCTAssertEqual(listen(listener,1),0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(withUnsafeMutablePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(listener,$0,&size) } },0)
        let port = UInt16(bigEndian:address.sin_port)
        let result = try await AIToolProcess.run(executable:URL(fileURLWithPath:"/usr/bin/curl"),arguments:["--silent","--show-error","--max-time","1","http://127.0.0.1:\(port)/"],workspace:workspace,scratch:scratch,timeout:3)
        XCTAssertNotEqual(result.exitCode,0)
        var waiting = pollfd(fd:listener,events:Int16(POLLIN),revents:0)
        XCTAssertEqual(poll(&waiting,1,0),0,"The sandboxed tool must not reach even an accepting local socket")
    }
    func testOutputLimitTerminatesProducer() async throws {
        do {
            _ = try await run(["-c","while :; do printf 012345678901234567890123456789; done"],timeout:3,maximum:1024)
            XCTFail("Unbounded output must be stopped")
        } catch { XCTAssertTrue(error.localizedDescription.contains("output limit"),error.localizedDescription) }
    }
    func testTimeoutAndCancellationStopOwnedProcessGroup() async throws {
        do {
            _ = try await run(["-c","sleep 10"],timeout:0.2)
            XCTFail("Long-running tool should time out")
        } catch { XCTAssertTrue(error.localizedDescription.contains("time limit"),error.localizedDescription) }
        let task = Task { try await run(["-c","sleep 10"],timeout:20) }
        try await Task.sleep(nanoseconds:100_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled tool must stop") }
        catch { XCTAssertTrue(error is CancellationError || error.localizedDescription.contains("cancelled")) }
    }
    func testSandboxProfileHasNoNetworkExceptionAndCannotBeEscapedByQuotedPath() throws {
        let weird = workspace.appendingPathComponent("quoted-\"-directory",isDirectory:true)
        try FileManager.default.createDirectory(at:weird,withIntermediateDirectories:false)
        let plan = try AIToolProcess.launchPlan(executable:URL(fileURLWithPath:"/usr/bin/true"),arguments:[],workspace:weird,scratch:scratch)
        XCTAssertEqual(plan.executable.path,"/usr/bin/sandbox-exec")
        XCTAssertTrue(plan.arguments[1].contains("(deny network*)"))
        XCTAssertFalse(plan.arguments[1].contains("(allow network"))
        XCTAssertTrue(plan.arguments[1].contains("quoted-\\\"-directory"))
    }
    func testHopperProfileDeniesChildAppleEventsAndRejectsInvalidControlChannels() throws {
        let fixture=try HopperProfileFixture(workspace:workspace)
        let plan=try AIToolProcess.launchPlan(executable:URL(fileURLWithPath:"/usr/bin/true"),arguments:[],workspace:workspace,scratch:fixture.scratch,environment:fixture.environment)
        let profile=plan.arguments[1]
        XCTAssertTrue(profile.contains("(deny appleevent-send)"))
        XCTAssertFalse(profile.contains("(allow appleevent-send"))
        XCTAssertTrue(profile.contains("(deny lsopen)"))
        XCTAssertTrue(profile.contains("(deny network*)"))
        XCTAssertFalse(profile.contains("network-outbound (remote ip"))
        XCTAssertFalse(profile.contains(fixture.environment["SEARCH_HOPPER_CONTROL_TOKEN"]!))
        var invalid=fixture.environment;invalid["SEARCH_HOPPER_CONTROL_TOKEN"]=String(repeating:"z",count:64)
        XCTAssertThrowsError(try AIToolProcess.launchPlan(executable:URL(fileURLWithPath:"/usr/bin/true"),arguments:[],workspace:workspace,scratch:fixture.scratch,environment:invalid))
        invalid=fixture.environment;invalid["SEARCH_HOPPER_CONTROL_SOCKET"]=workspace.appendingPathComponent("hopper-events.sock").path
        XCTAssertThrowsError(try AIToolProcess.launchPlan(executable:URL(fileURLWithPath:"/usr/bin/true"),arguments:[],workspace:workspace,scratch:fixture.scratch,environment:invalid))
        invalid=fixture.environment;invalid.removeValue(forKey:"SEARCH_HOPPER_ISOLATED")
        XCTAssertThrowsError(try AIToolProcess.launchPlan(executable:URL(fileURLWithPath:"/usr/bin/true"),arguments:[],workspace:workspace,scratch:fixture.scratch,environment:invalid))
    }
    func testHopperPrivateUnixGrantDoesNotAllowIPOrWorkspaceWrites() async throws {
        let fixture=try HopperProfileFixture(workspace:workspace)
        let unix=try await AIToolProcess.run(executable:URL(fileURLWithPath:"/usr/bin/nc"),arguments:["-U","-w","1",fixture.socket.path],workspace:workspace,scratch:fixture.scratch,timeout:3,environment:fixture.environment)
        XCTAssertEqual(unix.exitCode,0,unix.stderr)
        var unixPending=pollfd(fd:fixture.descriptor,events:Int16(POLLIN),revents:0)
        XCTAssertGreaterThan(poll(&unixPending,1,0),0,"The only network exception must reach the private Unix control socket")
        let selected=workspace.appendingPathComponent("selected.txt")
        try "original".write(to:selected,atomically:true,encoding:.utf8)
        let write=try await AIToolProcess.run(executable:URL(fileURLWithPath:"/bin/sh"),arguments:["-c","printf replaced > selected.txt"],workspace:workspace,scratch:fixture.scratch,environment:fixture.environment)
        XCTAssertNotEqual(write.exitCode,0)
        XCTAssertEqual(try String(contentsOf:selected,encoding:.utf8),"original")
        let outside=workspace.deletingLastPathComponent().appendingPathComponent("SearchHopperPrivate-\(UUID().uuidString).txt")
        try "outside-private-fixture".write(to:outside,atomically:true,encoding:.utf8)
        defer { try? FileManager.default.removeItem(at:outside) }
        let read=try await AIToolProcess.run(executable:URL(fileURLWithPath:"/bin/cat"),arguments:[outside.path],workspace:workspace,scratch:fixture.scratch,environment:fixture.environment)
        XCTAssertNotEqual(read.exitCode,0)
        XCTAssertFalse(read.output.contains("outside-private-fixture"))
        let listener=Darwin.socket(AF_INET,SOCK_STREAM,0)
        guard listener >= 0 else { return XCTFail("Could not create fixture socket") }
        defer { close(listener) }
        var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_addr.s_addr=inet_addr("127.0.0.1")
        XCTAssertEqual(withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(listener,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } },0)
        XCTAssertEqual(listen(listener,1),0)
        var size=socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(withUnsafeMutablePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(listener,$0,&size) } },0)
        let blocked=try await AIToolProcess.run(executable:URL(fileURLWithPath:"/usr/bin/curl"),arguments:["--silent","--show-error","--max-time","1","http://127.0.0.1:\(UInt16(bigEndian:address.sin_port))/"],workspace:workspace,scratch:fixture.scratch,timeout:3,environment:fixture.environment)
        XCTAssertNotEqual(blocked.exitCode,0)
        var pending=pollfd(fd:listener,events:Int16(POLLIN),revents:0)
        XCTAssertEqual(poll(&pending,1,0),0,"Private Unix access must never become IP access")
    }
    func testGhidraContextPinsRuntimesAndPrivateJVMSettings() throws {
        let environment = try ghidraEnvironment(scratch: scratch)
        let plan = try AIToolProcess.launchPlan(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], workspace: workspace, scratch: scratch, environment: environment)
        let profile = plan.arguments[1]
        XCTAssertTrue(profile.contains("(deny network*)"))
        XCTAssertTrue(profile.contains("(deny appleevent-send)"))
        XCTAssertTrue(profile.contains("(deny lsopen)"))
        XCTAssertFalse(profile.contains("mach-lookup"))
        XCTAssertFalse(profile.contains("(allow appleevent-send"))
        XCTAssertFalse(profile.contains("(subpath \"\(FileManager.default.homeDirectoryForCurrentUser.path)\")"))
        XCTAssertTrue(profile.contains(try AIToolProcess.canonicalURL(URL(fileURLWithPath: environment["GHIDRA_INSTALL_DIR"]!)).path))
        XCTAssertEqual(plan.environment["HOME"], scratch.path)
        XCTAssertEqual(plan.environment["TMPDIR"], scratch.path + "/")
        XCTAssertTrue(plan.environment["JAVA_TOOL_OPTIONS"]!.contains("-Duser.home=\(scratch.path)"))
        XCTAssertTrue(plan.environment["JAVA_TOOL_OPTIONS"]!.contains("-Djava.io.tmpdir=\(scratch.path)"))
        XCTAssertTrue(plan.environment["JAVA_TOOL_OPTIONS"]!.contains("-Djava.util.prefs.userRoot=\(scratch.path)/java-prefs"))
        for change: [String: String] in [
            ["GHIDRA_INSTALL_DIR": workspace.path], ["JAVA_HOME": "/usr/bin"],
            ["SEARCH_GHIDRA_WORKSPACE": workspace.deletingLastPathComponent().path],
            ["SEARCH_GHIDRA_ISOLATED": "0"], ["REA_ANALYSIS_PROVIDER": "auto"],
            ["HOPPER_LAUNCHER_PATH": "/bin/true"], ["JAVA_TOOL_OPTIONS": "-javaagent:/private/arbitrary.jar"]
        ] {
            let invalid = environment.merging(change) { _, new in new }
            XCTAssertThrowsError(try AIToolProcess.launchPlan(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], workspace: workspace, scratch: scratch, environment: invalid))
        }
        XCTAssertThrowsError(try AIToolProcess.launchPlan(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], workspace: workspace, scratch: scratch, environment: ["JAVA_HOME": environment["JAVA_HOME"]!]))
        XCTAssertThrowsError(try AIToolProcess.launchPlan(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], workspace: workspace, scratch: scratch, environment: ["REA_GHIDRA_INSTALL_DIR": environment["GHIDRA_INSTALL_DIR"]!]))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratch.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.path) }
        XCTAssertThrowsError(try AIToolProcess.launchPlan(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], workspace: workspace, scratch: scratch, environment: environment))
    }
    func testGhidraPrivateUnixAccessPreservesKernelIPAndFileIsolation() async throws {
        let files = FileManager.default
        let directory = URL(fileURLWithPath: "/private/tmp/search-ghidra-profile-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        let environment = try ghidraEnvironment(scratch: directory)
        let socketURL = directory.appendingPathComponent("bridge.sock")
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return XCTFail("Could not create private Unix fixture") }
        defer { close(descriptor) }
        var unixAddress = sockaddr_un(); unixAddress.sun_family = sa_family_t(AF_UNIX); unixAddress.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(socketURL.path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: unixAddress.sun_path) else { return XCTFail("Private fixture socket path is too long") }
        withUnsafeMutableBytes(of: &unixAddress.sun_path) { $0.copyBytes(from: bytes) }
        XCTAssertEqual(withUnsafePointer(to: &unixAddress) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }, 0)
        XCTAssertEqual(listen(descriptor, 2), 0)
        let unix = try await AIToolProcess.run(executable: URL(fileURLWithPath: "/usr/bin/nc"), arguments: ["-U", "-w", "1", socketURL.path], workspace: workspace, scratch: directory, timeout: 3, environment: environment)
        XCTAssertEqual(unix.exitCode, 0, unix.stderr)
        var unixPending = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        XCTAssertGreaterThan(poll(&unixPending, 1, 0), 0)
        let inside = workspace.appendingPathComponent("ghidra-selected.txt")
        try "original".write(to: inside, atomically: true, encoding: .utf8)
        let write = try await AIToolProcess.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf changed > ghidra-selected.txt"], workspace: workspace, scratch: directory, environment: environment)
        XCTAssertNotEqual(write.exitCode, 0)
        XCTAssertEqual(try String(contentsOf: inside, encoding: .utf8), "original")
        let outside = workspace.deletingLastPathComponent().appendingPathComponent("SearchGhidraPrivate-\(UUID().uuidString).txt")
        try "private-ghidra-fixture".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? files.removeItem(at: outside) }
        let read = try await AIToolProcess.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [outside.path], workspace: workspace, scratch: directory, environment: environment)
        XCTAssertNotEqual(read.exitCode, 0)
        XCTAssertFalse(read.output.contains("private-ghidra-fixture"))
        let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { return XCTFail("Could not create IP fixture") }
        defer { close(listener) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &size) } }, 0)
        let blocked = try await AIToolProcess.run(executable: URL(fileURLWithPath: "/usr/bin/curl"), arguments: ["--silent", "--show-error", "--max-time", "1", "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/"], workspace: workspace, scratch: directory, timeout: 3, environment: environment)
        XCTAssertNotEqual(blocked.exitCode, 0)
        var pending = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&pending, 1, 0), 0, "Ghidra's private IPC must never allow an IP connection")
    }
    func testOwnedDetachedDescendantIsStoppedAndUnrelatedProcessSurvives() async throws {
        let marker = workspace.appendingPathComponent("child-pid.txt")
        let script = "import subprocess,pathlib,sys,time\nchild=subprocess.Popen(['/bin/sleep','20'],start_new_session=True)\npathlib.Path(sys.argv[1]).write_text(str(child.pid))\nwhile True:time.sleep(0.1)\n"
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions);posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions);posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setpgroup(&attributes,0)
        posix_spawnattr_setflags(&attributes,Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        for fd in [STDIN_FILENO,STDOUT_FILENO,STDERR_FILENO] { posix_spawn_file_actions_addopen(&actions,fd,"/dev/null",fd == STDIN_FILENO ? O_RDONLY : O_WRONLY,0) }
        let arguments: [String] = ["/usr/bin/python3","-c",script,marker.path]
        let environmentStrings: [String] = ["PATH=/usr/bin:/bin","HOME=\(scratch.path)","PYTHONDONTWRITEBYTECODE=1"]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { value in value.withCString { strdup($0) } } + [nil]
        var environment: [UnsafeMutablePointer<CChar>?] = environmentStrings.map { value in value.withCString { strdup($0) } } + [nil]
        defer { argv.forEach { free($0) };environment.forEach { free($0) } }
        var pid:pid_t = 0
        XCTAssertEqual(posix_spawn(&pid,"/usr/bin/python3",&actions,&attributes,&argv,&environment),0)
        guard pid > 0 else { return }
        var identities = [AIChildProcesses.Identity]()
        var rootReaped = false
        defer {
            if !rootReaped { kill(-pid,SIGKILL) }
            for child in identities where AIChildProcesses.matches(child) { kill(child.pid,SIGKILL) }
            if !rootReaped { var status:Int32=0;_ = waitpid(pid,&status,0) }
        }
        let root = try XCTUnwrap(AIChildProcesses.captureRoot(pid))
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !FileManager.default.fileExists(atPath:marker.path),ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds:20_000_000) }
        let childPID = try XCTUnwrap(Int32(try String(contentsOf:marker,encoding:.utf8)))
        identities = AIChildProcesses.descendants(of:root)
        XCTAssertTrue(identities.contains(where:{$0.pid == childPID}))
        XCTAssertNotEqual(getpgid(childPID),pid,"The fixture must escape the server process group to exercise descendant cleanup")
        let unrelated = Process();unrelated.executableURL=URL(fileURLWithPath:"/bin/sleep");unrelated.arguments=["20"]
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate();unrelated.waitUntilExit() } }
        XCTAssertFalse(identities.contains(where:{$0.pid == unrelated.processIdentifier}))
        await AIChildProcesses.stopAndWait(root:root,descendants:identities,grace:0.1)
        var status:Int32=0;_ = waitpid(pid,&status,0);rootReaped=true
        let cleaned = ProcessInfo.processInfo.systemUptime + 2
        while identities.contains(where:AIChildProcesses.matches),ProcessInfo.processInfo.systemUptime < cleaned { try await Task.sleep(nanoseconds:20_000_000) }
        XCTAssertFalse(AIChildProcesses.matches(root))
        XCTAssertFalse(identities.contains(where:AIChildProcesses.matches))
        XCTAssertTrue(unrelated.isRunning,"Stopping a tool must never kill an external selected Frida target or other sibling")
    }
}
