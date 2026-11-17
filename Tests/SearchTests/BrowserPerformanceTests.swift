import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Search

@MainActor
final class BrowserPerformanceTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "browser-performance-\(getpid())", 1)
        super.setUp()
    }

    func testLargeSnapshotDecodeLeavesTheMainRunLoopResponsive() async throws {
        let network = "{\"records\":[{\"id\":\"1\",\"body\":\"" + String(repeating: "x", count: 64 * 1024 * 1024) + "\",\"bodyState\":\"available\"}]}"
        var ticks = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.002, repeats: true) { _ in ticks += 1 }
        defer { timer.invalidate() }
        let snapshot = try await AIInspectionSnapshot.decode(networkJSON: network, pageJSON: "{\"dom\":\"fixture\"}")
        XCTAssertGreaterThan(ticks, 1, "Snapshot decoding must allow the window's run loop to process events")
        let chunk = try await snapshot.chunk(part: "body", id: "1", count: 3)
        XCTAssertTrue(chunk.contains("xxx"))
    }

    func testCancelledSnapshotCannotReturnSuccess() async throws {
        let task = Task { try await AIInspectionSnapshot.decode(networkJSON: "{\"records\":[]}", pageJSON: "{}") }
        task.cancel()
        do { _ = try await task.value; XCTFail("A stopped capture cannot publish a snapshot") }
        catch is CancellationError { }
    }

    func testBackgroundCaptureReadAndExportPreserveRawUnicodeValues() async throws {
        let network = "{\"records\":[{\"id\":\"1\",\"body\":\"secret🙂value\",\"bodyState\":\"available\",\"request\":{\"headers\":{\"Cookie\":\"fixture-cookie\"}}}]}"
        let snapshot = try await AIInspectionSnapshot.decode(networkJSON: network, pageJSON: "{\"dom\":\"<p>秘密</p>\"}")
        let chunk = try await snapshot.chunk(part: "body", id: "1")
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(chunk.utf8)) as? [String: Any])
        XCTAssertEqual(value["data"] as? String, "secret🙂value")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("capture-export-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try await snapshot.export(to: file, actions: [["expression": "fixture", "result": "recorded"]])
        let exported = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertTrue(exported.contains("fixture-cookie"))
        XCTAssertTrue(exported.contains("秘密"))
        XCTAssertTrue(exported.contains("secret🙂value"))
        XCTAssertTrue(exported.contains("recorded"))
    }

    func testStopWhileStartingInspectionClearsBusyAndCannotResurrect() async throws {
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        defer { NSApp.setActivationPolicy(policy) }
        let tab = Tab(configuration: Web.configuration())
        tab.setAddressOptimistically(URL(string: "https://capture-fixture.invalid")!)
        tab.web.loadHTMLString("<!doctype html><title>Capture fixture</title><p>Local text</p>", baseURL: tab.pageAddress)
        for _ in 0..<300 where tab.web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        let assistant = Assistant(tab: tab, provider: .openAI, model: "synthetic", summary: false, selection: "Local text")
        defer { assistant.stop(); tab.aiInspection.stop(); tab.web.stopLoading() }
        for _ in 0..<300 where assistant.reading { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(assistant.reading)
        assistant.setInspection(true)
        XCTAssertTrue(assistant.inspectionBusy)
        assistant.cancelAnswer()
        XCTAssertFalse(assistant.busy)
        XCTAssertFalse(assistant.inspectEnabled)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(assistant.inspectionBusy)
        XCTAssertFalse(tab.aiInspection.recording)
        XCTAssertFalse(tab.aiInspection.connecting)
        XCTAssertTrue(assistant.turns.isEmpty)
    }

    func testStreamFollowCoalescesAndStopsWhenTheReaderScrollsAway() async throws {
        let follow = AssistantScrollFollow()
        var scrolls = 0
        for _ in 0..<100 { follow.schedule { scrolls += 1 } }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(scrolls, 1)
        follow.schedule { scrolls += 1 }
        follow.userScrolled(distanceFromBottom: 200)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(scrolls, 1, "A queued follow must not pull the reader away from earlier answers")
        follow.userScrolled(distanceFromBottom: 0)
        follow.schedule { scrolls += 1 }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(scrolls, 2)
    }

    func testNativeUserScrollingControlsFollowInBothCoordinateDirections() {
        _ = NSApplication.shared
        for flipped in [false, true] {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            let doc = ScrollFixtureView(frame: NSRect(x: 0, y: 0, width: 300, height: 2000))
            doc.fixtureFlipped = flipped
            scroll.documentView = doc
            let tracking = AssistantScrollTrackingView(frame: .zero)
            let follow = AssistantScrollFollow()
            tracking.follow = follow
            doc.addSubview(tracking)
            tracking.attach()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
            XCTAssertTrue(follow.following, "Programmatic movement alone must not change user intent")
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            XCTAssertFalse(follow.following)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: flipped ? doc.bounds.height - scroll.contentView.bounds.height : 0))
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            XCTAssertTrue(follow.following)
            tracking.detach()
        }
    }

    func testRealAssistantPanelAttachesItsNativeScrollObserver() async throws {
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord()), tab = Tab()
        let assistant = Assistant(tab: tab, provider: .openAI, model: "synthetic", summary: false, standalone: true)
        let host = NSHostingView(rootView: AssistantPanel(browser: browser, assistant: assistant).frame(width: 380, height: 500))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 380, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { assistant.stop(); browser.closeAll(); window.contentView = nil; window.close(); NSApp.setActivationPolicy(policy) }
        func find(_ view: NSView) -> AssistantScrollTrackingView? {
            if let tracker = view as? AssistantScrollTrackingView { return tracker }
            return view.subviews.lazy.compactMap(find).first
        }
        var found: AssistantScrollTrackingView?
        for _ in 0..<150 {
            host.layoutSubtreeIfNeeded()
            found = find(host)
            if found?.enclosingScrollView != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let tracker = try XCTUnwrap(found)
        let scroll = try XCTUnwrap(tracker.enclosingScrollView, "The real SwiftUI panel must connect the observer to its own scroll view")
        let document = try XCTUnwrap(scroll.documentView)
        document.setFrameSize(NSSize(width: 380, height: 2000))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        XCTAssertEqual(tracker.follow?.following, false, "Scrolling the panel up must stop streamed auto-follow")
    }

    func testEvidenceWritesPreserveNewerSaveAndDoNotReloadOtherReports() async throws {
        let profile = UUID(), session = OSINTSession()
        let folder = OSINTSession.savedFolder(profile)
        defer { try? FileManager.default.removeItem(at: folder) }
        let finding = OSINTFinding(category: "Images", title: "Fixture", detail: "Synthetic evidence", source: "Local fixture")
        let report = OSINTReport(context: OSINTContext(text: "Fixture"), kind: .image, findings: [finding])
        await session.restore(report)
        await session.loadSaved(profile)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unrelated = folder.appendingPathComponent("unrelated.json")
        try Data("invalid unrelated fixture".utf8).write(to: unrelated)
        await session.toggleSaved(finding.id, profile: profile)
        XCTAssertNil(session.problem, "Bookmarking one report must not synchronously decode all other evidence")
        XCTAssertEqual(session.savedReports.count, 1)
        try FileManager.default.removeItem(at: unrelated)
        let cold = OSINTSession()
        await cold.loadSaved(profile)
        XCTAssertEqual(cold.savedReports.first?.findings.first?.saved, true)
        await session.toggleSaved(finding.id, profile: profile)
        await cold.loadSaved(profile)
        XCTAssertTrue(cold.savedReports.isEmpty)
    }

    func testEvidenceStoreRejectsOutOfOrderOlderWrites() async throws {
        let store = OSINTEvidenceStore()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("evidence-order-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        var report = OSINTReport(context: OSINTContext(text: "Fixture"), kind: .image, findings: [OSINTFinding(category: "Images", title: "Fixture", detail: "Synthetic", source: "fixture", saved: true)])
        _ = try await store.save(report, image: nil, folder: folder, revision: 1)
        report.findings[0].saved = false
        _ = try await store.save(report, image: nil, folder: folder, revision: 3)
        report.findings[0].saved = true
        _ = try await store.save(report, image: nil, folder: folder, revision: 2)
        let cold = try await OSINTEvidenceStore().load(folder: folder)
        XCTAssertTrue(cold.isEmpty, "An older queued save cannot undo a later unbookmark")
    }

    func testLargeEvidenceSaveAndArchiveLoadLeaveTheMainRunLoopResponsive() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("evidence-large-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = OSINTEvidenceStore()
        let evidence = String(repeating: "fixture evidence\n", count: 1_000_000)
        let report = OSINTReport(context: OSINTContext(text: "Large fixture"), kind: .image, findings: [OSINTFinding(category: "Images", title: "Fixture", detail: "Synthetic", source: "fixture", evidence: evidence, saved: true)])
        var ticks = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.002, repeats: true) { _ in ticks += 1 }
        defer { timer.invalidate() }
        _ = try await store.save(report, image: nil, folder: folder, revision: 1)
        let cold = try await OSINTEvidenceStore().load(folder: folder)
        XCTAssertEqual(cold.first?.findings.first?.evidence, evidence)
        XCTAssertGreaterThan(ticks, 1, "Evidence encoding, writing and archive loading must leave UI events running")
        let file = folder.appendingPathComponent(report.id.uuidString + ".json")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testLateArchiveLoadCannotReplaceAnotherProfilesSavedList() async throws {
        let profile = UUID(), session = OSINTSession()
        let folder = OSINTSession.savedFolder(profile)
        defer { try? FileManager.default.removeItem(at: folder) }
        let report = OSINTReport(context: OSINTContext(text: "First profile"), kind: .image, findings: [OSINTFinding(category: "Images", title: "Fixture", detail: "Synthetic", source: "fixture", saved: true)])
        _ = try await OSINTEvidenceStore().save(report, image: nil, folder: folder, revision: 1)
        var started = false
        let old = Task { started = true; await session.loadSaved(profile) }
        while !started { await Task.yield() }
        await session.loadSaved(UUID())
        await old.value
        XCTAssertTrue(session.savedReports.isEmpty)
    }

    func testBookmarkDuringArchiveLoadPreservesTheOtherSavedReports() async throws {
        let profile = UUID(), session = OSINTSession()
        let folder = OSINTSession.savedFolder(profile)
        defer { try? FileManager.default.removeItem(at: folder) }
        let older = OSINTReport(context: OSINTContext(text: "Already saved"), kind: .image, findings: [OSINTFinding(category: "Images", title: "Older fixture", detail: "Synthetic", source: "fixture", evidence: String(repeating: "archive evidence\n", count: 1_000_000), saved: true)])
        _ = try await OSINTEvidenceStore().save(older, image: nil, folder: folder, revision: 1)
        let fresh = OSINTReport(context: OSINTContext(text: "Newly saved"), kind: .image, findings: [OSINTFinding(category: "Images", title: "New fixture", detail: "Synthetic", source: "fixture")])
        await session.restore(fresh)
        var started = false
        let loading = Task { started = true; await session.loadSaved(profile) }
        while !started { await Task.yield() }
        await session.toggleSaved(fresh.findings[0].id, profile: profile)
        await loading.value
        XCTAssertEqual(Set(session.savedReports.map(\.id)), Set([older.id, fresh.id]))
        let cold = try await OSINTEvidenceStore().load(folder: folder)
        XCTAssertEqual(Set(cold.map(\.id)), Set([older.id, fresh.id]))
    }
}

private final class ScrollFixtureView: NSView {
    var fixtureFlipped = false
    override var isFlipped: Bool { fixtureFlipped }
}
