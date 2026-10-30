import Foundation
import LocalAuthentication

/// Website insertion always has its own biometric proof. The Passwords
/// page may separately keep an approved context for its visible open spell.
/// Neither path permits the Mac account password as a fallback.
enum WebsitePasswordAuthentication {
    typealias Authorizer = @MainActor (LAContext, String) async -> Bool
    private static let lock = NSLock()
    private static var testingAuthorizer: Authorizer?
    private static var manager: (context: LAContext, until: Date)?
    private static var managerEpoch = 0
    private static var failure: String?

    static var lastFailure: String? { locked { failure } }
    static var managerGeneration: Int { locked { managerEpoch } }
    static func clearFailure() { locked { failure = nil } }

    private static func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// A rehearsal cannot access real biometrics; only this injected answer
    /// or the existing explicit test confirmation controls approval.
    static func useForTesting(_ authorizer: Authorizer?) {
        guard Store.testing else { return }
        revokeManagerAccess()
        locked { testingAuthorizer = authorizer; failure = nil }
    }

    @MainActor
    static func authorize(_ reason: String) async -> LAContext? {
        guard !Task.isCancelled else { return nil }
        let context = LAContext()
        context.localizedFallbackTitle = ""
        context.touchIDAuthenticationAllowableReuseDuration = 0
        let approved: Bool
        var cancelled = false
        var refusal = "Touch ID was not approved"
        if Store.testing {
            if let authorizer = locked({ testingAuthorizer }) {
                approved = await withTaskCancellationHandler {
                    await authorizer(context, reason)
                } onCancel: { context.invalidate() }
            }
            else { approved = Ask.testing ?? false }
        } else {
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
                locked { failure = explanation(for: error) }
                context.invalidate()
                return nil
            }
            let answer: (Bool, Error?) = await withTaskCancellationHandler {
                await withCheckedContinuation { completion in
                    context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { yes, error in
                        completion.resume(returning: (yes, error))
                    }
                }
            } onCancel: { context.invalidate() }
            approved = answer.0
            if let code = (answer.1 as? LAError)?.code {
                cancelled = [.userCancel, .appCancel, .systemCancel].contains(code)
                refusal = explanation(for: answer.1)
            }
        }
        guard approved, !Task.isCancelled else {
            locked { failure = cancelled || Task.isCancelled ? nil : refusal }
            context.invalidate()
            return nil
        }
        // The Secure Enclave operation must use this proof, without opening
        // another prompt or falling back to an account-password dialogue.
        context.interactionNotAllowed = true
        locked { failure = nil }
        return context
    }

    static func explanation(for error: Error?) -> String {
        switch (error as? LAError)?.code {
        case .biometryLockout:
            return "Touch ID is temporarily locked. Unlock your Mac to reset Touch ID, then try again"
        case .biometryNotEnrolled:
            return "Set up Touch ID in System Settings before filling saved website logins"
        case .biometryNotAvailable:
            return "Touch ID is not available on this Mac"
        case .authenticationFailed:
            return "Touch ID did not recognize your fingerprint. Try again"
        default:
            return "Touch ID could not be started. Unlock your Mac and try again"
        }
    }

    static func rememberManagerAccess(_ context: LAContext, until: Date, generation: Int) -> Bool {
        var accepted = false
        let previous = locked { () -> LAContext? in
            guard managerEpoch == generation, !Task.isCancelled else { return nil }
            let previous = manager?.context
            manager = (context, until)
            accepted = true
            return previous
        }
        if previous !== context { previous?.invalidate() }
        return accepted
    }

    static func managerContext() -> LAContext? {
        let kept = locked { manager }
        guard let kept else { return nil }
        guard kept.until > Date() else { revokeManagerAccess(); return nil }
        return kept.context
    }

    static func extendManagerAccess(until: Date) {
        let expired = locked { () -> LAContext? in
            guard let kept = manager else { return nil }
            guard kept.until > Date() else { manager = nil; return kept.context }
            manager = (kept.context, until)
            return nil
        }
        expired?.invalidate()
    }

    static func revokeManagerAccess() {
        let previous = locked { () -> LAContext? in
            managerEpoch += 1
            let previous = manager?.context
            manager = nil
            return previous
        }
        previous?.invalidate()
    }
}
