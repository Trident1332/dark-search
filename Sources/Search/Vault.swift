import Foundation
import Security
import LocalAuthentication

// Website passwords live in Search's encrypted store. Listing an account
// never reads its secret. Filling a website requires a fresh Touch ID proof;
// the old per-site Keychain items are read only by an explicit import.

struct Login: Identifiable, Equatable, Hashable {
    var host: String
    var user: String
    var password: String
    /// When it was last used to sign in, if known. Newest first in lists.
    var used: Date?
    /// Kept from a page sent in the clear, over plain http. Only these are
    /// offered on such a page: one kept from https, or from before this was
    /// written down, is never handed to a page anyone on the way could have
    /// written.
    var clear = false
    /// What was written beside it on the Passwords page, encrypted with it
    /// (see `Secret`). Empty for most.
    var notes = ""

    var id: String { host + "\u{1}" + user }
}

/// A password and its private note. The legacy codec below is used only
/// for explicit imports; the website vault seals each field separately.
struct Secret: Equatable {
    var password: String
    var notes = ""

    private static let mark = Data([0]) + Data("SV1".utf8)

    init(password: String, notes: String = "") {
        self.password = password
        self.notes = notes
    }

    init?(_ data: Data) {
        guard data.starts(with: Secret.mark) else {
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            password = text
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: data.dropFirst(Secret.mark.count)) as? [String: String],
              let password = object["p"]
        else { return nil }
        self.password = password
        notes = object["n"] ?? ""
    }

    var packed: Data? {
        guard !notes.isEmpty else { return password.data(using: .utf8) }
        guard let json = try? JSONSerialization.data(withJSONObject: ["p": password, "n": notes]) else { return nil }
        return Secret.mark + json
    }
}

/// One item as a list needs it: the site, the account, and when it was last
/// used, without the secret. The list never unlocks a password. Nothing
/// that writes a password or fills one into a
/// page takes this type, so a row cannot be handed on as though it held one.
struct Kept: Identifiable, Equatable, Hashable {
    var host: String
    var user: String
    /// When it was last used to sign in, if known. Newest first in lists.
    var used: Date?
    /// Kept from a page sent in the clear, over plain http. See `Login`.
    var clear = false
    /// When it went into the website vault, or the original import date.
    var since: Date?

    var id: String { host + "\u{1}" + user }
}

enum Vault {
    /// The old per-site Keychain label, used only by explicit migration.
    private static let legacyLabel = Store.world.map { "Search (\($0))" } ?? "Search"

    /// The facade's test driver supplies an isolated in-memory store. A
    /// missing own-vault item never authorizes reading the legacy Keychain.
    struct Backend {
        var entries: () throws -> [Kept]
        var read: (Kept, LAContext?) throws -> Secret
        var save: (String, String, String, Date?, Bool, String?) throws -> Void
        var touch: (Kept, Date) throws -> Void
        var forget: (Kept) throws -> Void
        /// The returned undo removes only the exact newly inserted record.
        /// Nil means another own-vault record already owns this identity.
        var importNew: ((Kept, Secret) throws -> (() throws -> Void)?)? = nil
    }

    private static let backendLock = NSLock()
    private static var testingBackend: Backend?
    private static var failure: String?

    private static func locked<T>(_ body: () -> T) -> T {
        backendLock.lock()
        defer { backendLock.unlock() }
        return body()
    }

    static var lastFailure: String? { locked { failure } ?? WebsitePasswordAuthentication.lastFailure }

    private static func failed(_ error: Error) { locked { failure = error.localizedDescription } }
    private static func clearFailure() {
        locked { failure = nil }
        WebsitePasswordAuthentication.clearFailure()
    }

    static func useBackendForTesting(_ backend: Backend?) {
        guard Store.testing else { return }
        locked { testingBackend = backend; failure = nil }
        WebsitePasswordAuthentication.revokeManagerAccess()
    }

    private static var backend: Backend {
        if Store.testing, let given = locked({ testingBackend }) { return given }
        let vault = WebsitePasswordVault.shared
        return Backend(entries: { try vault.entries() }, read: { try vault.read($0, context: $1) },
                       save: { try vault.save(host: $0, user: $1, password: $2, used: $3, clear: $4, notes: $5) },
                       touch: { try vault.touch($0, at: $1) }, forget: { try vault.forget($0) },
                       importNew: { kept, secret in
                           guard let receipt = try vault.insertImported(kept, secret: secret) else { return nil }
                           return { _ = try vault.discardImported(receipt) }
                       })
    }

