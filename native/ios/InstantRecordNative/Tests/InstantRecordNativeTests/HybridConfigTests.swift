@testable import InstantRecordNative
import SwiftUI
import WebKit
import XCTest

final class HybridConfigTests: XCTestCase {
    private let server = URL(string: "http://localhost:3999")!
    private let json = ##"{"app":{"entry_path":"/b"},"appearance":{"tint_color":{"light":"#112233","dark":"#AABBCC"}},"later":1,"tabs":[{"title":"A","titles":{"nl":"Aa"},"path":"/a","icon":"house","icons":{"ios":"star"},"key":"a","badge":true,"auto_route":false},{"title":"No path"},{"title":"B","path":"/b","screen":"mailbox"},{"title":"C","path":"/c","screen":"notes"}]}"##

    private func config(_ languages: [String] = ["en"]) -> HybridConfig { HybridConfig(json: Data(json.utf8), languages: languages)! }
    private func defaults() -> UserDefaults {
        let name = "hybrid-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func testReadsWhatItKnowsAndDropsATabWithNoPath() {
        let config = config()
        XCTAssertEqual(config.tabs.map(\.path), ["/a", "/b", "/c"])
        XCTAssertEqual(config.tabs[0].icon, "star")
        XCTAssertTrue(config.tabs[0].badge)
        XCTAssertEqual(config.entryPath, "/b")
        XCTAssertEqual(config.tint?.dark, 0xAABBCC)
    }

    func testATitleInThePhonesLanguageWins() {
        XCTAssertEqual(config(["nl-BE"]).tabs[0].title, "Aa")
        XCTAssertEqual(config(["en"]).tabs[0].title, "A")
    }

