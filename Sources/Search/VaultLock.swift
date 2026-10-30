import AppKit
import Foundation

// The lock on the Passwords page.
//
// The page opens locked. Touch ID opens it, and it stays open
// for a while (Settings › Passwords › Lock after), the clock starting again
// with every use. It locks on its own when that runs out, when the Mac goes
// to sleep, when the screen locks, and, if Settings says so, the moment
// Search is no longer the app in front. While it is open, showing or copying
// a password asks nothing more, unless Settings › Passwords › Ask again for
// each password is on: then the list is open but every secret is its own
// question, as every one was before there was a lock.
//
// Website passwords live in the browser's encrypted file. The page's
// biometric context lasts only for this open spell. A website insertion
// always asks for a fresh Touch ID proof, independently of this page.

/// How long the page stays open once opened.
enum VaultLockAfter: Int, CaseIterable, Identifiable {
    case minute = 60, five = 300, quarter = 900, hour = 3600

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .minute: return "1 min"
        case .five: return "5 min"
        case .quarter: return "15 min"
        case .hour: return "1 hour"
        }
    }

    /// As a sentence says it: "after five minutes".
    var spoken: String {
        switch self {
        case .minute: return "a minute"
        case .five: return "five minutes"
        case .quarter: return "a quarter of an hour"
        case .hour: return "an hour"
        }
    }

    var interval: TimeInterval { TimeInterval(rawValue) }
}

/// The open spell, as plain arithmetic: when it opened, how long each use
/// buys, and so when it ends. Kept apart from the clocks and the
/// notifications so it can be checked without either.
struct VaultSession: Equatable {
    var opened: Date
    var lockAfter: TimeInterval
    /// The last thing done with the page: the spell runs from here.
    private(set) var last: Date

    init(opened: Date, lockAfter: TimeInterval) {
        self.opened = opened
        self.lockAfter = lockAfter
        last = opened
    }

    /// When it locks on its own, nothing else happening.
    var until: Date { last.addingTimeInterval(lockAfter) }

    func locked(at now: Date) -> Bool { now >= until }

    /// Something was done with the page: the clock starts again. Never
    /// backwards — a clock put back doesn't shorten the spell.
    mutating func extend(at now: Date) { last = max(last, now) }
}

@MainActor
final class VaultLock: ObservableObject {
    static let shared = VaultLock()

    /// Open: the list and, unless each is asked for, its secrets.
    @Published private(set) var open = false
    /// When it locks on its own, while open. The page counts down to it.
    @Published private(set) var until: Date?

    private var session: VaultSession?
    private var timer: DispatchWorkItem?
    /// The Mac's sheet is up. Its coming takes the window from Search, which
    /// must not read as Search being hidden.
    private var proving = false
    private var proofTask: Task<Void, Never>?
    private var proofGeneration = UUID()
    private var observers: [Any] = []

    nonisolated static let lockAfterKey = "vault.lockAfter"
    nonisolated static let hiddenKey = "vault.lockHidden"
    nonisolated static let eachKey = "vault.askEach"

    /// Settings › Passwords › Lock after. Five minutes until set.
    nonisolated static var lockAfter: VaultLockAfter {
        VaultLockAfter(rawValue: Store.settings.integer(forKey: lockAfterKey)) ?? .five
    }
    /// Settings › Passwords › Lock when Search is hidden.
    nonisolated static var locksWhenHidden: Bool { Store.settings.bool(forKey: hiddenKey) }
    /// Settings › Passwords › Ask again for each password.
    nonisolated static var asksEach: Bool { Store.settings.bool(forKey: eachKey) }

    private init() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            })
        }
        // The lock screen: macOS says so to anyone listening, by this name.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, VaultLock.locksWhenHidden, !self.proving else { return }
                self.lock()
            }
        })
    }

    /// Opened, once the Mac has said who this is. Already open: a use, and
    /// a yes. The sheet already up: a no for this asker; the first gets
    /// the answer.
    func unlock(_ done: @escaping (Bool) -> Void = { _ in }) {
        if open {
            touch()
            done(true)
            return
        }
        guard !proving else {
            done(false)
            return
        }
        proving = true
        let generation = proofGeneration
        proofTask = Vault.prove("open your passwords") { [weak self] ok in
            guard let self else { return }
            self.proving = false
            self.proofTask = nil
            guard generation == self.proofGeneration else { done(false); return }
            if ok { self.opened() }
            done(ok)
        }
    }

    private func opened() {
        session = VaultSession(opened: Date(), lockAfter: VaultLock.lockAfter.interval)
        open = true
        schedule()
    }

    /// Something was done with the page: the clock starts again.
    func touch() {
        guard open, var spell = session else { return }
        spell.extend(at: Date())
        session = spell
        schedule()
    }

    /// Settings › Passwords › Lock after changed: the spell takes the new
    /// length from now.
    func refresh() {
        guard open, var spell = session else { return }
        spell.lockAfter = VaultLock.lockAfter.interval
        session = spell
        schedule()
    }

    private func schedule() {
        timer?.cancel()
        guard let session else { return }
        Vault.extendAccess(until: session.until)
        until = session.until
        let work = DispatchWorkItem { [weak self] in
            guard let self, let session = self.session else { return }
            // The timer fires late after a sleep the lock already heard of,
            // and early for nothing: it locks only once the time has come.
            if session.locked(at: Date()) { self.lock() } else { self.schedule() }
        }
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, session.until.timeIntervalSinceNow), execute: work)
    }

    func lock() {
        proofGeneration = UUID()
        proofTask?.cancel()
        Vault.revokeAccess()
        timer?.cancel()
        timer = nil
        session = nil
        until = nil
        if open { open = false }
    }

    /// Whether `reason` may go ahead without asking: the page is open and
    /// isn't set to ask for each one. Otherwise the Mac is asked, as every
    /// Show and Copy asked before there was a lock. A yes is a use.
    func allow(_ reason: String, _ done: @escaping (Bool) -> Void) {
        if open, !VaultLock.asksEach {
            touch()
            done(true)
            return
        }
        guard !proving else { done(false); return }
        proving = true
        let generation = proofGeneration
        proofTask = Vault.prove(reason) { [weak self] ok in
            guard let self else { done(false); return }
            self.proving = false
            self.proofTask = nil
            guard generation == self.proofGeneration else { done(false); return }
            if ok { self.touch() }
            done(ok)
            if !self.open { Vault.revokeAccess() }
        }
    }
}
