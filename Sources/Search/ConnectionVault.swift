import CryptoKit
import Darwin
import Dispatch
import Foundation
import LocalAuthentication
import Security

/// Device-bound encrypted connection secrets. File access is the authorization
/// boundary; this deliberately does not provide a Keychain per-app ACL.
final class ConnectionVault: @unchecked Sendable {
    enum Entry: Equatable { case missing, value(String), deleted }
    enum Failure: Error, Equatable {
        case invalidKey, tooLarge, corrupt, unsupportedVersion
        case insecureDirectory, insecureFile, changedFile
        case secureEnclaveUnavailable, protectionUnavailable, busy
        case io(Int32)
    }

    struct KeyMaterial {
        let representation: Data
        let publicKey: P256.KeyAgreement.PublicKey
        let agreement: (P256.KeyAgreement.PublicKey) throws -> SharedSecret
    }

    /// The production initializer always uses the Secure Enclave. Explicit
    /// injection lets tests exercise real AEAD without hardware or auth UI.
    struct KeyProvider {
        let create: () throws -> KeyMaterial
        let restore: (Data) throws -> KeyMaterial

        static var secureEnclave: Self {
            Self(create: {
                guard SecureEnclave.isAvailable else { throw Failure.secureEnclaveUnavailable }
                guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                                   [.privateKeyUsage], nil) else {
                    throw Failure.protectionUnavailable
                }
                let context = LAContext()
                context.interactionNotAllowed = true
                let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(compactRepresentable: false,
                                                                        accessControl: access,
                                                                        authenticationContext: context)
                return material(key, context: context)
            }, restore: { representation in
                guard SecureEnclave.isAvailable else { throw Failure.secureEnclaveUnavailable }
                let context = LAContext()
                context.interactionNotAllowed = true
                let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: representation,
                                                                        authenticationContext: context)
                return material(key, context: context)
            })
        }

        private static func material(_ key: SecureEnclave.P256.KeyAgreement.PrivateKey, context: LAContext) -> KeyMaterial {
            KeyMaterial(representation: key.dataRepresentation, publicKey: key.publicKey,
                        agreement: { peer in
                try withExtendedLifetime(context) { try key.sharedSecretFromKeyAgreement(with: peer) }
            })
        }
    }

    private struct Envelope: Codable {
        let version: Int
        let wrappedKey: Data
        let ephemeralPublicKey: Data
        let salt: Data
        let sealed: Data
    }
    private struct Record: Codable, Equatable {
        let deleted: Bool
        let value: String?
    }
    private struct Payload: Codable, Equatable {
        let version: Int
        var records: [String: Record]
    }
    private struct Stored {
        let data: Data
        let identity: FileIdentity
    }
    private struct State {
        var payload: Payload
        let key: KeyMaterial?
        let stored: Stored?
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
                  ConnectionVault.privateDirectory(current), ConnectionVault.privateDirectory(opened) else {
                throw Failure.insecureDirectory
            }
        }
    }

    private static let fileName = "connections.vault"
    private static let lockName = "connections.lock"
    private static let maximumFileBytes = 1_048_576
    private static let maximumPayloadBytes = 524_288
    private static let maximumRecords = 1024
    private static let maximumValueBytes = 65_536
    private static let aad = Data("com.officecommun.search|ConnectionVault|schema=1|P256-HKDF-SHA256-AES256GCM".utf8)
    private static let info = Data("com.officecommun.search.ConnectionVault.encryption.v1".utf8)

    private let directory: URL
    private let keyProvider: KeyProvider
    private let lock = NSLock()
    /// Fault injection can only add a failure before the atomic replacement.
    private let beforeCommit: (() throws -> Void)?

    convenience init(directory: URL) {
        self.init(directory: directory, keyProvider: .secureEnclave)
    }

    init(directory: URL, keyProvider: KeyProvider, beforeCommit: (() throws -> Void)? = nil) {
        self.directory = directory
        self.keyProvider = keyProvider
        self.beforeCommit = beforeCommit
    }

    func read(_ key: String) throws -> Entry {
        try validate(key: key)
        return try access(create: false, missing: .missing) { directory in
            let state = try load(directory)
            guard let record = state.payload.records[key] else { return .missing }
            return record.deleted ? .deleted : .value(record.value!)
        }
    }

    func save(_ value: String, for key: String) throws {
        try validate(key: key)
        guard value.utf8.count <= Self.maximumValueBytes else { throw Failure.tooLarge }
        try change(key, to: Record(deleted: false, value: value))
    }

    func forget(_ key: String) throws {
        try validate(key: key)
        try change(key, to: Record(deleted: true, value: nil))
    }

    private func validate(key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 1024, !key.utf8.contains(0) else { throw Failure.invalidKey }
    }

    private func change(_ key: String, to record: Record) throws {
        try access(create: true, missing: ()) { directory in
            var state = try load(directory)
            if state.payload.records[key] == record { return }
            state.payload.records[key] = record
            guard state.payload.records.count <= Self.maximumRecords else { throw Failure.tooLarge }
            let material = try state.key ?? keyProvider.create()
            let encoded = try seal(state.payload, with: material)
            // Exercise hardware recovery before replacing any existing file.
            let checked = try open(encoded)
            guard checked.payload == state.payload else { throw Failure.corrupt }
            try replace(encoded, previous: state.stored, in: directory)
        }
    }

    private func load(_ directory: Directory) throws -> State {
        guard let stored = try stored(directory) else {
            return State(payload: Payload(version: 1, records: [:]), key: nil, stored: nil)
        }
        let decoded = try open(stored.data)
        return State(payload: decoded.payload, key: decoded.key, stored: stored)
    }

    private func seal(_ payload: Payload, with material: KeyMaterial) throws -> Data {
        let plaintext = try JSONEncoder().encode(payload)
        guard plaintext.count <= Self.maximumPayloadBytes else { throw Failure.tooLarge }
        let ephemeral = P256.KeyAgreement.PrivateKey(compactRepresentable: false)
        var salt = Data(count: 32)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw Failure.protectionUnavailable }
        let agreement = try ephemeral.sharedSecretFromKeyAgreement(with: material.publicKey)
        let key = derive(agreement, salt: salt)
        guard let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: Self.aad).combined else {
            throw Failure.corrupt
        }
        let data = try JSONEncoder().encode(Envelope(version: 1, wrappedKey: material.representation,
            ephemeralPublicKey: ephemeral.publicKey.x963Representation, salt: salt, sealed: sealed))
        guard data.count <= Self.maximumFileBytes else { throw Failure.tooLarge }
        return data
    }

    private func open(_ data: Data) throws -> (payload: Payload, key: KeyMaterial) {
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw Failure.corrupt }
        guard envelope.version == 1 else { throw Failure.unsupportedVersion }
        guard !envelope.wrappedKey.isEmpty, envelope.wrappedKey.count <= 16384,
              envelope.ephemeralPublicKey.count == 65, envelope.salt.count == 32,
              envelope.sealed.count >= 28 else { throw Failure.corrupt }
        let material = try keyProvider.restore(envelope.wrappedKey)
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: envelope.ephemeralPublicKey)
        let agreement = try material.agreement(ephemeral)
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed),
            using: derive(agreement, salt: envelope.salt), authenticating: Self.aad)
        guard plaintext.count <= Self.maximumPayloadBytes else { throw Failure.tooLarge }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: plaintext) }
        catch { throw Failure.corrupt }
        guard payload.version == 1 else { throw Failure.unsupportedVersion }
        guard payload.records.count <= Self.maximumRecords else { throw Failure.tooLarge }
        for (key, record) in payload.records {
            try validate(key: key)
            guard record.deleted ? record.value == nil : record.value != nil else { throw Failure.corrupt }
            guard record.value?.utf8.count ?? 0 <= Self.maximumValueBytes else { throw Failure.tooLarge }
        }
        return (payload, material)
    }

    private func derive(_ agreement: SharedSecret, salt: Data) -> SymmetricKey {
        agreement.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Self.info, outputByteCount: 32)
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
        let descriptor = openat(directory.descriptor, Self.lockName,
            O_RDWR | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT : 0), 0o600)
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

    private func stored(_ directory: Directory, name: String = ConnectionVault.fileName) throws -> Stored? {
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
        let name = ".connection-vault-\(UUID().uuidString).tmp"
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
        // Physical readback after the durable atomic replacement. The exact
        // ciphertext was authenticated before commit, so no later hardware UI
        // or unlock transition can turn readback into a destructive retry.
        guard let readback = try stored(directory), readback.data == data,
              readback.identity.device == attributes.st_dev, readback.identity.inode == attributes.st_ino else {
            throw Failure.changedFile
        }
    }
}
