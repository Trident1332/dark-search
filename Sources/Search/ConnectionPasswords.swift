import CryptoKit
import Foundation

/// Connection passwords have one selected home. Device-vault mode never reads
/// Keychain implicitly; importing an old password is a separate, explicit act.
enum ConnectionPasswords {
    struct Backend {
        var read: (String) throws -> ConnectionVault.Entry
        var save: (String, String) throws -> Void
        var forget: (String) throws -> Void
    }

    enum Failure: Error { case disabled, invalidKey }
    private struct ImportTicket { let id: UUID; let epoch: Int; let generation: Int }

    private static let lock = NSLock()
    private static let setting = "connections.deviceVault"
    nonisolated(unsafe) private static var vault: ConnectionVault?
    nonisolated(unsafe) private static var testingBackend: Backend?
    nonisolated(unsafe) private static var testingEnabled: Bool?
    nonisolated(unsafe) private static var observedMode: Bool?
    nonisolated(unsafe) private static var generation = 0
    nonisolated(unsafe) private static var epochs: [String: Int] = [:]
    nonisolated(unsafe) private static var pendingImports: [String: ImportTicket] = [:]
    nonisolated(unsafe) private static var importAnswers: [String: Bool] = [:]

    private static func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Test drivers and mode overrides cannot replace the production backend.
    /// Resetting the driver also invalidates work from an earlier test launch.
    static func useBackendForTesting(_ backend: Backend?, enabled: Bool? = nil) {
        guard Store.testing else { return }
        locked {
            testingBackend = backend
            testingEnabled = enabled
            observedMode = nil
            generation += 1
            epochs.removeAll(); pendingImports.removeAll(); importAnswers.removeAll()
            vault = nil
        }
    }

    private static func enabledLocked() -> Bool {
        let enabled = Store.testing ? testingEnabled ?? Store.settings.bool(forKey: setting)
                                    : Store.settings.bool(forKey: setting)
        if observedMode != enabled {
            observedMode = enabled
            generation += 1
            importAnswers.removeAll()
        }
        return enabled
    }

    static var usesVault: Bool { locked { enabledLocked() } }

    /// Settings uses this setter so an off/on transition also invalidates an
    /// import whose old Keychain approval is still pending outside the lock.
    static func setUsesVault(_ enabled: Bool) {
        locked {
            _ = enabledLocked()
            if Store.testing, testingEnabled != nil { testingEnabled = enabled }
            else { Store.settings.set(enabled, forKey: setting) }
            _ = enabledLocked()
        }
    }

    static var storageHint: String { usesVault ? "Encrypted on this Mac" : "Kept in your keychain" }
    static var savedDescription: String { usesVault ? "Encrypted on this Mac" : "Kept in your keychain" }
    static var passwordPlaceholder: String {
        usesVault ? "••••••••  encrypted on this Mac" : "••••••••  kept in your keychain"
    }
    static let missingHint = "Enter the password or import it once from Keychain"

    /// The ordered JSON array avoids separator collisions without exposing its
    /// host, account, or connection kind in the vault's record names.
    static func identity(kind: String, components: [String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data: Data
        do { data = try encoder.encode([kind] + components) }
        catch { preconditionFailure("A connection password identity could not be encoded") }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Called under the controller lock. Vault I/O and mutations are serialized.
    private static func backendLocked() -> Backend {
        if Store.testing, let testingBackend { return testingBackend }
        let current: ConnectionVault
        if let vault { current = vault }
        else {
            current = ConnectionVault(directory: Store.folder.appendingPathComponent("Connection Vault", isDirectory: true))
            vault = current
        }
        return Backend(read: { try current.read($0) }, save: { try current.save($0, for: $1) },
                       forget: { try current.forget($0) })
    }

    static func read(_ key: String) throws -> ConnectionVault.Entry {
        try locked {
            guard enabledLocked() else { throw Failure.disabled }
            guard !key.isEmpty else { throw Failure.invalidKey }
            return try backendLocked().read(key)
        }
    }

    @discardableResult
    static func save(_ value: String, for key: String) -> Bool {
        locked {
            guard enabledLocked(), !key.isEmpty else { return false }
            epochs[key, default: 0] += 1
            importAnswers.removeValue(forKey: key)
            guard !value.isEmpty else { return false }
            do { try backendLocked().save(value, key); return true }
            catch { return false }
        }
    }

    @discardableResult
    static func forget(_ key: String) -> Bool {
        locked {
            guard enabledLocked(), !key.isEmpty else { return false }
            epochs[key, default: 0] += 1
            importAnswers.removeValue(forKey: key)
            do { try backendLocked().forget(key); return true }
            catch { return false }
        }
    }

    /// The legacy closure may ask for approval, so it always runs outside our
    /// lock. A concurrent read never invokes it, and save/forget can invalidate
    /// its ticket while approval is pending. The legacy item is never deleted.
    @discardableResult
    static func importLegacy(_ key: String, read legacyRead: () -> String?) -> Bool {
        var ticket: ImportTicket?
        let immediate: Bool? = locked {
            guard enabledLocked(), !key.isEmpty else { return false }
            if pendingImports[key] != nil { return false }
            do {
                switch try backendLocked().read(key) {
                case .value(let value): return !value.isEmpty
                case .deleted: return false
                case .missing: break
                }
            } catch { return false }
            // A prior successful attempt is not proof that a now-missing
            // record still exists; only the vault read above can report that.
            if importAnswers[key] != nil { return false }
            let made = ImportTicket(id: UUID(), epoch: epochs[key] ?? 0, generation: generation)
            pendingImports[key] = made
            ticket = made
            return nil
        }
        if let immediate { return immediate }
        guard let ticket else { return false }
        let password = legacyRead()
        return locked {
            if pendingImports[key]?.id == ticket.id { pendingImports.removeValue(forKey: key) }
            guard enabledLocked(), generation == ticket.generation,
                  (epochs[key] ?? 0) == ticket.epoch else { return false }
            guard let password, !password.isEmpty else {
                importAnswers[key] = false
                return false
            }
            let backend = backendLocked()
            do {
                // Another writer may have populated a shared test/backend file.
                // An existing value or tombstone always wins over old approval.
                switch try backend.read(key) {
                case .value(let value): return !value.isEmpty
                case .deleted: return false
                case .missing: break
                }
                try backend.save(password, key)
                guard case .value(let saved) = try backend.read(key), saved == password else {
                    importAnswers[key] = false
                    return false
                }
                importAnswers[key] = true
                return true
            } catch {
                importAnswers[key] = false
                return false
            }
        }
    }
}
