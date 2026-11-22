import AppKit
import Combine
import Foundation
import WebKit
import XCTest
@testable import Search

@MainActor
final class FetchEntryTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    func testCopyAddressOffersOnlyWhatAnotherAppCanFetch() {
        func address(_ text: String) -> String? { Keep.address(of: URL(string: text)) }

        // A signed link only works exactly as it was asked.
        let signed = "https://cdn.example.test/a%20b.zip?x-amz-signature=a%2Fb+c&y=1#part"
        XCTAssertEqual(address(signed), signed)
        XCTAssertEqual(address("http://example.test/a.zip"), "http://example.test/a.zip")
        XCTAssertEqual(address("https://me:made-up@example.test/a.zip"), "https://example.test/a.zip")

        XCTAssertNil(address("blob:https://example.test/1234"))
        XCTAssertNil(address("data:text/plain,hello"))
        XCTAssertNil(address("file:///tmp/a.zip"))
        XCTAssertNil(Keep.address(of: nil))
        XCTAssertNil(FetchEntry(name: "a.zip", request: nil, webView: nil).address)
    }

    func testAListWrittenBeforeAddressesStillReads() throws {
        let written = #"[{"name":"a.zip","from":"example.test","path":"/tmp/a.zip","date":0}]"#
        let list = try JSONDecoder().decode([Keep].self, from: Data(written.utf8))
        XCTAssertEqual(list.first?.name, "a.zip")
        XCTAssertNil(list.first?.address)
    }

    func testAnAddressSurvivesTheListsFile() throws {
        let keep = Keep(name: "a.zip", from: "example.test", path: "/tmp/a.zip", date: Date(timeIntervalSince1970: 0),
                        address: "https://example.test/a.zip")
        let read = try JSONDecoder().decode(Keep.self, from: JSONEncoder().encode(keep))
        XCTAssertEqual(read, keep)
    }

    func testFailedResumeDataAllowsResumeWithoutOriginalRequest() async throws {
        let webView = makeWebView()
        let entry = FetchEntry(name: "archive.zip", request: nil, webView: webView)
        entry.failed(NSError(domain: "DownloadFixture", code: 1), resumeData: Data([1, 2, 3]))

        XCTAssertEqual(entry.state, .failed)
        XCTAssertTrue(entry.canResume)
        XCTAssertFalse(entry.canRetry)
        XCTAssertEqual(try XCTUnwrap(Fetches().beginResume(entry)?.resumeData), Data([1, 2, 3]))
    }

    /// An editor's Export: a blob: address, which the page may already have
    /// let go of. Asked again it only fails, so its row offers neither.
    func testAPagesOwnFileIsNeitherPausedNorTriedAgain() async throws {
        let webView = makeWebView()
        let request = URLRequest(url: URL(string: "blob:http://localhost:5173/6a1f6c0e-0d8b-4c0e-9a51-2f6d1c1b7e11")!)
        let entry = FetchEntry(name: "Mailify.png", request: request, webView: webView)
        XCTAssertFalse(entry.canPause)

        entry.failed(NSError(domain: "WebKitBlobResource", code: 1), resumeData: nil)
        XCTAssertEqual(entry.state, .failed)
        XCTAssertEqual(entry.errorDescription, FetchEntry.pageMadeGone)
        XCTAssertFalse(entry.canRetry)
        XCTAssertFalse(entry.canResume)
        XCTAssertNil(Fetches().beginRetry(entry, destination: { URL(fileURLWithPath: "/tmp/Mailify.png") }))

        // Any other reason is said as it is, and a server's file is as before.
        entry.failed(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), resumeData: nil)
        XCTAssertNotEqual(entry.errorDescription, FetchEntry.pageMadeGone)
        let served = FetchEntry(name: "a.png", request: URLRequest(url: URL(string: "https://example.test/a.png")!), webView: webView)
        XCTAssertTrue(served.canPause)
        served.failed(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), resumeData: nil)
        XCTAssertTrue(served.canRetry)
    }

    func testPauseWithoutResumeDataBecomesRetryableWithVisibleReason() async throws {
        let webView = makeWebView()
        let request = URLRequest(url: URL(string: "https://example.test/archive.zip")!)
        let entry = FetchEntry(name: "archive.zip", request: request, webView: webView)

        entry.stopped(.pause, data: nil)

        XCTAssertEqual(entry.state, .failed)
        XCTAssertFalse(entry.canResume)
        XCTAssertTrue(entry.canRetry)
        XCTAssertTrue(try XCTUnwrap(entry.errorDescription).contains("doesn't let this download pause"))
    }

    func testACancelInFlightRedrawsTheRow() {
        let entry = FetchEntry(name: "archive.zip", request: nil, webView: nil)
        _ = entry.preparingToStop(.pause)
        XCTAssertEqual(entry.stopping, "Pausing")
        var redraws = 0
        let watching = entry.objectWillChange.sink { redraws += 1 }

        // What upgradeStopToCancel does when Cancel is pressed mid-pause.
        entry.pendingStop = .cancel

        XCTAssertEqual(redraws, 1)
        XCTAssertEqual(entry.stopping, "Cancelling")
        watching.cancel()
    }

    func testCancelSaysCancellingWhileItStops() {
        let entry = FetchEntry(name: "archive.zip", request: nil, webView: nil)
        _ = entry.preparingToStop(.cancel)
        XCTAssertEqual(entry.state, .pausing)
        XCTAssertEqual(entry.stopping, "Cancelling")
    }

    func testBeginResumeRejectsDuplicateActionWhileWebKitStarts() async throws {
        let webView = makeWebView()
        let entry = FetchEntry(name: "archive.zip", request: nil, webView: webView)
        entry.failed(NSError(domain: "DownloadFixture", code: 1), resumeData: Data([1]))
        let fetches = Fetches()

        let first = try XCTUnwrap(fetches.beginResume(entry))

        XCTAssertTrue(fetches.accepts(first))
        XCTAssertNil(fetches.beginResume(entry))
    }

    func testRemovingPendingStartInvalidatesItsCallback() async throws {
        let webView = makeWebView()
        let request = URLRequest(url: URL(string: "https://example.test/archive.zip")!)
        let entry = FetchEntry(name: "archive.zip", request: request, webView: webView)
        entry.failed(NSError(domain: "DownloadFixture", code: 1), resumeData: nil)
        let fetches = Fetches()
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("retry.zip")
        let start = try XCTUnwrap(fetches.beginRetry(entry, destination: { target }))

        XCTAssertTrue(fetches.accepts(start))
        fetches.removeStarting(entry)

        XCTAssertFalse(fetches.accepts(start))
        XCTAssertNil(entry.request)
        XCTAssertNil(entry.webView)
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }
}
