import XCTest
@testable import Search

/// UK Telicall configuration is independent of the two Numero lines.
/// Every number here is a synthetic fixture; no account is registered.
final class DialerTelicallTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "dialer-telicall-\(getpid())", 1)
        super.setUp()
    }

    func testUKNumberAcceptsExplicitCountryCodeAndPastedFormatting() {
        XCTAssertEqual(DialerTelicall.number("+44 20 7946 0958"), "+442079460958")
        XCTAssertEqual(DialerTelicall.number("44 (20) 7946-0958"), "+442079460958")
        XCTAssertEqual(DialerTelicall.number(" +44 7700.900123 "), "+447700900123")
        XCTAssertEqual(DialerTelicall.number("+44123456789"), "+44123456789")
    }

    func testUKNumberRejectsWrongCountryTrunkAndUnsafeSIPInput() {
        for typed in ["", "020 7946 0958", "+44 (0)20 7946 0958", "+12025550123", "+33123456789",
                      "+4412345678", "+4412345678901", "+44123456789012345", "++442079460958",
                      "+44\t2079460958", "tel:+442079460958", "+442079460958;ext=5",
                      "+442079460958\r\nX-Provider: numero", "＋４４２０７９４６０９５８"] {
            XCTAssertNil(DialerTelicall.number(typed), "Invalid UK caller number was accepted")
        }
    }

    @MainActor func testDefaultCountryNeverChangesTheUKOutgoingNumber() {
        let dialer = Dialer.shared
        let before = dialer.setup
        defer { dialer.take(before) }
        for region in ["US", "CA", "GB"] {
            dialer.take(DialerSetup(region: region, telicallUK: "+44 20 7946 0958"))
            XCTAssertEqual(dialer.values(["telicallUK"])["telicallUK"] as? String, "+442079460958")
        }
        dialer.take(DialerSetup(region: "GB", telicallUK: "020 7946 0958"))
        XCTAssertEqual(dialer.values(["telicallUK"])["telicallUK"] as? String, "020 7946 0958",
                       "An invalid explicit draft stays nonempty instead of silently using a legacy route")
    }

    @MainActor func testUKPreferencePersistsAndRestoresSeparatelyFromNumero() {
        let prefs = Shared.prefs
        let before = prefs.dialerTelicallUK
        defer { prefs.dialerTelicallUK = before }
        prefs.dialerTelicallUK = "+44 20 7946 0958"
        XCTAssertEqual(Store.settings.string(forKey: "dialer.telicall.uk"), "+44 20 7946 0958")
        let restored = Preferences()
        XCTAssertEqual(restored.dialerTelicallUK, "+44 20 7946 0958")
        XCTAssertEqual(restored.dialerSetup.telicallUK, "+44 20 7946 0958")
        XCTAssertEqual(Dialer.shared.values(["telicallUK"])["telicallUK"] as? String, "+442079460958")
    }

    @MainActor func testApprovedSiteConfigurationKeepsTheProviderNumbersSeparate() {
        let prefs = Shared.prefs
        let before = prefs.dialerTelicallUK
        let numero = (prefs.dialerNumeroUS, prefs.dialerNumeroCA)
        defer { prefs.dialerTelicallUK = before }
        Dialer.shared.takeConfig(["telicallUK": "+44 20 7946 0958"])
        XCTAssertEqual(prefs.dialerTelicallUK, "+44 20 7946 0958")
        XCTAssertEqual(prefs.dialerNumeroUS, numero.0)
        XCTAssertEqual(prefs.dialerNumeroCA, numero.1)
        let config = Dialer.shared.configForSites()
        XCTAssertEqual(config["telicallUK"] as? String, "+442079460958")
        XCTAssertNil(config["password"])
    }

    @MainActor func testSettingsIncludeTheUKTelicallFieldAndSearchTerms() throws {
        let item = try XCTUnwrap(SettingsIndex.item("dialer.numbers"))
        XCTAssertEqual(item.title, "Your phone numbers")
        XCTAssertTrue(item.keys.contains("dialer.telicall.uk"))
        XCTAssertTrue(SettingsIndex.find("Telicall").contains { $0.id == item.id })
        XCTAssertTrue(SettingsIndex.find("UK").contains { $0.id == item.id })
    }

    @MainActor func testCallRecordKeepsTheHistoricalUKTelicallIdentity() throws {
        let dialer = Dialer.shared
        let before = dialer.setup
        defer { dialer.take(before) }
        dialer.take(DialerSetup(telicallUK: "+447700900123"))
        var record = callRecord()
        record["telicallLine"] = "uk"
        record["fromNumber"] = "+44 20 7946 0958"
        let clean = try XCTUnwrap(Dialer.cleanRecord(record))
        XCTAssertEqual(clean["telicallLine"] as? String, "uk")
        XCTAssertEqual(clean["fromNumber"] as? String, "+442079460958")
        XCTAssertNil(clean["numeroLine"])
    }

    func testMixedOrMalformedProviderMetadataCannotClaimAnOutgoingLine() throws {
        let cases: [[String: Any]] = [
            ["telicallLine": "uk"], ["fromNumber": "+442079460958"],
            ["telicallLine": "us", "fromNumber": "+442079460958"],
            ["telicallLine": "uk", "fromNumber": "+12025550123"],
            ["numeroLine": "us", "telicallLine": "uk", "fromNumber": "+12025550123"],
            ["numeroLine": "us", "telicallLine": "uk", "fromNumber": "+442079460958"],
        ]
        for metadata in cases {
            var record = callRecord()
            record.merge(metadata) { _, value in value }
            let clean = try XCTUnwrap(Dialer.cleanRecord(record))
            XCTAssertNil(clean["numeroLine"])
            XCTAssertNil(clean["telicallLine"])
            XCTAssertNil(clean["fromNumber"])
        }
    }

    private func callRecord() -> [String: Any] {
        ["id": "telicall-fixture", "number": "+12025550123", "direction": "out", "startedAt": 1_000,
         "answeredAt": 2_000, "endedAt": 3_000, "durationSec": 1, "outcome": "answered"]
    }
}
