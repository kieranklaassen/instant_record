import SwiftUI
import XCTest
@testable import InstantRecordNative

final class NodeTests: XCTestCase {
    private static func node(_ kind: String, id: String = "", text: String = "", action: String = "", params: [String: String] = [:], props: [String: String] = [:], _ children: [String] = []) -> String {
        func strings(_ value: [String: String]) -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        }
        let quoted = [kind, id, text, action].map { String(decoding: (try? JSONSerialization.data(withJSONObject: [$0])) ?? Data(), as: UTF8.self).dropFirst().dropLast() }
        return "{\"kind\":\(quoted[0]),\"id\":\(quoted[1]),\"text\":\(quoted[2]),\"action\":\(quoted[3]),\"params\":\(strings(params)),\"props\":\(strings(props)),\"children\":[\(children.joined(separator: ","))]}"
    }

    /// Every kind the Ruby view layer writes, with an unknown one among them.
    static let screen = node("screen", [
        node("navigation", props: ["title": "Support"], [
            node("list", props: ["refresh": "true"], [
                node("swift", text: "Summary", [
                    node("number", id: "unread", text: "2"),
                    node("flag", id: "filtered", text: "true"),
                    node("flag", id: "more", text: "false"),
                    node("prop", id: "since", text: "2026-11-19T06:21:00.000000Z"),
                    node("props", id: "people", [
                        node("record", [node("prop", id: "name", text: "Rae"), node("props", id: "tags", [node("record", [node("prop", id: "name", text: "night")])])]),
                        node("record", [node("prop", id: "name", text: "Sam")]),
                    ]),
                ]),
                node("swift", text: "Nobody"),
                node("section", text: "Today", [
                    node("row", id: "m2", params: ["member": "maya", "inbox": "support", "id": "m2"], props: ["link": "thread"], [
                        node("stack", props: ["axis": "horizontal"], [
                            node("image", text: "unread", props: ["tone": "accent"]),
                            node("text", text: "Sam \"S\" Ortiz", props: ["style": "headline", "lines": "1"]),
                            node("spacer"),
                            node("date", text: "2026-11-19T06:21:00.000000Z", props: ["style": "caption", "tone": "secondary"]),
                        ]),
                        node("text", text: "Hello\ncafé", props: ["lines": "2"]),
                        node("hologram"),
                        node("swipe", text: "Archive", action: "archive", params: ["id": "m2"], props: ["role": "destructive", "image": "archive"]),
                    ]),
                    node("row", id: "m1"),
                ]),
            ]),
            node("toolbar", [
                node("button", text: "Archive", action: "archive", params: ["id": "m2"], props: ["image": "archive", "position": "trailing"]),
                node("button", text: "Inboxes", props: ["image": "person", "position": "leading"], [
                    node("item", text: "Support", params: ["member": "maya", "inbox": "support"], props: ["link": "mailbox", "selected": "true"]),
                    node("item", text: "Empty", action: "empty", props: ["role": "destructive", "image": "trash"]),
                ]),
            ]),
            node("bottom", [
                node("field", id: "body", text: "Draft", props: ["placeholder": "Reply"]),
                node("button", text: "Send", action: "reply", props: ["image": "send"]),
            ]),
        ]),
    ])

    private func host(_ views: Screens = Screens(), engine: FakeEngine = FakeEngine()) -> AppHost {
        AppHost(engine: engine, root: Route("mailbox", ["member": "maya"]), views: views, store: { _ in AppHost.Store(database: "", endpoint: "") },
                clock: ManualClock(), reachability: ManualReachability())
    }

    private func list() throws -> Node { try Node(json: NodeTests.screen).children[0].children[0] }

    func testATreeWithEveryKindDecodes() throws {
        let navigation = try Node(json: NodeTests.screen).children[0]
        let row = try list().children(of: "section")[0].children[0]
        let menu = navigation.children[1].children[1]

        XCTAssertEqual("Support", navigation.prop("title"))
        XCTAssertEqual(["list", "toolbar", "bottom"], navigation.children.map(\.kind))
        XCTAssertEqual("thread", row.prop("link"))
        XCTAssertEqual(["member": "maya", "inbox": "support", "id": "m2"], row.params)
        XCTAssertEqual("Sam \"S\" Ortiz", row.children[0].children[1].text)
        XCTAssertEqual("Hello\ncafé", row.children[1].text)
        XCTAssertEqual(["archive", "m2"], [row.children(of: "swipe")[0].action, row.children(of: "swipe")[0].params["id"]])
        XCTAssertEqual("", row.prop("nothing"))
        XCTAssertEqual("true", try list().prop("refresh"))
        XCTAssertEqual(["leading", "item", "true", "mailbox"], [menu.prop("position"), menu.children[0].kind, menu.children[0].prop("selected"), menu.children[0].prop("link")])
    }

    func testARowIsKeptByItsRecordAndAnythingElseByItsPlace() throws {
        let section = try list().children(of: "section")[0]

        XCTAssertEqual(["m2", "m1"], section.keyed.map(\.key))
        XCTAssertEqual(["#0", "#1", "#2", "#3"], section.children[0].keyed.map(\.key))
    }

    func testAnswerThatIsNotAScreenDoesNotDecode() {
        XCTAssertThrowsError(try Node(json: "{\"kind\":\"row\"}"))
    }

    @MainActor
    func testEveryKindDrawsAndAnUnknownOneDrawsNothing() throws {
        let host = host()
        let screen = try Node(json: NodeTests.screen)
        let unknownNode = try list().children(of: "section")[0].children[0].children[2]
        let drawn = ImageRenderer(content: NodeView(node: screen, route: host.root, host: host, typed: .constant([:]), first: true).frame(width: 390, height: 700))
        let unknown = ImageRenderer(content: NodeView(node: unknownNode, route: host.root, host: host, typed: .constant([:])))

        XCTAssertNotNil(drawn.cgImage)
        XCTAssertNil(unknown.cgImage, "an unknown kind has no size to draw")
    }

    func testASwiftViewReadsItsPropsByNameAndKind() throws {
        let props = Props(try list().children[0])

        XCTAssertEqual(2, props.int("unread"))
        XCTAssertEqual([true, false, false], [props.bool("filtered"), props.bool("more"), props.bool("missing")])
        XCTAssertEqual(["2", ""], [props["unread"], props["missing"]])
        XCTAssertEqual(0, props.int("since"))
        XCTAssertEqual(["Rae", "Sam"], props.list("people").map { $0["name"] })
        XCTAssertEqual(["night"], props.list("people")[0].list("tags").map { $0["name"] })
        XCTAssertEqual([], props.list("people")[1].list("tags"))
        XCTAssertEqual([], props.list("missing"))
        XCTAssertEqual(ISO8601DateFormatter().date(from: "2026-11-19T06:21:00Z"), props.date("since"))
        XCTAssertNil(props.date("unread"))
    }

    @MainActor
    func testARegisteredSwiftViewIsDrawnWithItsPropsAndSendsItsTapsToTheScreen() throws {
        let engine = FakeEngine()
        var seen: Props?
        var actions: Actions?
        var views = Screens()
        views.register("Summary") { props, taps -> Text in
            seen = props
            actions = taps
            return Text(props["unread"])
        }
        let host = host(views, engine: engine)

        XCTAssertNotNil(ImageRenderer(content: NodeView(node: try list().children[0], route: host.root, host: host, typed: .constant([:]))).cgImage)
        actions?.perform("archive", ["id": "m2"])
        host.settle()

        XCTAssertEqual(2, seen?.int("unread"))
        XCTAssertEqual("action mailbox member=maya archive id=m2", engine.calls.first)
    }

    @MainActor
    func testEachHostDrawsItsOwnViewForAName() throws {
        var one = Screens(), two = Screens()
        var drew: [String] = []
        one.register("Summary") { _, _ -> Text in drew.append("one"); return Text("1") }
        two.register("Summary") { _, _ -> Text in drew.append("two"); return Text("2") }
        let node = try list().children[0]

        for host in [host(one), host(two), host()] {
            XCTAssertNotNil(ImageRenderer(content: NodeView(node: node, route: host.root, host: host, typed: .constant([:]))).cgImage)
        }

        XCTAssertEqual(["one", "two"], drew, "the third host has no view by that name and draws the warning")
    }

    func testAnIconIsNamedByMeaningAndAnUnknownNameIsUsedAsGiven() {
        XCTAssertEqual(["archivebox", "person.crop.circle", "circle.fill"], ["archive", "person", "unread"].map(Icons.symbol))
        XCTAssertEqual("trash", Icons.symbol("trash"))
    }

    func testAMomentIsWrittenAsTheTimeTodayAndTheDayOtherwise() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-11-19T12:00:00Z")!

        XCTAssertFalse(Moment.written("2026-11-19T06:21:00.123456Z", now: now, calendar: calendar).contains("Nov"))
        XCTAssertTrue(Moment.written("2026-01-07T12:00:00.123456Z", now: now, calendar: calendar).contains("7"))
        XCTAssertEqual("soon", Moment.written("soon", now: now, calendar: calendar))
    }
}
