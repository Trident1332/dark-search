import Darwin
import Foundation

// A child-owned, offline alternative to Hopper's global AppleScript launcher.
// This file never chooses a running application, changes licensing, launches
// through LaunchServices, sends AppleEvents, evaluates AppleScript, or executes
// the target. Only the trusted Search host dispatches the fixed analysis event.
private struct LaunchFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
private func fail(_ message: String) throws -> Never { throw LaunchFailure(message: message) }
private func code(_ text: String) -> UInt32 { text.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
private func canonical(_ path: String) throws -> String {
    guard !path.contains("\0"), let pointer = realpath(path,nil) else { try fail("A selected analysis path is unavailable") }
    defer { free(pointer) }; return String(cString:pointer)
}
private func contains(_ root:String,_ path:String) -> Bool { path == root || path.hasPrefix(root + "/") }
private func regular(_ path:String) throws {
    var info=stat()
    guard lstat(path,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { try fail("The selected target or bridge must be a regular file with one link") }
}
private struct ParentIdentity {
    let pid:pid_t
    let uid:uid_t
    let startedSeconds:UInt64
    let startedMicroseconds:UInt64
    static func read(_ pid:pid_t) -> ParentIdentity? {
        var info=proc_bsdinfo()
        let size=Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid>1,proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,size) == size,
              info.pbi_pid == UInt32(pid) else { return nil }
        return ParentIdentity(pid:pid,uid:info.pbi_uid,startedSeconds:info.pbi_start_tvsec,startedMicroseconds:info.pbi_start_tvusec)
    }
    static func capture() throws -> ParentIdentity {
        guard let identity=read(getppid()),identity.uid == getuid() else { try fail("The analysis supervisor's process identity is unavailable") }
        return identity
    }
    func stillParent() -> Bool {
        guard getppid() == pid,let current=Self.read(pid) else { return false }
        return current.uid == uid && current.startedSeconds == startedSeconds && current.startedMicroseconds == startedMicroseconds
    }
}
private final class OwnedChild {
    let pid:pid_t
    private let lock=NSLock()
    private var reaped=false
    private var status:Int32=0
    private var signals:[DispatchSourceSignal]=[]
    private var parentWatchdog:DispatchSourceTimer?
    private let parent:ParentIdentity
    init(binary:String,environment:[String:String],scratch:String) throws {
        // Capture before spawning: loss or reuse of the MCP supervisor must
        // never leave its native parser alive after that supervisor disappears.
        parent=try ParentIdentity.capture()
        // This process already inherits Search's fixed analysis sandbox.
        // Direct spawning preserves that single sandbox, including IP, AE,
        // and LaunchServices denials; nested sandbox initialization is refused
        // by macOS. The trusted host alone sends the analysis event.
        let arguments=[binary]
        var actions:posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions,0,"/dev/null",O_RDONLY,0)
        posix_spawn_file_actions_addinherit_np(&actions,STDERR_FILENO)
        posix_spawn_file_actions_adddup2(&actions,STDERR_FILENO,STDOUT_FILENO)
        var attributes:posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Preserve the supervisor's owned process group for group cancellation.
        // The separate parent watchdog also handles supervisor death when no
        // cancellation signal reaches this helper.
        posix_spawnattr_setflags(&attributes,Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        // Hopper is a separate application, not an extension of Search's
        // privacy identity. Without this attribute macOS can identify the
        // AppleEvent recipient as Search itself. It changes neither ancestry,
        // process group nor the inherited analysis sandbox.
        typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>,Int32) -> Int32
        guard let symbol=dlsym(UnsafeMutableRawPointer(bitPattern:-2),"responsibility_spawnattrs_setdisclaim") else {
            try fail("macOS cannot establish Hopper's independent application identity; no analysis process was launched")
        }
        let disclaim=unsafeBitCast(symbol,to:Disclaim.self)
        let attributed=disclaim(&attributes,1)
        guard attributed == 0 else {
            try fail("macOS could not establish Hopper's independent application identity (\(attributed)); no analysis process was launched")
        }
        var argv=arguments.map { strdup($0) } + [nil]
        var env=environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for pointer in argv { free(pointer) };for pointer in env { free(pointer) } }
        var child:pid_t=0
        let result=posix_spawn(&child,binary,&actions,&attributes,&argv,&env)
        guard result == 0 else { try fail("The isolated Hopper process could not start (\(result))") }
        pid=child
        for number in [SIGTERM,SIGINT,SIGHUP] {
            signal(number,SIG_IGN)
            let source=DispatchSource.makeSignalSource(signal:number,queue:.global(qos:.utility))
            source.setEventHandler { [weak self] in self?.terminate() }
            source.resume(); signals.append(source)
        }
        let watchdog=DispatchSource.makeTimerSource(queue:.global(qos:.utility))
        watchdog.schedule(deadline:.now(),repeating:.milliseconds(250),leeway:.milliseconds(50))
        watchdog.setEventHandler { [weak self] in
            guard let self,!self.parent.stillParent() else { return }
            self.terminate()
            self.parentWatchdog?.cancel()
            FileHandle.standardError.write(Data("The analysis supervisor exited; the isolated Hopper child was stopped.\n".utf8))
        }
        parentWatchdog=watchdog
        watchdog.resume()
    }
    // Until reaped, this PID cannot be reused. Every send checks this state.
    func running() -> Bool {
        lock.lock();defer { lock.unlock() }
        guard !reaped else { return false }
        let result=waitpid(pid,&status,WNOHANG)
        if result == pid { reaped=true;return false }
        if result < 0 && errno != EINTR { reaped=true;status=127<<8;return false }
        return result == 0 || (result < 0 && errno == EINTR)
    }
    func matches(_ executable:String) -> Bool {
        guard running() else { return false }
        var buffer=[CChar](repeating:0,count:4*Int(MAXPATHLEN))
        let count=proc_pidpath(pid,&buffer,UInt32(buffer.count))
        return count > 0 && String(cString:buffer) == executable
    }
    func terminate() {
        lock.lock()
        if !reaped { _ = kill(pid,SIGKILL) }
        lock.unlock()
    }
    func wait() -> Int32 {
        while running() { Thread.sleep(forTimeInterval:0.05) }
        return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }
    deinit { parentWatchdog?.cancel();terminate();for source in signals { source.cancel() } }
}