    // MARK: - metadata, without unlocking a password

    private static func entries() -> [Kept] {
        do { return try backend.entries() }
        catch { failed(error); return [] }
    }

    static func kept(for host: String) -> [Kept] { entries().filter { $0.host == host } }

    /// Whether an account kept for `server` is offered on `host`: the same
    /// host, or with `wide`, another host of the same registrable site.
    static func belongs(_ server: String, to host: String, wide: Bool = true, domain: String? = nil) -> Bool {
        server == host || (wide && registrable(server) == (domain ?? registrable(host)))
    }

    static func kept(matching host: String, wide: Bool = true) -> [Kept] {
        let domain = registrable(host)
        return entries().filter { belongs($0.host, to: host, wide: wide, domain: domain) }
            .sorted { ($0.used ?? .distantPast) > ($1.used ?? .distantPast) }
    }

    static func all() -> [Kept] {
        entries().sorted { $0.host == $1.host ? $0.user < $1.user : $0.host < $1.host }
    }

    // MARK: - explicit secret access

    /// Only the Passwords page's biometric unlock opens synchronous access.
    /// Website insertion uses its own proof below, even while that page is open.
    static func details(of kept: Kept) -> Secret? {
        guard let context = WebsitePasswordAuthentication.managerContext() else {
            locked { failure = "Unlock Dark Search Passwords with Touch ID first" }
            return nil
        }
        do { let secret = try backend.read(kept, context); clearFailure(); return secret }
        catch { failed(error); return nil }
    }

    static func secret(of kept: Kept) -> String? { details(of: kept)?.password }

    static func login(_ kept: Kept) -> Login? {
        guard let secret = details(of: kept) else { return nil }
        return Login(host: kept.host, user: kept.user, password: secret.password, used: kept.used, clear: kept.clear, notes: secret.notes)
    }

    @MainActor
    static func loginForFill(_ kept: Kept) async -> Login? {
        clearFailure()
        // A removed account does not deserve an unnecessary biometric prompt.
        guard let current = entries().first(where: { $0.id == kept.id }) else { return nil }
        guard current.clear == kept.clear else {
            locked { failure = "This saved login changed. Choose it again before filling" }
            return nil
        }
        guard let context = await WebsitePasswordAuthentication.authorize("fill your saved login for \(current.host)") else { return nil }
        defer { context.invalidate() }
        guard !Task.isCancelled else { return nil }
        do {
            let secret = try backend.read(current, context)
            guard !Task.isCancelled else { return nil }
            clearFailure()
            return Login(host: current.host, user: current.user, password: secret.password, used: current.used,
                         clear: current.clear, notes: secret.notes)
        } catch { failed(error); return nil }
    }

    // MARK: - writes, using the vault's public encryption key

    @discardableResult
    static func save(host: String, user: String, password: String, used: Date? = nil, clear: Bool = false, notes: String? = nil) -> Bool {
        guard !host.isEmpty, !password.isEmpty else { return false }
        do { try backend.save(host, user, password, used, clear, notes); clearFailure(); return true }
        catch { failed(error); return false }
    }

    static func touch(_ login: Login) {
        touch(Kept(host: login.host, user: login.user, used: login.used, clear: login.clear, since: nil))
    }

    static func touch(_ kept: Kept) {
        do { try backend.touch(kept, Date()); clearFailure() }
        catch { failed(error) }
    }

    @discardableResult
    static func forget(host: String, user: String) -> Bool {
        do {
            try backend.forget(Kept(host: host, user: user, used: nil, clear: false, since: nil))
            clearFailure()
            return true
        } catch { failed(error); return false }
    }

    // MARK: - explicit migration from Search's old per-site Keychain items

    /// Attributes only, with all Keychain interaction forbidden. Existing
    /// own-vault accounts are omitted so repeated imports cannot replace them.
    static func legacyKept() -> [Kept] {
        let existing = Set(entries().map(migrationID))
        return legacyRows().compactMap(legacyKept(from:)).filter { !existing.contains(migrationID($0)) }
    }
    static var legacyCount: Int { legacyKept().count }

    private static func migrationID(_ kept: Kept) -> String {
        kept.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "\u{1}" + kept.user
    }

    private static func legacyRows() -> [[String: Any]] {
        var result: CFTypeRef?
        let status = KeychainAccess.copyMatching([
            kSecClass as String: kSecClassInternetPassword, kSecAttrLabel as String: legacyLabel,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ] as CFDictionary, &result)
        guard status == errSecSuccess else { return [] }
        return result as? [[String: Any]] ?? []
    }

