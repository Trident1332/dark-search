import Foundation
import Security

// Notes of your own beside the passwords: the Wi-Fi password written on the
// router, a safe's combination, the recovery codes behind a login. Kept as
// generic keychain items of Search's, one service for all of them, the way
// Keychain Access keeps its own secure notes: the keychain encrypts the text,
// and the title is the item's name, so Keychain Access shows which is which.
// Nothing is written to disk by this app in any other form.

/// One note as the list needs it: its title and when it was last changed,
/// without the text. The text is `Vault.note(_:)`, read when the note is
/// opened and let go with it.
struct Note: Identifiable, Equatable, Hashable {
    /// The keychain account: a UUID, so two notes may share a title.
    var id: String
    var title: String
    var edited: Date?
}

extension Vault {
    /// What every note is kept under. A test run keeps its own apart.
    private static let noteService = Store.world.map { "Search Notes (\($0))" } ?? "Search Notes"

    private static func noteIdentity(_ id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: noteService,
            kSecAttrAccount as String: id,
        ]
    }

    /// Every note, newest change first, without the text.
    static func notes() -> [Note] {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: noteService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ] as CFDictionary, &out)
        guard status == errSecSuccess, let rows = out as? [[String: Any]] else {
            if status != errSecItemNotFound { NSLog("Vault: keychain note list failed (%d)", status) }
            return []
        }
        return rows.compactMap { row in
            guard let id = row[kSecAttrAccount as String] as? String else { return nil }
            let title = (row[kSecAttrLabel as String] as? String) ?? ""
            let edited = row[kSecAttrModificationDate as String] as? Date
            return Note(id: id, title: title.isEmpty ? "Untitled" : title, edited: edited)
        }
        .sorted { ($0.edited ?? .distantPast) > ($1.edited ?? .distantPast) }
    }

    /// One note's text, once it is opened.
    static func note(_ id: String) -> String? {
        var asked = noteIdentity(id)
        asked[kSecReturnData as String] = true
        asked[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(asked as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            if status != errSecItemNotFound { NSLog("Vault: keychain note read failed (%d)", status) }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// A note written or changed. Nil `id`: a new one, given its own.
    /// Answers the id, or nil when the keychain refused it.
    @discardableResult
    static func saveNote(_ id: String? = nil, title: String, text: String) -> String? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty || !text.isEmpty, let data = text.data(using: .utf8) else { return nil }
        let id = id ?? UUID().uuidString
        let fields: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: name.isEmpty ? "Untitled" : name,
            kSecAttrDescription as String: "Search note",
        ]
        let status = SecItemUpdate(noteIdentity(id) as CFDictionary, fields as CFDictionary)
        if status == errSecSuccess { return id }
        guard status == errSecItemNotFound else { return nil }
        var fresh = noteIdentity(id).merging(fields) { _, new in new }
        fresh[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(fresh as CFDictionary, nil) == errSecSuccess ? id : nil
    }

    @discardableResult
    static func forgetNote(_ id: String) -> Bool {
        SecItemDelete(noteIdentity(id) as CFDictionary) == errSecSuccess
    }
}
