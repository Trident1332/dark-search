import AppKit
import Foundation
import WebKit
import XCTest
@testable import Search

/// Native WebKit PDF saves use temporary files and an isolated browser store.
/// The tests call the actual delegate rather than a duplicate privacy predicate.
@MainActor
final class DownloadPrivacyTests: XCTestCase {
    private static let world = "download-privacy-tests-\(getpid())"
    private var browser: Browser!
    private var folder: URL!
    private var previousDownloads: URL?
    private var previousAsk = false

    override class func setUp() {
        setenv("SEARCH_PROBE", world, 1)
        super.setUp()
    }

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        XCTAssertTrue(Store.testing)
        browser = Browser(record: WindowRecord())
        browser.loot.forgetAll()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("download-privacy-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        previousDownloads = browser.prefs.downloads
        previousAsk = browser.prefs.asksWhereToSave
        browser.prefs.downloads = folder
        browser.prefs.asksWhereToSave = false
    }

    override func tearDown() async throws {
        if let browser {
            browser.loot.forgetAll()
            if let previousDownloads { browser.prefs.downloads = previousDownloads }
            browser.prefs.asksWhereToSave = previousAsk
            browser.closeAll()
        }
        Disk.drain()
        if let folder { try? FileManager.default.removeItem(at: folder) }
        browser = nil
        try await super.tearDown()
    }

    func testPrivatePDFSaveDoesNotEnterOrdinaryDownloadHistory() throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        try checkNativePDFSave(configuration, filename: "private-review.pdf", source: "https://private-pdf.invalid/document.pdf")
    }

    func testTorPDFSaveDoesNotEnterOrdinaryDownloadHistory() throws {
        let source = WKWebsiteDataStore.nonPersistent()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Onion.shared.store(for: source)
        XCTAssertTrue(Onion.shared.owns(configuration.websiteDataStore))
        try checkNativePDFSave(configuration, filename: "tor-review.pdf", source: "https://tor-pdf.invalid/document.pdf")
    }

    func testOrdinaryPDFSaveStillEntersDownloadHistory() throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Store.websites
        XCTAssertTrue(configuration.websiteDataStore.isPersistent)
        let filename = "ordinary-fixture.pdf"
        let source = URL(string: "https://ordinary-pdf.invalid/document.pdf")!
        let web = WKWebView(frame: .zero, configuration: configuration)
        let data = Data("%PDF-1.4\n% ordinary synthetic fixture\n%%EOF\n".utf8)
        browser.webView(web, saveDataToFile: data, suggestedFilename: filename,
                        mimeType: "application/pdf", originatingURL: source)
        let file = folder.appendingPathComponent(filename)
        XCTAssertEqual(try Data(contentsOf: file), data)
        let record = try XCTUnwrap(browser.loot.kept.first)
        XCTAssertEqual(record.name, filename)
        XCTAssertEqual(record.path, file.path)
        XCTAssertEqual(record.from, source.host)
        Disk.drain()
        let records = try JSONDecoder().decode([Keep].self, from: Data(contentsOf: Store.file("downloads.json")))
        XCTAssertTrue(records.contains(record))
    }

    func testPrivateTabFlagStillProtectsPDFSaveWithAPersistentStore() throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Store.websites
        let tab = Tab(shy: true, configuration: configuration)
        browser.insert(tab, at: 0)
        let filename = "private-tab-fixture.pdf"
        browser.webView(tab.web, saveDataToFile: Data("%PDF-1.4\n%%EOF\n".utf8), suggestedFilename: filename,
                        mimeType: "application/pdf", originatingURL: URL(string: "https://private-pdf.invalid/document.pdf"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(filename).path))
        XCTAssertTrue(browser.loot.kept.isEmpty)
        Disk.drain()
        let records = try JSONDecoder().decode([Keep].self, from: Data(contentsOf: Store.file("downloads.json")))
        XCTAssertTrue(records.isEmpty)
    }

    func testTorTitleDoesNotOverwriteOrdinaryHistory() async throws {
        let url = try XCTUnwrap(URL(string: "https://tor-title-fixture.invalid/\(UUID().uuidString.lowercased())"))
        let ordinary = "Ordinary fixture title"
        let privateTitle = "Private Tor fixture title"
        browser.history.record(url, title: ordinary)
        let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
        tab.restore(url: url, title: "Initial Tor fixture", tor: true)
        XCTAssertFalse(tab.shy, "Reproduce an ordinary tab converted to Tor")
        XCTAssertTrue(tab.usesTor)
        browser.prepare(tab)
        tab.restore(url: url, title: privateTitle, tor: true)

        let title = browser.history.everything().first { $0.url == url }?.title
        XCTAssertEqual(title, ordinary, "A title received over Tor must not overwrite the ordinary browsing record")
        try await Task.sleep(for: .milliseconds(1700))
        Disk.drain()
        let file = Store.file("history.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "The debounced history write must actually complete")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        XCTAssertFalse(text.contains(privateTitle), "The Tor title must not be persisted in ordinary history.json")
        tab.close()
        browser.history.forget(History.identity(for: url))
    }

    func testOrdinaryTitleStillUpdatesHistory() throws {
        let url = try XCTUnwrap(URL(string: "https://ordinary-title-fixture.invalid/\(UUID().uuidString.lowercased())"))
        browser.history.record(url, title: "Initial ordinary title")
        defer { browser.history.forget(History.identity(for: url)) }
        let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
        defer { tab.close() }
        tab.restore(url: url, title: "Initial ordinary title")
        browser.prepare(tab)
        tab.restore(url: url, title: "Updated ordinary title")
        XCTAssertEqual(browser.history.everything().first { $0.url == url }?.title, "Updated ordinary title")
    }

    func testPrivateTitleDoesNotOverwriteOrdinaryHistory() throws {
        let url = try XCTUnwrap(URL(string: "https://private-title-fixture.invalid/\(UUID().uuidString.lowercased())"))
        browser.history.record(url, title: "Ordinary title")
        defer { browser.history.forget(History.identity(for: url)) }
        let tab = Tab(shy: true)
        defer { tab.close() }
        tab.restore(url: url, title: "Initial private title")
        browser.prepare(tab)
        tab.restore(url: url, title: "Private title")
        XCTAssertEqual(browser.history.everything().first { $0.url == url }?.title, "Ordinary title")
    }

    private func checkNativePDFSave(_ configuration: WKWebViewConfiguration, filename: String, source: String) throws {
        XCTAssertFalse(configuration.websiteDataStore.isPersistent)
        let web = WKWebView(frame: .zero, configuration: configuration)
        let pdf = Data("%PDF-1.4\n% synthetic review fixture\n%%EOF\n".utf8)
        browser.webView(web, saveDataToFile: pdf, suggestedFilename: filename,
                        mimeType: "application/pdf", originatingURL: URL(string: source))
        let file = folder.appendingPathComponent(filename)
        XCTAssertEqual(try Data(contentsOf: file), pdf, "The native save path must actually run")
        XCTAssertTrue(browser.loot.kept.isEmpty,
                      "Saving from a nonpersistent PDF viewer must not publish its file path and host in ordinary Downloads")
        Disk.drain()
        let records = (try? Data(contentsOf: Store.file("downloads.json")))
            .flatMap { try? JSONDecoder().decode([Keep].self, from: $0) } ?? []
        XCTAssertFalse(records.contains { $0.name == filename || $0.from.contains("pdf.invalid") },
                       "Private and Tor PDF metadata must not persist in downloads.json")
    }
}
