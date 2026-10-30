import AppKit
import LocalAuthentication
import XCTest
@testable import Search

/// A pending biometric reply is deliberately allowed to arrive after the
/// manager locks. Fake approval and an in-memory store never use Touch ID,
/// a real credential, the clipboard, or a legacy Keychain item.
@MainActor
final class WebsitePasswordLockTests: XCTestCase {
    private var authorizer: DeferredProof!
    private var store: LockPasswordStore!
    private var previousSettings: [String: Any] = [:]
    private var previousAsk: Bool?
    private let keys = [VaultLock.eachKey, VaultLock.lockAfterKey, VaultLock.hiddenKey]

    override class func setUp() {
        setenv("SEARCH_PROBE", "website-password-lock-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        previousAsk = Ask.testing
        Ask.testing = nil
        for key in keys { previousSettings[key] = Store.settings.object(forKey: key) }
        Store.settings.set(false, forKey: VaultLock.eachKey)
        Store.settings.set(VaultLockAfter.five.rawValue, forKey: VaultLock.lockAfterKey)
        Store.settings.set(false, forKey: VaultLock.hiddenKey)
        VaultLock.shared.lock()
        authorizer = DeferredProof()
        store = LockPasswordStore()
        Vault.useBackendForTesting(store.backend)
        let authorizer = authorizer!
        WebsitePasswordAuthentication.useForTesting { context, reason in
            await authorizer.answer(context, reason: reason)
        }
        try await super.setUp()
    }

    override func tearDown() async throws {
        VaultLock.shared.lock()
        authorizer.releaseAll(false)
        // Let canceled proof tasks deliver their refused completion before
        // another test starts using the shared manager lock.
        try await Task.sleep(for: .milliseconds(20))
        WebsitePasswordAuthentication.useForTesting(nil)
        Vault.useBackendForTesting(nil)
        Ask.testing = previousAsk
        for key in keys {
            if let value = previousSettings[key] { Store.settings.set(value, forKey: key) }
            else { Store.settings.removeObject(forKey: key) }
        }
        previousSettings.removeAll()
        authorizer = nil
        store = nil
        try await super.tearDown()
    }

    func testLockRejectsLateUnlockAndCannotRestoreManagerLease() async throws {
        let lock = VaultLock.shared
        var replies: [Bool] = []
        lock.unlock { replies.append($0) }
        try await until { authorizer.prompts.count == 1 }
        XCTAssertFalse(lock.open)
        let generation = WebsitePasswordAuthentication.managerGeneration
        lock.lock()
        authorizer.release(true)
        try await until { replies.count == 1 }
        XCTAssertEqual(replies, [false])
        XCTAssertFalse(lock.open)
        XCTAssertNil(lock.until)
        XCTAssertNil(WebsitePasswordAuthentication.managerContext())
        XCTAssertGreaterThan(WebsitePasswordAuthentication.managerGeneration, generation)
        XCTAssertEqual(store.reads, 0)
    }

    func testSleepRejectsLateUnlockWithoutOpeningOrKeepingAContext() async throws {
        var response: Bool?
        VaultLock.shared.unlock { response = $0 }
        try await until { authorizer.prompts.count == 1 }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        authorizer.release(true)
        try await until { response != nil }
        XCTAssertEqual(response, false)
        XCTAssertFalse(VaultLock.shared.open)
        XCTAssertNil(VaultLock.shared.until)
        XCTAssertNil(WebsitePasswordAuthentication.managerContext())
    }

    func testPendingShowAndCopyCannotSucceedAfterManagerLocks() async throws {
        for reason in ["show the password for fixture.invalid", "copy the password for fixture.invalid"] {
            try await openManager()
            Store.settings.set(true, forKey: VaultLock.eachKey)
            let count = authorizer.prompts.count
            var response: Bool?
            VaultLock.shared.allow(reason) { response = $0 }
            try await until { authorizer.prompts.count == count + 1 }
            VaultLock.shared.lock()
            authorizer.release(true)
            try await until { response != nil }
            XCTAssertEqual(response, false, reason)
            XCTAssertFalse(VaultLock.shared.open)
            XCTAssertNil(WebsitePasswordAuthentication.managerContext())
            XCTAssertNil(Vault.details(of: store.kept), "A late UI callback must not regain access to the secret")
            XCTAssertEqual(store.reads, 0)
        }
    }

    func testOverlappingUnlockAndAllowDoNotStartAnotherPrompt() async throws {
        let lock = VaultLock.shared
        var first: Bool?
        var second: Bool?
        var show: Bool?
        lock.unlock { first = $0 }
        try await until { authorizer.prompts.count == 1 }
        lock.unlock { second = $0 }
        lock.allow("show a password") { show = $0 }
        XCTAssertEqual(second, false)
        XCTAssertEqual(show, false)
        XCTAssertEqual(authorizer.prompts.count, 1)
        authorizer.release(true)
        try await until { first != nil }
        XCTAssertEqual(first, true)
        XCTAssertTrue(lock.open)
        XCTAssertNotNil(WebsitePasswordAuthentication.managerContext())
        XCTAssertEqual(authorizer.prompts.count, 1)
    }

    func testOverlappingShowAndCopyWithAskEachUseOnlyOnePendingProof() async throws {
        try await openManager()
        Store.settings.set(true, forKey: VaultLock.eachKey)
        let count = authorizer.prompts.count
        var show: Bool?
        var copy: Bool?
        VaultLock.shared.allow("show a password") { show = $0 }
        try await until { authorizer.prompts.count == count + 1 }
        VaultLock.shared.allow("copy a password") { copy = $0 }
        XCTAssertEqual(copy, false)
        XCTAssertEqual(authorizer.prompts.count, count + 1)
        authorizer.release(true)
        try await until { show != nil }
        XCTAssertEqual(show, true)
        XCTAssertTrue(VaultLock.shared.open)
        XCTAssertEqual(authorizer.prompts.count, count + 1)
    }

    func testOpenManagerLeaseNeverApprovesWebsiteInsertion() async throws {
        try await openManager()
        let manager = try XCTUnwrap(WebsitePasswordAuthentication.managerContext())
        XCTAssertEqual(authorizer.prompts.count, 1)
        let denied = Task { await Vault.loginForFill(store.kept) }
        try await until { authorizer.prompts.count == 2 }
        XCTAssertEqual(store.reads, 0, "The manager lease cannot decrypt a website insertion while its own approval waits")
        authorizer.release(false)
        let refused = await denied.value
        XCTAssertNil(refused)
        XCTAssertEqual(store.reads, 0)
        XCTAssertTrue(VaultLock.shared.open, "Refusing a fill must not alter the separately approved manager session")
        XCTAssertTrue(WebsitePasswordAuthentication.managerContext() === manager)

        let accepted = Task { await Vault.loginForFill(store.kept) }
        try await until { authorizer.prompts.count == 3 }
        authorizer.release(true)
        let login = await accepted.value
        XCTAssertEqual(login?.password, store.secret.password)
        XCTAssertEqual(store.reads, 1)
        XCTAssertFalse(try XCTUnwrap(store.readContext) === manager)
        XCTAssertTrue(WebsitePasswordAuthentication.managerContext() === manager)
        XCTAssertTrue(authorizer.prompts[1].reason.contains("fill your saved login"))
        XCTAssertTrue(authorizer.prompts[2].reason.contains("fill your saved login"))
    }

    private func openManager() async throws {
        let count = authorizer.prompts.count
        var response: Bool?
        VaultLock.shared.unlock { response = $0 }
        try await until { authorizer.prompts.count == count + 1 }
        authorizer.release(true)
        try await until { response != nil }
        XCTAssertEqual(response, true)
        XCTAssertTrue(VaultLock.shared.open)
        XCTAssertNotNil(WebsitePasswordAuthentication.managerContext())
    }

    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The fake biometric lifecycle did not settle", file: file, line: line)
        throw URLError(.timedOut)
    }

