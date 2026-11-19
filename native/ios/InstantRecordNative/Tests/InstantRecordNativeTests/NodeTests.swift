import SwiftUI
import XCTest
@testable import InstantRecordNative

final class NodeTests: XCTestCase {
    /// Every kind the Ruby view layer writes, with an unknown one among them.
    static let screen = """
    {"kind":"screen","id":"","text":"","action":"","arg":"","props":{},"children":[
      {"kind":"navigation","id":"","text":"","action":"","arg":"","props":{"title":"Support"},"children":[
        {"kind":"list","id":"","text":"","action":"","arg":"","props":{},"children":[
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
          {"kind":"button","id":"","text":"Archive","action":"archive","arg":"maya/support/m2","props":{"image":"archivebox"},"children":[]}]}]}]}
    """

    func testATreeWithEveryKindDecodes() throws {
        let screen = try Node(json: NodeTests.screen)
        let navigation = screen.children[0]
        let row = navigation.children[0].children[0].children[0]

        XCTAssertEqual("Support", navigation.prop("title"))
        XCTAssertEqual(["list", "toolbar"], navigation.children.map(\.kind))
        XCTAssertEqual("thread", row.prop("link"))
        XCTAssertEqual("read", row.action)
        XCTAssertEqual("maya/support/m2", row.arg)
        XCTAssertEqual("Sam \"S\" Ortiz", row.children[0].children[1].text)
        XCTAssertEqual("Hello\ncafé", row.children[1].text)
        XCTAssertEqual("archive", row.children(of: "swipe")[0].action)
        XCTAssertEqual("", row.prop("nothing"))
    }

    func testARowIsKeptByItsRecordAndAnythingElseByItsPlace() throws {
        let section = try Node(json: NodeTests.screen).children[0].children[0].children[0]

        XCTAssertEqual(["m2", "m1"], section.keyed.map(\.key))
        XCTAssertEqual(["#0", "#1", "#2", "#3"], section.children[0].keyed.map(\.key))
    }

    func testAnswerThatIsNotAScreenDoesNotDecode() {
        XCTAssertThrowsError(try Node(json: "{\"kind\":\"row\"}"))
    }

    @MainActor
    func testEveryKindDrawsAndAnUnknownOneDrawsNothing() throws {
        let host = AppHost(engine: FakeEngine(), root: Route("mailbox", "maya/support"), endpoint: "http://example.test/sync")
        let screen = try Node(json: NodeTests.screen)
        let drawn = ImageRenderer(content: NodeView(node: screen.children[0], route: host.root, host: host, first: true).frame(width: 390, height: 600))
        let unknown = ImageRenderer(content: NodeView(node: screen.children[0].children[0].children[0].children[0].children[2], route: host.root, host: host))

        XCTAssertNotNil(drawn.cgImage)
        XCTAssertNil(unknown.cgImage, "an unknown kind has no size to draw")
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
