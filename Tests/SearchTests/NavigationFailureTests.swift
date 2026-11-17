import AppKit
import WebKit
import SwiftUI
import XCTest
@testable import Search

final class NavigationFailureMessageTests: XCTestCase {
    func testTransportErrorsDescribeTheDestinationWithoutClaimingGlobalOffline() {
        let url = URL(string: "https://mail.example.test/login?token=secret")!
        let cases: [(Int, String)] = [
            (NSURLErrorNetworkConnectionLost, "The connection to mail.example.test was interrupted."),
            (NSURLErrorNotConnectedToInternet, "Couldn't reach mail.example.test. Check your network connection and try again."),
            (NSURLErrorCannotFindHost, "Couldn't find mail.example.test. Check the address or try again later."),
            (NSURLErrorDNSLookupFailed, "Couldn't find mail.example.test. Check the address or try again later."),
            (NSURLErrorTimedOut, "mail.example.test took too long to respond."),
            (NSURLErrorCannotConnectToHost, "Couldn't connect to mail.example.test. The site may be unavailable."),
            (NSURLErrorServerCertificateUntrusted, "A secure connection to mail.example.test could not be established."),
        ]
        for (code, expected) in cases {
            XCTAssertEqual(NavigationFailure.message(NSError(domain: NSURLErrorDomain, code: code), destination: url), expected)
        }
    }

    func testOnlyURLErrorDomainIsInterpretedAndPrivateURLPartsAreOmitted() {
        let url = URL(string: "https://user:password@mail.example.test/private?token=secret#fragment")!
        let message = NavigationFailure.message(NSError(domain: "OtherErrorDomain", code: NSURLErrorNotConnectedToInternet), destination: url)
        XCTAssertEqual(message, "Couldn't load mail.example.test.")
        XCTAssertEqual(NavigationFailure.message(NSError(domain: NSURLErrorDomain, code: 999), destination: nil), "Couldn't load this page.")
    }

    func testFailingRedirectURLWinsOverTheOriginalDestination() {
        let original = URL(string: "https://original.example.test")!
        let redirected = URL(string: "https://redirect.example.test/signin")!
        XCTAssertEqual(NavigationFailure.destination(NSError(domain: NSURLErrorDomain, code: -1005,
            userInfo: [NSURLErrorFailingURLErrorKey: redirected]), fallback: original), redirected)
        XCTAssertEqual(NavigationFailure.destination(NSError(domain: NSURLErrorDomain, code: -1005,
            userInfo: [NSURLErrorFailingURLStringErrorKey: redirected.absoluteString]), fallback: original), redirected)
        XCTAssertEqual(NavigationFailure.destination(NSError(domain: NSURLErrorDomain, code: -1005), fallback: original), original)
    }
}

@MainActor
final class NavigationFailureTests: XCTestCase {
    override class func setUp() {
        if ProcessInfo.processInfo.environment["SEARCH_PROBE"] == nil {
            setenv("SEARCH_PROBE", "navigation-failure-\(getpid())", 1)
        }
        super.setUp()
    }

    func testFirstLoadFailureKeepsDestinationWithoutCommittingItsOrigin() throws {
        let browser = makeBrowser()
        defer { browser.closeAll() }
        let tab = try XCTUnwrap(browser.active)
        let destination = URL(string: "https://mail.example.test/login")!
        tab.setAddressOptimistically(destination)
        let web = tab.web
        XCTAssertNil(tab.restAddress)
        XCTAssertEqual(tab.addressBarAddress, destination, "A pending first load must not leave the toolbar empty")
        XCTAssertTrue(tab.addressBarIsDestination, "The requested address must not appear as a committed identity")
        browser.webView(web, didFailProvisionalNavigation: nil, withError: NSError(domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost, userInfo: [NSURLErrorFailingURLErrorKey: destination]))
        XCTAssertEqual(tab.addressBarAddress, destination)
        XCTAssertNil(tab.committed)
        XCTAssertNil(tab.restAddress, "A failed destination must not vouch for a document")
        XCTAssertEqual(tab.failure, "The connection to mail.example.test was interrupted.")
    }

