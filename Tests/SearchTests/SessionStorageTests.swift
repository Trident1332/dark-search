import Foundation
import XCTest
@testable import Search

/// Synthetic destinations only. No browser windows, browsing history, or
/// keychain items are read by these serialization and write-order checks.
final class SessionStorageTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "session-storage-\(getpid())", 1)
        super.setUp()
    }

    private let address = "https://synthetic-user:synthetic-password@example.test:8443/a%20path?q=one#section"
    private let clean = "https://example.test:8443/a%20path?q=one#section"

    private func entry(_ address: String) -> Session.Entry {
        Session.Entry(url: address, title: "Synthetic page", pin: "S", name: nil, home: address)
    }

    func testSessionEntryStripsURLCredentialsOnEncode() throws {
        let data = try JSONEncoder().encode(entry(address))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["url"] as? String, clean)
        XCTAssertEqual(json["home"] as? String, clean)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("synthetic-password"))
    }

    func testLegacySessionEntryStripsURLCredentialsBeforeRestore() throws {
        let data = try JSONSerialization.data(withJSONObject: ["url": address, "home": address, "title": "Legacy page"])
        let decoded = try JSONDecoder().decode(Session.Entry.self, from: data)
        XCTAssertEqual(decoded.url, clean)
        XCTAssertEqual(decoded.home, clean)
        XCTAssertFalse(decoded.muted, "Older entries still read with their original defaults")
    }

    func testWindowRowsUseTheSameCredentialBoundary() throws {
        let space = UUID()
        var record = WindowRecord(space: space)
        record.rows[space.uuidString] = Session.Shape(tabs: [entry(address)], active: 0)
        let data = try JSONEncoder().encode([record])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("synthetic-password"))
        let restored = try JSONDecoder().decode([WindowRecord].self, from: data)
        XCTAssertEqual(restored.first?.rows[space.uuidString]?.tabs.first?.url, clean)
        XCTAssertEqual(restored.first?.rows[space.uuidString]?.tabs.first?.home, clean)
    }

    func testOwnAndSharedPinsDoNotPersistURLCredentials() throws {
        let pin = PinDef(id: UUID(), letter: "S", home: address, title: "Synthetic pin", name: nil)
        let space = UUID(), other = UUID()
        let data = try XCTUnwrap(Pins.encode(bySpace: [space: [pin]], shared: [pin], others: [other: [pin]]))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("synthetic-password"))
        let decoded = try XCTUnwrap(Pins.decode(data))
        XCTAssertEqual(decoded.bySpace[space]?.first?.home, clean)
        XCTAssertEqual(decoded.shared.first?.home, clean)
        XCTAssertEqual(Pins.sharedLists(data)[other]?.first?.home, clean)
    }

    func testLegacyPinHomeIsScrubbedBeforeRestore() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString, "letter": "S", "home": address, "title": "Legacy pin"
        ])
        XCTAssertEqual(try JSONDecoder().decode(PinDef.self, from: data).home, clean)
    }

    func testSavedAddressPreservesDestinationAndNonCredentialAtSigns() {
        for value in ["https://example.test/path?q=someone@example.test#section", "file:///tmp/someone@example.test", "search://settings/proxy"] {
            XCTAssertEqual(Session.savedAddress(value), value)
        }
        XCTAssertEqual(Session.savedAddress("https://user%40name:pass%3Aword@[::1]:8443/path"), "https://[::1]:8443/path")
    }

    func testErasingSessionInvalidatesAnOlderQueuedSave() throws {
        XCTAssertTrue(Store.testing, "Persistence regression must use a disposable test world")
        guard Store.testing else { return }
        let space = UUID()
        let file = Store.file("session-\(space.uuidString).json")
        let blocker = Store.file("session-race-blocker-\(UUID().uuidString).tmp")
        let encoding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer {
            release.signal()
            Disk.drain()
            try? FileManager.default.removeItem(at: blocker)
            Session.erase(space: space)
            Disk.drain()
        }
        let shape = Session.Shape(tabs: [entry(clean)], active: 0)
        Session.write(now: true, space: space, shape)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        // Hold the real disk queue so the session save is deterministically
        // pending when erase happens, rather than relying on a timing race.
        Disk.write(blocker) {
            encoding.signal()
            release.wait()
            return Data()
        }
        XCTAssertEqual(encoding.wait(timeout: .now() + 2), .success)
        Session.write(space: space, shape)
        Session.erase(space: space)
        release.signal()
        Disk.drain()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "The queued save must not resurrect the deleted session")
    }
}
