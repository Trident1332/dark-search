import Darwin
import Foundation

/// A file picker grants exactly the selected file. Copying it into a private
/// workspace never grants an analysis tool access to its original parent.
enum AILocalAttachment {
    struct Attachment: Sendable {
        let workspace: URL
        let target: URL
    }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static let maximumBytes: Int64 = 500_000_000

    static func copyFile(_ source: URL) async throws -> Attachment {
        try Task.checkCancellation()
        let copy = Task.detached(priority: .userInitiated) { try copySelectedFile(source) }
        return try await withTaskCancellationHandler(operation: { try await copy.value }, onCancel: { copy.cancel() })
    }
    private static func copySelectedFile(_ source: URL) throws -> Attachment {
        try Task.checkCancellation()
        guard source.isFileURL, source.path.hasPrefix("/"), !source.path.contains("\0"),
              !["", ".", "..", "/"].contains(source.lastPathComponent) else { throw Failure(message: "Choose a local regular file to attach.") }
        // Resolve this explicitly selected path before opening it. System /var
        // aliases and user-selected parent aliases are allowed here; the final
        // selected item itself must be a regular file, never a symbolic link.
        var selected = stat()
        guard lstat(source.path, &selected) == 0, selected.st_mode & S_IFMT == S_IFREG else { throw Failure(message: "Choose a regular file; symbolic links and folders cannot be attached.") }
        let canonical = try canonicalPath(source.path)
        let input = try openWithoutSymlinks(canonical, directory: false)
        defer { close(input) }
        var before = stat()
        guard fstat(input, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_dev == selected.st_dev, before.st_ino == selected.st_ino else { throw Failure(message: "The selected file changed before it could be attached.") }
        guard before.st_size >= 0, before.st_size <= maximumBytes else { throw Failure(message: "Attachments must be 500 MB or smaller.") }

        let temporary = try canonicalPath(FileManager.default.temporaryDirectory.path)
        var template = Array((temporary + "/search-ai-attachment-XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { throw Failure(message: "The private attachment folder could not be created.") }
        let workspace = URL(fileURLWithPath: String(cString: template), isDirectory: true)
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: workspace) } }
        let directory = try openWithoutSymlinks(workspace.path, directory: true)
        defer { close(directory) }
        guard fchmod(directory, 0o700) == 0 else { throw Failure(message: "The attachment folder could not be made private.") }
        let basename = source.lastPathComponent
        let output = openat(directory, basename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw Failure(message: "The attachment copy could not be created.") }
        defer { close(output) }
        guard fchmod(output, 0o600) == 0 else { throw Failure(message: "The attachment copy could not be made private.") }
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try Task.checkCancellation()
            // Read at most the originally captured size plus one byte. A
            // growing file cannot keep this stream running indefinitely.
            let remaining = before.st_size - total
            let count = Darwin.read(input, &buffer, min(buffer.count, Int(max(0, remaining)) + 1))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw Failure(message: "The selected attachment could not be read.") }
            if count == 0 { break }
            total += Int64(count)
            guard total <= before.st_size, total <= maximumBytes else { throw Failure(message: "The selected file grew while it was being attached. Try again after it stops changing.") }
            try buffer.withUnsafeBytes { bytes in
                var offset = 0
                while offset < count {
                    try Task.checkCancellation()
                    let written = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw Failure(message: "The private attachment copy could not be written.") }
                    offset += written
                }
            }
        }
        var after = stat()
        guard fstat(input, &after) == 0, after.st_mode & S_IFMT == S_IFREG,
              after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              after.st_size == before.st_size, total == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else {
            throw Failure(message: "The selected file changed while it was being attached. Try again after it stops changing.")
        }
        guard fsync(output) == 0 else { throw Failure(message: "The attachment copy could not be saved.") }
        try Task.checkCancellation()
        finished = true
        return Attachment(workspace: workspace, target: workspace.appendingPathComponent(basename))
    }
    private static func canonicalPath(_ path: String) throws -> String {
        guard !path.contains("\0"), let pointer = realpath(path, nil) else { throw Failure(message: "The selected file or temporary folder is unavailable.") }
        defer { free(pointer) }; return String(cString: pointer)
    }
    private static func openWithoutSymlinks(_ path: String, directory: Bool) throws -> Int32 {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard path.hasPrefix("/"), !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." }) else { throw Failure(message: "The selected attachment path is invalid.") }
        var parent = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Failure(message: "The selected attachment folder is unavailable.") }
        defer { close(parent) }
        for part in parts.dropLast() {
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Failure(message: "The attachment path changed or contains a symbolic link.") }
            close(parent); parent = next
        }
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (directory ? O_DIRECTORY : 0)
        let result = openat(parent, parts.last!, flags)
        guard result >= 0 else { throw Failure(message: "The selected attachment changed or is no longer a regular file.") }
        return result
    }
}
