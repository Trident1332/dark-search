import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Search

final class AILocalAttachmentTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/search-attachment-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func testCopiesOnlySelectedFileAndPreservesOriginalWithPrivateMetadata() async throws {
        let source = root.appendingPathComponent("selected file.js")
        let sibling = root.appendingPathComponent("unselected-secret.txt")
        let bytes = Data("function selected() { return 42; }\n".utf8)
        try bytes.write(to: source); try Data("unselected fixture".utf8).write(to: sibling)
        let before = try FileManager.default.attributesOfItem(atPath: source.path)
        let copy = try await AILocalAttachment.copyFile(source)
        defer { try? FileManager.default.removeItem(at: copy.workspace) }
        XCTAssertNotEqual(copy.workspace, root)
        XCTAssertEqual(copy.target.lastPathComponent, source.lastPathComponent)
        XCTAssertEqual(copy.target.deletingLastPathComponent(), copy.workspace)
        XCTAssertEqual(try Data(contentsOf: copy.target), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: copy.workspace.path), [source.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.workspace.appendingPathComponent(sibling.lastPathComponent).path))
        let directory = try FileManager.default.attributesOfItem(atPath: copy.workspace.path)
        let file = try FileManager.default.attributesOfItem(atPath: copy.target.path)
        XCTAssertEqual((directory[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let after = try FileManager.default.attributesOfItem(atPath: source.path)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        // Mutating the isolated copy cannot change the original inode.
        try Data("edited private fixture".utf8).write(to: copy.target)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
    func testMultiChunkCopyAndIndependentWorkspaces() async throws {
        let source = root.appendingPathComponent("multi.bin")
        let bytes = Data((0..<400_003).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        let first = try await AILocalAttachment.copyFile(source)
        let second = try await AILocalAttachment.copyFile(source)
        defer { try? FileManager.default.removeItem(at: first.workspace); try? FileManager.default.removeItem(at: second.workspace) }
        XCTAssertNotEqual(first.workspace, second.workspace)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: first.target)), SHA256.hash(data: bytes))
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: second.target)), SHA256.hash(data: bytes))
    }
    func testOversizedSparseFileFailsBeforeCopyWithoutChangingSource() async throws {
        let source = root.appendingPathComponent("huge.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let fd = Darwin.open(source.path, O_WRONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { if fd >= 0 { close(fd) } }
        XCTAssertEqual(ftruncate(fd, off_t(AILocalAttachment.maximumBytes + 1)), 0)
        do { _ = try await AILocalAttachment.copyFile(source); XCTFail("Oversized file copied") }
        catch { XCTAssertTrue(error.localizedDescription.contains("500 MB")) }
        let size = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber
        XCTAssertEqual(size?.int64Value, AILocalAttachment.maximumBytes + 1)
    }
    func testSymlinksDirectoriesAndFIFOsAreRejected() async throws {
        let source = root.appendingPathComponent("original.txt")
        try Data("unchanged".utf8).write(to: source)
        let symbolic = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: source)
        let fifo = root.appendingPathComponent("named-pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        for candidate in [symbolic, root!, fifo] {
            do { _ = try await AILocalAttachment.copyFile(candidate); XCTFail("Accepted nonregular file: \(candidate)") }
            catch { XCTAssertTrue(error.localizedDescription.contains("regular file")) }
        }
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "unchanged")
    }
    func testCancelledAttachmentNeverStartsCopy() async throws {
        let source = root.appendingPathComponent("cancelled.txt")
        try Data("unchanged".utf8).write(to: source)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AILocalAttachment.copyFile(source)
        }
        do { _ = try await task.value; XCTFail("Cancelled copy succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "unchanged")
    }
}
