import XCTest

/// The Inbox's flows, tapped through in the simulator against a running demo
/// server. With HOLD naming a file, a test writes that file once it has
/// reached its screen and waits until the file is gone, so a screenshot can be
/// taken from outside (xcrun simctl io booted screenshot).
///
///   TEST_RUNNER_SERVER=http://localhost:3000 xcodebuild test -project Inbox.xcodeproj -scheme Inbox \
///     -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:InboxUITests/InboxUITests/testOpenAConversation
final class InboxUITests: XCTestCase {
    private let app = XCUIApplication()
    // The list's first cell is the summary, and each cell after it is a row.
    private var first: XCUIElement { app.cells.element(boundBy: 1) }
    private var firstWords: String { first.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ") }

    override func setUp() {
        continueAfterFailure = false
        app.launchArguments = ["-server", ProcessInfo.processInfo.environment["SERVER"] ?? "http://localhost:3000"]
        app.launch()
        XCTAssertTrue(first.waitForExistence(timeout: 15), "the mailbox has no rows: has the app synced once?")
    }

    override func tearDown() {
        guard let hold = ProcessInfo.processInfo.environment["HOLD"] else { return }
        FileManager.default.createFile(atPath: hold, contents: nil)
        let limit = Date().addingTimeInterval(30)
        while FileManager.default.fileExists(atPath: hold) && Date() < limit { usleep(200_000) }
    }

    func testTheMailboxShowsItsMailUnderItsBarButtons() {
        XCTAssertTrue(app.navigationBars["Support"].exists)
        XCTAssertTrue(app.buttons["Inboxes"].exists)
        XCTAssertTrue(app.buttons["View"].exists)
        XCTAssertTrue(app.staticTexts["unread in Support"].exists, "the Swift view at the head of the list is missing")
    }

    func testOpenAConversationInItsSwiftView() {
        first.tap()

        XCTAssertTrue(app.buttons["Archive"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Support"].exists)
    }

    func testArchiveWithASwipe() {
        let archived = firstWords
        first.swipeLeft()
        app.buttons["Archive"].tap()

        let gone = NSPredicate { _, _ in self.firstWords != archived }
        wait(for: [expectation(for: gone, evaluatedWith: nil)], timeout: 5)
    }

    func testTheLeadingMenuListsTheInboxes() {
        app.buttons["Inboxes"].tap()

        XCTAssertTrue(app.buttons["Billing"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Support"].exists)
    }

    func testChoosingAnInboxPutsItInThisOnesPlace() {
        app.buttons["Inboxes"].tap()
        app.buttons["Billing"].tap()

        XCTAssertTrue(app.navigationBars["Billing"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["unread in Billing"].waitForExistence(timeout: 10))
    }

    func testTheTrailingMenuOffersAllOrUnread() {
        app.buttons["View"].tap()

        XCTAssertTrue(app.buttons["Unread"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["All"].exists)
        XCTAssertTrue(app.buttons["Mark all read"].exists)
    }

    func testUnreadOnly() {
        app.buttons["View"].tap()
        app.buttons["Unread"].tap()

        XCTAssertTrue(app.staticTexts["Showing unread only"].waitForExistence(timeout: 5))
    }

    func testMarkAllReadEmptiesTheUnreadList() {
        app.buttons["View"].tap()
        app.buttons["Mark all read"].tap()
        app.buttons["View"].tap()
        app.buttons["Unread"].tap()

        XCTAssertTrue(app.staticTexts["Showing unread only"].waitForExistence(timeout: 5))
        XCTAssertFalse(first.waitForExistence(timeout: 2))
    }
}
