@testable import InstantRecordNative
import XCTest

final class HybridNavigationTests: XCTestCase {
    private let server = URL(string: "https://app.test")!
    private func decide(_ url: String, mainFrame: Bool = true, method: String = "GET") -> HybridNavigation {
        HybridNavigation.decide(URL(string: url)!, server: server, mainFrame: mainFrame, method: method)
    }

    func testTheServersOwnPagesStay() {
        XCTAssertEqual(decide("https://app.test/a"), .stay)
        XCTAssertEqual(decide("https://APP.test:443/a", method: "POST"), .stay)
        XCTAssertEqual(decide("https://elsewhere.test/frame", mainFrame: false), .stay)
    }

    func testAnotherServerIsOpenedOutside() {
        for url in ["http://app.test/", "https://app.test:8443/", "https://app.test.evil.test/", "https://app.test@evil.test/", "mailto:a@b.c", "tel:1"] {
            XCTAssertEqual(decide(url), .outside, url)
        }
        XCTAssertEqual(decide("https://evil.test/", method: "POST"), .refuse)
    }

    func testOtherSchemesAreRefused() {
        for url in ["javascript:alert(1)", "data:text/html,x", "file:///etc/hosts", "other-app://x"] { XCTAssertEqual(decide(url), .refuse, url) }
    }

    func testBackPassesOverForms() {
        XCTAssertEqual(HybridNavigation.back(over: [false, false, true]), 1)
        XCTAssertNil(HybridNavigation.back(over: [true]))
        XCTAssertNil(HybridNavigation.back(over: []))
    }

    func testTheTabBarShowsWhereItIsAskedForAndOnARubyScreen() {
        XCTAssertTrue(tabBarShows(tabs: 2, screen: true, signals: nil))
        XCTAssertFalse(tabBarShows(tabs: 2, screen: false, signals: nil))
        XCTAssertFalse(tabBarShows(tabs: 1, screen: true, signals: nil))
    }
}
