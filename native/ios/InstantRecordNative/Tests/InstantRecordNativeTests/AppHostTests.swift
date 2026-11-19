import XCTest
@testable import InstantRecordNative

final class AppHostTests: XCTestCase {
    private let mailbox = Route("mailbox", ["member": "maya", "inbox": "support"])
    private let thread = Route("thread", ["member": "maya", "inbox": "support", "id": "m2"])
    private let billing = Route("mailbox", ["member": "maya", "inbox": "billing"])
    private var engine = FakeEngine()
    private let clock = ManualClock()
    private let network = ManualReachability()
    private let renderMailbox = "render mailbox inbox=support,member=maya"
    private let syncSupport = "sync http://example.test/maya-support"

    private func host(answer: @escaping (String) -> String = { _ in "200\n" }) -> AppHost {
        let host = AppHost(engine: engine, root: mailbox, store: { route in
            let place = (route.params["member"] ?? "") + "-" + (route.params["inbox"] ?? "")
            return AppHost.Store(database: "/tmp/\(place).sqlite3", endpoint: "http://example.test/" + place)
        }, exchange: answer, clock: clock, reachability: network)
        host.start()
        pass(host)
        return host
    }

    /// Let the planned sync pass run, and its results land.
    private func pass(_ host: AppHost) {
        host.settle()
        clock.fire()
        host.settle()
    }

    func testItDrawsFromTheDatabaseBeforeItSyncs() {
        let host = host()

        XCTAssertEqual(["boot /tmp/maya-support.sqlite3", renderMailbox, syncSupport], engine.calls)
        XCTAssertEqual(["m2", "m1"], host.screens[mailbox]?.children.map(\.id))
        XCTAssertTrue(host.online)
        XCTAssertEqual(0, host.pending)
    }

    func testATapIsPerformedWithItsValuesThenDrawnThenSynced() {
        let host = host()
        engine.calls = []

        host.perform("archive", with: ["id": "m2"], on: mailbox)
        pass(host)

        XCTAssertEqual(["action mailbox inbox=support,member=maya archive id=m2", renderMailbox, syncSupport], engine.calls)
        XCTAssertEqual(["m1"], host.screens[mailbox]?.children.map(\.id))
    }

    func testAValueWithANewlineASlashAndAQuoteReachesTheAppAsItIs() {
        let odd = "a/b\n\"c\""
        let input = Route("thread", ["id": odd]).input(action: "reply", with: ["body": odd])
        let object = try? JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any]

