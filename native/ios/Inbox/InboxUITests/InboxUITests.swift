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
    private var first: XCUIElement { app.cells.element(boundBy: 0) }
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

    func testTheMailboxShowsItsMail() {
        XCTAssertTrue(app.navigationBars["Support"].exists)
    }

    func testOpenAConversation() {
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
}