    private static func legacyKept(from row: [String: Any]) -> Kept? {
        guard let host = row[kSecAttrServer as String] as? String else { return nil }
        let used = (row[kSecAttrComment as String] as? String).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        return Kept(host: host, user: row[kSecAttrAccount as String] as? String ?? "", used: used,
                    clear: row[kSecAttrProtocol as String] as? String == kSecAttrProtocolHTTP as String,
                    since: row[kSecAttrCreationDate as String] as? Date)
    }

    /// The caller's explicit import is the only secret-query entry point.
    /// Run it off the UI actor because an old item's system approval can wait.
    private static func legacySecret(_ kept: Kept) -> Secret? {
        var result: CFTypeRef?
        let status = KeychainAccess.copyMatching([
            kSecClass as String: kSecClassInternetPassword, kSecAttrLabel as String: legacyLabel,
            kSecAttrServer as String: kept.host, kSecAttrAccount as String: kept.user,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIAllow
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let secret = Secret(data), !secret.password.isEmpty else { return nil }
        return secret
    }

    /// Called only by the person's Import from Keychain action. The legacy
    /// copy survives even after the new encrypted copy is verified.
    @MainActor
    static func importLegacyLogins() async -> (kept: Int, skipped: Int) {
        clearFailure()
        let candidates = legacyKept()
        guard !candidates.isEmpty else { return (0, 0) }
        guard let insert = backend.importNew else {
            locked { failure = "This password store does not support importing old Keychain logins" }
            return (0, candidates.count)
        }
        guard let context = await WebsitePasswordAuthentication.authorize("import your saved website logins into Dark Search Passwords") else {
            return (0, candidates.count)
        }
        defer { context.invalidate() }
        var imported = 0, skipped = 0
        for kept in candidates {
            guard !Task.isCancelled else { return (imported, skipped + candidates.count - imported - skipped) }
            // Recheck after approval: an existing destination is never replaced.
            guard !entries().contains(where: { migrationID($0) == migrationID(kept) }) else { skipped += 1; continue }
            let secret = await Task.detached(priority: .userInitiated) { legacySecret(kept) }.value
            guard !Task.isCancelled else { return (imported, candidates.count - imported) }
            guard let secret else {
                locked { failure = "The old Keychain login could not be imported. Its original copy was left in place" }
                skipped += 1
                continue
            }
            guard !entries().contains(where: { migrationID($0) == migrationID(kept) }) else { skipped += 1; continue }
            var rollback: (() throws -> Void)?
            do {
                guard let undo = try insert(kept, secret) else { skipped += 1; continue }
                rollback = undo
                guard try backend.read(kept, context) == secret else { throw ImportFailure.verification }
                imported += 1
            } catch {
                // The undo is bound to ciphertext, not just host/account or
                // timestamps. A concurrent newer password is never removed.
                do { try rollback?() } catch { }
                failed(error)
                skipped += 1
            }
        }
        return (imported, skipped)
    }

    private enum ImportFailure: LocalizedError {
        case verification
        var errorDescription: String? {
            "The imported login could not be verified. Its original Keychain copy was left in place"
        }
    }

    // MARK: - sites that asked not to be asked

    private static let neverKey = "passwords.never"

    static var never: Set<String> {
        get { Set(Store.settings.stringArray(forKey: neverKey) ?? []) }
        set { Store.settings.set(Array(newValue).sorted(), forKey: neverKey) }
    }

    static func never(_ host: String) { never.insert(host) }
    static func isNever(_ host: String) -> Bool { never.contains(host) || never.contains(registrable(host)) }

    // MARK: - showing one

    /// The Passwords page's open spell also requires biometrics, without
    /// silently falling back to the Mac login password.
    @discardableResult
    @MainActor static func prove(_ reason: String, _ done: @escaping (Bool) -> Void) -> Task<Void, Never> {
        clearFailure()
        let generation = WebsitePasswordAuthentication.managerGeneration
        return Task {
            guard let context = await WebsitePasswordAuthentication.authorize(reason) else { done(false); return }
            guard WebsitePasswordAuthentication.rememberManagerAccess(context, until: Date().addingTimeInterval(VaultLock.lockAfter.interval),
                                                                      generation: generation) else {
                context.invalidate()
                done(false)
                return
            }
            done(true)
        }
    }

    static func revokeAccess() { WebsitePasswordAuthentication.revokeManagerAccess() }
    static func extendAccess(until: Date) { WebsitePasswordAuthentication.extendManagerAccess(until: until) }

    // MARK: - the site behind a host

    /// example.com for www.example.com and accounts.example.com; bbc.co.uk
    /// stays bbc.co.uk.
    static func registrable(_ host: String) -> String {
        Registrable.domain(of: host, isSuffix: Passkeys.publicSuffix.map { test in { test($0 as CFString) } })
    }

    static func host(of text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        if !value.contains("://") { value = "https://" + value }
        // A website's, and nothing else: an Android app's login in an export
        // (android://…@com.vendor.app/) names a package, which can read as a
        // domain somebody else owns — com.vendor.app, .shopping… — and would
        // be offered to them.
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host()?.lowercased()
        else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - taking in an export

    /// A CSV as Google Password Manager, Chrome or Dia write it: name, url,
    /// username, password, note. Read once, encrypted into Search's store, and the file
    /// is yours to delete — this never keeps a copy of it.
    static func take(csv text: String) -> (kept: Int, skipped: Int) {
        var rows = parse(csv: text)
        guard !rows.isEmpty else { return (0, 0) }

        let header = rows.removeFirst().map { $0.lowercased() }
        func column(_ names: [String]) -> Int? {
            header.firstIndex { names.contains($0) }
        }
        guard let urlAt = column(["url", "login_uri", "website", "site"]),
              let userAt = column(["username", "login_username", "user", "email"]),
              let passAt = column(["password", "login_password"])
        else { return (0, rows.count) }

        var kept = 0, skipped = 0
        for row in rows {
            guard row.count > max(urlAt, max(userAt, passAt)) else {
                skipped += 1
                continue
            }
            let host = self.host(of: row[urlAt])
            let password = row[passAt]
            guard !host.isEmpty, !password.isEmpty else {
                skipped += 1
                continue
            }
            let clear = row[urlAt].trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://")
            save(host: host, user: row[userAt], password: password, clear: clear) ? (kept += 1) : (skipped += 1)
        }
        return (kept, skipped)
    }

    /// Called on the import worker. Parsing finishes before any keychain
    /// writes; cancellation between writes preserves an exact partial count.
    static func take(csv text: String, control: ImportFile.Control) -> (kept: Int, skipped: Int) {
        guard !control.isCancelled else { return (0, 0) }
        control.report(.init(message: "Reading password CSV", completed: 0))
        var rows = parse(csv: text, control: control)
        guard !rows.isEmpty, !control.isCancelled else { return (0, 0) }
        let header = rows.removeFirst().map { $0.lowercased() }
        func column(_ names: [String]) -> Int? { header.firstIndex { names.contains($0) } }
        guard let urlAt = column(["url", "login_uri", "website", "site"]),
              let userAt = column(["username", "login_username", "user", "email"]),
              let passAt = column(["password", "login_password"])
        else { return (0, rows.count) }
        var kept = 0, skipped = 0
        control.report(.init(message: "Saving passwords", completed: 0, total: rows.count))
        for (index, row) in rows.enumerated() {
            if control.isCancelled { break }
            defer {
                if (index + 1) % 25 == 0 || index + 1 == rows.count {
                    control.report(.init(message: "Saving passwords", completed: index + 1, total: rows.count))
                }
            }
            guard row.count > max(urlAt, max(userAt, passAt)) else { skipped += 1; continue }
            let host = self.host(of: row[urlAt])
            let password = row[passAt]
            guard !host.isEmpty, !password.isEmpty else { skipped += 1; continue }
            let clear = row[urlAt].trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://")
            save(host: host, user: row[userAt], password: password, clear: clear) ? (kept += 1) : (skipped += 1)
        }
        return (kept, skipped)
    }

    /// Quoted fields, doubled quotes inside them, and newlines inside those —
    /// all three turn up in a real export.
    private static func parse(csv text: String, control: ImportFile.Control? = nil) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = text.startIndex
        var scanned = 0

        while index < text.endIndex {
            scanned += 1
            if scanned % 8192 == 0, let control {
                if control.isCancelled { return [] }
                control.report(.init(message: "Reading password CSV", completed: scanned))
            }
            let c = text[index]
            if quoted {
                if c == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\n", "\r\n", "\r":
                    row.append(field)
                    field = ""
                    if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                    row = []
                default: field.append(c)
                }
            }
            index = text.index(after: index)
        }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        if let control {
            if control.isCancelled { return [] }
            control.report(.init(message: "Reading password CSV", completed: scanned))
        }
        return rows
    }
}
