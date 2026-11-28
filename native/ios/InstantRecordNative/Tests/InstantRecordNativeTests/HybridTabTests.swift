@testable import InstantRecordNative
import WebKit
import XCTest

/// The page script in a real web view. The fixture is what the gem's
/// helpers render (test/native_helper_test.rb keeps it so).
@MainActor
final class HybridTabTests: XCTestCase {
    private let server = URL(string: "http://localhost:3999")!
    private var opened: [URL] = []
    private lazy var site = HybridSite(server: server, data: .nonPersistent()) { [weak self] in self?.opened.append($0) }

    private func page(_ html: String, at base: String = "http://localhost:3999/orders/1", guarded: Bool = true) -> HybridTab {
        let tab = HybridTab(site: site, path: "/")
        if !guarded { tab.web.navigationDelegate = nil }
        tab.web.loadSimulatedRequest(URLRequest(url: URL(string: base)!), responseHTML: html)
        return tab
    }

    private func fixture() throws -> String {
        try String(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "native_page", withExtension: "html", subdirectory: "Fixtures")), encoding: .utf8)
    }

    private func wait(_ what: String, _ until: () async throws -> Bool) async throws {
        for _ in 0..<200 {
            if try await until() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Waited in vain: \(what)")
    }

    private func js(_ tab: HybridTab, _ script: String) async throws -> Any? {
        try await tab.web.callAsyncJavaScript(script, contentWorld: .page)
    }

    func testReadsWhatTheHelpersRender() async throws {
        let tab = try page(fixture())
        try await wait("signals") { tab.signals != nil }
        let signals = try XCTUnwrap(tab.signals), bar = try XCTUnwrap(signals.navbar)
        XCTAssertTrue(signals.tabs)
        XCTAssertTrue(signals.form)
        XCTAssertEqual(signals.badges, ["inbox": "true", "cart": "new"])
        XCTAssertEqual(tab.toast?.message, "Saved")
        XCTAssertEqual(bar.title, "Orders")
        XCTAssertFalse(bar.pullToRefresh)
        XCTAssertEqual(bar.buttons.map(\.title), ["Close", "More", "Share"])
        XCTAssertEqual(bar.buttons.map(\.leading), [true, false, false])
        XCTAssertEqual(bar.buttons[1].items.map(\.title), ["Edit", "Delete", "Share"])
        XCTAssertTrue(bar.buttons[1].items[0].replace && bar.buttons[1].items[0].selected)
        XCTAssertTrue(bar.buttons[1].items[1].destructive)
        XCTAssertEqual(tab.shared(bar.buttons[2]).absoluteString, "http://localhost:3999/orders")
        XCTAssertEqual(signals.fab?.href, "/x")
        XCTAssertEqual(bar.segments.map(\.selected), [true, false])
        XCTAssertEqual(bar.submit?.click, "#save")
    }

    func testAClickReachesAnElementThePageHidesInTheApp() async throws {
        let tab = try page(fixture())
        try await wait("signals") { tab.signals != nil }
        let hidden = try await js(tab, "return getComputedStyle(document.querySelector('#delete')).display") as? String
        XCTAssertEqual(hidden, "none")
        tab.tap(try XCTUnwrap(tab.signals?.navbar?.buttons[1].items[1]))
        try await wait("the click") { try await js(tab, "return document.body.dataset.deleted") as? String == "1" }
    }

    func testFollowsThePageAsItChanges() async throws {
        let tab = page(#"<title>One</title><body><div data-native='{"navbar":{"title":"","pullToRefresh":true,"buttons":[],"segments":[]}}' hidden></div>"#)
        try await wait("signals") { tab.signals?.navbar?.title == "One" }
        _ = try await js(tab, "document.title = 'Two'")
        try await wait("the change") { tab.signals?.navbar?.title == "Two" }
        _ = try await js(tab, "document.body = document.createElement('body')")
        try await wait("the bar going") { tab.signals?.navbar == nil }
    }

    func testAToastIsShownOnce() async throws {
        let tab = try page(fixture())
        try await wait("the toast") { tab.toast != nil }
        tab.dismissToast()
        _ = try await js(tab, "window.instantRecordHybrid.gather()")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(tab.toast)
    }

    func testBackPassesOverAFormAmongPagesTheirScriptPushes() async throws {
        let tab = page("<title>List</title><body><p>list</p>")
        try await wait("signals") { tab.signals != nil }
        _ = try await js(tab, ##"history.pushState({}, '', '/new'); document.body.innerHTML = '<div data-native="{&quot;form&quot;:true}"></div>'"##)
        try await wait("the form") { tab.signals?.form == true }
        _ = try await js(tab, "history.pushState({}, '', '/done'); document.body.innerHTML = '<p>done</p>'")
        try await wait("the page after") { tab.signals?.url.hasSuffix("/done") == true && tab.canGoBack }
        tab.back()
        try await wait("the list") { tab.web.url?.path == "/orders/1" }
    }

    func testAnotherServersPageIsNotHeard() async throws {
        let tab = page(#"<title>Evil</title><div data-native='{"navbar":{"title":"","pullToRefresh":true,"buttons":[],"segments":[]}}' hidden></div>"#, at: "http://evil.test/", guarded: false)
        try await wait("the page") { try await js(tab, "return !!window.instantRecordHybrid && document.readyState === 'complete'") as? Bool == true }
        _ = try await js(tab, "window.InstantRecord.visit('https://elsewhere.test/'); window.InstantRecord.share('https://elsewhere.test/')")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(tab.signals)
        XCTAssertNil(tab.sharing)
        XCTAssertEqual(opened, [])
    }

    func testAFrameIsNotHeard() async throws {
        let tab = page(#"<body><iframe srcdoc="<script>window.webkit?.messageHandlers?.instantRecordHybrid?.postMessage({type:'share',url:'/x'}); parent.framed = true</script>"></iframe>"#)
        try await wait("the frame") { try await js(tab, "return window.framed === true") as? Bool == true }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(tab.sharing)
    }

    func testAPageCannotLeadTheWebViewAway() async throws {
        let tab = page("<body></body>")
        try await wait("signals") { tab.signals != nil }
        tab.visit("javascript:document.title='ran'")
        tab.visit("https://elsewhere.test/")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(opened.map(\.absoluteString), ["https://elsewhere.test/"])
        XCTAssertEqual(tab.web.url?.absoluteString, "http://localhost:3999/orders/1")
        XCTAssertNotEqual(tab.web.title, "ran")
    }

    func testALinkToANativePlaceOpensItAndOthersDoNot() async throws {
        site.use([HybridConfig.Place(path: "/inbox/:thread", screen: "thread", view: nil, sheet: false),
                  HybridConfig.Place(path: "/map", screen: nil, view: "Map", sheet: true)])
        let tab = page(#"""
        <body><a id="a" href="/inbox/a%20b?from=list">thread</a><a id="b" href="/map?at=1">map</a><a id="c" href="#x">x</a>
        <script>window.fetched = 0; document.addEventListener("click", () => window.fetched++)</script></body>
        """#)
        try await wait("signals") { tab.signals != nil }
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = try await js(tab, "document.querySelector('#a').click()")
        try await wait("the screen") { tab.path == [Route("thread", ["thread": "a b", "from": "list"])] }
        _ = try await js(tab, "document.querySelector('#b').click()")
        try await wait("the sheet") { tab.sheet == .view("Map", ["at": "1"]) }
        let fetched = try await js(tab, "const before = window.fetched; document.querySelector('#c').click(); return [before, window.fetched]") as? [Int]
        XCTAssertEqual(fetched, [0, 1], "Turbo and Inertia never hear of a native place's link, and hear of every other")
        XCTAssertEqual(tab.path.count, 1)
    }

    func testARouteDeployedLaterIsKnownToAPageAlreadyOpen() async throws {
        let tab = page(#"<body><a id="a" href="/map">map</a></body>"#)
        try await wait("signals") { tab.signals != nil }
        site.use([HybridConfig.Place(path: "/map", screen: nil, view: "Map", sheet: false)])
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = try await js(tab, "document.querySelector('#a').click()")
        try await wait("the view") { tab.path == [.view("Map")] }
    }

    func testALinkToAnotherServerLeavesTheApp() async throws {
        let tab = page(#"<body><a id="a" href="https://elsewhere.test/x">x</a></body>"#)
        try await wait("signals") { tab.signals != nil }
        _ = try await js(tab, "document.querySelector('#a').click()")
        try await wait("the browser") { self.opened.map(\.absoluteString) == ["https://elsewhere.test/x"] }
        XCTAssertEqual(tab.web.url?.path, "/orders/1")
    }

    func testBrokenJSONIsPassedOver() async throws {
        let tab = page(#"<div data-native="{"></div><div data-native='{"tabs":true}'></div>"#)
        try await wait("signals") { tab.signals != nil }
        XCTAssertEqual(tab.signals?.tabs, true)
    }
}
