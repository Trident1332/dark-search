import XCTest
@testable import Search

final class ProxyCountryTests: XCTestCase {
    func testRecognizedCountryCodesProduceTheirFlags() {
        for (code, flag) in [("DE", "🇩🇪"), ("US", "🇺🇸"), ("GB", "🇬🇧")] {
            XCTAssertEqual(ProxyCountry.normalized(code), code)
            XCTAssertEqual(ProxyCountry.flag(for: code), flag)
        }
    }

    func testCountryCodesAreTrimmedAndUppercased() {
        for (raw, code, flag) in [(" de ", "DE", "🇩🇪"), ("\tus\n", "US", "🇺🇸"), ("gB", "GB", "🇬🇧")] {
            XCTAssertEqual(ProxyCountry.normalized(raw), code)
            XCTAssertEqual(ProxyCountry.flag(for: raw), flag)
        }
    }

    func testMissingAndUnknownCountriesDoNotInventFlags() {
        let values: [String?] = [nil, "", " \t\n", "ZZ", "zz", "XX", "QQ"]
        for value in values {
            XCTAssertNil(ProxyCountry.normalized(value))
            XCTAssertNil(ProxyCountry.flag(for: value))
        }
    }

    func testMalformedAndNonASCIICodesAreRejected() {
        for value in ["D", "DEU", "Germany", "D1", "D E", "🇩🇪", "💡", "éé", "ß", "𝕌𝕊"] {
            XCTAssertNil(ProxyCountry.normalized(value))
            XCTAssertNil(ProxyCountry.flag(for: value))
        }
    }
}