    func testFailedNavigationShowsItsDestinationThenRestoresCommittedIdentity() async throws {
        let browser = makeBrowser()
        defer { browser.closeAll() }
        let tab = try XCTUnwrap(browser.active)
        let server = try LocalPageServer(["/": .init(type: "text/html", body: "<title>Original</title>")])
        defer { server.stop() }
        tab.go(to: server.url("/"))
        try await until { tab.committed == server.url("/") && !tab.loading }
        let original = tab.committed
        let failed = URL(string: "https://failed.example.test/redirect")!
        browser.webView(tab.web, didFailProvisionalNavigation: nil, withError: NSError(domain: NSURLErrorDomain,
            code: NSURLErrorCannotFindHost, userInfo: [NSURLErrorFailingURLErrorKey: failed]))
        XCTAssertEqual(tab.addressBarAddress, failed)
        XCTAssertEqual(tab.committed, original)
        XCTAssertEqual(tab.restAddress, original)
        XCTAssertTrue(tab.addressBarIsDestination)
        tab.failure = nil
        XCTAssertNil(tab.failedAddress)
        XCTAssertEqual(tab.addressBarAddress, original)
        XCTAssertFalse(tab.addressBarIsDestination)
    }

    func testCancelledAndHandedOffLoadsKeepTheCurrentPage() throws {
        let browser = makeBrowser()
        defer { browser.closeAll() }
        let tab = try XCTUnwrap(browser.active)
        let web = tab.web
        for (domain, code) in [(NSURLErrorDomain, NSURLErrorCancelled), ("WebKitErrorDomain", 102), ("WebKitErrorDomain", 204)] {
            browser.webView(web, didFailProvisionalNavigation: nil, withError: NSError(domain: domain, code: code))
            XCTAssertNil(tab.failure)
            XCTAssertNil(tab.failedAddress)
        }
    }

    func testActualRefusedFirstLoadThenNewNavigationRecovers() async throws {
        let browser = makeBrowser()
        defer { browser.closeAll() }
        let tab = try XCTUnwrap(browser.active)
        let closed = try LocalPageServer([:])
        let destination = closed.url("/unreachable")
        closed.stop()
        tab.go(to: destination)
        _ = tab.web
        try await until { tab.failure != nil }
        XCTAssertEqual(tab.addressBarAddress, destination)
        XCTAssertNil(tab.committed)
        XCTAssertTrue(tab.failure?.contains("127.0.0.1") == true)
        let server = try LocalPageServer(["/": .init(type: "text/html", body: "<title>Recovered</title>")])
        defer { server.stop() }
        tab.go(to: server.url("/"))
        try await until { tab.committed == server.url("/") && !tab.loading }
        XCTAssertNil(tab.failure)
        XCTAssertNil(tab.failedAddress)
        XCTAssertEqual(tab.addressBarAddress, server.url("/"))
    }

    func testFailedAddressRendersInTheNativeToolbar() async throws {
        let browser = makeBrowser()
        defer { browser.closeAll() }
        let tab = try XCTUnwrap(browser.active)
        let destination = URL(string: "https://mail.example.test/login")!
        tab.setAddressOptimistically(destination)
        _ = tab.web
        tab.navigationFailed(NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost))
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            AddressBar(browser: browser)
            Trouble(message: tab.failure!) { tab.reload() }
        }.frame(width: 1000, height: 400))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(nanoseconds: 200_000_000)
        host.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        XCTAssertGreaterThan(image.pixelsWide, 0)
        if let folder = ProcessInfo.processInfo.environment["SEARCH_FAILURE_SCREENSHOTS"] {
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("failed-address.png"))
        }
    }

    private func makeBrowser() -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        return Browser(record: WindowRecord())
    }
    private func until(_ check: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if check() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Navigation did not settle")
        throw CancellationError()
    }
}
