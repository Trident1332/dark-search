import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Search

final class ImageLookupRequestTests: XCTestCase {
    static func fixture() -> Data {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<24 { for x in 0..<32 { image.setColor((x + y) % 2 == 0 ? .systemBlue : .white, atX: x, y: y) } }
        return image.representation(using: .png, properties: [:])!
    }
    func testURLValidationRejectsFilesScriptsCredentialsAndMissingHosts() {
        for value in ["file:///tmp/picture.png", "javascript:alert(1)", "data:image/png;base64,test", "https://user:password@example.com/a.jpg", "https:///", "not a url"] {
            XCTAssertThrowsError(try ImageLookupRequest.imageURL(value), value)
        }
    }
    func testImageURLIsEncodedAsOneQueryValue() throws {
        let link = "https://example.com/a.jpg?a=1&b=two%20words#crop"
        let request = try ImageLookupRequest.request(picture: nil, link: link)
        let parts = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.host, "lens.google.com")
        XCTAssertEqual(parts.path, "/uploadbyurl")
        XCTAssertEqual(parts.queryItems, [URLQueryItem(name: "url", value: link)])
        XCTAssertNil(request.httpBody)
    }
    func testNonImageAndOversizedInputAreRejected() {
        XCTAssertThrowsError(try ImageLookupRequest.picture(Data("%PDF-1.7 Not an image".utf8)))
        XCTAssertThrowsError(try ImageLookupRequest.picture(Data(repeating: 0, count: ImageLookupRequest.limit + 1)))
    }
    func testPictureIsRerasterizedWithoutSourceMetadata() throws {
        let picture = try ImageLookupRequest.picture(Self.fixture())
        XCTAssertEqual(picture.width, 32)
        XCTAssertEqual(picture.height, 24)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(picture.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil(properties[kCGImagePropertyIPTCDictionary])
    }
    func testUploadBodyContainsOnlyNormalizedImageAndGenericFilename() throws {
        let picture = try ImageLookupRequest.picture(Self.fixture())
        let request = try ImageLookupRequest.request(picture: picture, link: "https://unused.invalid/private-filename")
        XCTAssertEqual(request.url, ImageLookupRequest.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertNotNil(body.range(of: picture.data))
        XCTAssertTrue(String(decoding: body.prefix(200), as: UTF8.self).contains("filename=\"image.jpg\""))
        XCTAssertNil(body.range(of: Data("private-filename".utf8)))
        XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }
}

@MainActor
final class ImageLookupInteractionTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "image-lookup-tests-\(getpid())", 1)
        super.setUp()
    }
    func testPreparationRequiresExplicitSearchAndClearForgetsImage() async throws {
        _ = NSApplication.shared
        let lookup = ImageLookup()
        let data = ImageLookupRequestTests.fixture()
        XCTAssertFalse(lookup.canSearch)
        lookup.prepare { data }
        try await until { !lookup.loading }
        XCTAssertTrue(lookup.canSearch)
        XCTAssertNotNil(lookup.picture)
        lookup.clear()
        XCTAssertFalse(lookup.canSearch)
        XCTAssertNil(lookup.picture)
        XCTAssertTrue(lookup.link.isEmpty)
    }
    func testLatePreparationCannotRestoreAnImageAfterClosing() async throws {
        _ = NSApplication.shared
        let lookup = ImageLookup()
        let data = ImageLookupRequestTests.fixture()
        lookup.prepare { Thread.sleep(forTimeInterval: 0.1); return data }
        lookup.clear()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(lookup.loading)
        XCTAssertNil(lookup.picture)
        XCTAssertFalse(lookup.canSearch)
    }
    private func until(_ ready: () -> Bool) async throws {
        for _ in 0..<200 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Image preparation timed out")
    }
}
