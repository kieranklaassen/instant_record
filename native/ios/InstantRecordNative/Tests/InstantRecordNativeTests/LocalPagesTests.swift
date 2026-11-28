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
        if entry == "routes" { return "GET /orders\nPATCH /orders\nGET /orders/:id\nPOST /pay\nPOST /out" }
        guard entry == "request" else { return "" }
        lock.withLock { kept.append(input) }
        let line = input.components(separatedBy: "\r\n")[0]
        switch line {
        case "GET /orders HTTP/1.1": return "200\nContent-Type: text/html\n\n<title>Orders</title><body><h1>two orders</h1><div data-native='{\"navbar\":{\"title\":\"Orders\",\"pullToRefresh\":true,\"buttons\":[],\"segments\":[]}}'></div><form method=\"post\" action=\"/orders\"><input name=\"name\" value=\"tea &amp; milk\"><input type=\"hidden\" name=\"_method\" value=\"patch\"><button id=\"go\">Go</button></form></body>"
        case "PATCH /orders HTTP/1.1": lock.withLock { note = "records_changed" }; return "302\nLocation: /orders/1\nSet-Cookie: s=1; path=/\n\n"
        case "POST /pay HTTP/1.1": return "303\nLocation: https://pay.test/x\n\n"
        case "POST /out HTTP/1.1": return "303\nLocation: /account\n\n"
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
        XCTAssertEqual(engine.asked, [], "no page is drawn to learn whether there is one")
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

    /// With Turbo itself, when TURBO_JS names turbo.min.js.
    func testTurboTakesAFormsAnswerAndALinkFindsItsWay() async throws {
        guard let path = ProcessInfo.processInfo.environment["TURBO_JS"] else { throw XCTSkip("Set TURBO_JS to run this.") }
        try FileManager.default.copyItem(atPath: path, toPath: folder.appending(path: "Pages/assets/turbo.min.js").path)
        let tab = HybridTab(site: site, path: "/orders")
        tab.load()
        try await wait("the page") { tab.signals != nil }
        func js(_ script: String) async throws -> Any? { try await tab.web.callAsyncJavaScript(script, contentWorld: .page) }
        _ = try await js("await new Promise((done, fail) => { const tag = document.createElement('script'); tag.type = 'module'; tag.src = '/assets/turbo.min.js'; tag.onload = done; tag.onerror = fail; document.head.append(tag) }); window.errors = []; window.addEventListener('unhandledrejection', event => errors.push(String(event.reason)))")
        try await wait("Turbo") { try await js("return !!window.Turbo") as? Bool == true }
        _ = try await js("document.querySelector('form').requestSubmit(document.querySelector('#go'))")
        try await wait("where the form led") { try await self.text(tab).contains("order one") }
        XCTAssertEqual(tab.web.url?.absoluteString, "instant-record://app/orders/1")
        XCTAssertEqual(engine.asked.filter { $0.hasPrefix("PATCH") }.count, 1)
        let errors = try await js("return window.errors") as? [String]
        XCTAssertEqual(errors, [], "Turbo stayed, and saw nothing wrong")
        _ = try await js("const link = document.createElement('a'); link.href = '/account'; document.body.append(link); link.click()")
        try await wait("the server, which is not there") { tab.failure != nil }
        XCTAssertFalse(engine.asked.contains { $0.contains("/account") })
    }

    func testAnArrivingChangeLeavesAHalfFilledFormAlone() async throws {
        let tab = HybridTab(site: site, path: "/orders")
        tab.load()
        try await wait("the page") { tab.signals != nil }
        func js(_ script: String) async throws -> Any? { try await tab.web.callAsyncJavaScript(script, contentWorld: .page) }
        _ = try await js("window.times = 0; window.Turbo = { session: { refresh: () => window.times++ } }")
        tab.recordsChanged()
        try await wait("a redraw") { try await js("return window.times") as? Int == 1 }
        _ = try await js("document.querySelector('input[name=name]').value = 'half'")
        tab.recordsChanged()
        try await Task.sleep(nanoseconds: 200_000_000)
        let times = try await js("return window.times") as? Int
        XCTAssertEqual(times, 1)
    }

    private func send(_ path: String, origin: String? = "instant-record://app", referer: String? = nil, turbo: Bool = false, type: String = "application/x-www-form-urlencoded", body: Data = Data("a=1".utf8)) async -> LocalPages.Answer {
        var request = URLRequest(url: URL(string: "instant-record://app" + path)!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        if turbo { request.setValue("1", forHTTPHeaderField: "X-Turbo-Request-Id") }
        return await site.local!.answer(request)
    }

    func testOnlyTheAppsOwnPagesWrite() async {
        for (origin, referer) in [(nil, nil), ("null", nil), ("https://srv.test", nil), (nil, "about:srcdoc"), (nil, "https://ads.test/"), (nil, "instant-record://app.evil/"), ("https://srv.test", "instant-record://app/")] as [(String?, String?)] {
            let said = await send("/orders?_method=patch", origin: origin, referer: referer)
            XCTAssertEqual(said.status, 403, "\(origin ?? "-") \(referer ?? "-")")
        }
        XCTAssertEqual(engine.asked, [])
        let own = await send("/pay", origin: nil, referer: "instant-record://app/orders")
        XCTAssertEqual(own.status, 200)
    }

    func testAFrameCannotWrite() async throws {
        let tab = HybridTab(site: site, path: "/orders")
        tab.load()
        try await wait("the page") { tab.signals != nil }
        _ = try await tab.web.callAsyncJavaScript("""
        const frame = document.createElement("iframe")
        frame.sandbox = "allow-scripts allow-forms allow-top-navigation"
        frame.srcdoc = `<form id=f method=post target=_top action="instant-record://app/pay"></form><script>fetch("instant-record://app/pay", { mode: "no-cors", method: "POST", body: "a" }); setTimeout(() => f.submit(), 200)<\\/script>`
        document.body.append(frame)
        """, contentWorld: .page)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertFalse(engine.asked.contains { $0.hasPrefix("POST /pay") }, "\(engine.asked)")
        XCTAssertEqual(tab.web.url?.path, "/orders")
    }

    func testWhereAFormLeadsIsSaidAndNotFollowedWhenItIsNotDrawnHere() async {
        let pay = await send("/pay"), out = await send("/out"), turbo = await send("/orders", turbo: true, body: Data("_method=patch".utf8))
        XCTAssertEqual(pay.headers[LocalPages.elsewhere], "https://pay.test/x")
        XCTAssertEqual(out.headers[LocalPages.elsewhere], "http://localhost:1/account")
        XCTAssertEqual(turbo.headers[LocalPages.elsewhere], "instant-record://app/orders/1")
        XCTAssertEqual(engine.asked.filter { $0.hasPrefix("GET") }, [], "each is the page's to visit")
    }

    func testAFileIsRefusedAndAMethodInPartsIsRead() async {
        let file = await send("/orders", body: Data([0xFF, 0xD8, 0x00]))
        XCTAssertEqual(file.status, 415)
        let parts = "--b\r\nContent-Disposition: form-data; name=\"_method\"\r\n\r\npatch\r\n--b--\r\n"
        let sent = await send("/orders", type: "multipart/form-data; boundary=b", body: Data(parts.utf8))
        XCTAssertEqual(sent.status, 200)
        XCTAssertTrue(engine.asked.contains { $0.hasPrefix("PATCH /orders") })
    }

    func testADayIsTheDayThatWasChosen() {
        let zone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(Day.written(Day.date("2026-11-28", zone: zone)!, zone: zone), "2026-11-28")
        XCTAssertNil(Day.date("", zone: zone))
    }

    func testAnAnswerThatIsNotJSONIsLeftOut() {
        XCTAssertEqual(Capabilities.strings(["a": Date(), "b": NSNull(), "c": ["x": Date()], "d": 1]), ["d": "1"])
    }

    func testAnAddressIsTheSameHereAndThere() {
        let there = URL(string: "http://localhost:1/a%20b?c=d")!
        XCTAssertEqual(LocalPages.local(there).absoluteString, "instant-record://app/a%20b?c=d")
        XCTAssertEqual(LocalPages.remote(LocalPages.local(there), server: server), there)
        XCTAssertFalse(site.owns(URL(string: "instant-record://other/")!))
    }
}
