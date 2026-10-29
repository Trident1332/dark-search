import Foundation
import Security

/// The legacy macOS Keychain ignores SecItem's per-query UI controls.
/// Serialize its process-wide interaction flag with every app-owned SecItem
/// operation, and never make a quiet caller wait for somebody's approval.
enum KeychainAccess {
    struct Backend {
        var getInteraction: () -> (OSStatus, Bool) = {
            var allowed = DarwinBoolean(true)
            let status = SecKeychainGetUserInteractionAllowed(&allowed)
            return (status, allowed.boolValue)
        }
        var setInteraction: (Bool) -> OSStatus = { SecKeychainSetUserInteractionAllowed($0) }
        var copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = { SecItemCopyMatching($0, $1) }
        var add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = { SecItemAdd($0, $1) }
        var update: (CFDictionary, CFDictionary) -> OSStatus = { SecItemUpdate($0, $1) }
        var delete: (CFDictionary) -> OSStatus = { SecItemDelete($0) }
    }

    private static let operationLock = NSLock()
    private static let stateLock = NSLock()
    private static var owner: UInt64?
    private static var testingBackend: Backend?

    /// Synthetic drivers never escape rehearsal runs or alter a real item.
    static func useBackendForTesting(_ backend: Backend?) {
        guard Store.testing else { return }
        stateLock.lock()
        testingBackend = backend
        stateLock.unlock()
    }

    static func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        result?.pointee = nil
        let status = perform(quiet: quiet(query)) { $0.copyMatching(query, result) }
        if status != errSecSuccess { result?.pointee = nil }
        return status
    }

    static func add(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        result?.pointee = nil
        let status = perform(quiet: false) { $0.add(attributes, result) }
        if status != errSecSuccess { result?.pointee = nil }
        return status
    }

    static func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        perform(quiet: false) { $0.update(query, attributes) }
    }

    static func delete(_ query: CFDictionary) -> OSStatus {
        perform(quiet: false) { $0.delete(query) }
    }

    private static func quiet(_ query: CFDictionary) -> Bool {
        let parameters = query as NSDictionary
        let returnsData = parameters[kSecReturnData as String] as? Bool == true
        let ui = parameters[kSecUseAuthenticationUI as String] as? String
        return !returnsData || ui == kSecUseAuthenticationUIFail as String
            || ui == kSecUseAuthenticationUISkip as String
            || parameters[kSecUseNoAuthenticationUI as String] as? Bool == true
    }

    private static func perform(quiet: Bool, _ operation: (Backend) -> OSStatus) -> OSStatus {
        var thread: UInt64 = 0
        guard pthread_threadid_np(nil, &thread) == 0 else { return errSecInteractionNotAllowed }
        stateLock.lock()
        let reentrant = owner == thread
        stateLock.unlock()
        guard !reentrant else { return errSecInteractionNotAllowed }

        if quiet {
            guard operationLock.try() else { return errSecInteractionNotAllowed }
        } else {
            operationLock.lock()
        }
        stateLock.lock()
        owner = thread
        let backend = Store.testing ? testingBackend ?? Backend() : Backend()
        stateLock.unlock()
        defer {
            stateLock.lock()
            owner = nil
            stateLock.unlock()
            operationLock.unlock()
        }

        // Never enable interaction that another owner has already disabled.
        // Apple implements this as a Globals Boolean, not a query/thread flag:
        // https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/libsecurity_keychain/lib/Globals.cpp#L66-L68
        guard quiet else { return operation(backend) }
        let (readStatus, previous) = backend.getInteraction()
        guard readStatus == errSecSuccess else { return readStatus }
        guard previous else { return operation(backend) }
        let disabled = backend.setInteraction(false)
        guard disabled == errSecSuccess else {
            // A failing setter is not proof that the state stayed unchanged.
            _ = backend.setInteraction(previous)
            return disabled
        }
        let status = operation(backend)
        let restored = backend.setInteraction(previous)
        return restored == errSecSuccess ? status : restored
    }
}
