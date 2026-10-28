import Foundation
import Security
import XCTest
@testable import Search

final class UpdateFeedBoundsTests: XCTestCase {
    private var folders: [URL] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders.removeAll()
        FeedProtocol.plan = nil
        super.tearDown()
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("feed-bounds-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url)
        return url
    }

    @discardableResult
    private func run(_ executable: String, _ args: [String]) throws -> Data {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, executable)
        return data
    }

    private func zip(_ contents: Data, signed: Bool = false) throws -> Data {
        let root = try folder(), file = root.appendingPathComponent("appcast.json")
        try contents.write(to: file)
        if signed { try run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "invalid.example.feed-fixture", file.path]) }
        let zip = root.appendingPathComponent("feed.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", file.path, zip.path])
        return try Data(contentsOf: zip)
    }

    private func unpack(_ packed: Data) throws -> URL {
        let root = try folder(), zip = root.appendingPathComponent("canonical.zip"), out = root.appendingPathComponent("out")
        try packed.write(to: zip)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
        return out.appendingPathComponent("appcast.json")
    }

    func testValidDeflatedFeedIsPreserved() throws {
        let json = Data(#"{"version":"test","build":1}"#.utf8)
        let normalized = try UpdateFeedArchive.normalized(zip(json))
        XCTAssertEqual(try Data(contentsOf: unpack(normalized)), json)
    }

    func testSignatureMetadataSurvivesBoundedNormalization() throws {
        let packed = try zip(Data(#"{"version":"signed-fixture","build":1}"#.utf8), signed: true)
        let file = try unpack(UpdateFeedArchive.normalized(packed))
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(file as CFURL, [], &code), errSecSuccess)
        let signed = try XCTUnwrap(code)
        XCTAssertEqual(SecStaticCodeCheckValidity(signed, [], nil), errSecSuccess,
                       "Repacking must preserve the AppleDouble code signature, not just the JSON")
        XCTAssertNil(Updater.opened(packed), "An ad-hoc fixture must still fail the pinned release-key requirement")
    }

    func testOversizedCompressedInputIsRejectedBeforeParsing() {
        XCTAssertThrowsError(try UpdateFeedArchive.normalized(Data(repeating: 0, count: UpdateFeedArchive.compressedLimit + 1)))
    }

    func testHighlyCompressedOversizedFeedIsRejected() throws {
        let packed = try zip(Data(repeating: 65, count: UpdateFeedArchive.fileLimit + 1))
        XCTAssertLessThan(packed.count, UpdateFeedArchive.compressedLimit)
        XCTAssertThrowsError(try UpdateFeedArchive.normalized(packed))
        XCTAssertNil(Updater.opened(packed))
    }

    func testLyingExpandedSizeCannotBypassInflaterBound() throws {
        var packed = try zip(Data(repeating: 65, count: UpdateFeedArchive.fileLimit + 1))
        let central = try XCTUnwrap(packed.range(of: Data([0x50, 0x4b, 0x01, 0x02])))
        packed.replaceSubrange((central.lowerBound + 24)..<(central.lowerBound + 28), with: [64, 0, 0, 0])
        XCTAssertThrowsError(try UpdateFeedArchive.normalized(packed), "Actual output must be bounded even when ZIP metadata lies")
    }

    func testUnapprovedPathsAndSymlinkEntriesAreRejected() throws {
        let packed = try zip(Data("fixture".utf8))
        var traversal = packed
        let name = Data("appcast.json".utf8), replacement = Data("../evil.json".utf8)
        XCTAssertEqual(name.count, replacement.count)
        while let range = traversal.range(of: name) { traversal.replaceSubrange(range, with: replacement) }
        XCTAssertThrowsError(try UpdateFeedArchive.normalized(traversal))
        var symlink = packed
        let central = try XCTUnwrap(symlink.range(of: Data([0x50, 0x4b, 0x01, 0x02])))
        symlink.replaceSubrange((central.lowerBound + 38)..<(central.lowerBound + 42), with: [0, 0, 0xff, 0xa1])
        XCTAssertThrowsError(try UpdateFeedArchive.normalized(symlink))
    }

    func testBadChecksumIsRejectedBeforeExtraction() throws {
        var packed = try zip(Data("fixture".utf8))
        let central = try XCTUnwrap(packed.range(of: Data([0x50, 0x4b, 0x01, 0x02])))
        packed[central.lowerBound + 16] ^= 1
        XCTAssertThrowsError(try UpdateFeedArchive.normalized(packed))
    }

    private func session(_ plan: FeedPlan) -> URLSession {
        FeedProtocol.plan = plan
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedProtocol.self]
        return URLSession(configuration: configuration)
    }

    private let target = URL(string: "https://bounded-feed.invalid/feed.zip")!

    func testDownloadStopsAtLimitWithoutContentLength() async throws {
        let plan = FeedPlan(body: Data(repeating: 65, count: 128 << 10))
        let session = session(plan)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await Updater.downloadFeed(target, limit: 4096, session: session)
            XCTFail("An unknown-length response must not exceed its cap")
        } catch Updater.FeedFailure.tooLarge { }
        for _ in 0..<100 where !plan.stopped { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(plan.stopped, "The network task is cancelled, not just abandoned")
        XCTAssertLessThan(plan.sent, plan.body.count)
    }

    func testDownloadRejectsOversizedHeaderBeforeBody() async throws {
        let plan = FeedPlan(body: Data(repeating: 65, count: 128 << 10), declared: 128 << 10)
        let session = session(plan)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await Updater.downloadFeed(target, limit: 4096, session: session)
            XCTFail("An oversized Content-Length must be rejected")
        } catch Updater.FeedFailure.tooLarge { }
        XCTAssertLessThan(plan.sent, plan.body.count)
    }

    func testSmallDownloadStillWorksAndHTTPFailureIsRejected() async throws {
        let body = Data("small fixture".utf8)
        var client = session(FeedPlan(body: body, declared: body.count))
        let received = try await Updater.downloadFeed(target, limit: 4096, session: client)
        XCTAssertEqual(received, body)
        client.invalidateAndCancel()
        client = session(FeedPlan(body: body, status: 503))
        defer { client.invalidateAndCancel() }
        do {
            _ = try await Updater.downloadFeed(target, limit: 4096, session: client)
            XCTFail("An error response isn't a feed")
        } catch Updater.FeedFailure.response { }
    }
}

