import AppKit
import WebKit
import XCTest
@testable import Search

/// Synthetic AppKit overlays cover the lifecycle policy without entering a
/// system full-screen window or claiming that real video controls were clicked.
@MainActor
final class FullscreenVideoOverlayTests: XCTestCase {
    override class func setUp() {
        if ProcessInfo.processInfo.environment["SEARCH_PROBE"] == nil {
            setenv("SEARCH_PROBE", "fullscreen-video-overlay-\(getpid())", 1)
        }
        super.setUp()
    }

    func testOnlyVideoAnalysisOverlayIsHiddenWhileFullscreen() {
        withPage { page in
            let ordinary = NSView(frame: .zero)
            let analysis = VKCImageAnalysisOverlayViewSearchRegression(frame: .zero)
            page.adjustVideoAnalysisOverlay(ordinary, fillingScreen: true)
            XCTAssertFalse(ordinary.isHidden, "ordinary WebKit subviews must retain their visibility")

            page.adjustVideoAnalysisOverlay(analysis, fillingScreen: false)
            XCTAssertFalse(analysis.isHidden, "inline image analysis remains available")
            page.adjustVideoAnalysisOverlay(analysis, fillingScreen: true)
            XCTAssertTrue(analysis.isHidden, "paused full-screen video must receive clicks itself")
        }
    }

    func testReusedAnalysisViewReturnsToInlineWithoutChangingLaterWebKitVisibility() {
        withPage { page in
            let analysis = VKCImageAnalysisOverlayViewSearchRegression(frame: .zero)
            page.addSubview(analysis)
            page.adjustVideoAnalysisOverlay(analysis, fillingScreen: true)
            XCTAssertTrue(analysis.isHidden)

            analysis.removeFromSuperview()
            page.addSubview(analysis)
            XCTAssertFalse(analysis.isHidden, "didAddSubview restores our hidden view when WebKit reuses it inline")

            analysis.isHidden = true
            analysis.removeFromSuperview()
            page.addSubview(analysis)
            XCTAssertTrue(analysis.isHidden, "after restoration, WebKit's own visibility choice is respected")
        }
    }

    func testAnInlineOverlayHiddenByWebKitIsNotUnhidden() {
        withPage { page in
            let analysis = VKCImageAnalysisOverlayViewSearchRegression(frame: .zero)
            analysis.isHidden = true
            page.addSubview(analysis)
            XCTAssertTrue(analysis.isHidden)
        }
    }

    private func withPage(_ body: (PageView) -> Void) {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = PageView(frame: .zero, configuration: configuration)
        defer { ProxyTimeZone.close(page) }
        body(page)
    }
}

@objc(VKCImageAnalysisOverlayViewSearchRegression)
private final class VKCImageAnalysisOverlayViewSearchRegression: NSView {}