    private final class DeferredProof {
        struct Prompt { let context: LAContext; let reason: String }
        var prompts: [Prompt] = []
        private var replies: [CheckedContinuation<Bool, Never>] = []

        func answer(_ context: LAContext, reason: String) async -> Bool {
            prompts.append(Prompt(context: context, reason: reason))
            return await withCheckedContinuation { replies.append($0) }
        }

        func release(_ answer: Bool) {
            guard !replies.isEmpty else { XCTFail("No biometric reply is waiting"); return }
            replies.removeFirst().resume(returning: answer)
        }

        func releaseAll(_ answer: Bool) {
            let pending = replies
            replies.removeAll()
            for reply in pending { reply.resume(returning: answer) }
        }
    }

    private final class LockPasswordStore {
        let kept = Kept(host: "lock-fixture.invalid", user: "fixture-user")
        let secret = Secret(password: "synthetic-manager-lock-secret")
        var reads = 0
        var readContext: LAContext?

        var backend: Vault.Backend {
            .init(entries: { [self] in [kept] }, read: { [self] _, context in
                guard let context else { throw URLError(.userAuthenticationRequired) }
                reads += 1
                readContext = context
                return secret
            }, save: { _, _, _, _, _, _ in }, touch: { _, _ in }, forget: { _ in })
        }
    }
}
