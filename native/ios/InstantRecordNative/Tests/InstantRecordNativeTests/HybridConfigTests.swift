@testable import InstantRecordNative
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

    func testOnlyTheFirstRegisteredScreenDrawsATab() {
        XCTAssertEqual(config().screenTab(registered: ["mailbox", "notes"]), 1)
        XCTAssertEqual(config().screenTab(registered: ["notes"]), 2)
        XCTAssertNil(config().screenTab(registered: ["other"]))
        XCTAssertNil(config().screenTab(registered: []))
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
        let host = HybridHost(server: server, screens: [:], data: .nonPersistent(), defaults: defaults(), exchange: { _ in answer }, outside: { _ in })
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
        let host = HybridHost(server: server, screens: ["mailbox": app], data: .nonPersistent(), defaults: defaults(), exchange: { [json] _ in "200\n" + json }, outside: { _ in })
        await host.refresh()
        XCTAssertTrue(host.shown[1].screen === app)
        XCTAssertNil(host.shown[1].page)
        XCTAssertNil(host.shown[2].screen)
    }
}
