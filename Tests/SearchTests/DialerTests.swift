import XCTest
@testable import Search

/// What a right-click is read for (DialMenu.swift), what otto's call
/// records have to be (Dialer.cleanRecord), and the line's own checks.
final class DialerTests: XCTestCase {
    /// A world of its own, as every suite here has: the keychain stays a
    /// rehearsal and the dialer's files are found from this checkout.
    override class func setUp() {
        setenv("SEARCH_PROBE", "dialer-\(getpid())", 1)
        super.setUp()
    }

    private func found(_ text: String, at offset: Int? = nil) -> String? {
        Dialer.number(link: "", selection: offset == nil ? text : "", around: offset == nil ? "" : text, offset: offset ?? -1)
    }

    func testSelectedNumbersAreOfferedAsWritten() {
        XCTAssertEqual(found("020 7946 0958"), "020 7946 0958")
        XCTAssertEqual(found("+44 20 7946 0958"), "+44 20 7946 0958")
        XCTAssertEqual(found("(415) 555-2671"), "(415) 555-2671")
        XCTAssertEqual(found("Call us on 0800 123 4567 today"), "0800 123 4567")
        XCTAssertEqual(found("Tel: +1-202-555-0143."), "+1-202-555-0143")
        XCTAssertEqual(found("07700\u{00a0}900\u{00a0}123"), "07700 900 123")
    }

    func testWordsThatAreNotNumbersAreLeftAlone() {
        XCTAssertNil(found("hello there"))
        XCTAssertNil(found("2026-10-29"))
        XCTAssertNil(found("29/10/2026"))
        XCTAssertNil(found("12345"))
        XCTAssertNil(found("1234"))
        XCTAssertNil(found("order 1234-5678-9012-3456"))
        XCTAssertNil(found(""))
        XCTAssertNil(found("+1234567890123456789"))
    }

    func testTheWordsAroundThePointerCountOnlyUnderIt() {
        let line = "Reception is on 020 7946 0958 and sales on 020 7946 0999 all day"
        let first = line.distance(from: line.startIndex, to: line.range(of: "7946 0958")!.lowerBound)
        let second = line.distance(from: line.startIndex, to: line.range(of: "0999")!.lowerBound)
        XCTAssertEqual(found(line, at: first), "020 7946 0958")
        XCTAssertEqual(found(line, at: second), "020 7946 0999")
        XCTAssertNil(found(line, at: 3))
        XCTAssertNil(found(line, at: line.count - 2))
    }

    func testALinkComesFirstAndIsCleaned() {
        XCTAssertEqual(Dialer.number(ofTel: "tel:+44-20-7946-0958"), "+442079460958")
        XCTAssertEqual(Dialer.number(ofTel: "callto:020%207946%200958"), "02079460958")
        XCTAssertEqual(Dialer.number(ofTel: "tel:+4420;ext=12"), "+4420")
        XCTAssertEqual(Dialer.number(ofTel: "TEL:9196"), "9196")
        XCTAssertNil(Dialer.number(ofTel: "mailto:a@b.c"))
        XCTAssertNil(Dialer.number(ofTel: "tel:"))
        XCTAssertNil(Dialer.number(ofTel: "https://example.com/tel:123"))
        XCTAssertEqual(Dialer.number(link: "tel:123456789", selection: "020 7946 0958", around: "", offset: -1), "123456789")
    }

