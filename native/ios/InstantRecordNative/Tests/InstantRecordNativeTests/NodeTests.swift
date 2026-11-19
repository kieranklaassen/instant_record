import SwiftUI
import XCTest
@testable import InstantRecordNative

final class NodeTests: XCTestCase {
    /// Every kind the Ruby view layer writes, with an unknown one among them.
    static let screen = """
    {"kind":"screen","id":"","text":"","action":"","arg":"","props":{},"children":[
      {"kind":"navigation","id":"","text":"","action":"","arg":"","props":{"title":"Support"},"children":[
        {"kind":"list","id":"","text":"","action":"","arg":"","props":{"refresh":"true"},"children":[
          {"kind":"swift","id":"","text":"Summary","action":"","arg":"","props":{},"children":[
            {"kind":"prop","id":"unread","text":"2","action":"","arg":"","props":{},"children":[]},
            {"kind":"prop","id":"since","text":"2026-11-19T06:21:00.000000Z","action":"","arg":"","props":{},"children":[]},
            {"kind":"props","id":"people","text":"","action":"","arg":"","props":{},"children":[
              {"kind":"record","id":"","text":"","action":"","arg":"","props":{},"children":[
                {"kind":"prop","id":"name","text":"Rae","action":"","arg":"","props":{},"children":[]},
                {"kind":"props","id":"tags","text":"","action":"","arg":"","props":{},"children":[
                  {"kind":"record","id":"","text":"","action":"","arg":"","props":{},"children":[
                    {"kind":"prop","id":"name","text":"night","action":"","arg":"","props":{},"children":[]}]}]}]},
              {"kind":"record","id":"","text":"","action":"","arg":"","props":{},"children":[
                {"kind":"prop","id":"name","text":"Sam","action":"","arg":"","props":{},"children":[]}]}]}]},
          {"kind":"swift","id":"","text":"Nobody","action":"","arg":"","props":{},"children":[]},
          {"kind":"section","id":"","text":"Today","action":"","arg":"","props":{},"children":[
            {"kind":"row","id":"m2","text":"","action":"read","arg":"maya/support/m2","props":{"link":"thread"},"children":[
              {"kind":"stack","id":"","text":"","action":"","arg":"","props":{"axis":"horizontal"},"children":[
                {"kind":"image","id":"","text":"circle.fill","action":"","arg":"","props":{"tone":"accent"},"children":[]},
                {"kind":"text","id":"","text":"Sam \\"S\\" Ortiz","action":"","arg":"","props":{"style":"headline"},"children":[]},
                {"kind":"date","id":"","text":"2026-11-19T06:21:00.000000Z","action":"","arg":"","props":{"style":"caption","tone":"secondary"},"children":[]}]},
              {"kind":"text","id":"","text":"Hello\\ncafé","action":"","arg":"","props":{},"children":[]},
              {"kind":"hologram","id":"","text":"","action":"","arg":"","props":{},"children":[]},
              {"kind":"swipe","id":"","text":"Archive","action":"archive","arg":"maya/support/m2","props":{"role":"destructive","image":"archivebox"},"children":[]}]},
            {"kind":"row","id":"m1","text":"","action":"","arg":"","props":{},"children":[]}]}]},
        {"kind":"toolbar","id":"","text":"","action":"","arg":"","props":{},"children":[
          {"kind":"button","id":"","text":"Archive","action":"archive","arg":"maya/support/m2","props":{"image":"archivebox","position":"trailing"},"children":[]},
          {"kind":"button","id":"","text":"Inboxes","action":"","arg":"","props":{"image":"person.crop.circle","position":"leading"},"children":[
            {"kind":"item","id":"","text":"Support","action":"","arg":"maya/support","props":{"link":"mailbox","selected":"true"},"children":[]},
            {"kind":"item","id":"","text":"Empty","action":"empty","arg":"maya/support","props":{"role":"destructive","image":"trash"},"children":[]}]}]}]}]}
    """

