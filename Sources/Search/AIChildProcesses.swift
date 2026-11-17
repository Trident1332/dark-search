import Foundation
import Darwin

/// Host-side lifecycle accounting. A PID alone is never authority to signal a
/// process; every send checks the captured user and kernel start time again.
enum AIChildProcesses {
    struct Identity: Hashable, Sendable {
        let pid: pid_t
        let startedSeconds: UInt64
        let startedMicroseconds: UInt64
        let user: uid_t
        fileprivate init(pid:pid_t,startedSeconds:UInt64,startedMicroseconds:UInt64,user:uid_t) {
            self.pid=pid;self.startedSeconds=startedSeconds;self.startedMicroseconds=startedMicroseconds;self.user=user
        }
    }
    private struct Information {
        let identity: Identity
        let parent: pid_t
        let group: pid_t
    }
    private static func information(_ pid: pid_t) -> Information? {
        guard pid > 1, pid != getpid() else { return nil }
        var value = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, Int32(size)) == Int32(size),
              value.pbi_uid == getuid(), value.pbi_pid == UInt32(pid) else { return nil }
        return Information(identity:Identity(pid:pid,startedSeconds:value.pbi_start_tvsec,
            startedMicroseconds:value.pbi_start_tvusec,user:value.pbi_uid), parent:pid_t(value.pbi_ppid),group:pid_t(value.pbi_pgid))
    }
    /// Capture immediately after a successful SETPGROUP spawn, before starting
    /// the background waiter. External selected Frida targets cannot enter here.
    static func captureRoot(_ pid: pid_t) -> Identity? {
        guard let value = information(pid), value.parent == getpid(), value.group == pid else { return nil }
        return value.identity
    }
    static func matches(_ identity: Identity) -> Bool { information(identity.pid)?.identity == identity }
    static func descendants(of root: Identity, maximum: Int = 512) -> [Identity] {
        guard matches(root) else { return [] }
        let maximum = min(1024,max(1,maximum))
        var result = [Identity](), queue = [root], visited: Set<pid_t> = [root.pid]
        var index = 0
        while index < queue.count && result.count < maximum {
            let parent = queue[index]; index += 1
            guard matches(parent) else { continue }
            var children = [pid_t](repeating:0,count:maximum)
            // libproc returns a count of PIDs, not a byte count.
            let count = proc_listchildpids(parent.pid,&children,Int32(children.count * MemoryLayout<pid_t>.size))
            guard count > 0 else { continue }
            for pid in children.prefix(min(Int(count),children.count)) {
                guard visited.insert(pid).inserted, let child = information(pid), child.parent == parent.pid else { continue }
                result.append(child.identity); queue.append(child.identity)
                if result.count == maximum { break }
            }
        }
        return result
    }
    /// The caller closes protocol stdin first. Work and the grace period run
    /// off the main actor; an LSP that made a new process group is still owned
    /// by its previously captured identity. No process arguments are inspected.
    static func stop(root: Identity, descendants captured: [Identity], grace: TimeInterval = 0.35,
                     completion: @escaping @Sendable () -> Void = {}) {
        DispatchQueue.global(qos:.utility).async {
            var owned = Set(captured.filter { $0.pid != root.pid && $0.user == root.user })
            owned.formUnion(descendants(of:root))
            if owned.isEmpty && !matches(root) { completion(); return }
            // Let EOF-triggered protocol cleanup run before escalating.
            Thread.sleep(forTimeInterval:0.06)
            owned.formUnion(descendants(of:root))
            if matches(root) { kill(root.pid,SIGTERM) }
            for child in owned where matches(child) { kill(child.pid,SIGTERM) }
            Thread.sleep(forTimeInterval:min(1,max(0.05,grace)))
            owned.formUnion(descendants(of:root))
            if let current = information(root.pid), current.identity == root, current.group == root.pid {
                // The root identity still owns this SETPGROUP group, so a
                // reused PID or an unrelated application's group is excluded.
                kill(-root.pid,SIGKILL)
            }
            for child in owned where matches(child) { kill(child.pid,SIGKILL) }
            if matches(root) { kill(root.pid,SIGKILL) }
            // Give the already-running waiter time to reap before scratch is
            // removed. Identity checks never reap someone else's child.
            let end = ProcessInfo.processInfo.systemUptime + 0.25
            while ProcessInfo.processInfo.systemUptime < end,
                  matches(root) || owned.contains(where:matches) { Thread.sleep(forTimeInterval:0.01) }
            completion()
        }
    }
    static func stopAndWait(root: Identity, descendants: [Identity], grace: TimeInterval = 0.35) async {
        await withCheckedContinuation { continuation in
            stop(root:root,descendants:descendants,grace:grace) { continuation.resume() }
        }
    }
}