    func testARecordHasToBeOneBeforeItIsFiled() {
        let good: [String: Any] = ["id": "abc", "number": "+442079460958", "name": "Ada", "direction": "out",
                                   "startedAt": 1_000.0, "answeredAt": 2_000.0, "endedAt": 9_000.0,
                                   "durationSec": 7, "outcome": "answered", "ref": ["ws": 1, "l": "x"]]
        let clean = Dialer.cleanRecord(good)
        XCTAssertEqual(clean?["id"] as? String, "abc")
        XCTAssertEqual(clean?["number"] as? String, "+442079460958")
        XCTAssertEqual((clean?["ref"] as? [String: Any])?["l"] as? String, "x")
        XCTAssertNil(Dialer.cleanRecord(nil))
        XCTAssertNil(Dialer.cleanRecord(["id": "", "number": "+442079460958", "outcome": "answered", "startedAt": 1, "endedAt": 2]))
        XCTAssertNil(Dialer.cleanRecord(["id": "x", "number": "9196", "outcome": "answered", "startedAt": 1, "endedAt": 2]))
        XCTAssertNil(Dialer.cleanRecord(["id": "x", "number": "*72#", "outcome": "answered", "startedAt": 1, "endedAt": 2]))
        XCTAssertNil(Dialer.cleanRecord(["id": "x", "number": "+442079460958", "outcome": "spoke", "startedAt": 1, "endedAt": 2]))
        XCTAssertNil(Dialer.cleanRecord(["id": "x", "number": "+442079460958", "outcome": "busy", "startedAt": "now", "endedAt": 2]))
        let unanswered = Dialer.cleanRecord(["id": "x", "number": "+442079460958", "outcome": "busy", "startedAt": 1, "endedAt": 2, "answeredAt": NSNull()])
        XCTAssertTrue(unanswered?["answeredAt"] is NSNull)
        XCTAssertNil(Dialer.cleanRecord(["id": "x", "number": "+442079460958", "outcome": "busy", "startedAt": 1, "endedAt": 2,
                                         "ref": ["long": String(repeating: "x", count: 500)]])?["ref"] as? [String: Any])
    }

    func testTheLineIsCheckedBeforeItIsUsed() {
        XCTAssertTrue(DialerSetup.validWSS("wss://sip.example.com:7443"))
        XCTAssertTrue(DialerSetup.validWSS(" ws://127.0.0.1:5066 "))
        XCTAssertFalse(DialerSetup.validWSS("https://sip.example.com"))
        XCTAssertFalse(DialerSetup.validWSS("sip.example.com"))
        XCTAssertFalse(DialerSetup.validWSS(""))
        var setup = DialerSetup(on: true, wss: "wss://a", domain: "a", user: "1001")
        XCTAssertTrue(setup.complete)
        setup.user = " "
        XCTAssertFalse(setup.complete)
        XCTAssertEqual(Dialer.site("https://Otto.Example.com:8080"), "https://otto.example.com:8080")
        XCTAssertEqual(Dialer.site("https://otto.example.com/leads"), "")
        XCTAssertEqual(Dialer.defaultSites, ["https://otto.investigate.agency"])
    }

    @MainActor func testSitesAreAllowedOnlyWhileOnAndListed() {
        let prefs = Shared.prefs
        let was = (prefs.dialerOn, prefs.dialerSites)
        defer { prefs.dialerOn = was.0; prefs.dialerSites = was.1 }
        prefs.dialerSites = ["https://otto.example.com", "http://localhost:3000"]
        prefs.dialerOn = false
        XCTAssertFalse(Dialer.shared.allows(scheme: "https", host: "otto.example.com", port: 443))
        prefs.dialerOn = true
        XCTAssertTrue(Dialer.shared.allows(scheme: "https", host: "Otto.Example.com", port: 443))
        XCTAssertTrue(Dialer.shared.allows(scheme: "http", host: "localhost", port: 3000))
        XCTAssertFalse(Dialer.shared.allows(scheme: "http", host: "localhost", port: 3001))
        XCTAssertFalse(Dialer.shared.allows(scheme: "http", host: "otto.example.com", port: 80))
        XCTAssertFalse(Dialer.shared.allows(scheme: "https", host: "evil.example.com", port: 443))
        XCTAssertFalse(Dialer.shared.allows(scheme: "https", host: "sub.otto.example.com", port: 443))
    }

    @MainActor func testThePasswordStaysWithItsSeat() {
        let a = DialerSetup(on: true, wss: "wss://a", domain: "sip.a", user: "1001")
        let b = DialerSetup(on: true, wss: "wss://a", domain: "sip.a", user: "1002")
        defer { DialerPassword.forget(a); DialerPassword.forget(b) }
        XCTAssertTrue(DialerPassword.save("secret", for: a))
        XCTAssertEqual(DialerPassword.read(a), "secret")
        XCTAssertNil(DialerPassword.read(b))
        XCTAssertTrue(DialerPassword.kept(a))
        XCTAssertFalse(DialerPassword.save("", for: a))
        XCTAssertTrue(DialerPassword.forget(a))
        XCTAssertNil(DialerPassword.read(a))
        XCTAssertEqual(Dialer.shared.values(["password"])["password"] as? String, "")
    }