private final class FeedPlan: @unchecked Sendable {
    let body: Data
    let declared: Int?
    let status: Int
    private let lock = NSLock()
    private var bytesSent = 0
    private var cancelled = false
    var sent: Int { lock.withLock { bytesSent } }
    var stopped: Bool { lock.withLock { cancelled } }
    init(body: Data, declared: Int? = nil, status: Int = 200) {
        self.body = body; self.declared = declared; self.status = status
    }
    func didSend(_ count: Int) { lock.withLock { bytesSent += count } }
    func stop() { lock.withLock { cancelled = true } }
}

private final class FeedProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: FeedPlan?
    static var plan: FeedPlan? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    private var response: FeedPlan?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "bounded-feed.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let plan = Self.plan, let url = request.url else { return }
        response = plan
        var headers: [String: String] = [:]
        if let declared = plan.declared { headers["Content-Length"] = String(declared) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: plan.status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        send(at: 0, plan: plan)
    }
    private func send(at offset: Int, plan: FeedPlan) {
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(2)) { [weak self] in
            guard let self, !plan.stopped else { return }
            guard offset < plan.body.count else { client?.urlProtocolDidFinishLoading(self); return }
            let end = min(offset + 1024, plan.body.count)
            plan.didSend(end - offset)
            client?.urlProtocol(self, didLoad: plan.body.subdata(in: offset..<end))
            send(at: end, plan: plan)
        }
    }
    override func stopLoading() { response?.stop() }
}
