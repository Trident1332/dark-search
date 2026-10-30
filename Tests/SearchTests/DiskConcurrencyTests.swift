import Foundation
import XCTest
@testable import Search

/// Hold a physical write, rather than just an encoder, to verify that
/// publishing background saves never waits for filesystem work. Every file
/// is disposable; no live browser data or process is involved.
final class DiskConcurrencyTests: XCTestCase {
    private var folder: URL!
    private var release: [() -> Void] = []

    override class func setUp() {
        setenv("SEARCH_PROBE", "disk-concurrency-\(getpid())", 1)
        super.setUp()
    }

    override func setUpWithError() throws {
        Disk.drain()
        Disk.useWriterForTesting(nil)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("disk-concurrency-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for unblock in release { unblock() }
        release.removeAll()
        Disk.drain()
        Disk.useWriterForTesting(nil)
        try? FileManager.default.removeItem(at: folder)
    }

    func testBackgroundWriteAndRemovalPublishWhileAnotherWriteIsInFilesystemIO() throws {
        let slow = slowWriter("first.json")
        Disk.write(slow.file) { slow.held }
        XCTAssertEqual(slow.entered.wait(timeout: .now() + 2), .success)
        let second = file("second.json")
        let published = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            Disk.write(second) { Data("second".utf8) }
            Disk.remove(slow.file)
            published.signal()
        }
        let responsive = published.wait(timeout: .now() + 0.3)
        XCTAssertEqual(responsive, .success, "Neither background enqueue nor deletion publication may wait for the slow write")
        slow.open()
        if responsive != .success { XCTAssertEqual(published.wait(timeout: .now() + 2), .success) }
        Disk.drain()
        XCTAssertFalse(FileManager.default.fileExists(atPath: slow.file.path), "The requested deletion must follow the in-flight write")
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
    }

    func testImmediateWriteOfAnotherFileDoesNotWaitForSlowFile() throws {
        let slow = slowWriter("slow.json")
        Disk.write(slow.file) { slow.held }
        XCTAssertEqual(slow.entered.wait(timeout: .now() + 2), .success)
        let other = file("immediate.json")
        let complete = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            Disk.write(other, now: true) { Data("independent".utf8) }
            complete.signal()
        }
        let responsive = complete.wait(timeout: .now() + 0.3)
        XCTAssertEqual(responsive, .success, "One file's I/O must not lock every other file")
        if responsive == .success { XCTAssertEqual(try Data(contentsOf: other), Data("independent".utf8)) }
        slow.open()
        if responsive != .success { XCTAssertEqual(complete.wait(timeout: .now() + 2), .success) }
        Disk.drain()
        XCTAssertEqual(try Data(contentsOf: slow.file), slow.held)
    }

    func testImmediateNewestWriteSurvivesAnOlderQueuedJob() throws {
        let blocker = blockQueue()
        XCTAssertEqual(blocker.entered.wait(timeout: .now() + 2), .success)
        let target = file("session.json")
        Disk.write(target) { Data("old queued session".utf8) }
        Disk.write(target, now: true) { Data("new immediate session".utf8) }
        XCTAssertEqual(try Data(contentsOf: target), Data("new immediate session".utf8))
        blocker.open()
        Disk.drain()
        XCTAssertEqual(try Data(contentsOf: target), Data("new immediate session".utf8), "A stale queued snapshot must not replace the immediate save")
    }

    func testRemovalInvalidatesOlderQueuedWritesAndCannotResurrectFile() throws {
        let target = file("history.json")
        Disk.write(target, now: true) { Data("existing history".utf8) }
        let blocker = blockQueue()
        XCTAssertEqual(blocker.entered.wait(timeout: .now() + 2), .success)
        Disk.write(target) { Data("stale history".utf8) }
        Disk.remove(target)
        blocker.open()
        Disk.drain()
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testOlderQueuedRemovalCannotDeleteANewerImmediateSave() throws {
        let target = file("tabs.json")
        Disk.write(target, now: true) { Data("existing tabs".utf8) }
        let blocker = blockQueue()
        XCTAssertEqual(blocker.entered.wait(timeout: .now() + 2), .success)
        Disk.remove(target)
        Disk.write(target, now: true) { Data("new tabs".utf8) }
        blocker.open()
        Disk.drain()
        XCTAssertEqual(try Data(contentsOf: target), Data("new tabs".utf8))
    }

    func testImmediateSameFileSavePublishesThenSerializesCommitBehindOlderIO() throws {
        let slow = slowWriter("window.json")
        Disk.write(slow.file) { slow.held }
        XCTAssertEqual(slow.entered.wait(timeout: .now() + 2), .success)
        let encoded = DispatchSemaphore(value: 0)
        let complete = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            Disk.write(slow.file, now: true) {
                encoded.signal()
                return Data("latest window".utf8)
            }
            complete.signal()
        }
        XCTAssertEqual(encoded.wait(timeout: .now() + 0.3), .success, "The newest generation must publish without waiting for filesystem I/O")
        XCTAssertEqual(complete.wait(timeout: .now() + 0.05), .timedOut, "Same-file commits must serialize, so an old write cannot land after the newer immediate save returns")
        slow.open()
        XCTAssertEqual(complete.wait(timeout: .now() + 2), .success)
        Disk.drain()
        XCTAssertEqual(try Data(contentsOf: slow.file), Data("latest window".utf8))
    }

    private func file(_ name: String) -> URL { folder.appendingPathComponent(name) }

    private func slowWriter(_ name: String) -> SlowWriter {
        let slow = SlowWriter(file: file(name))
        release.append { slow.open() }
        Disk.useWriterForTesting { data, file in try slow.write(data, to: file) }
        return slow
    }

    private func blockQueue() -> EncoderGate {
        let gate = EncoderGate()
        release.append { gate.open() }
        Disk.write(file("queue-blocker-\(UUID().uuidString)")) {
            gate.entered.signal()
            guard gate.permission.wait(timeout: .now() + 5) == .success else { return nil }
            return Data("blocker".utf8)
        }
        return gate
    }

    private final class SlowWriter: @unchecked Sendable {
        let file: URL
        let held = Data("held physical write".utf8)
        let entered = DispatchSemaphore(value: 0)
        private let permission = DispatchSemaphore(value: 0)
        init(file: URL) { self.file = file }
        func open() { permission.signal() }
        func write(_ data: Data, to file: URL) throws {
            if file == self.file, data == held {
                entered.signal()
                guard permission.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
            }
            try data.write(to: file, options: .atomic)
        }
    }

    private final class EncoderGate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let permission = DispatchSemaphore(value: 0)
        func open() { permission.signal() }
    }
}