private func relayAnalysis(_ request:[String:Any],socketPath:String,child:OwnedChild) throws {
    var data=try JSONSerialization.data(withJSONObject:request,options:[.sortedKeys])
    guard data.count<=16_384 else { try fail("The fixed Hopper analysis request is too large") }
    data.append(10)
    let descriptor=socket(AF_UNIX,SOCK_STREAM,0)
    guard descriptor>=0 else { try fail("Search's private Hopper control connection is unavailable") }
    defer { close(descriptor) }
    var noSignal:Int32=1
    guard setsockopt(descriptor,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout<Int32>.size)) == 0,
          fcntl(descriptor,F_SETFL,O_NONBLOCK) == 0 else { try fail("Search's private Hopper control connection could not be configured") }
    var address=sockaddr_un()
    address.sun_family=sa_family_t(AF_UNIX)
    let bytes=Array(socketPath.utf8)+[0]
    guard bytes.count<=MemoryLayout.size(ofValue:address.sun_path) else { try fail("Search's Hopper control socket path is too long") }
    withUnsafeMutableBytes(of:&address.sun_path) { destination in destination.copyBytes(from:bytes) }
    let addressSize=socklen_t(MemoryLayout<sockaddr_un>.size)
    address.sun_len=UInt8(addressSize)
    let connection=withUnsafePointer(to:&address) { pointer in
        pointer.withMemoryRebound(to:sockaddr.self,capacity:1) { connect(descriptor,$0,addressSize) }
    }
    guard connection == 0 || errno == EINPROGRESS || errno == EAGAIN else { try fail("Search's private Hopper control host is unavailable") }
    let deadline=Date().addingTimeInterval(120)
    func ready(_ events:Int16) throws {
        while Date()<deadline {
            guard child.running() else { try fail("The owned Hopper process stopped before Search completed its analysis request") }
            var item=pollfd(fd:descriptor,events:events,revents:0)
            let result=poll(&item,1,200)
            if result<0 { if errno == EINTR { continue };try fail("Search's Hopper control connection failed") }
            if result>0 {
                guard item.revents & Int16(POLLERR|POLLNVAL) == 0 else { try fail("Search's Hopper control connection was closed") }
                if item.revents & (events|Int16(POLLHUP)) != 0 { return }
            }
        }
        try fail("Search's Hopper analysis authorization timed out; no unsandboxed fallback was used")
    }
    try ready(Int16(POLLOUT))
    var connectionError:Int32=0
    var errorSize=socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(descriptor,SOL_SOCKET,SO_ERROR,&connectionError,&errorSize) == 0,connectionError == 0 else { try fail("Search's private Hopper control host did not accept the connection") }
    var peerUID:uid_t=0,peerGID:gid_t=0
    guard getpeereid(descriptor,&peerUID,&peerGID) == 0,peerUID == getuid() else { try fail("Search's Hopper control host has an invalid user identity") }
    var offset=0
    while offset<data.count {
        try ready(Int16(POLLOUT))
        let count=data.withUnsafeBytes { send(descriptor,$0.baseAddress!.advanced(by:offset),data.count-offset,0) }
        if count>0 { offset += count }
        else if count<0 && (errno == EINTR || errno == EAGAIN) { continue }
        else { try fail("The fixed Hopper analysis request could not be sent to Search") }
    }
    var received=Data(),buffer=[UInt8](repeating:0,count:2048)
    while !received.contains(10) {
        try ready(Int16(POLLIN))
        let count=recv(descriptor,&buffer,buffer.count,0)
        if count>0 { received.append(contentsOf:buffer.prefix(count)) }
        else if count<0 && (errno == EINTR || errno == EAGAIN) { continue }
        else { try fail("Search closed the Hopper control connection before returning an analysis result") }
        guard received.count<=8192 else { try fail("Search returned an oversized Hopper control response") }
    }
    let line=received.prefix { $0 != 10 }
    guard let reply=try JSONSerialization.jsonObject(with:line) as? [String:Any],reply["version"] as? Int == 1,
          let accepted=reply["ok"] as? Bool else { try fail("Search returned an invalid Hopper control response") }
    guard accepted else { try fail(String((reply["error"] as? String ?? "Search could not authorize the isolated Hopper analysis request").prefix(2000))) }
}

