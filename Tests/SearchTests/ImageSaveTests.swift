import AppKit
import WebKit
import XCTest
@testable import Search

/// Real WebKit transfers and native save panels, confined to a disposable
/// profile and a temporary folder. No public image or user download is touched.
@MainActor
final class ImageSaveTests: XCTestCase {
    private var browser: Browser!
    private var server: LocalDownloadServer!
    private var folder: URL!
    private var window: NSWindow!
    private var savePanel: NSSavePanel?

    override class func setUp() {
        setenv("SEARCH_PROBE", "image-save-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        browser.loot.forgetAll()
        server = try LocalDownloadServer(size: 64 * 1024)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("Search-image-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        browser.prefs.downloads = folder
        browser.prefs.asksWhereToSave = false
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 640, height: 480), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        window.orderFront(nil)
    }

    override func tearDown() async throws {
        savePanel?.cancel(nil)
        savePanel = nil
        browser.downloadSavePanelForTesting = nil
        for entry in browser.fetches.entries { browser.cancelDownload(entry) }
        browser.closeAll()
        browser.loot.forgetAll()
        server.stop()
        window.contentView = nil; window.close()
        try? FileManager.default.removeItem(at: folder)
    }

    private func page(privateTab: Bool = false) async throws -> Search.Tab {
        let source: Search.Tab? = privateTab ? Search.Tab(shy: true) : nil
        let tab = browser.open(URL(string: "about:blank")!, foreground: true, from: source)
        window.contentView = tab.web
        tab.go(to: server.url("/page"))
        try await until { tab.committed == self.server.url("/page") && !tab.loading }
        return tab
    }

    func testSaveAsUsesChosenDestinationDespiteAutomaticDownloadsAndKeepsSessionCookies() async throws {
        let tab = try await page()
        let destination = folder.appendingPathComponent("my-chosen-image.bin")
        var showed = false
        browser.downloadSaveDestinationForTesting = destination
        browser.downloadSavePanelForTesting = { panel in
            showed = true
            XCTAssertEqual(panel.nameFieldStringValue, "fixture.bin", "Use the response's suggested filename")
        }
        let menu = try XCTUnwrap(browser.imageMenu(for: tab, at: server.url("/picture.png")))
        XCTAssertTrue(menu.items.contains { $0.title == "Download Image" })
        let save = try XCTUnwrap(menu.items.first { $0.title == "Save Image As…" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(save.action), to: save.target, from: save))
        try await until { FileManager.default.fileExists(atPath: destination.path) && self.browser.downloading.isEmpty }
        XCTAssertTrue(showed)
        XCTAssertEqual(try Data(contentsOf: destination), server.expectedBytes())
        XCTAssertTrue(server.cookies("/picture.png").contains { $0?.contains("download-session=fixture-cookie") == true })
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("fixture.bin").path))
        XCTAssertFalse(browser.prefs.asksWhereToSave)
        XCTAssertTrue(browser.imageSaveAsDownloads.isEmpty)
    }

    func testCancelSaveAsWritesNoFileAndClearsPendingDownload() async throws {
        let tab = try await page()
        var showed = false
        let timer = respondToPanel(destination: nil) { _ in showed = true }
        defer { timer.invalidate() }
        // The native linked-image menu forwards through this same callback.
        try XCTUnwrap(tab.web.onSaveImageAs)(server.url("/cancel-image.png"))
        try await until { showed && self.browser.downloading.isEmpty && self.browser.fetches.entries.isEmpty }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        XCTAssertTrue(browser.imageSaveAsDownloads.isEmpty)
        XCTAssertTrue(browser.loot.kept.isEmpty)
    }

    func testDownloadImageStillUsesAutomaticFolderWithoutPicker() async throws {
        let tab = try await page()
        var showed = false
        let timer = respondToPanel(destination: nil) { _ in showed = true }
        defer { timer.invalidate() }
        browser.downloadImage(at: server.url("/quick-image.png"), from: tab.web)
        let destination = folder.appendingPathComponent("fixture.bin")
        try await until { FileManager.default.fileExists(atPath: destination.path) && self.browser.downloading.isEmpty }
        XCTAssertFalse(showed)
        XCTAssertEqual(try Data(contentsOf: destination), server.expectedBytes())
    }

    func testBlobImageSaveAsUsesPrivateTabAndDoesNotPublishDownloadHistory() async throws {
        let tab = try await page(privateTab: true)
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jGZkAAAAASUVORK5CYII="
        let script = "URL.createObjectURL(new Blob([Uint8Array.from(atob('\(png)'), c => c.charCodeAt(0))], {type:'image/png'}))"
        let result = try await tab.web.evaluateJavaScript(script)
        let address = try XCTUnwrap(result as? String)
        let url = try XCTUnwrap(URL(string: address))
        let destination = folder.appendingPathComponent("private-image.png")
        var showed = false
        browser.downloadSaveDestinationForTesting = destination
        browser.downloadSavePanelForTesting = { _ in showed = true }
        browser.downloadImage(at: url, from: tab.web, askWhere: true)
        try await until { FileManager.default.fileExists(atPath: destination.path) && self.browser.downloading.isEmpty }
        XCTAssertTrue(showed)
        XCTAssertEqual(try Data(contentsOf: destination), Data(base64Encoded: png))
        XCTAssertTrue(browser.loot.kept.isEmpty)
        XCTAssertTrue(browser.fetches.entries.isEmpty)
        XCTAssertTrue(browser.imageSaveAsDownloads.isEmpty)
    }

    private func respondToPanel(destination: URL?, appeared: @escaping (NSSavePanel) -> Void) -> Timer {
        precondition(destination == nil, "Native picker checks cancel; selected paths use the test destination")
        browser.downloadSavePanelForTesting = { [weak self] in self?.savePanel = $0 }
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard let panel = self.savePanel else { return }
                appeared(panel)
                timer.invalidate()
                panel.cancel(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func until(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(20)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "The isolated image save did not finish")
        if !condition() { throw URLError(.timedOut) }
    }
}
