import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Search

final class OSINTTests: XCTestCase {
    func testAutomaticDetectionAndExplicitAmbiguities() {
        for (input,kind) in [("@example",OSINTKind.username),("Jane Example",.person),("Example Labs",.company),("example.com",.domain),("https://example.com/about",.website),("https://github.com/octocat",.social),("8.8.8.8",.ip),("2001:4860:4860::8888",.ip),("+1 (416) 555-0100",.phone)] {
            XCTAssertEqual(OSINTKind.detect(input),kind,input)
        }
    }
    func testInternationalNumberingDistinguishesSharedCallingCodes() {
        let canada=OSINTPhone.describe("+1 (416) 555-0100")
        XCTAssertEqual(canada["international"] as? String,"+14165550100")
        XCTAssertEqual(canada["numberingRegions"] as? [String],["Canada"])
        XCTAssertEqual(OSINTPhone.describe("+12125550100")["numberingRegions"] as? [String],["United States"])
        XCTAssertNotNil(OSINTPhone.describe("020 7946 0958")["error"])
        XCTAssertEqual(OSINTPhone.describe("02079460958",region:"GB")["international"] as? String,"+442079460958")
        XCTAssertNotNil(OSINTPhone.describe("+999123456789")["error"])
        XCTAssertTrue((canada["meaning"] as? String ?? "").contains("not proof"))
    }
    func testBlockedProfilesAndSoft404AreNotMatches() {
        let url=URL(string:"https://fixture.invalid/alice")!
        let site=OSINTService.Site(name:"Fixture",rule:["type":"message"],missing:["Profile missing"])
        func response(_ status: Int,_ body: String) -> OSINTHTTP.Response { .init(data:Data(body.utf8),status:status,url:url) }
        XCTAssertEqual(OSINTService.profileState(site,response(200,"Profile missing"),profile:url),.notFound)
        XCTAssertEqual(OSINTService.profileState(site,response(200,"Verify you are human"),profile:url),.unavailable)
        XCTAssertEqual(OSINTService.profileState(site,response(429,"slow down"),profile:url),.unavailable)
        XCTAssertEqual(OSINTService.profileState(site,response(200,"Alice's profile"),profile:url),.possible)
        XCTAssertEqual(OSINTService.profileState(site,response(404,""),profile:url),.notFound)
    }
    func testOriginalImageMetadataGPSAndHashArePreserved() throws {
        let data=try Self.imageFixture()
        let result=try OSINTImage.analyse(data)
        XCTAssertTrue(result.metadata.contains("Fixture Camera"))
        XCTAssertTrue(result.metadata.contains("SHA-256"))
        XCTAssertTrue(result.metadata.contains("-73.5"))
        XCTAssertTrue(result.pivots.contains { $0.contains("mlat=40.5") && $0.contains("mlon=-73.5") })
        XCTAssertTrue(result.summary.contains("GPS metadata present"))
        XCTAssertThrowsError(try OSINTImage.analyse(Data("not an image".utf8)))
    }
    func testReverseImageUploadContainsAReadableImageAndCompleteMultipartBody() throws {
        let picture=try ImageLookupRequest.picture(Self.imageFixture())
        let request=try ImageLookupRequest.request(picture:picture,link:"")
        XCTAssertEqual(request.httpMethod,"POST")
        XCTAssertEqual(request.url?.absoluteString,"https://lens.google.com/v3/upload")
        let header=try XCTUnwrap(request.value(forHTTPHeaderField:"Content-Type"))
        let boundary=try XCTUnwrap(header.components(separatedBy:"boundary=").last)
        let body=try XCTUnwrap(request.httpBody)
        XCTAssertTrue(body.starts(with:Data(("--"+boundary+"\r\n").utf8)))
        XCTAssertTrue(body.suffix(boundary.utf8.count+6).elementsEqual(Data(("--"+boundary+"--\r\n").utf8)))
        XCTAssertNotNil(body.range(of:picture.data))
        let source=try XCTUnwrap(CGImageSourceCreateWithData(picture.data as CFData,nil))
        let image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
        XCTAssertEqual(image.width,96)
        XCTAssertEqual(image.height,96)
    }
    static func imageFixture() throws -> Data {
        let color=CGColorSpaceCreateDeviceRGB()
        let context=try XCTUnwrap(CGContext(data:nil,width:96,height:96,bitsPerComponent:8,bytesPerRow:0,space:color,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray:0.8,alpha:1));context.fill(CGRect(x:0,y:0,width:96,height:96))
        let image=try XCTUnwrap(context.makeImage()),data=NSMutableData()
        let destination=try XCTUnwrap(CGImageDestinationCreateWithData(data,UTType.jpeg.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,[kCGImagePropertyTIFFDictionary:[kCGImagePropertyTIFFModel:"Fixture Camera"],kCGImagePropertyGPSDictionary:[kCGImagePropertyGPSLatitude:40.5,kCGImagePropertyGPSLatitudeRef:"N",kCGImagePropertyGPSLongitude:73.5,kCGImagePropertyGPSLongitudeRef:"W"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination));return data as Data
    }
    func testReportRoundTripPreservesEvidenceAndMissingSourceStates() throws {
        var report=OSINTReport(context:OSINTContext(text:"example.com"),kind:.domain)
        report.findings=[OSINTFinding(category:"Public profiles",title:"Possible",detail:"not confirmed identity",source:"https://fixture.invalid",state:.possible,evidence:"raw-\"value\"\n秘密",saved:true),OSINTFinding(category:"Sources",title:"Blocked",detail:"HTTP 403",source:"https://fixture.invalid",state:.unavailable)]
        let copy=try JSONDecoder().decode(OSINTReport.self,from:JSONEncoder().encode(report))
        XCTAssertEqual(copy.findings,report.findings)
    }
    func testDomainCollectionRejectsMalformedSourcesInsteadOfInventingNoResults() async {
        let collector=FindingCollector()
        let service=OSINTService(fetch: { url in .init(data:Data("<html>blocked</html>".utf8),status:200,url:url) })
        await service.domain("fixture.invalid") { await collector.append($0) }
        let results=await collector.values
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { $0.state == .unavailable })
    }
    func testIPCollectionAcceptsTheStringASNsReturnedByRIPE() async {
        let collector=FindingCollector()
        let service=OSINTService(fetch: { url in
            .init(data:Data("{\"data\":{\"asns\":[\"13335\"],\"prefix\":\"1.1.1.0/24\"}}".utf8),status:200,url:url)
        })
        await service.ip("1.1.1.1") { await collector.append($0) }
        let rows=await collector.values
        XCTAssertTrue(rows.contains { $0.title=="Announcing networks" && $0.detail.contains("AS13335") })
    }
    func testPublicCompanyAndWebResultsKeepProvenanceAndPossibleStatus() async {
        let collector=FindingCollector()
        let service=OSINTService(fetch: { url in
            let j: [String:Any]=url.host=="api.gleif.org" ? ["data":[["id":"fixture-lei","attributes":["lei":"fixture-lei","entity":["legalName":["name":"Fixture Ltd"],"status":"ACTIVE"]]]]] : ["results":[["title":"Fixture result","url":"https://fixture.invalid/about","content":"Public snippet"]]]
            return .init(data:try JSONSerialization.data(withJSONObject:j),status:200,url:url)
        },searx:"http://localhost:8080")
        await service.company("Fixture Ltd") { await collector.append($0) }
        await service.web("Fixture Ltd") { await collector.append($0) }
        let rows=await collector.values
        XCTAssertEqual(rows.first?.title,"Fixture Ltd")
        XCTAssertEqual(rows.first?.state,.possible)
        XCTAssertTrue(rows.contains { $0.source=="https://fixture.invalid/about" && $0.state == .possible })
        XCTAssertTrue(rows.contains { $0.state == .reference })
    }
}

private actor FindingCollector {
    var values: [OSINTFinding]=[]
    func append(_ finding: OSINTFinding) { values.append(finding) }
}

@MainActor final class OSINTPersistenceTests: XCTestCase {
    override class func setUp() { setenv("SEARCH_PROBE","osint-tests-\(getpid())",1);super.setUp() }
    func testBookmarkPersistsWithItsProfileAndCanBeRemoved() async throws {
        _ = NSApplication.shared
        let profile=UUID(),session=OSINTSession()
        defer { try? FileManager.default.removeItem(at:OSINTSession.savedFolder(profile)) }
        session.image(try OSINTTests.imageFixture(),name:"fixture.jpg")
        for _ in 0..<800 where session.running { try await Task.sleep(for:.milliseconds(50)) }
        XCTAssertFalse(session.running)
        let id=try XCTUnwrap(session.report?.findings.first?.id)
        session.toggleSaved(id,profile:profile)
        XCTAssertNil(session.problem)
        let other=OSINTSession();other.loadSaved(profile)
        XCTAssertEqual(other.savedReports.count,1)
        other.loadSaved(UUID());XCTAssertTrue(other.savedReports.isEmpty)
        other.loadSaved(profile);other.restore(try XCTUnwrap(other.savedReports.first))
        XCTAssertNotNil(other.imageData)
        let folder=OSINTSession.savedFolder(profile)
        let permission=try FileManager.default.attributesOfItem(atPath:folder.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permission?.intValue,0o700)
        other.toggleSaved(id,profile:profile)
        XCTAssertTrue(other.savedReports.isEmpty)
    }
    func testClearingDuringBrowserImageFetchDoesNotRestoreAnOldReport() async throws {
        let session=OSINTSession(),data=try OSINTTests.imageFixture()
        session.investigate(OSINTContext(text:"https://fixture.invalid/image.jpg",imageURL:"https://fixture.invalid/image.jpg",kind:.image),imageResolver: {
            try? await Task.sleep(for:.milliseconds(100))
            return data
        })
        await Task.yield()
        session.clear()
        try await Task.sleep(for:.milliseconds(200))
        XCTAssertNil(session.report)
        XCTAssertFalse(session.running)
        XCTAssertNil(session.imageData)
    }
    func testPanelAndMenuAreAvailableWithoutEnablingAI() throws {
        let browser=Browser(record:WindowRecord());defer { browser.closeAll() }
        browser.prefs.ai=false
        let tab=browser.open(URL(string:"https://fixture.invalid")!,foreground:true)
        browser.showOSINT()
        XCTAssertEqual(browser.sidePanel,.osint)
        let menu=NSMenu();tab.web.addOSINTItem(to:menu);tab.web.addOSINTItem(to:menu)
        XCTAssertEqual(menu.items.filter { $0.title=="OSINT it" }.count,1)
        browser.closeSidePanel();XCTAssertFalse(browser.sidePanelShown)
    }
}
