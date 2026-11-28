@testable import InstantRecordNative
import WebKit
import XCTest

/// An engine that answers pages as the compiled app does, and keeps what it
/// was asked.
private final class PageEngine: Engine {
    private let lock = NSLock()
    private var kept: [String] = []
    private var note = ""
    var asked: [String] { lock.withLock { kept } }
    func boot(database: String) -> Bool { true }
    func open(database: String) -> Bool { true }
    func notice() -> String { lock.withLock { note } }
    func error() -> String { "" }
    func onExchange(_ answer: @escaping (String) -> String) {}
    func call(_ entry: String, _ input: String) -> String? {
        guard entry == "request" else { return "" }
        lock.withLock { kept.append(input) }
        let line = input.components(separatedBy: "\r\n")[0]
        switch line {
        case "GET /orders HTTP/1.1": return "200\nContent-Type: text/html\n\n<title>Orders</title><body><h1>two orders</h1><div data-native='{\"navbar\":{\"title\":\"Orders\",\"pullToRefresh\":true,\"buttons\":[],\"segments\":[]}}'></div><form method=\"post\" action=\"/orders\"><input name=\"name\" value=\"tea &amp; milk\"><input type=\"hidden\" name=\"_method\" value=\"patch\"><button id=\"go\">Go</button></form></body>"
        case "PATCH /orders HTTP/1.1": lock.withLock { note = "records_changed" }; return "302\nLocation: /orders/1\nSet-Cookie: s=1; path=/\n\n"
        case "GET /orders/1 HTTP/1.1": return "200\n\n<title>One</title><h1>order one</h1>"
        default: return "404\n\nnothing"
        }
    }
}

@MainActor
final class LocalPagesTests: XCTestCase {
    // Nothing answers here: whatever is drawn was drawn on the device.
    private let server = URL(string: "http://localhost:1")!
    private var engine: PageEngine!
    private var app: AppHost!
    private var site: HybridSite!
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        engine = PageEngine()
        app = AppHost(engine: engine, root: Route("mailbox"), store: { _ in AppHost.Store(database: "d", endpoint: "e") }, exchange: { _ in "0\n" }, reachability: ManualReachability())
        app.start()
        site = HybridSite(server: server, data: .nonPersistent(), outside: { _ in })
        try? FileManager.default.createDirectory(at: folder.appending(path: "Pages/assets"), withIntermediateDirectories: true)
        try? Data("body{}".utf8).write(to: folder.appending(path: "Pages/assets/a.css"))
        try? Data("secret".utf8).write(to: folder.appending(path: "secret.css"))
        site.draw(with: app, pages: LocalPages(app: app, server: server, bundled: folder.appending(path: "Pages"), copies: folder.appending(path: "copies")))
    }

    private func wait(_ what: String, _ until: () async throws -> Bool) async throws {
        for _ in 0..<200 {
            if try await until() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Waited in vain: \(what)")
    }

    private func text(_ tab: HybridTab) async throws -> String { try await tab.web.callAsyncJavaScript("return document.body?.innerText ?? ''", contentWorld: .page) as? String ?? "" }

    func testAPageIsDrawnAndItsFormIsSentWithNoServer() async throws {
        let tab = HybridTab(site: site, path: "/orders")
        tab.load()
        try await wait("the page") { tab.signals?.navbar?.title == "Orders" }
        XCTAssertEqual(tab.web.url?.absoluteString, "instant-record://app/orders")
        _ = try await tab.web.callAsyncJavaScript("document.querySelector('#go').click()", contentWorld: .page)
        try await wait("where the form led") { try await self.text(tab).contains("order one") }
        let sent = try XCTUnwrap(engine.asked.first { $0.hasPrefix("PATCH") })
        XCTAssertTrue(sent.hasSuffix("name=tea+%26+milk&_method=patch"), sent)
        XCTAssertTrue(try XCTUnwrap(engine.asked.last { $0.hasPrefix("GET /orders/1") }).contains("Cookie: s=1\r\n"))
    }

    func testAnAddressTheAppLacksIsTheServers() async throws {
        let tab = HybridTab(site: site, path: "/elsewhere")
        tab.load()
        try await wait("the failure of a server that is not there") { tab.failure != nil }
        XCTAssertTrue(engine.asked.contains { $0.hasPrefix("GET /elsewhere") })
    }

    func testFilesComeFromTheBundleAndNotFromOutsideIt() async {
        func get(_ path: String) async -> LocalPages.Answer { await site.local!.answer(URLRequest(url: URL(string: "instant-record://app" + path)!)) }
        let style = await get("/assets/a.css"), outside = await get("/assets/%2e%2e/%2e%2e/secret.css")
        XCTAssertEqual(String(decoding: style.body, as: UTF8.self), "body{}")
        XCTAssertEqual(style.headers["Content-Type"], "text/css; charset=utf-8")
        XCTAssertFalse(String(decoding: outside.body, as: UTF8.self).contains("secret"))
    }

    func testAHeaderCannotAddAnother() {
        let text = HTTPText.request(method: "GET", path: "/", headers: ["X-A": "1\r\nX-B: 2", "Host": "evil"], body: Data(), host: "app", cookies: [:])
        XCTAssertFalse(text.contains("\nX-B"))
        XCTAssertFalse(text.contains("evil"))
    }

    func testAnAddressIsTheSameHereAndThere() {
        let there = URL(string: "http://localhost:1/a%20b?c=d")!
        XCTAssertEqual(LocalPages.local(there).absoluteString, "instant-record://app/a%20b?c=d")
        XCTAssertEqual(LocalPages.remote(LocalPages.local(there), server: server), there)
        XCTAssertFalse(site.owns(URL(string: "instant-record://other/")!))
    }
}
