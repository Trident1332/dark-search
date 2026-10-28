import Foundation
import Security
import WebKit
import XCTest
@testable import Search

@MainActor
final class CertificateExceptionsTests: XCTestCase {
    private let host = "certificate-exception.example.invalid"

    private func space(host: String = "certificate-exception.example.invalid", port: Int = 443,
                       scheme: String = "https") -> URLProtectionSpace {
        URLProtectionSpace(host: host, port: port, protocol: scheme, realm: nil,
                           authenticationMethod: NSURLAuthenticationMethodServerTrust)
    }

    private func trust(_ encoded: String) throws -> SecTrust {
        let bytes = try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, bytes as CFData))
        var made: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, host as CFString), &made), errSecSuccess)
        let trust = try XCTUnwrap(made)
        SecTrustSetNetworkFetchAllowed(trust, false)
        XCTAssertFalse(SecTrustEvaluateWithError(trust, nil), "The fixture is an untrusted self-signed certificate")
        return trust
    }

    func testAcceptedCertificateIsRecognizedAcrossTrustObjects() throws {
        let exceptions = CertificateExceptions()
        let store = WKWebsiteDataStore.nonPersistent()
        let original = try trust(Self.first)
        XCTAssertFalse(exceptions.contains(original, for: space(), in: store))
        XCTAssertTrue(exceptions.accept(original, for: space(), in: store))
        XCTAssertTrue(exceptions.contains(try trust(Self.first), for: space(), in: store),
                      "Revisiting the accepted certificate on the same origin and store stays accepted")
    }

    func testAChangedCertificateRequiresConsentAgain() throws {
        let exceptions = CertificateExceptions()
        let store = WKWebsiteDataStore.nonPersistent()
        exceptions.accept(try trust(Self.first), for: space(), in: store)
        XCTAssertFalse(exceptions.contains(try trust(Self.second), for: space(), in: store))
    }

    func testAnExceptionDoesNotCrossPortsSchemesOrHosts() throws {
        let exceptions = CertificateExceptions()
        let store = WKWebsiteDataStore.nonPersistent()
        let certificate = try trust(Self.first)
        exceptions.accept(certificate, for: space(), in: store)
        XCTAssertFalse(exceptions.contains(certificate, for: space(port: 8443), in: store))
        XCTAssertFalse(exceptions.contains(certificate, for: space(scheme: "http"), in: store))
        XCTAssertFalse(exceptions.contains(certificate, for: space(host: "other.example.invalid"), in: store))
    }

    func testAnotherProfileOrPrivateStoreRequiresItsOwnConsent() throws {
        let exceptions = CertificateExceptions()
        let profile = WKWebsiteDataStore.nonPersistent()
        let otherProfile = WKWebsiteDataStore.nonPersistent()
        let privateTab = WKWebsiteDataStore.nonPersistent()
        let certificate = try trust(Self.first)
        exceptions.accept(certificate, for: space(), in: profile)
        XCTAssertFalse(exceptions.contains(certificate, for: space(), in: otherProfile))
        XCTAssertFalse(exceptions.contains(certificate, for: space(), in: privateTab))
        exceptions.accept(certificate, for: space(), in: privateTab)
        XCTAssertTrue(exceptions.contains(certificate, for: space(), in: privateTab))
    }

    // Public self-signed certificates generated only for these tests. The
    // corresponding private keys are discarded and never enter the repo.
    private static let first = """
    MIICPDCCAeICAQEwCgYIKoZIzj0EAwIwMDEuMCwGA1UEAwwlY2VydGlmaWNhdGUtZXhjZXB0aW9uLmV4YW1wbGUu
    aW52YWxpZDAeFw0yNjEwMjgyMTExNDFaFw0zNjEwMjUyMTExNDFaMDAxLjAsBgNVBAMMJWNlcnRpZmljYXRlLWV4
    Y2VwdGlvbi5leGFtcGxlLmludmFsaWQwggFLMIIBAwYHKoZIzj0CATCB9wIBATAsBgcqhkjOPQEBAiEA/////wAA
    AAEAAAAAAAAAAAAAAAD///////////////8wWwQg/////wAAAAEAAAAAAAAAAAAAAAD///////////////wEIFrG
    NdiqOpPns+u9VXaYhrxlHQawzFOw9jvOPD4n0mBLAxUAxJ02CIbnBJNqZnjhE50mt4GffpAEQQRrF9Hy4SxCR/i8
    5uVjpEDydwN9gS3rM6D0oTlF2JjClk/jQuL+Gn+bjufrSnwPnhYrzjNXazFezsu2QGg3v1H1AiEA/////wAAAAD/
    /////////7zm+q2nF56E87nKwvxjJVECAQEDQgAEtCpdupTo04vSr8jmkm48RT+WC9LNCk37wEpd7LLumzonvPXS
    1IJEvqn4HC3MNJJsKfU0fVubBGhYLs4XVl9lbjAKBggqhkjOPQQDAgNIADBFAiEAhUsa1ud5VaZHYaZzhPU2ukwW
    wKZJ7S9QUVh/t8I+vjMCIBOiAgoOEEIq//2dyi8Qcg2KlUk7DOYK4qoX35D4lhpq
    """
    private static let second = """
    MIICOzCCAeICAQIwCgYIKoZIzj0EAwIwMDEuMCwGA1UEAwwlY2VydGlmaWNhdGUtZXhjZXB0aW9uLmV4YW1wbGUu
    aW52YWxpZDAeFw0yNjEwMjgyMTExNDFaFw0zNjEwMjUyMTExNDFaMDAxLjAsBgNVBAMMJWNlcnRpZmljYXRlLWV4
    Y2VwdGlvbi5leGFtcGxlLmludmFsaWQwggFLMIIBAwYHKoZIzj0CATCB9wIBATAsBgcqhkjOPQEBAiEA/////wAA
    AAEAAAAAAAAAAAAAAAD///////////////8wWwQg/////wAAAAEAAAAAAAAAAAAAAAD///////////////wEIFrG
    NdiqOpPns+u9VXaYhrxlHQawzFOw9jvOPD4n0mBLAxUAxJ02CIbnBJNqZnjhE50mt4GffpAEQQRrF9Hy4SxCR/i8
    5uVjpEDydwN9gS3rM6D0oTlF2JjClk/jQuL+Gn+bjufrSnwPnhYrzjNXazFezsu2QGg3v1H1AiEA/////wAAAAD/
    /////////7zm+q2nF56E87nKwvxjJVECAQEDQgAEpeAhmhDSBtGYsDemWkgg5f1gf6Q/oKC2bZh95+rXfke0FHVe
    ht3jLJXzhq+9jIcQKCiKBUZ/TtG20gtILqbQWjAKBggqhkjOPQQDAgNHADBEAiBkVkRLc0blb3Gfc54x0ozkgP7y
    JGP6D+gOGEBatlVzEgIgUdxAGHAuF6rMynSSFqx8F9C2aPOxitFjtm1uPcLD+mw=
    """
}
