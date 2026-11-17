import AppKit
import WebKit
import XCTest
@testable import Search

@MainActor
final class ScreenshotTests: XCTestCase {
    override class func setUp() { setenv("SEARCH_PROBE","screenshots-\(getpid())",1);super.setUp() }
    override func setUp() { _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited) }
    private func fixture(width: Int = 180,height: Int = 120) throws -> CGImage {
        var bytes=[UInt8](repeating:255,count:width*height*4)
        for y in 0..<height { for x in 0..<width {
            let i=(y*width+x)*4,bright=(x/3+y/3)%2==0
            bytes[i]=bright ? 240 : 12;bytes[i+1]=y<height/2 ? 50 : 200;bytes[i+2]=bright ? 40 : 240
        } }
        let provider=try XCTUnwrap(CGDataProvider(data:Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
                                    space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    }
    private func pixels(_ image: CGImage) throws -> NSBitmapImageRep { try XCTUnwrap(NSBitmapImageRep(data:ScreenshotImage.png(image))) }
    private func colour(_ image: NSBitmapImageRep,_ x: Int,_ y: Int) -> [Double] {
        let c=image.colorAt(x:x,y:y)!.usingColorSpace(.sRGB)!
        return [c.redComponent,c.greenComponent,c.blueComponent,c.alphaComponent].map(Double.init)
    }
    private func difference(_ a: [Double],_ b: [Double]) -> Double { zip(a,b).map { abs($0-$1) }.reduce(0,+) }
    private func done(_ document: ScreenshotDocument) async throws {
        let end=Date().addingTimeInterval(8)
        while document.rendering,Date()<end { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertFalse(document.rendering);XCTAssertNil(document.problem)
    }
    func testReverseDragAndRetinaPreviewMapToTopLeftPixelsAndClampToTheImage() {
        let size=CGSize(width:2400,height:1200)
        let frame=ScreenshotGeometry.imageFrame(size,in:CGRect(x:20,y:20,width:800,height:600))
        XCTAssertEqual(frame,CGRect(x:20,y:120,width:800,height:400))
        let selection=ScreenshotGeometry.selection(from:CGPoint(x:420,y:320),to:CGPoint(x:120,y:170),inside:frame)
        XCTAssertEqual(ScreenshotGeometry.pixels(selection,in:frame,image:size),CGRect(x:300,y:150,width:900,height:450))
        XCTAssertEqual(ScreenshotGeometry.pixels(CGRect(x:-20,y:0,width:80,height:200),in:frame,image:size),CGRect(x:0,y:0,width:120,height:240))
        XCTAssertNil(ScreenshotGeometry.pixels(CGRect(x:0,y:0,width:10,height:10),in:frame,image:size))
    }
    func testCaptureCropUsesTheSelectedPixelsAndPreservesOrientation() throws {
        let original=try fixture(),full=try pixels(original)
        let crop=try ScreenshotImage.cropped(original,to:CGRect(x:20,y:12,width:90,height:50)),image=try pixels(crop)
        XCTAssertEqual(crop.width,90);XCTAssertEqual(crop.height,50)
        XCTAssertLessThan(difference(colour(image,0,0),colour(full,20,12)),0.01)
        XCTAssertLessThan(difference(colour(image,89,49),colour(full,109,61)),0.01)
    }
    func testBlurChangesOnlySelectedTopLeftPixelRegions() throws {
        let original=try fixture(),full=try pixels(original)
        let output=try pixels(ScreenshotImage.render(original,areas:[CGRect(x:12,y:9,width:54,height:30),CGRect(x:120,y:81,width:36,height:24)]))
        XCTAssertGreaterThan(difference(colour(full,15,12),colour(output,15,12)),0.2)
        XCTAssertGreaterThan(difference(colour(full,123,84),colour(output,123,84)),0.2)
        for point in [(2,2),(90,15),(20,90),(170,110),(90,60)] {
            XCTAssertLessThan(difference(colour(full,point.0,point.1),colour(output,point.0,point.1)),0.015,"Outside the selected areas must stay unchanged")
        }
    }
    func testCopyAndSaveContainFlattenedBlurredPixelsInBothClipboardFormats() async throws {
        let original=try fixture(),document=ScreenshotDocument(original)
        document.blur(CGRect(x:12,y:9,width:54,height:30));try await done(document)
        let board=NSPasteboard(name:.init("SearchScreenshotTests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        XCTAssertTrue(document.copy(to:board))
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let file=folder.appendingPathComponent("blurred.png");try document.save(to:file)
        let expected=try pixels(document.image),before=try pixels(original)
        for data in [try XCTUnwrap(board.data(forType:.png)),try XCTUnwrap(board.data(forType:.tiff)),try Data(contentsOf:file)] {
            let exported=try XCTUnwrap(NSBitmapImageRep(data:data))
            XCTAssertLessThan(difference(colour(exported,15,12),colour(expected,15,12)),0.015)
            XCTAssertGreaterThan(difference(colour(exported,15,12),colour(before,15,12)),0.2)
            XCTAssertLessThan(difference(colour(exported,90,90),colour(before,90,90)),0.015)
        }
    }
    func testAnInFlightBlurCannotCopyOrSaveTheOriginalAndUndoRestoresIt() async throws {
        let original=try fixture(),document=ScreenshotDocument(original)
        let board=NSPasteboard(name:.init("SearchScreenshotTests-\(UUID().uuidString)"));defer { board.releaseGlobally() }
        board.setString("Existing clipboard",forType:.string)
        document.blur(CGRect(x:12,y:9,width:54,height:30))
        XCTAssertTrue(document.rendering);XCTAssertThrowsError(try document.png())
        XCTAssertFalse(document.copy(to:board));XCTAssertEqual(board.string(forType:.string),"Existing clipboard")
        try await done(document);document.undo();try await done(document)
        XCTAssertTrue(document.areas.isEmpty)
        XCTAssertEqual(try ScreenshotImage.png(document.image),try ScreenshotImage.png(original))
    }
    func testSaveDialogStartsInDocumentsWithAnEditablePNGName() {
        let panel=ScreenshotImage.savePanel(date:Date(timeIntervalSince1970:0))
        XCTAssertEqual(panel.directoryURL,FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first)
        XCTAssertTrue(panel.nameFieldStringValue.hasPrefix("Screenshot "))
        XCTAssertTrue(panel.nameFieldStringValue.hasSuffix(".png"))
        XCTAssertTrue(panel.canCreateDirectories);XCTAssertEqual(panel.allowedContentTypes,[.png])
        panel.nameFieldStringValue="My edited capture.png"
        XCTAssertEqual(panel.nameFieldStringValue,"My edited capture.png")
    }
    func testRealWebKitCaptureWaitsForSelectionThenOpensEditorAndClosesCleanly() async throws {
        let browser=Browser(record:WindowRecord());browser.closeAll()
        let window=NSWindow(contentRect:CGRect(x:-20000,y:-20000,width:640,height:440),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;browser.window=window
        defer { browser.closeAll();window.contentView=nil;window.close() }
        let tab=browser.open(URL(string:"about:blank")!,foreground:true)
        window.contentView=tab.web;window.orderBack(nil)
        tab.web.loadHTMLString("<title>Screenshot fixture</title><body style='background:#20395a;color:white;font:32px system-ui'>Capture this selected area</body>",baseURL:URL(string:"http://localhost"))
        let end=Date().addingTimeInterval(10)
        while tab.web.isLoading || tab.web.title != "Screenshot fixture" { guard Date()<end else { return XCTFail("Page failed to load") };try await Task.sleep(for:.milliseconds(20)) }
        tab.setAddressOptimistically(URL(string:"http://localhost/fixture")!)
        browser.screenshot.capture(in:browser)
        while browser.screenshot.selectionPanel==nil { guard Date()<end else { return XCTFail("Selection did not open") };try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertNil(browser.screenshot.document)
        let canvas=try XCTUnwrap(browser.screenshot.selectionPanel?.contentView as? ScreenshotCanvas)
        let rect=CGRect(x:40,y:30,width:200,height:100)
        browser.screenshot.select(rect)
        let document=try XCTUnwrap(browser.screenshot.document)
        XCTAssertEqual(document.image.width,200);XCTAssertEqual(document.image.height,100)
        XCTAssertNotNil(browser.screenshot.editorWindow);XCTAssertNil(browser.screenshot.selectionPanel)
        XCTAssertTrue(canvas.choosingCapture)
        browser.closeAll();XCTAssertNil(browser.screenshot.editorWindow);XCTAssertNil(browser.screenshot.document)
    }
}
