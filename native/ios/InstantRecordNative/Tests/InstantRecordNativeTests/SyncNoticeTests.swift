import XCTest
@testable import InstantRecordNative

final class SyncNoticeTests: XCTestCase {
    private let mailbox = Route("mailbox", ["member": "maya", "inbox": "support"])
    private let billing = Route("mailbox", ["member": "maya", "inbox": "billing"])
    private let support = "http://example.test/maya-support"
    private let sampleNoticeJSON = """
    {"id":"n-1","mutation_id":"m-1","kind":"conflict","record_type":"MailEntry","record_id":"e-1","operation":"update","reason":"Overwritten by a newer server change","attempted_changes":{"id":"e-1","subject":"My draft","server_version":2},"server_attributes":{"id":"e-1","subject":"Teammate edit","server_version":3},"server_version":3,"created_at":"2026-11-21T12:00:00.000000Z"}
    """

    func testNoticeSignalParsesRecordsChangedAndSyncNoticeLines() {
        XCTAssertEqual(NoticeSignal.Parsed(recordsChanged: false, syncNotices: []), NoticeSignal.parse(""))
        XCTAssertEqual(NoticeSignal.Parsed(recordsChanged: true, syncNotices: []), NoticeSignal.parse("records_changed\nMailEntry:e-1"))

        let parsed = NoticeSignal.parse("records_changed\nMailEntry:e-1\nsync_notice:\(sampleNoticeJSON)\nsync_notice:not-json")
        XCTAssertTrue(parsed.recordsChanged)
        XCTAssertEqual(1, parsed.syncNotices.count)
        let notice = parsed.syncNotices[0]
        XCTAssertEqual("n-1", notice.id)
        XCTAssertTrue(notice.isConflict)
        XCTAssertEqual("MailEntry", notice.recordType)
        XCTAssertEqual("Overwritten by a newer server change", notice.reason)
        XCTAssertEqual(3, notice.serverVersion)
        XCTAssertEqual([SyncNotice.FieldDiff(field: "subject", localValue: "My draft", serverValue: "Teammate edit")], notice.fieldDiffs)
    }

    func testAppHostSurfacesSyncNoticesFromSyncAndStream() async {
        let engine = FakeEngine()
        let clock = ManualClock()
        let network = ManualReachability()
        let host = AppHost(engine: engine, root: mailbox, store: { _ in
            AppHost.Store(database: "/tmp/maya-support.sqlite3", endpoint: self.support)
        }, exchange: { _ in "200\n" }, clock: clock, reachability: network)

        engine.noticeAfter["sync"] = "records_changed\nsync_notice:\(sampleNoticeJSON)"
        host.start()
        host.settle()
        clock.fire()
        host.settle()

        XCTAssertEqual(1, host.notices.count)
        XCTAssertEqual("n-1", host.notices.first?.id)

        let rejectedJSON = """
        {"id":"n-2","mutation_id":"m-2","kind":"rejected","record_type":"Issue","record_id":"i-9","operation":"create","reason":"Title is not allowed","attempted_changes":{"title":"reject me"},"server_attributes":{},"server_version":0}
        """
        engine.noticeAfter["stream"] = "records_changed\nsync_notice:\(rejectedJSON)"
        await host.feed("id: 9\ndata: {}\n\n", from: AppHost.Store(database: "/tmp/maya-support.sqlite3", endpoint: support))
        host.settle()

        XCTAssertEqual(["n-2", "n-1"], host.notices.map(\.id))
    }

    func testAppHostHydratesPersistedNoticesOnBootAndClearsOnDatabaseSwitch() {
        let engine = FakeEngine()
        let clock = ManualClock()
        let network = ManualReachability()
        engine.noticesCount = 1
        engine.noticesResponses["list"] = "{\"ok\":true,\"notices\":[\(sampleNoticeJSON)]}"

        let host = AppHost(engine: engine, root: mailbox, store: { route in
            let inbox = route.params["inbox"] ?? "support"
            return AppHost.Store(database: "/tmp/maya-\(inbox).sqlite3", endpoint: "http://example.test/maya-\(inbox)")
        }, exchange: { _ in "200\n" }, clock: clock, reachability: network)

        host.start()
        host.settle()

        XCTAssertEqual(["n-1"], host.notices.map(\.id))
        XCTAssertTrue(engine.calls.contains("notices list"))

        engine.noticesCount = 0
        host.replace(with: billing)
        host.settle()

        XCTAssertTrue(host.notices.isEmpty)
    }

    func testRetryForkAndDismissResolveNoticesAndScheduleSyncWhenWriting() {
        let engine = FakeEngine()
        let clock = ManualClock()
        let network = ManualReachability()
        engine.noticesCount = 1
        engine.noticesResponses["list"] = "{\"ok\":true,\"notices\":[\(sampleNoticeJSON)]}"
        engine.noticesResponses["retry"] = "{\"ok\":true,\"record_id\":\"e-1\",\"notices\":[]}"
        engine.noticesResponses["fork"] = "{\"ok\":true,\"record_id\":\"e-fork\",\"notices\":[]}"
        engine.noticesResponses["dismiss"] = "{\"ok\":true,\"notices\":[]}"

        let host = AppHost(engine: engine, root: mailbox, store: { _ in
            AppHost.Store(database: "/tmp/maya-support.sqlite3", endpoint: self.support)
        }, exchange: { _ in "200\n" }, clock: clock, reachability: network)

        host.start()
        host.settle()
        clock.fire()
        host.settle()
        engine.calls = []

        host.retryNotice("n-1")
        host.settle()
        XCTAssertTrue(host.notices.isEmpty)
        XCTAssertTrue(engine.calls.contains("notices retry n-1"))
        XCTAssertTrue(clock.waiting, "retry must schedule a sync pass")
        clock.fire()
        host.settle()

        engine.calls = []
        host.forkNotice("n-1")
        host.settle()
        XCTAssertTrue(engine.calls.contains("notices fork n-1"))
        XCTAssertTrue(clock.waiting, "fork must schedule a sync pass")
        clock.fire()
        host.settle()

        engine.calls = []
        host.dismissNotice("n-1")
        host.settle()
        XCTAssertTrue(engine.calls.contains("notices dismiss n-1"))
        XCTAssertFalse(clock.waiting, "dismiss does not need to schedule a sync pass")
    }
}