    @MainActor func testFiledCallsWaitForOttoAndGoWhenAcknowledged() {
        let dialer = Dialer.shared
        _ = dialer.ackCalls(dialer.outbox.compactMap { $0["id"] as? String })
        XCTAssertNil(dialer.fileCall(["id": "x", "number": "9196", "outcome": "answered", "startedAt": 1, "endedAt": 2]))
        XCTAssertEqual(dialer.fileCall(["id": "one", "number": "+442079460958", "outcome": "answered", "startedAt": 1, "endedAt": 2]), 1)
        XCTAssertEqual(dialer.fileCall(["id": "two", "number": "02079460958", "outcome": "busy", "startedAt": 1, "endedAt": 2]), 2)
        // The same id again replaces its earlier self rather than doubling it.
        XCTAssertEqual(dialer.fileCall(["id": "one", "number": "+442079460958", "outcome": "cancelled", "startedAt": 1, "endedAt": 3]), 2)
        XCTAssertEqual(dialer.outbox.map { $0["id"] as? String }, ["two", "one"])
        XCTAssertEqual(dialer.outbox.last?["outcome"] as? String, "cancelled")
        XCTAssertEqual(dialer.ackCalls(["two"]), 1)
        XCTAssertEqual(dialer.ackCalls(["one", "never"]), 0)
        XCTAssertTrue(dialer.outbox.isEmpty)
    }

    @MainActor func testThePageKeepsOnlyItsOwnKeys() {
        let dialer = Dialer.shared
        defer { dialer.remove(["provider", "voice"]) }
        dialer.set(["provider": "telicall", "voice": "-3", "wss": "wss://evil", "password": "nope"])
        XCTAssertEqual(dialer.values(["provider", "voice"])["provider"] as? String, "telicall")
        XCTAssertEqual(dialer.values(["voice"])["voice"] as? String, "-3")
        XCTAssertNotEqual(dialer.values(["wss"])["wss"] as? String, "wss://evil")
        dialer.remove(["provider"])
        XCTAssertNil(dialer.values(["provider"])["provider"])
    }

    @MainActor func testOttoCanSetTheLineUp() {
        let prefs = Shared.prefs
        let was = prefs.dialerSetup
        defer {
            prefs.dialerWSS = was.wss; prefs.dialerDomain = was.domain; prefs.dialerUser = was.user
            prefs.dialerRegion = was.region; prefs.dialerAutodial = was.autodial
            DialerPassword.forget(prefs.dialerSetup)
        }
        Dialer.shared.takeConfig(["wss": "wss://sip.example.com:7443", "domain": "sip.example.com", "user": "1007",
                                  "region": "us", "autodial": false, "password": "pw", "provider": "telicall", "updatesUrl": "x"])
        XCTAssertEqual(prefs.dialerWSS, "wss://sip.example.com:7443")
        XCTAssertEqual(prefs.dialerUser, "1007")
        XCTAssertEqual(prefs.dialerRegion, "US")
        XCTAssertFalse(prefs.dialerAutodial)
        XCTAssertEqual(DialerPassword.read(prefs.dialerSetup), "pw")
        let config = Dialer.shared.configForSites()
        XCTAssertNil(config["password"])
        XCTAssertEqual(config["passwordSaved"] as? Bool, true)
        XCTAssertEqual(config["provider"] as? String, "telicall")
        Dialer.shared.takeConfig(["region": "united kingdom"])
        XCTAssertEqual(prefs.dialerRegion, "US")
    }

    func testTheFilesAreWhereTheBuildPutsThem() throws {
        let files = try XCTUnwrap(Dialer.files)
        for name in ["dialer.html", "dialer.js", "dialer.css", "search.js", "search.css", "calls.js", "vendor/sip.min.js", "vendor/phone.min.js"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: files.appendingPathComponent(name).path), name)
        }
        let html = try String(contentsOf: files.appendingPathComponent("dialer.html"), encoding: .utf8)
        XCTAssertTrue(html.contains("search.js"))
        XCTAssertTrue(html.range(of: "search.js")! .lowerBound < html.range(of: "dialer.js")!.lowerBound)
    }
}
