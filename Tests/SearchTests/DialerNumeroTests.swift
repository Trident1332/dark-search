import XCTest
@testable import Search

/// Owned-line configuration and the metadata retained for Otto's call log.
/// These checks never register a SIP account or place a call.
final class DialerNumeroTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "dialer-numero-\(getpid())", 1)
        super.setUp()
    }

    func testOwnedNumbersAcceptPastedNANPFormatting() {
        XCTAssertEqual(DialerNumero.number("(202) 555-0123"), "+12025550123")
        XCTAssertEqual(DialerNumero.number("1 (202) 555-0123"), "+12025550123")
        XCTAssertEqual(DialerNumero.number(" +1 416.555.0123 "), "+14165550123")
        XCTAssertEqual(DialerNumero.number("6045550123"), "+16045550123")
        XCTAssertEqual(DialerNumero.number("+1 (877) 555-0123"), "+18775550123",
                       "A Canadian-assigned slot may hold a shared NANP toll-free number")
    }

    func testOwnedNumbersRejectSIPTextExtensionsAndHeaderInjection() {
        for typed in ["tel:+12025550123", "sip:+12025550123@example.invalid", "+12025550123;ext=5",
                      "+12025550123,5", "+12025550123#", "*12025550123", "+12025550123 ext 5",
                      "+1202\t5550123", "+1202\n5550123", "+12025550123\r\nX-Provider: telicall",
                      "++12025550123", "1+2025550123", "１２０２５５５０１２３", "call 2025550123"] {
            XCTAssertNil(DialerNumero.number(typed), "Unsafe owned-number input was accepted")
        }
    }

    func testOwnedNumbersRequireACompleteNANPNumber() {
        for typed in ["", " ", "202555012", "120255501234", "+442079460958", "+2025550123",
                      "+11025550123", "+12021550123", "0012025550123"] {
            XCTAssertNil(DialerNumero.number(typed))
        }
    }

    func testInvalidNonemptyConfigurationCannotBecomeLegacyBlank() {
        XCTAssertEqual(DialerNumero.value("  (202) 555-0123  "), "+12025550123")
        XCTAssertEqual(DialerNumero.value("  invalid-owned-number  "), "invalid-owned-number")
        XCTAssertFalse(DialerNumero.value("+442079460958").isEmpty,
                       "Invalid explicit configuration must block instead of selecting the legacy route")
        XCTAssertEqual(DialerNumero.value(" \n "), "")
    }

    @MainActor func testNativeConfigurationCarriesBothOwnedNumbersAndSavedSelection() {
        let dialer = Dialer.shared
        let before = dialer.setup
        let oldSelection = dialer.pageValue("numeroLine")
        defer {
            dialer.take(before)
            if let oldSelection { dialer.set(["numeroLine": oldSelection]) }
            else { dialer.remove(["numeroLine"]) }
        }
        dialer.take(DialerSetup(numeroUS: "(202) 555-0123", numeroCA: "+1 (877) 555-0123"))
        dialer.set(["numeroLine": "ca"])
        let values = dialer.values(["numeroUS", "numeroCA", "numeroLine"])
        XCTAssertEqual(values["numeroUS"] as? String, "+12025550123")
        XCTAssertEqual(values["numeroCA"] as? String, "+18775550123")
        XCTAssertEqual(values["numeroLine"] as? String, "ca")
        dialer.take(DialerSetup(numeroUS: "invalid", numeroCA: ""))
        XCTAssertEqual(dialer.values(["numeroUS"])["numeroUS"] as? String, "invalid")
    }

    func testCallRecordPreservesCanonicalOwnedLinePair() throws {
        var record = callRecord()
        record["numeroLine"] = "ca"
        record["fromNumber"] = "+1 (877) 555-0123"
        let clean = try XCTUnwrap(Dialer.cleanRecord(record))
        XCTAssertEqual(clean["numeroLine"] as? String, "ca")
        XCTAssertEqual(clean["fromNumber"] as? String, "+18775550123")
        XCTAssertEqual(clean["number"] as? String, "+442079460958", "The destination stays independent of the owned line")
    }

    func testMalformedOrPartialLineMetadataCannotClaimAnOwnedNumber() throws {
        let cases: [[String: Any]] = [["numeroLine": "ca"], ["fromNumber": "+18775550123"],
                                     ["numeroLine": "uk", "fromNumber": "+18775550123"],
                                     ["numeroLine": "us", "fromNumber": "+442079460958"],
                                     ["numeroLine": "us", "fromNumber": "+12025550123\r\nX-Test: injected"]]
        for metadata in cases {
            var record = callRecord()
            record.merge(metadata) { _, value in value }
            let clean = try XCTUnwrap(Dialer.cleanRecord(record))
            XCTAssertNil(clean["numeroLine"])
            XCTAssertNil(clean["fromNumber"])
            XCTAssertEqual(clean["id"] as? String, "numero-call-fixture", "Legacy call details remain usable")
        }
    }

    @MainActor func testCompletedCallKeepsItsHistoricalLineAfterSettingsChange() throws {
        let dialer = Dialer.shared
        let before = dialer.setup
        defer { dialer.take(before) }
        var record = callRecord()
        record["numeroLine"] = "us"
        record["fromNumber"] = "+12025550123"
        dialer.take(DialerSetup(numeroUS: "+14155550123", numeroCA: "+16045550123"))
        let clean = try XCTUnwrap(Dialer.cleanRecord(record))
        XCTAssertEqual(clean["numeroLine"] as? String, "us")
        XCTAssertEqual(clean["fromNumber"] as? String, "+12025550123",
                       "Changing an owned number must not rewrite or remove an earlier call's identity")
    }

    private func callRecord() -> [String: Any] {
        ["id": "numero-call-fixture", "number": "+442079460958", "name": "Offline fixture", "direction": "out",
         "startedAt": 1_000, "answeredAt": 2_000, "endedAt": 3_000, "durationSec": 1, "outcome": "answered"]
    }
}