    func testATreeWithEveryKindDecodes() throws {
        let screen = try Node(json: NodeTests.screen)
        let navigation = screen.children[0]
        let row = navigation.children[0].children(of: "section")[0].children[0]
        let menu = navigation.children[1].children[1]

        XCTAssertEqual("Support", navigation.prop("title"))
        XCTAssertEqual(["list", "toolbar"], navigation.children.map(\.kind))
        XCTAssertEqual("thread", row.prop("link"))
        XCTAssertEqual("read", row.action)
        XCTAssertEqual("maya/support/m2", row.arg)
        XCTAssertEqual("Sam \"S\" Ortiz", row.children[0].children[1].text)
        XCTAssertEqual("Hello\ncafé", row.children[1].text)
        XCTAssertEqual("archive", row.children(of: "swipe")[0].action)
        XCTAssertEqual("", row.prop("nothing"))
        XCTAssertEqual("true", navigation.children[0].prop("refresh"))
        XCTAssertEqual(["leading", "item", "true", "mailbox"], [menu.prop("position"), menu.children[0].kind, menu.children[0].prop("selected"), menu.children[0].prop("link")])
    }

    func testARowIsKeptByItsRecordAndAnythingElseByItsPlace() throws {
        let section = try Node(json: NodeTests.screen).children[0].children[0].children(of: "section")[0]

        XCTAssertEqual(["m2", "m1"], section.keyed.map(\.key))
        XCTAssertEqual(["#0", "#1", "#2", "#3"], section.children[0].keyed.map(\.key))
    }

    func testAnswerThatIsNotAScreenDoesNotDecode() {
        XCTAssertThrowsError(try Node(json: "{\"kind\":\"row\"}"))
    }

    @MainActor
    func testEveryKindDrawsAndAnUnknownOneDrawsNothing() throws {
        let host = AppHost(engine: FakeEngine(), root: Route("mailbox", "maya/support")) { _ in AppHost.Store(database: "", endpoint: "") }
        let screen = try Node(json: NodeTests.screen)
        let drawn = ImageRenderer(content: NodeView(node: screen.children[0], route: host.root, host: host, first: true).frame(width: 390, height: 600))
        let unknown = ImageRenderer(content: NodeView(node: screen.children[0].children[0].children(of: "section")[0].children[0].children[2], route: host.root, host: host))

        XCTAssertNotNil(drawn.cgImage)
        XCTAssertNil(unknown.cgImage, "an unknown kind has no size to draw")
    }

    func testASwiftViewReadsItsPropsByName() throws {
        let props = Props(try Node(json: NodeTests.screen).children[0].children[0].children[0])

        XCTAssertEqual("2", props["unread"])
        XCTAssertEqual("", props["missing"])
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
        let host = AppHost(engine: engine, root: Route("mailbox", "maya/support")) { _ in AppHost.Store(database: "", endpoint: "") }
        let list = try Node(json: NodeTests.screen).children[0].children[0]
        var seen: Props?
        var actions: Actions?
        Screens.register("Summary") { props, taps -> Text in
            seen = props
            actions = taps
            return Text(props["unread"])
        }

        XCTAssertNotNil(ImageRenderer(content: NodeView(node: list.children[0], route: host.root, host: host)).cgImage)
        actions?.perform("archive", "maya/support/m2")
        host.settle()

        XCTAssertEqual("2", seen?["unread"])
        XCTAssertEqual("action mailbox|maya/support|archive|maya/support/m2", engine.calls.first)
    }

    @MainActor
    func testASwiftViewNobodyRegisteredSaysSoOnScreen() throws {
        let host = AppHost(engine: FakeEngine(), root: Route("mailbox", "maya/support")) { _ in AppHost.Store(database: "", endpoint: "") }
        let missing = try Node(json: NodeTests.screen).children[0].children[0].children[1]

        XCTAssertNotNil(ImageRenderer(content: NodeView(node: missing, route: host.root, host: host)).cgImage)
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