        XCTAssertEqual(odd, (object?["params"] as? [String: String])?["id"])
        XCTAssertEqual(odd, (object?["with"] as? [String: String])?["body"])
        XCTAssertEqual(["reply", "thread"], [object?["action"] as? String, object?["screen"] as? String])
    }

    func testTwoRoutesWithTheSameParamsAreTheSameRoute() {
        XCTAssertEqual(Route("mailbox", ["inbox": "support", "member": "maya"]), mailbox)
        XCTAssertNotEqual(Route("mailbox", ["inbox": "support", "member": "maya", "show": "unread"]), mailbox)
        XCTAssertEqual(mailbox.input(), Route("mailbox", ["inbox": "support", "member": "maya"]).input())
    }

    func testSeveralTapsCloseTogetherSyncOnce() {
        let host = host()
        engine.calls = []

        host.perform("archive", with: ["id": "m2"], on: mailbox)
        host.perform("archive", with: ["id": "m1"], on: mailbox)
        host.sync()
        pass(host)

        XCTAssertEqual(1, engine.calls.filter { $0 == syncSupport }.count)
        XCTAssertEqual(2, engine.calls.filter { $0.hasPrefix("action") }.count)
    }

    func testAChangeNoticeDrawsTheScreensOnShowOnceMore() {
        let host = host()
        host.path = [thread]
        host.settle()
        engine.calls = []
        engine.noticeAfterSync = "records_changed\nMailEntry:m3"
        engine.rows = ["m3", "m2", "m1"]

        host.sync()
        pass(host)

        XCTAssertEqual([syncSupport, renderMailbox, "render thread id=m2,inbox=support,member=maya"], engine.calls)
        XCTAssertEqual(["m3", "m2", "m1"], host.screens[mailbox]?.children.map(\.id))
    }

    func testASyncThatChangedNothingDrawsNothing() {
        let host = host()
        engine.calls = []

        host.sync()
        pass(host)

        XCTAssertEqual([syncSupport], engine.calls)
    }

    func testAPushedScreenIsToldItOpenedBeforeItIsDrawn() {
        let host = host()
        engine.calls = []

        host.path.append(thread)
        host.settle()

        XCTAssertEqual(["action thread id=m2,inbox=support,member=maya open", renderMailbox, "render thread id=m2,inbox=support,member=maya"], engine.calls)
        XCTAssertEqual("thread", host.screens[thread]?.text)
    }

    func testGoingBackTellsNobodyAndDropsTheScreen() {
        let host = host()
        host.path = [thread]
        host.settle()
        engine.calls = []

        host.path = []
        host.settle()

        XCTAssertEqual([renderMailbox], engine.calls)
        XCTAssertNil(host.screens[thread])
    }

    func testAnotherFirstScreenOpensItsOwnDatabaseAndSyncsWithItsOwnAddress() {
        let host = host()
        host.path = [thread]
        host.settle()
        engine.calls = []

        host.replace(with: billing)
        pass(host)

        XCTAssertEqual([syncSupport, "open /tmp/maya-billing.sqlite3", "render mailbox inbox=billing,member=maya", "sync http://example.test/maya-billing"], engine.calls,
                       "the inbox being left is synced while its database is still open")
        XCTAssertEqual(billing, host.root)
        XCTAssertEqual([], host.path)
        XCTAssertEqual([billing], Array(host.screens.keys))
        XCTAssertEqual(["b1"], host.screens[billing]?.children.map(\.id))
    }

    func testAnotherViewOfTheSameDataDoesNotOpenItAgain() {
        let host = host()
        engine.calls = []

        host.replace(with: Route("mailbox", ["member": "maya", "inbox": "support", "show": "unread"]))
        pass(host)

        XCTAssertEqual(["render mailbox inbox=support,member=maya,show=unread", syncSupport], engine.calls)
    }

    func testADatabaseThatWillNotOpenIsReportedAndTheOldOneKeepsSyncing() {
        let host = host()
        engine.calls = []

        host.replace(with: Route("mailbox", ["member": "maya", "inbox": "locked"]))
        pass(host)

        XCTAssertEqual("ArgumentError: No screen named nowhere", host.failure)
        XCTAssertEqual(syncSupport, engine.calls.last)
    }

    func testAnAppThatDidNotComeUpStillSyncsOnceADatabaseOpens() {
        engine.boots = false
        let host = host()
        XCTAssertFalse(engine.calls.contains { $0.hasPrefix("sync") })
        engine.calls = []

        host.replace(with: billing)
        pass(host)

        XCTAssertEqual("sync http://example.test/maya-billing", engine.calls.last, "the schedule is still waiting for a pass that never ran")
    }

    func testAPullSyncsAndDrawsEvenWhenNothingChanged() async {
        let host = host()
        engine.calls = []

        await host.refresh()

        XCTAssertEqual([syncSupport, renderMailbox], engine.calls)
    }

    func testOfflineWithAWriteWaitingIsSaidAndTriedAgainUntilItGoes() {
        var reachable = false
        let host = host(answer: { _ in reachable ? "200\n" : Transport.offline })
        engine.pending = 1

        host.perform("archive", with: ["id": "m2"], on: mailbox)
        pass(host)

        XCTAssertFalse(host.online)
        XCTAssertEqual(1, host.pending)
        XCTAssertTrue(clock.waiting, "nothing is planned to try again")
        XCTAssertEqual([0.3, 2, 0.3, 4], clock.planned, "the launch pass failed too, so the second wait is longer")

        reachable = true
        engine.pending = 0
        pass(host)

        XCTAssertTrue(host.online)
        XCTAssertEqual(0, host.pending)
    }

    func testAServerThatAnswersAndRefusesIsShownAndAskedLessOften() {
        var status = "401"
        let host = host(answer: { _ in status + "\nno" })
        engine.pending = 1

        host.perform("archive", with: ["id": "m2"], on: mailbox)
        pass(host)

        XCTAssertTrue(host.online, "a server that answers is not offline")
        XCTAssertEqual("The server answered 401 to GET http://example.test/maya-support/events", host.failure)
        XCTAssertEqual([0.3, 2, 0.3, 4], clock.planned)

        status = "200"
        engine.pending = 0
        host.dismissFailure()
        pass(host)

        XCTAssertEqual("", host.failure)
        XCTAssertFalse(clock.waiting)
    }

    func testTheNetworkComingBackSyncsWithoutATouch() {
        var reachable = false
        let host = host(answer: { _ in reachable ? "200\n" : Transport.offline })
        engine.calls = []
        reachable = true

        network.comeBack()
        pass(host)

        XCTAssertEqual([syncSupport], engine.calls)
        XCTAssertTrue(host.online)
        XCTAssertEqual(0, clock.planned.last)
    }

    func testInFrontTheAppKeepsSyncingOnATimer() {
        let host = host()
        engine.calls = []

        host.front(true)
        pass(host)
        pass(host)
        host.front(false)

        XCTAssertEqual([syncSupport, syncSupport], engine.calls)
        XCTAssertFalse(clock.waiting)
    }

    func testWhatTheAppRaisesIsKeptUntilDismissedAndTheScreenStays() {
        let host = host()
        engine.raises = true

        host.perform("archive", with: ["id": "m2"], on: mailbox)
        host.settle()
        engine.raises = false
        host.perform("archive", with: ["id": "missing"], on: mailbox)
        host.settle()

        XCTAssertEqual("ArgumentError: No screen named nowhere", host.failure)
        XCTAssertEqual(["m2", "m1"], host.screens[mailbox]?.children.map(\.id))

        host.dismissFailure()

        XCTAssertEqual("", host.failure)
    }

    func testTheStatusLineSaysWhatIsWaitingAndWhy() {
        XCTAssertEqual("Offline", Wording.status(online: false, pending: 0))
        XCTAssertEqual("Offline · 1 change waiting", Wording.status(online: false, pending: 1))
        XCTAssertEqual("3 changes waiting to sync", Wording.status(online: true, pending: 3))
    }
}