private func launch() throws -> Int32 {
    let environment=ProcessInfo.processInfo.environment
    guard environment["SEARCH_HOPPER_ISOLATED"] == "1",
          let application=environment["SEARCH_HOPPER_APPLICATION"],
          let selectedWorkspace=environment["SEARCH_HOPPER_WORKSPACE"],
          let selectedScratch=environment["TMPDIR"],
          let controlSocket=environment["SEARCH_HOPPER_CONTROL_SOCKET"],
          let controlToken=environment["SEARCH_HOPPER_CONTROL_TOKEN"] else { try fail("Search's host-selected isolated Hopper configuration is missing") }
    let workspace=try canonical(selectedWorkspace),scratch=try canonical(selectedScratch)
    var scratchInfo=stat()
    guard lstat(scratch,&scratchInfo) == 0,scratchInfo.st_mode & S_IFMT == S_IFDIR,scratchInfo.st_uid == getuid(),scratchInfo.st_mode & 0o077 == 0 else { try fail("Hopper's scratch directory must be private and owned by this user") }
    let socketPath=try canonical(controlSocket)
    var socketInfo=stat()
    guard URL(fileURLWithPath:socketPath).deletingLastPathComponent().path == scratch,
          URL(fileURLWithPath:socketPath).lastPathComponent == "hopper-events.sock",
          socketPath.utf8.count<104,lstat(socketPath,&socketInfo) == 0,
          socketInfo.st_mode & S_IFMT == S_IFSOCK,socketInfo.st_uid == getuid(),socketInfo.st_mode & 0o077 == 0,
          controlToken.utf8.count == 64,controlToken.utf8.allSatisfy({ (48...57).contains($0)||(97...102).contains($0) }) else { try fail("Search's host-selected Hopper control channel is invalid") }
    let app=try canonical(application)
    let infoURL=URL(fileURLWithPath:app).appendingPathComponent("Contents/Info.plist")
    guard app.hasSuffix("/Hopper Disassembler.app"),
          let info=try PropertyListSerialization.propertyList(from:Data(contentsOf:infoURL),format:nil) as? [String:Any],
          info["CFBundleIdentifier"] as? String == "com.cryptic-apps.hopper-web-4" else { try fail("The host-selected application is not Hopper") }
    let binary=try canonical(app + "/Contents/MacOS/Hopper Disassembler")
    guard contains(app,binary),FileManager.default.isExecutableFile(atPath:binary) else { try fail("Hopper's installed executable is unavailable") }
    var target:String?,script:String?,analysis=false,loaders:[String]=[],architecture:String?
    let arguments=Array(CommandLine.arguments.dropFirst());var index=0
    while index < arguments.count {
        switch arguments[index] {
        case "--analysis","-a":analysis=true
        case "-Y","--python":index += 1;guard index<arguments.count else { try fail("Missing bridge script") };script=arguments[index]
        case "-e","--executable":index += 1;guard index<arguments.count else { try fail("Missing native target") };target=arguments[index]
        case "-l","--loader":index += 1;guard index<arguments.count,["Mach-O","FAT","ELF","WinPE"].contains(arguments[index]) else { try fail("Unsupported native loader") };loaders.append(arguments[index])
        case "--intel-32","--intel-64","--armv7","--aarch64":guard architecture == nil else { try fail("Duplicate architecture option") };architecture=arguments[index]
        default:try fail("This isolated Hopper launcher does not support this loader option or database workflow")
        }
        index += 1
    }
    guard let target,let script else { try fail("Missing native target or bridge script") }
    let targetPath=try canonical(target),scriptPath=try canonical(script)
    guard contains(workspace,targetPath)||contains(scratch,targetPath),contains(scratch,scriptPath),scriptPath.hasSuffix(".py") else { try fail("Native target and bridge are outside their selected workspace/scratch") }
    try regular(targetPath);try regular(scriptPath)
    guard loaders.count<=2 else { try fail("Too many native loader stages") }
    let child=try OwnedChild(binary:binary,environment:environment,scratch:scratch)
    defer { child.terminate();_ = child.wait() }
    let deadline=Date().addingTimeInterval(20)
    while child.running(),!child.matches(binary),Date()<deadline { Thread.sleep(forTimeInterval:0.05) }
    guard child.matches(binary) else {
        let reason=child.running() ? "startup identity could not be confirmed before the timeout" : "owned process exited with code \(child.wait()) before startup identity was confirmed"
        try fail("Hopper startup failed: \(reason). No analysis was completed.")
    }
    guard let identity=ParentIdentity.read(child.pid),identity.uid == getuid() else { try fail("The owned Hopper process identity is unavailable") }
    var request:[String:Any]=["version":1,"token":controlToken,"helperPID":getpid(),"hopperPID":child.pid,
        "hopperStartedSec":identity.startedSeconds,"hopperStartedUsec":identity.startedMicroseconds,
        "targetPath":targetPath,"bridgePath":scriptPath,"analysis":analysis,"loaders":loaders]
    if let architecture { request["architecture"]=architecture }
    try relayAnalysis(request,socketPath:socketPath,child:child)
    return child.wait()
}

do { exit(try launch()) }
catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8));exit(1) }
