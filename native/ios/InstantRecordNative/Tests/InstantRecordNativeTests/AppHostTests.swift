import XCTest
@testable import InstantRecordNative

/// Stands where the compiled app would be and keeps what it was asked.
final class FakeEngine: Engine {
    var calls: [String] = []
    var rows = ["m2", "m1"]
    var noticeAfterSync = ""
    var raises = false
    private var last = ""
    private var answer: (String) -> String = { _ in Transport.offline }
    var answered: [String] = []

    func boot(database: String) -> Bool {
        calls.append("boot " + database)
        return true
    }

    func call(_ entry: String, _ input: String) -> String? {
        calls.append(entry + " " + input.replacingOccurrences(of: "\n", with: "|"))
        last = entry
        if raises { return nil }
        switch entry {
        case "render": return screen(input)
        case "action": rows.removeAll { input.hasSuffix($0) }
        case "sync": answered.append(answer("GET " + input + "/events"))
        default: break
        }
        return ""
    }

    func notice() -> String { last == "sync" ? noticeAfterSync : "" }
    func error() -> String { "ArgumentError: No screen named nowhere" }
    func onExchange(_ answer: @escaping (String) -> String) { self.answer = answer }

    private func screen(_ input: String) -> String {
        let items = rows.map { "{\"kind\":\"row\",\"id\":\"\($0)\",\"text\":\"\",\"action\":\"\",\"arg\":\"\",\"props\":{},\"children\":[]}" }
        return "{\"kind\":\"screen\",\"id\":\"\",\"text\":\"\(input.split(separator: "\n")[0])\",\"action\":\"\",\"arg\":\"\",\"props\":{},\"children\":[\(items.joined(separator: ","))]}"
    }
}

final class AppHostTests: XCTestCase {
    private let mailbox = Route("mailbox", "maya/support")
    private let thread = Route("thread", "maya/support/m2")
    private var engine = FakeEngine()

    private func host(answer: @escaping (String) -> String = { _ in "200\n" }) -> AppHost {
        let host = AppHost(engine: engine, root: mailbox, endpoint: "http://example.test/sync", exchange: answer)
        host.start(database: "/tmp/inbox.sqlite3")
        host.settle()
        return host
    }

    func testItDrawsFromTheDatabaseBeforeItSyncs() {
        let host = host()

        XCTAssertEqual(["boot /tmp/inbox.sqlite3", "render mailbox|maya/support", "sync http://example.test/sync"], engine.calls)
        XCTAssertEqual(["m2", "m1"], host.screens[mailbox]?.children.map(\.id))
    }

    func testATapIsPerformedThenDrawnThenSynced() {
        let host = host()
        engine.calls = []

        host.perform("archive", arg: "maya/support/m2", on: mailbox)
        host.settle()

        XCTAssertEqual(["action mailbox|maya/support|archive|maya/support/m2", "render mailbox|maya/support", "sync http://example.test/sync"], engine.calls)
        XCTAssertEqual(["m1"], host.screens[mailbox]?.children.map(\.id))
    }

    func testAChangeNoticeDrawsTheScreensOnShowOnceMore() {
        let host = host()
        host.path = [thread]
        host.settle()
        engine.calls = []
        engine.noticeAfterSync = "records_changed\nMailEntry:m3"
        engine.rows = ["m3", "m2", "m1"]

        host.sync()
        host.settle()

        XCTAssertEqual(["sync http://example.test/sync", "render mailbox|maya/support", "render thread|maya/support/m2"], engine.calls)
        XCTAssertEqual(["m3", "m2", "m1"], host.screens[mailbox]?.children.map(\.id))
    }

    func testASyncThatChangedNothingDrawsNothing() {
        let host = host()
        engine.calls = []

        host.sync()
        host.settle()

        XCTAssertEqual(["sync http://example.test/sync"], engine.calls)
    }

    func testARowsActionIsPerformedBeforeTheScreenItOpensIsDrawn() {
        let host = host()
        engine.calls = []

        host.open("thread", arg: "maya/support/m2", action: "read", from: mailbox)
        host.settle()

        XCTAssertEqual([thread], host.path)
        XCTAssertEqual("action mailbox|maya/support|read|maya/support/m2", engine.calls.first)
        XCTAssertLessThan(engine.calls.firstIndex(of: "action mailbox|maya/support|read|maya/support/m2")!,
                          engine.calls.firstIndex(of: "render thread|maya/support/m2")!)
        XCTAssertEqual("thread", host.screens[thread]?.text)
    }

    func testAScreenThatWasClosedIsNoLongerKeptOrDrawn() {
        let host = host()
        host.path = [thread]
        host.settle()
        host.path = []
        host.settle()
        engine.calls = []

        host.perform("archive", arg: "maya/support/m1", on: mailbox)
        host.settle()

        XCTAssertNil(host.screens[thread])
        XCTAssertFalse(engine.calls.contains("render thread|maya/support/m2"))
    }

    func testWhatTheAppRaisesIsKeptAndTheScreenStays() {
        let host = host()
        engine.raises = true

        host.perform("archive", arg: "maya/support/m2", on: mailbox)
        host.settle()

        XCTAssertEqual("ArgumentError: No screen named nowhere", host.failure)
        XCTAssertEqual(["m2", "m1"], host.screens[mailbox]?.children.map(\.id))
    }

    func testWithNoNetworkTheAppIsToldSoAndNotKeptWaiting() {
        // Nothing listens on port 9, so the connection is refused at once.
        let transport = Transport(timeout: 2)
        _ = host(answer: transport.exchange)

        XCTAssertEqual([Transport.offline], engine.answered)
        XCTAssertEqual(Transport.offline, transport.exchange("GET http://127.0.0.1:9/events"))
        XCTAssertEqual(Transport.offline, transport.exchange("nonsense"))
    }
}