    func testATabLeadingToAnotherServerIsDropped() {
        XCTAssertNil(HybridConfig(json: Data(#"{"tabs":[{"title":"X","path":"//evil.test/"}]}"#.utf8)))
    }

    func testTheAppsFirstScreenDrawsItsTabAndNoOther() {
        XCTAssertEqual(config().screenTab(root: "mailbox"), 1)
        XCTAssertEqual(config().screenTab(root: "notes"), 2)
        XCTAssertNil(config().screenTab(root: "other"))
        XCTAssertNil(config().screenTab(root: nil))
    }

    func testWhatIsNotAGoodConfigKeepsTheOneThatWas() {
        var answer = "200\n" + json
        let store = HybridConfigStore(server: server, defaults: defaults(), exchange: { _ in answer })
        XCTAssertNotNil(store.fetch())
        for bad in ["0\n", "404\n{\"error\":\"missing\"}", "200\n<html>", "200\n{\"tabs\":[]}", "500\n" + json] {
            answer = bad
            XCTAssertNil(store.fetch(), bad)
            XCTAssertEqual(store.kept()?.tabs.count, 3, bad)
        }
    }

    func testOneServersConfigIsNotAnothers() {
        let shared = defaults()
        _ = HybridConfigStore(server: server, defaults: shared, exchange: { [json] _ in "200\n" + json }).fetch()
        XCTAssertNil(HybridConfigStore(server: URL(string: "http://other.test")!, defaults: shared, exchange: { _ in "0\n" }).kept())
    }

    @MainActor func testADeployedTabAppearsAndAKeptTabKeepsItsWebView() async {
        var answer = #"200\#n{"tabs":[{"title":"A","path":"/a"}]}"#
        let host = HybridHost(site: HybridSite(server: server, data: .nonPersistent(), outside: { _ in }), app: nil, screens: [], views: Screens(), defaults: defaults(), exchange: { _ in answer })
        await host.refresh()
        XCTAssertEqual(host.shown.map(\.tab.path), ["/a"])
        let page = host.shown[0].page
        answer = #"200\#n{"tabs":[{"title":"A2","path":"/a"},{"title":"N","path":"/n","screen":"unknown"}]}"#
        await host.refresh()
        XCTAssertEqual(host.shown.map(\.tab.title), ["A2", "N"])
        XCTAssertTrue(host.shown[0].page === page)
        XCTAssertNotNil(host.shown[1].page, "a screen this app lacks is its path")
    }

    @MainActor func testARegisteredScreenDrawsItsTab() async {
        let app = AppHost(engine: FakeEngine(), root: Route("mailbox"), store: { _ in AppHost.Store(database: "d", endpoint: "e") }, reachability: ManualReachability())
        let host = HybridHost(site: HybridSite(server: server, data: .nonPersistent(), outside: { _ in }), app: app, screens: [], views: Screens(), defaults: defaults(), exchange: { [json] _ in "200\n" + json })
        await host.refresh()
        guard case .screen(let drawn) = host.shown[1].kind else { return XCTFail("a page") }
        XCTAssertTrue(drawn === app)
        XCTAssertNil(host.shown[1].page)
        XCTAssertNotNil(host.shown[2].page)
    }

    private func places(_ routes: String) -> [HybridConfig.Place] {
        HybridConfig(json: Data((#"{"tabs":[{"title":"A","path":"/"}],"routes":"# + routes + "}").utf8))!.routes
    }

    func testARouteMatchesWholeAddresses() {
        let place = places(#"[{"path":"/inbox/:id","screen":"thread","sheet":true}]"#)[0]
        func route(_ path: String) -> Route? { place.route(for: URL(string: path, relativeTo: server)!) }
        XCTAssertTrue(place.sheet)
        XCTAssertEqual(route("/inbox/7/?a=1&id=9"), Route("thread", ["id": "7", "a": "1"]))
        XCTAssertNil(route("/inbox"))
        XCTAssertNil(route("/inbox/7/edit"))
        XCTAssertNil(route("/other/7"))
    }

    func testARouteMustSayWhatItOpensOnce() {
        XCTAssertEqual(places(#"[{"path":"/a"},{"path":"/b","screen":"s","view":"V"},{"path":"//evil","view":"V"},{"path":"/c","view":"V"}]"#).map(\.path), ["/c"])
    }

    func testAnOlderAppLeavesOutThePlacesItLacks() {
        var views = Screens()
        views.register("Map") { _, _ in EmptyView() }
        let config = HybridConfig(json: Data(#"{"tabs":[{"path":"/"}],"routes":[{"path":"/m","view":"Map"},{"path":"/n","view":"New"},{"path":"/t","screen":"thread"}]}"#.utf8))!
        XCTAssertEqual(config.places(screens: [], views: views).map(\.path), ["/m"])
        XCTAssertEqual(config.places(screens: ["thread"], views: Screens()).map(\.path), ["/t"])
    }

    @MainActor func testASwiftViewDrawsATabOnlyWhereItIsRegistered() async {
        let json = #"200\#n{"tabs":[{"title":"A","path":"/a","view":"Map"},{"title":"B","path":"/b","view":"New"}]}"#
        var views = Screens()
        views.register("Map") { _, _ in EmptyView() }
        let host = HybridHost(site: HybridSite(server: server, data: .nonPersistent(), outside: { _ in }), app: nil, screens: [], views: views, defaults: defaults(), exchange: { _ in json })
        await host.refresh()
        XCTAssertNil(host.shown[0].page)
        XCTAssertNotNil(host.shown[1].page)
    }

    @MainActor func testOnlyRubysOwnScreensAreAskedOfRuby() {
        let engine = FakeEngine()
        let app = AppHost(engine: engine, root: Route("mailbox"), store: { _ in AppHost.Store(database: "d", endpoint: "e") }, exchange: { _ in "0\n" }, reachability: ManualReachability())
        app.start()
        app.path = [.page("/orders"), .view("Map")]
        app.perform("tap", on: .view("Map"))
        app.visited([Route("thread", ["id": "7"]), .page("/x")], in: ObjectIdentifier(self))
        app.settle()
        XCTAssertFalse(engine.calls.contains { $0.contains("page:") || $0.contains("swift:") }, "\(engine.calls)")
        XCTAssertTrue(engine.calls.contains { $0.hasPrefix("render thread") }, "\(engine.calls)")
    }

    @MainActor func testAScreenAWebPageOpenedIsToldOnce() {
        let engine = FakeEngine()
        let app = AppHost(engine: engine, root: Route("mailbox"), store: { _ in AppHost.Store(database: "d", endpoint: "e") }, exchange: { _ in "0\n" }, reachability: ManualReachability())
        app.start()
        let thread = Route("thread", ["id": "7"])
        app.visited([thread], in: ObjectIdentifier(self))
        app.visited([thread], in: ObjectIdentifier(self))
        app.visited([], in: ObjectIdentifier(self))
        app.settle()
        XCTAssertEqual(engine.calls.filter { $0.hasPrefix("action thread") }.count, 1, "\(engine.calls)")
        XCTAssertNil(app.screens[thread])
    }

    @MainActor func testTheFirstRouteThatMatchesDecidesAlsoThatItIsAPage() {
        let site = HybridSite(server: server, data: .nonPersistent(), outside: { _ in })
        site.use(places(#"[{"path":"/p/new","page":true},{"path":"/p/:id","screen":"p"}]"#))
        XCTAssertNil(site.place(at: URL(string: "/p/new", relativeTo: server)!))
        XCTAssertEqual(site.place(at: URL(string: "/p/7", relativeTo: server)!)?.route, Route("p", ["id": "7"]))
        XCTAssertNil(site.place(at: URL(string: "http://evil.test/p/7")!))
    }

    @MainActor func testATabThatGoesTakesItsOpenScreensAlong() async {
        let engine = FakeEngine()
        let app = AppHost(engine: engine, root: Route("mailbox"), store: { _ in AppHost.Store(database: "d", endpoint: "e") }, exchange: { _ in "0\n" }, reachability: ManualReachability())
        app.start()
        var answer = #"200\#n{"tabs":[{"title":"A","path":"/a"},{"title":"B","path":"/b"}]}"#
        let host = HybridHost(site: HybridSite(server: server, data: .nonPersistent(), outside: { _ in }), app: app, screens: [], views: Screens(), defaults: defaults(), exchange: { _ in answer })
        await host.refresh()
        app.visited([Route("thread")], in: ObjectIdentifier(host.shown[1].page!))
        answer = #"200\#n{"tabs":[{"title":"A","path":"/a"}]}"#
        await host.refresh()
        engine.calls = []
        app.perform("tap", on: Route("mailbox"))
        app.settle()
        XCTAssertFalse(engine.calls.contains { $0.hasPrefix("render thread") }, "\(engine.calls)")
    }

    @MainActor func testTheEntryOpensOnTheFirstLaunch() async {
        let json = #"200\#n{"app":{"entry_path":"/welcome"},"tabs":[{"title":"A","path":"/"},{"title":"B","path":"/b"}]}"#
        let host = HybridHost(site: HybridSite(server: server, data: .nonPersistent(), outside: { _ in }), app: nil, screens: [], views: Screens(), defaults: defaults(), exchange: { _ in json })
        let bare = host.shown[0].page
        await host.refresh()
        XCTAssertFalse(host.shown[0].page === bare)
    }
}
