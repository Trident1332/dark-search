import AppKit
import WebKit
import XCTest
@testable import Search

/// A held native-capture stand-in makes queue pressure and late replies
/// observable without starting a web process or touching the live browser.
@MainActor
final class TabSwitcherPreviewTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "tab-switcher-previews-\(getpid())", 1)
        super.setUp()
    }

    func testThreeTabsAcrossOneHundredCyclesHaveOneCaptureEach() {
        let driver = PreviewDriver(), switcher = makeSwitcher(driver)
        let tabs = (0..<3).map { tab("tab\($0)") }
        let alive = Set(tabs.map(\.id))
        for index in 0..<100 { switcher.left(tabs[index % tabs.count], alive: alive) }
        XCTAssertEqual(driver.requests.count, 3, "Moving between three tabs must not queue one capture per switch")
        for tab in tabs { XCTAssertEqual(driver.pending(for: tab.id), 1) }
        for index in driver.requests.indices { driver.reply(index, image: image()) }
        for tab in tabs { XCTAssertNotNil(switcher.preview(for: tab.id, address: tab.address)) }

        driver.now = 1
        for index in 0..<100 { switcher.left(tabs[index % tabs.count], alive: alive) }
        XCTAssertEqual(driver.requests.count, 3, "Recent same-address thumbnails need no redundant native work")
        driver.now = 2.1
        switcher.left(tabs[0], alive: alive)
        for _ in 0..<100 { switcher.left(tabs[0], alive: alive) }
        XCTAssertEqual(driver.requests.count, 4, "A later refresh still has only one pending capture")
    }

    func testNavigationRefreshesImmediatelyAndOldReplyCannotReplaceNewAddress() {
        let driver = PreviewDriver(), switcher = makeSwitcher(driver)
        let tab = tab("before"), alive: Set<Tab.ID> = [tab.id]
        switcher.left(tab, alive: alive)
        let oldAddress = tab.address
        tab.setAddressOptimistically(URL(string: "https://preview.invalid/after")!)
        switcher.left(tab, alive: alive)
        XCTAssertEqual(driver.requests.count, 2, "A new address must not wait for the previous address's lease")
        driver.reply(0, image: image())
        XCTAssertNil(switcher.preview(for: tab.id, address: oldAddress))
        XCTAssertNil(switcher.preview(for: tab.id, address: tab.address))
        let current = image()
        driver.reply(1, image: current)
        XCTAssertTrue(switcher.preview(for: tab.id, address: tab.address) === current)

        tab.setAddressOptimistically(URL(string: "https://preview.invalid/third")!)
        switcher.left(tab, alive: alive)
        XCTAssertEqual(driver.requests.count, 3, "Even a fresh cache must be bypassed after navigation")
    }

    func testTimeoutAllowsOneRetryButNeverAccumulatesUnansweredCaptures() {
        let driver = PreviewDriver(), switcher = makeSwitcher(driver)
        let tab = tab("slow"), alive: Set<Tab.ID> = [tab.id]
        switcher.left(tab, alive: alive)
        driver.now = 4.9
        switcher.left(tab, alive: alive)
        XCTAssertEqual(driver.requests.count, 1)
        driver.now = 5.1
        switcher.left(tab, alive: alive)
        XCTAssertEqual(driver.requests.count, 2, "A lost callback may be retried once")
        for _ in 0..<100 {
            driver.now += 10
            switcher.left(tab, alive: alive)
        }
        XCTAssertEqual(driver.requests.count, 2, "Expiry cannot release an uncompleted native capture slot")
        XCTAssertEqual(driver.pending(for: tab.id), 2)

        driver.reply(0, image: image())
        XCTAssertNil(switcher.preview(for: tab.id, address: tab.address), "A timed-out reply cannot publish over its retry")
        switcher.left(tab, alive: alive)
        XCTAssertEqual(driver.requests.count, 3, "Only the completed capture's own slot is available again")
        driver.reply(1, image: image())
        switcher.left(tab, alive: alive)
        XCTAssertEqual(driver.requests.count, 3, "A stale completion must not clear the newest request")
        let current = image()
        driver.reply(2, image: current)
        XCTAssertTrue(switcher.preview(for: tab.id, address: tab.address) === current)
    }

    func testSameAddressFreshViewDoesNotReusePendingOrCachedImage() {
        let driver = PreviewDriver(), switcher = makeSwitcher(driver)
        let tab = tab("same-address"), alive: Set<Tab.ID> = [tab.id]
        switcher.left(tab, alive: alive)
        _ = tab.web
        switcher.left(tab, alive: alive)
        XCTAssertEqual(driver.requests.count, 2, "A fresh view invalidates a request made for the previous view state")
        driver.reply(0, image: image())
        XCTAssertNil(switcher.preview(for: tab.id, address: tab.address))
        driver.reply(1, image: image())
        XCTAssertNotNil(switcher.preview(for: tab.id, address: tab.address))
        tab.rest()
        _ = tab.web
        switcher.left(tab, alive: alive)
        XCTAssertEqual(driver.requests.count, 3, "Fresh-view refresh must bypass the old view's cache and attempt throttle")
        XCTAssertNil(switcher.preview(for: tab.id, address: tab.address))
        let current = image()
        driver.reply(2, image: current)
        XCTAssertTrue(switcher.preview(for: tab.id, address: tab.address) === current)
        tab.close()
    }

    func testFailedCapturesAreRateLimitedAndCanBeRetried() {
        let driver = PreviewDriver(), switcher = makeSwitcher(driver)
        let tab = tab("failed"), alive: Set<Tab.ID> = [tab.id]
        switcher.left(tab, alive: alive)
        driver.reply(0, image: nil)
        for _ in 0..<100 { switcher.left(tab, alive: alive) }
        XCTAssertEqual(driver.requests.count, 1, "A nil snapshot must not become a hot retry loop")
        driver.now = 2.1
        switcher.left(tab, alive: alive)
        XCTAssertEqual(driver.requests.count, 2)
        let recovered = image()
        driver.reply(1, image: recovered)
        XCTAssertTrue(switcher.preview(for: tab.id, address: tab.address) === recovered)
    }

    func testGlobalCaptureBudgetSurvivesCachePruningAndReset() {
        let driver = PreviewDriver(), switcher = makeSwitcher(driver)
        let tabs = (0..<20).map { tab("budget\($0)") }
        let alive = Set(tabs.map(\.id))
        for tab in tabs { switcher.left(tab, alive: alive) }
        XCTAssertLessThanOrEqual(driver.requests.count, 8)
        let initial = driver.requests.count
        for index in 0..<100 {
            switcher.reset()
            driver.now += 10
            switcher.left(tabs[index % tabs.count], alive: alive)
        }
        XCTAssertEqual(driver.requests.count, initial,
                       "Pruning or disabling the switcher must not pretend unfinished native work ended")
    }

    func testCreatingNewTabsAndResettingCannotReleaseUnfinishedGlobalSlots() {
        let driver = PreviewDriver(), switcher = makeSwitcher(driver)
        for index in 0..<100 {
            autoreleasepool {
                let closing = tab("new\(index)")
                switcher.left(closing, alive: [closing.id])
                switcher.reset()
                closing.close()
            }
            driver.now += 10
        }
        XCTAssertLessThanOrEqual(driver.requests.count, 8,
                                 "New identities and logical resets cannot uncouple the physical capture budget")
        let count = driver.requests.count
        driver.reply(0, image: nil)
        let next = tab("after-completion")
        switcher.left(next, alive: [next.id])
        XCTAssertEqual(driver.requests.count, count + 1, "A completion frees exactly one physical slot")
    }

    func testInactivePruneAndResetDiscardLateRepliesWithoutRetainingClosedTabs() {
        let driver = PreviewDriver(), switcher = makeSwitcher(driver)
        let first = tab("pruned"), second = tab("kept")
        switcher.left(first, alive: [first.id, second.id])
        switcher.left(second, alive: [second.id])
        driver.reply(0, image: image())
        XCTAssertNil(switcher.preview(for: first.id, address: first.address))
        driver.reply(1, image: image())
        XCTAssertNotNil(switcher.preview(for: second.id, address: second.address))

        weak var released: Tab?
        var releasedID: Tab.ID?
        autoreleasepool {
            let closing = tab("closed")
            released = closing
            releasedID = closing.id
            switcher.left(closing, alive: [closing.id])
            switcher.reset()
            closing.close()
        }
        XCTAssertNil(released, "Outstanding preview bookkeeping must not retain a closed tab")
        driver.reply(2, image: image())
        XCTAssertNil(switcher.preview(for: releasedID!, address: URL(string: "https://preview.invalid/closed")))
    }

    func testCancelledGestureRepliesCannotPopulateTheNextGesture() async throws {
        let driver = PreviewDriver(), switcher = makeSwitcher(driver)
        let tabs = [tab("gestureA"), tab("gestureB")]
        let row = tabs.map(\.id)
        func begin() {
            switcher.step(row: row, current: row[0], backwards: false)
            switcher.step(row: row, current: row[0], backwards: false)
            switcher.capturePreviews(of: { id in tabs.first { $0.id == id } }, current: row[0])
        }
        begin()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(driver.requests.count, 2)
        switcher.cancel()
        begin()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(driver.requests.count, 4)
        driver.reply(0, image: image())
        driver.reply(1, image: image())
        for tab in tabs { XCTAssertNil(switcher.preview(for: tab.id, address: tab.address)) }
        driver.reply(2, image: image())
        driver.reply(3, image: image())
        for tab in tabs { XCTAssertNotNil(switcher.preview(for: tab.id, address: tab.address)) }
        switcher.reset()
    }

    private func makeSwitcher(_ driver: PreviewDriver) -> TabSwitcher {
        TabSwitcher(previewProvider: { tab, width, done in driver.capture(tab, width: width, done: done) },
                    previewNow: { driver.now })
    }

    private func tab(_ name: String) -> Tab {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(configuration: configuration)
        tab.setAddressOptimistically(URL(string: "https://preview.invalid/\(name)")!)
        return tab
    }

    private func image() -> NSImage { NSImage(size: NSSize(width: 2, height: 2)) }
}

@MainActor
private final class PreviewDriver {
    struct Request {
        let tab: Tab.ID
        var done: ((NSImage?) -> Void)?
    }
    var now: TimeInterval = 0
    private(set) var requests: [Request] = []

    func capture(_ tab: Tab, width: CGFloat, done: @escaping (NSImage?) -> Void) {
        XCTAssertEqual(width, 180)
        requests.append(Request(tab: tab.id, done: done))
    }

    func pending(for id: Tab.ID) -> Int { requests.filter { $0.tab == id && $0.done != nil }.count }

    func reply(_ index: Int, image: NSImage?) {
        guard requests.indices.contains(index) else { return XCTFail("The expected capture was never scheduled") }
        let done = requests[index].done
        requests[index].done = nil
        done?(image)
    }
}
