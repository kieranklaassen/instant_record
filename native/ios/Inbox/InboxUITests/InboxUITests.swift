import XCTest

/// The Inbox's flows, tapped through in the simulator. Run them with
/// native/ios/ui-test.sh, which seeds the server they expect
/// (demo/db/seeds/native_ui.rb) and does what a test cannot do from inside
/// the simulator: stop the server, start it, delete a message behind the
/// app's back. A test asks for that by writing a line to the SIGNAL file and
/// waiting for the file to go.
///
/// Every test starts the app on an empty local database and uses messages of
/// its own, and none asserts a count another test could have changed, so the
/// order they run in does not matter.
final class InboxUITests: XCTestCase {
    private let app = XCUIApplication()
    private let environment = ProcessInfo.processInfo.environment
    private var server: String { environment["SERVER"] ?? "http://localhost:3000" }

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        // A test that took the server down and then failed must not leave it down for the next.
        ask("server-up")
        ask("shot " + name.split(separator: " ").last!.dropLast())
    }

    private func launch(_ extra: [String] = []) {
        app.launchArguments = ["-server", server, "-token", environment["TOKEN"] ?? "", "-reset", "YES"] + extra
        app.launch()
        // The summary is drawn before the first sync. It names mail once the mailbox has filled.
        eventually("the mailbox did not fill from the server", within: 20) { self.summary.exists && self.unread > 0 }
    }

    /// A row of a list, by the id of the record it shows.
    private func row(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private var summary: XCUIElement { app.descendants(matching: .any).matching(identifier: "summary").firstMatch }
    /// How many unread messages the summary at the head of the list counts.
    private var unread: Int { Int(summary.label.prefix { $0.isNumber }) ?? -1 }
    private var status: XCUIElement { app.descendants(matching: .any).matching(identifier: "sync-status").firstMatch }

    /// Have the script outside the simulator do something, and wait until it has.
    private func ask(_ request: String) {
        guard let signal = environment["SIGNAL"] else { return }
        FileManager.default.createFile(atPath: signal, contents: Data(request.utf8))
        let limit = Date().addingTimeInterval(60)
        while FileManager.default.fileExists(atPath: signal), Date() < limit { usleep(100_000) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: signal), "the script outside the simulator did not do: \(request)")
    }

    private func eventually(_ message: String, within seconds: TimeInterval = 15, _ holds: @escaping () -> Bool) {
        let limit = Date().addingTimeInterval(seconds)
        while !holds(), Date() < limit { usleep(200_000) }
        XCTAssertTrue(holds(), message)
    }

    private func archive(_ id: String) {
        row(id).swipeLeft()
        app.buttons["Archive"].firstMatch.tap()
    }

    /// A message arrives in Support from somewhere else.
    private func deliver() {
        var request = URLRequest(url: URL(string: server + "/email/sync/maya/support/incoming")!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + (environment["TOKEN"] ?? ""), forHTTPHeaderField: "Authorization")
        let done = expectation(description: "delivered")
        var code = 0
        URLSession.shared.dataTask(with: request) { _, response, _ in
            code = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        XCTAssertEqual(201, code, "the server did not take the message")
    }

    func testTheMailboxShowsItsMailUnderItsBarButtons() {
        launch()

        XCTAssertTrue(app.navigationBars["Support"].exists)
        XCTAssertTrue(app.buttons["Inboxes"].exists)
        XCTAssertTrue(app.buttons["View"].exists)
        XCTAssertTrue(summary.label.contains("unread in Support"), summary.label)
        XCTAssertTrue(summary.label.contains("50 on this phone"), summary.label)
        XCTAssertTrue(summary.label.contains("more on the server"), summary.label)
    }

    func testOpenAConversationInItsSwiftViewAndComeBackToItRead() {
        launch()
        let before = unread

        // A message no other test opens, so that it is unread whatever ran before.
        row("ui-54").tap()
        XCTAssertTrue(app.staticTexts["Could you look at number 54?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "body").firstMatch.exists)
        app.navigationBars.buttons.firstMatch.tap()

        eventually("the count of unread mail did not go down by one") { self.unread == before - 1 }
    }

    func testReplyToAConversation() {
        launch()
        row("ui-58").tap()
        let box = app.descendants(matching: .any).matching(identifier: "body").firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 5))

        box.tap()
        box.typeText("On it, thanks")
        app.buttons["Send"].tap()

        XCTAssertTrue(app.staticTexts["On it, thanks"].waitForExistence(timeout: 5))
        eventually("the reply box was not emptied") { (box.value as? String) != "On it, thanks" }
    }

    func testArchiveWithASwipe() {
        launch()

        archive("ui-59")

        eventually("the row is still there") { !self.row("ui-59").exists }
        XCTAssertTrue(row("ui-60").exists)
    }

    func testTheLeadingMenuSwitchesInbox() {
        launch()

        app.buttons["Inboxes"].tap()
        XCTAssertTrue(app.buttons["Support"].waitForExistence(timeout: 5))
        app.buttons["Billing"].tap()

        XCTAssertTrue(app.navigationBars["Billing"].waitForExistence(timeout: 5))
        XCTAssertTrue(row("ui-b1").waitForExistence(timeout: 10))
        XCTAssertFalse(row("ui-60").exists)
    }

    func testTheTrailingMenuShowsUnreadOnly() {
        launch()
        row("ui-60").tap()
        XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["View"].tap()
        XCTAssertTrue(app.buttons["All"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Mark ' AND label ENDSWITH ' read'")).firstMatch.exists)
        app.buttons["Unread"].tap()
        // A sync that lands while the menu is open redraws the bar and can
        // swallow the tap. Choose again if the menu is still up.
        if app.buttons["Unread"].waitForExistence(timeout: 2), app.buttons["Unread"].isHittable { app.buttons["Unread"].tap() }

        eventually("a read message is listed as unread") { !self.row("ui-60").exists && self.row("ui-55").exists }
        XCTAssertTrue(summary.label.contains("Showing unread only"), summary.label)
    }

    func testTheViewMenuOpensTheFeedbackFormAndCancelComesBack() {
        // A relay nothing listens at: no note can leave the simulator.
        launch(["-relay", "http://localhost:9"])

        app.buttons["View"].tap()
        XCTAssertTrue(app.buttons["Send feedback"].waitForExistence(timeout: 5))
        app.buttons["Send feedback"].tap()
        if app.buttons["Send feedback"].waitForExistence(timeout: 2), app.buttons["Send feedback"].isHittable { app.buttons["Send feedback"].tap() }

        XCTAssertTrue(app.staticTexts["Sent with your note"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Feedback"].firstMatch.exists)
        // Who is writing and from which inbox go with the note, and are shown.
        XCTAssertTrue(app.staticTexts["From"].exists)
        XCTAssertTrue(app.staticTexts["maya"].exists)
        XCTAssertTrue(app.staticTexts["support"].exists)
        XCTAssertFalse(app.buttons["Send"].isEnabled, "an empty note can be sent")

        app.buttons["Cancel"].tap()

        XCTAssertTrue(app.navigationBars["Support"].waitForExistence(timeout: 5))
        XCTAssertTrue(row("ui-60").exists)
    }

    func testOpenedAgainWithNothingGivenItStillKnowsItsServerAndItsToken() {
        launch()
        let before = unread

        // As from the home screen: no arguments at all.
        app.terminate()
        app.launchArguments = []
        app.launch()
        eventually("the mailbox was not there when opened again") { self.summary.exists && self.unread == before }
        deliver()

        // Only the server it was first given, asked with the token it was
        // first given, can bring the new message.
        eventually("the new message did not arrive", within: 20) { self.unread == before + 1 }
        XCTAssertFalse(status.exists, status.label)
    }

    func testOlderMailLoadsAsTheListIsScrolled() {
        launch()
        XCTAssertTrue(summary.label.contains("more on the server"), summary.label)

        for _ in 0..<30 where !row("ui-01").exists { app.swipeUp(velocity: .fast) }

        XCTAssertTrue(row("ui-01").waitForExistence(timeout: 5), "the oldest message did not load")
        for _ in 0..<30 where !summary.exists { app.swipeDown(velocity: .fast) }
        eventually("it still says the server has more") { !self.summary.label.contains("more on the server") }
    }

    func testAMessageFromElsewhereArrivesWithoutATouch() {
        launch()
        let before = unread

        deliver()

        eventually("the new message did not arrive", within: 20) { self.unread == before + 1 }
    }

    func testAPullRefreshesWhenNothingElseWould() {
        launch(["-follow", "NO"])
        sleep(2)
        let before = unread
        deliver()
        sleep(3)
        XCTAssertEqual(before, unread, "it synced with nothing following the server and no touch")

        let top = row("ui-60").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        top.press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 500)))

        eventually("the pull did not bring the new message") { self.unread == before + 1 }
    }

    func testAnArchiveTheServerRefusesComesBack() {
        launch()
        ask("server-down")
        archive("ui-57")
        eventually("the row is still there") { !self.row("ui-57").exists }
        eventually("it does not say it is offline", within: 20) { self.status.exists && self.status.label.contains("Offline") }

        // While the phone cannot reach it, the server loses the message.
        ask("delete ui-57")
        ask("server-up")

        eventually("the refused archive was not undone", within: 40) { self.row("ui-57").exists }
        eventually("something is still waiting", within: 20) { !self.status.exists }
    }

    func testAnArchiveMadeOfflineGoesOutWhenTheServerReturns() {
        launch()
        ask("server-down")

        archive("ui-56")

        eventually("the row is still there") { !self.row("ui-56").exists }
        eventually("it does not say it is offline", within: 20) { self.status.exists && self.status.label.contains("Offline") }

        ask("server-up")

        eventually("the change did not go out by itself", within: 40) { !self.status.exists }
        XCTAssertFalse(row("ui-56").exists)
    }

    func testTheMainControlsCanBeReachedHoweverTheyAreShown() {
        launch()

        XCTAssertTrue(app.buttons["Inboxes"].isHittable)
        XCTAssertTrue(app.buttons["View"].isHittable)
        // At the largest text size the first message may start below the screen.
        for _ in 0..<6 where !row("ui-60").isHittable { app.swipeUp() }
        XCTAssertTrue(row("ui-60").isHittable)
        row("ui-60").tap()
        let box = app.descendants(matching: .any).matching(identifier: "body").firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 5))
        XCTAssertTrue(box.isHittable)
        XCTAssertTrue(app.buttons["Send"].isHittable)
    }
}
