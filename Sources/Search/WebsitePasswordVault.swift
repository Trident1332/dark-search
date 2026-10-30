import CryptoKit
import Darwin
import Dispatch
import Foundation
import LocalAuthentication
import Security

/// Website passwords belong to this browser's own encrypted file, independently
/// of legacy Keychain items and connection passwords. Metadata can be listed
/// without unlocking a secret; the Secure Enclave enforces biometry on every
/// private-key agreement used to open a password or note.
final class WebsitePasswordVault: @unchecked Sendable {
    enum Failure: LocalizedError, Equatable {
        case invalidKey, tooLarge, corrupt, unsupportedVersion, missing, changedRecord
        case insecureDirectory, insecureFile, changedFile
        case secureEnclaveUnavailable, protectionUnavailable, authenticationRequired, busy
        case io(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidKey: return "The website or account details are not valid"
            case .tooLarge: return "The website password vault or one of its entries exceeds the supported size"
            case .corrupt: return "The website password vault could not be read safely"
            case .unsupportedVersion: return "This website password vault requires a newer version of Search"
            case .missing: return "This website login is no longer saved"
            case .changedRecord: return "The saved website login changed. Choose it again"
            case .insecureDirectory: return "The website password folder could not be opened safely. Check its private permissions"
            case .insecureFile: return "The website password file could not be opened safely. Check its private permissions"
            case .changedFile: return "The website password vault changed while it was being saved. Try again"
            case .secureEnclaveUnavailable: return "Website passwords require this Mac's Secure Enclave"
            case .protectionUnavailable: return "This Mac could not protect the website password vault with Touch ID"
            case .authenticationRequired: return "Approve Touch ID to unlock this website password"
            case .busy: return "The website password vault is busy. Try again"
            case .io: return "The website password vault could not access its storage. Try again"
            }
        }
    }

    struct KeyMaterial {
        let representation: Data
        let publicKey: P256.KeyAgreement.PublicKey
    }

    /// A capability for undoing exactly one insertion. Its fingerprint
    /// covers ciphertext as well as metadata, so a password edited without
    /// changing the displayed account information cannot be rolled back.
    struct ImportReceipt {
        fileprivate let directory: String
        fileprivate let identity: String
        fileprivate let key: Data
        fileprivate let record: Data
    }

    /// Tests may inject software keys, but the production default has no
    /// software fallback. Public-key restoration does not use a private key.
    struct KeyProvider {
        let create: () throws -> KeyMaterial
        let publicKey: (Data) throws -> P256.KeyAgreement.PublicKey
        let agreement: (Data, P256.KeyAgreement.PublicKey, LAContext?) throws -> SharedSecret

        static var secureEnclave: Self {
            Self(create: {
                guard SecureEnclave.isAvailable else { throw Failure.secureEnclaveUnavailable }
                guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                    [.privateKeyUsage, .biometryAny], nil) else { throw Failure.protectionUnavailable }
                let context = LAContext()
                context.interactionNotAllowed = true
                let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(compactRepresentable: false,
                    accessControl: access, authenticationContext: context)
                return KeyMaterial(representation: key.dataRepresentation, publicKey: key.publicKey)
            }, publicKey: { data in
                guard SecureEnclave.isAvailable else { throw Failure.secureEnclaveUnavailable }
                let context = LAContext()
                context.interactionNotAllowed = true
                return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data,
                    authenticationContext: context).publicKey
            }, agreement: { data, peer, context in
                guard SecureEnclave.isAvailable else { throw Failure.secureEnclaveUnavailable }
                guard let context else { throw Failure.authenticationRequired }
                // The facade proves presence with this same context. If that
                // proof has expired or was denied, fail instead of opening a
                // second prompt or falling back to the Mac account password.
                context.interactionNotAllowed = true
                let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data,
                    authenticationContext: context)
                return try withExtendedLifetime(context) { try key.sharedSecretFromKeyAgreement(with: peer) }
            })
        }

        /// Never selected outside Store.testing. Its raw software keys live
        /// only in the isolated test folder, with no hardware or auth UI.
        fileprivate static var rehearsal: Self {
            Self(create: {
                let key = P256.KeyAgreement.PrivateKey(compactRepresentable: false)
                return KeyMaterial(representation: key.rawRepresentation, publicKey: key.publicKey)
            }, publicKey: { try P256.KeyAgreement.PrivateKey(rawRepresentation: $0).publicKey },
            agreement: { data, peer, _ in
                try P256.KeyAgreement.PrivateKey(rawRepresentation: data).sharedSecretFromKeyAgreement(with: peer)
            })
        }
    }

    static let shared = WebsitePasswordVault(
        directory: Store.folder.appendingPathComponent("Website Passwords", isDirectory: true),
        keyProvider: Store.testing ? .rehearsal : .secureEnclave)

    private struct Box: Codable {
        let ephemeralPublicKey: Data
        let salt: Data
        let sealed: Data
    }
    private struct Record: Codable {
        let host: String
        let user: String
        let clear: Bool
        var used: Date?
        let since: Date
        let password: Box
        let notes: Box?

        var kept: Kept { Kept(host: host, user: user, used: used, clear: clear, since: since) }
    }
    private struct Body: Codable {
        let version: Int
        let wrappedKey: Data
        let publicKey: Data
        var records: [String: Record]
    }
    private struct Envelope: Codable {
        let body: Body
        /// Detect incomplete/accidentally changed files before unauthenticated
        /// metadata operations. Secret authenticity comes from each AEAD tag,
        /// checked when its hardware-protected key is used, not this checksum.
        let checksum: Data
    }
    private struct State {
        var body: Body
        let publicKey: P256.KeyAgreement.PublicKey
        let stored: Stored?
    }

    private struct Stored {
        let data: Data
        let identity: FileIdentity
    }
    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }

    private final class Directory {
        let parent: Int32
        let descriptor: Int32
        let name: String
        let device: dev_t
        let inode: ino_t
        init(parent: Int32, descriptor: Int32, name: String, attributes: stat) {
            self.parent = parent; self.descriptor = descriptor; self.name = name
            device = attributes.st_dev; inode = attributes.st_ino
        }
        deinit { Darwin.close(descriptor); Darwin.close(parent) }
        func verify() throws {
            var current = stat(), opened = stat()
            guard fstat(descriptor, &opened) == 0,
                  fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_dev == device, current.st_ino == inode,
                  opened.st_dev == device, opened.st_ino == inode,
                  WebsitePasswordVault.privateDirectory(current), WebsitePasswordVault.privateDirectory(opened) else {
                throw Failure.insecureDirectory
            }
        }
    }

    private static let fileName = "websites.vault"
    private static let lockName = "websites.lock"
    private static let maximumFileBytes = 16 * 1_048_576
    private static let maximumRecords = 4000
    private static let maximumPasswordBytes = 65_536
    private static let maximumNotesBytes = 262_144
    private static let info = Data("com.officecommun.search.WebsitePasswordVault.P256-HKDF-SHA256-AES256GCM.v1".utf8)

    private let directory: URL
    private let keyProvider: KeyProvider
    private let lock = NSLock()
    private let beforeCommit: (() throws -> Void)?

    convenience init(directory: URL) { self.init(directory: directory, keyProvider: .secureEnclave) }

    init(directory: URL, keyProvider: KeyProvider, beforeCommit: (() throws -> Void)? = nil) {
        self.directory = directory
        self.keyProvider = keyProvider
        self.beforeCommit = beforeCommit
    }

    func entries() throws -> [Kept] {
        try access(create: false, missing: []) { directory in
            guard let state = try load(directory) else { return [] }
            return state.body.records.values.map(\.kept).sorted {
                $0.host == $1.host ? $0.user < $1.user : $0.host < $1.host
            }
        }
    }

    func all() throws -> [Kept] { try entries() }

    func read(_ kept: Kept, context: LAContext? = nil) throws -> Secret {
        let host = try canonicalHost(kept.host)
        try validate(user: kept.user)
        let result: Secret? = try access(create: false, missing: Optional<Secret>.none) { directory -> Secret? in
            guard let state = try load(directory), let record = state.body.records[Self.identity(host, kept.user)] else { return nil }
            guard record.clear == kept.clear else { throw Failure.changedRecord }
            let password = try open(record.password, purpose: "password", record: record, state: state,
                                    maximum: Self.maximumPasswordBytes, context: context)
            let notes = try record.notes.map {
                try open($0, purpose: "notes", record: record, state: state, maximum: Self.maximumNotesBytes, context: context)
            } ?? ""
            guard !password.isEmpty else { throw Failure.corrupt }
            return Secret(password: password, notes: notes)
        }
        guard let result else { throw Failure.missing }
        return result
    }

    func save(host: String, user: String, password: String, used: Date? = nil,
              clear: Bool = false, notes: String? = nil) throws {
        let host = try canonicalHost(host)
        try validate(user: user)
        guard !password.isEmpty else { throw Failure.invalidKey }
        guard password.utf8.count <= Self.maximumPasswordBytes,
              notes?.utf8.count ?? 0 <= Self.maximumNotesBytes else { throw Failure.tooLarge }
        guard used?.timeIntervalSinceReferenceDate.isFinite != false else { throw Failure.invalidKey }
        try access(create: true, missing: ()) { directory in
            var state = try stateForSaving(in: directory)
            let id = Self.identity(host, user), prior = state.body.records[id]
            // An old note's AAD includes its original transport boundary.
            // Do not silently drop it or decrypt it while changing that boundary.
            if notes == nil, prior?.notes != nil, prior?.clear != clear { throw Failure.changedRecord }
            let aad = Self.binding(host: host, user: user, clear: clear, purpose: "password")
            let sealedPassword = try seal(password, aad: aad, publicKey: state.publicKey)
            let sealedNotes: Box?
            if let notes {
                sealedNotes = notes.isEmpty ? nil : try seal(notes,
                    aad: Self.binding(host: host, user: user, clear: clear, purpose: "notes"), publicKey: state.publicKey)
            } else { sealedNotes = prior?.notes }
            state.body.records[id] = Record(host: host, user: user, clear: clear, used: used ?? prior?.used,
                since: prior?.since ?? Date(), password: sealedPassword, notes: sealedNotes)
            guard state.body.records.count <= Self.maximumRecords else { throw Failure.tooLarge }
            try replace(encode(state.body), previous: state.stored, in: directory)
        }
    }

    /// Import never replaces an existing login. The absence check and
    /// insertion share the same interprocess lock and durable replacement.
    func insertImported(_ kept: Kept, secret: Secret) throws -> ImportReceipt? {
        let host = try canonicalHost(kept.host)
        try validate(user: kept.user)
        guard !secret.password.isEmpty else { throw Failure.invalidKey }
        guard secret.password.utf8.count <= Self.maximumPasswordBytes,
              secret.notes.utf8.count <= Self.maximumNotesBytes else { throw Failure.tooLarge }
        guard kept.used?.timeIntervalSinceReferenceDate.isFinite != false,
              kept.since?.timeIntervalSinceReferenceDate.isFinite != false else { throw Failure.invalidKey }
        return try access(create: true, missing: Optional<ImportReceipt>.none) { directory in
            var state = try stateForSaving(in: directory)
            let id = Self.identity(host, kept.user)
            guard state.body.records[id] == nil else { return nil }
            let record = Record(host: host, user: kept.user, clear: kept.clear, used: kept.used,
                since: kept.since ?? Date(),
                password: try seal(secret.password, aad: Self.binding(host: host, user: kept.user,
                    clear: kept.clear, purpose: "password"), publicKey: state.publicKey),
                notes: secret.notes.isEmpty ? nil : try seal(secret.notes,
                    aad: Self.binding(host: host, user: kept.user, clear: kept.clear, purpose: "notes"),
                    publicKey: state.publicKey))
            state.body.records[id] = record
            guard state.body.records.count <= Self.maximumRecords else { throw Failure.tooLarge }
            let receipt = ImportReceipt(directory: self.directory.path, identity: id,
                key: Self.keyFingerprint(state.body), record: try Self.fingerprint(record))
            try replace(encode(state.body), previous: state.stored, in: directory)
            return receipt
        }
    }

    /// Undo a failed import only while its exact record is still present.
    /// Any intervening password, note or metadata update survives rollback.
    @discardableResult
    func discardImported(_ receipt: ImportReceipt) throws -> Bool {
        guard receipt.directory == directory.path else { return false }
        return try access(create: false, missing: false) { directory in
            guard var state = try load(directory), Self.keyFingerprint(state.body) == receipt.key,
                  let record = state.body.records[receipt.identity],
                  try Self.fingerprint(record) == receipt.record else { return false }
            state.body.records[receipt.identity] = nil
            try replace(encode(state.body), previous: state.stored, in: directory)
            return true
        }
    }

    private func stateForSaving(in directory: Directory) throws -> State {
        if let existing = try load(directory) { return existing }
        let key = try keyProvider.create()
        guard !key.representation.isEmpty, key.representation.count <= 16_384 else { throw Failure.corrupt }
        let restored = try keyProvider.publicKey(key.representation)
        guard restored.x963Representation == key.publicKey.x963Representation else { throw Failure.corrupt }
        return State(body: Body(version: 1, wrappedKey: key.representation,
            publicKey: key.publicKey.x963Representation, records: [:]), publicKey: restored, stored: nil)
    }

    private static func keyFingerprint(_ body: Body) -> Data {
        Data(SHA256.hash(data: body.wrappedKey + body.publicKey))
    }

    private static func fingerprint(_ record: Record) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(record)))
    }

    /// Last-used metadata never reads or rewrites the encrypted fields.
    func touch(_ kept: Kept, at date: Date = Date()) throws {
        let host = try canonicalHost(kept.host)
        try validate(user: kept.user)
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw Failure.invalidKey }
        try access(create: false, missing: ()) { directory in
            guard var state = try load(directory) else { return }
            let id = Self.identity(host, kept.user)
            guard var record = state.body.records[id] else { return }
            guard record.clear == kept.clear else { throw Failure.changedRecord }
            record.used = date
            state.body.records[id] = record
            try replace(encode(state.body), previous: state.stored, in: directory)
        }
    }

    func forget(_ kept: Kept) throws {
        let host = try canonicalHost(kept.host)
        try validate(user: kept.user)
        try access(create: false, missing: ()) { directory in
            guard var state = try load(directory) else { return }
            guard state.body.records.removeValue(forKey: Self.identity(host, kept.user)) != nil else { return }
            try replace(encode(state.body), previous: state.stored, in: directory)
        }
    }

    private func canonicalHost(_ host: String) throws -> String {
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value.utf8.count <= 1024,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !value.contains("/"), !value.contains("\\") else { throw Failure.invalidKey }
        return value
    }

    private func validate(user: String) throws {
        guard user.utf8.count <= 4096, !user.utf8.contains(0) else { throw Failure.invalidKey }
    }

    private static func identity(_ host: String, _ user: String) -> String {
        SHA256.hash(data: try! JSONEncoder().encode([host, user])).map { String(format: "%02x", $0) }.joined()
    }

    private static func binding(host: String, user: String, clear: Bool, purpose: String) -> Data {
        // An array has unambiguous lengths/separators even for unusual account names.
        try! JSONEncoder().encode(["com.officecommun.search", "WebsitePasswordVault", "1", host, user,
                                  clear ? "http" : "https", purpose])
    }

    private func seal(_ value: String, aad: Data, publicKey: P256.KeyAgreement.PublicKey) throws -> Box {
        let ephemeral = P256.KeyAgreement.PrivateKey(compactRepresentable: false)
        var salt = Data(count: 32)
        guard salt.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess else {
            throw Failure.protectionUnavailable
        }
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: publicKey)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Self.info + aad, outputByteCount: 32)
        guard let combined = try AES.GCM.seal(Data(value.utf8), using: key, authenticating: aad).combined else { throw Failure.corrupt }
        return Box(ephemeralPublicKey: ephemeral.publicKey.x963Representation, salt: salt, sealed: combined)
    }

    private func open(_ box: Box, purpose: String, record: Record, state: State,
                      maximum: Int, context: LAContext?) throws -> String {
        let aad = Self.binding(host: record.host, user: record.user, clear: record.clear, purpose: purpose)
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: box.ephemeralPublicKey)
        let shared = try keyProvider.agreement(state.body.wrappedKey, peer, context)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: box.salt, sharedInfo: Self.info + aad, outputByteCount: 32)
        let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: box.sealed), using: key, authenticating: aad)
        guard bytes.count <= maximum, let value = String(data: bytes, encoding: .utf8) else { throw Failure.corrupt }
        return value
    }

    private func encode(_ body: Body) throws -> Data {
        let canonical = JSONEncoder()
        canonical.outputFormatting = [.sortedKeys]
        let checksum = Data(SHA256.hash(data: try canonical.encode(body)))
        let data = try canonical.encode(Envelope(body: body, checksum: checksum))
        guard data.count <= Self.maximumFileBytes else { throw Failure.tooLarge }
        return data
    }

    private func load(_ directory: Directory) throws -> State? {
        guard let previous = try stored(directory) else { return nil }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: previous.data) }
        catch { throw Failure.corrupt }
        let body = envelope.body
        guard body.version == 1 else { throw Failure.unsupportedVersion }
        let canonical = JSONEncoder()
        canonical.outputFormatting = [.sortedKeys]
        guard envelope.checksum.count == 32,
              Data(SHA256.hash(data: try canonical.encode(body))) == envelope.checksum,
              !body.wrappedKey.isEmpty, body.wrappedKey.count <= 16_384,
              body.publicKey.count == 65, body.records.count <= Self.maximumRecords else { throw Failure.corrupt }
        let publicKey = try keyProvider.publicKey(body.wrappedKey)
        guard publicKey.x963Representation == body.publicKey else { throw Failure.corrupt }
        for (id, record) in body.records {
            guard try canonicalHost(record.host) == record.host,
                  id == Self.identity(record.host, record.user),
                  record.since.timeIntervalSinceReferenceDate.isFinite,
                  record.used?.timeIntervalSinceReferenceDate.isFinite != false else { throw Failure.corrupt }
            try validate(user: record.user)
            try validate(record.password, maximum: Self.maximumPasswordBytes)
            if let notes = record.notes { try validate(notes, maximum: Self.maximumNotesBytes) }
        }
        return State(body: body, publicKey: publicKey, stored: previous)
    }

    private func validate(_ box: Box, maximum: Int) throws {
        guard box.ephemeralPublicKey.count == 65, box.salt.count == 32,
              box.sealed.count >= 28, box.sealed.count <= maximum + 28 else { throw Failure.corrupt }
        _ = try P256.KeyAgreement.PublicKey(x963Representation: box.ephemeralPublicKey)
    }

    private static func privateDirectory(_ attributes: stat) -> Bool {
        attributes.st_mode & S_IFMT == S_IFDIR && attributes.st_uid == geteuid()
            && attributes.st_mode & 0o777 == 0o700
    }
    private static func privateFile(_ attributes: stat) -> Bool {
        attributes.st_mode & S_IFMT == S_IFREG && attributes.st_uid == geteuid()
            && attributes.st_mode & 0o777 == 0o600 && attributes.st_nlink == 1
    }

    private func openDirectory(create: Bool) throws -> Directory? {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.path.utf8.contains(0) else {
            throw Failure.insecureDirectory
        }
        let components = directory.pathComponents.filter { $0 != "/" }
        guard let name = components.last, !components.contains(".."), !components.contains(".") else {
            throw Failure.insecureDirectory
        }
        var parent = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw Failure.io(errno) }
        for component in components.dropLast() {
            var next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            var requirePrivate = false
            if next < 0, errno == ENOENT, create {
                requirePrivate = true
                if mkdirat(parent, component, 0o700) == 0 {
                    guard fsync(parent) == 0 else {
                        let status = errno; Darwin.close(parent); throw Failure.io(status)
                    }
                } else if errno != EEXIST {
                    let status = errno; Darwin.close(parent); throw Failure.io(status)
                }
                next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            if next < 0 {
                let status = errno; Darwin.close(parent)
                if !create, status == ENOENT { return nil }
                throw status == ELOOP || status == ENOTDIR ? Failure.insecureDirectory : Failure.io(status)
            }
            if requirePrivate {
                var attributes = stat()
                guard fstat(next, &attributes) == 0, Self.privateDirectory(attributes) else {
                    Darwin.close(next); Darwin.close(parent); throw Failure.insecureDirectory
                }
            }
            Darwin.close(parent); parent = next
        }
        var descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT, create {
            if mkdirat(parent, name, 0o700) == 0 {
                guard fsync(parent) == 0 else {
                    let status = errno; Darwin.close(parent); throw Failure.io(status)
                }
            } else if errno != EEXIST {
                let status = errno; Darwin.close(parent); throw Failure.io(status)
            }
            descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            let status = errno; Darwin.close(parent)
            if !create, status == ENOENT { return nil }
            throw status == ELOOP || status == ENOTDIR ? Failure.insecureDirectory : Failure.io(status)
        }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, Self.privateDirectory(attributes) else {
            Darwin.close(descriptor); Darwin.close(parent); throw Failure.insecureDirectory
        }
        return Directory(parent: parent, descriptor: descriptor, name: name, attributes: attributes)
    }

    private func access<T>(create: Bool, missing: T, body: (Directory) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard let directory = try openDirectory(create: create) else { return missing }
        let flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC
        var descriptor = openat(directory.descriptor, Self.lockName, flags)
        if descriptor < 0, create, errno == ENOENT {
            // Concurrent O_CREAT opens can report ENOENT on macOS even
            // after the other creator has installed the file. Create only
            // if absent, then open the winning file without O_CREAT. Never
            // unlink, chmod or replace an existing lock to make it usable.
            descriptor = openat(directory.descriptor, Self.lockName, flags | O_CREAT | O_EXCL, 0o600)
            if descriptor < 0, errno == EEXIST || errno == ENOENT {
                descriptor = openat(directory.descriptor, Self.lockName, flags)
            }
        }
        if descriptor < 0 {
            if !create, errno == ENOENT {
                var found = stat()
                if fstatat(directory.descriptor, Self.fileName, &found, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT {
                    return missing
                }
            }
            throw Failure.insecureFile
        }
        defer { Darwin.close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, Self.privateFile(attributes) else { throw Failure.insecureFile }
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else { throw Failure.io(errno) }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw Failure.busy }
            usleep(10_000)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        var current = stat()
        guard fstatat(directory.descriptor, Self.lockName, &current, AT_SYMLINK_NOFOLLOW) == 0,
              Self.privateFile(current), current.st_dev == attributes.st_dev, current.st_ino == attributes.st_ino else {
            throw Failure.changedFile
        }
        try directory.verify()
        let result = try body(directory)
        try directory.verify()
        return result
    }

    private func stored(_ directory: Directory, name: String = WebsitePasswordVault.fileName) throws -> Stored? {
        let descriptor = openat(directory.descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw Failure.insecureFile
        }
        defer { Darwin.close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, Self.privateFile(attributes),
              attributes.st_size > 0, attributes.st_size <= Self.maximumFileBytes else { throw Failure.insecureFile }
        let identity = FileIdentity(attributes)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure.io(errno)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= Self.maximumFileBytes else { throw Failure.tooLarge }
        }
        var after = stat(), current = stat()
        guard fstat(descriptor, &after) == 0, Self.privateFile(after), FileIdentity(after) == identity,
              fstatat(directory.descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              Self.privateFile(current), FileIdentity(current) == identity else { throw Failure.changedFile }
        return Stored(data: data, identity: identity)
    }

    private func replace(_ data: Data, previous: Stored?, in directory: Directory) throws {
        let name = ".website-password-vault-\(UUID().uuidString).tmp"
        let descriptor = openat(directory.descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.io(errno) }
        defer { Darwin.close(descriptor); _ = unlinkat(directory.descriptor, name, 0) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, Self.privateFile(attributes) else { throw Failure.insecureFile }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.io(errno) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw Failure.io(errno) }
        try beforeCommit?()
        try directory.verify()
        let current = try stored(directory)
        guard current?.identity == previous?.identity, current?.data == previous?.data else { throw Failure.changedFile }
        guard let staged = try stored(directory, name: name), staged.data == data,
              staged.identity.device == attributes.st_dev, staged.identity.inode == attributes.st_ino else {
            throw Failure.changedFile
        }
        var temporary = stat()
        guard fstatat(directory.descriptor, name, &temporary, AT_SYMLINK_NOFOLLOW) == 0,
              Self.privateFile(temporary), temporary.st_dev == attributes.st_dev, temporary.st_ino == attributes.st_ino else {
            throw Failure.changedFile
        }
        guard renameat(directory.descriptor, name, directory.descriptor, Self.fileName) == 0 else { throw Failure.io(errno) }
        guard fsync(directory.descriptor) == 0 else { throw Failure.io(errno) }
        // Physical readback after the durable atomic replacement checks the
        // exact staged bytes without any private-key operation or auth UI.
        guard let readback = try stored(directory), readback.data == data,
              readback.identity.device == attributes.st_dev, readback.identity.inode == attributes.st_ino else {
            throw Failure.changedFile
        }
    }
}
