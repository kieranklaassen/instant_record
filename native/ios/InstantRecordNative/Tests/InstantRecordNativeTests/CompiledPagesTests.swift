@testable import InstantRecordNative
import WebKit
import XCTest

/// The demo, compiled, drawing pages in a web view with no server. Runs when
/// INSTANT_RECORD_DYLIB names libinstant_record_app.dylib, which
/// `ruby compiled/pipeline/build_native.rb` builds.
private final class DylibEngine: Engine {
    private typealias Text = @convention(c) () -> UnsafePointer<CChar>?
    private typealias Open = @convention(c) (UnsafePointer<CChar>) -> Int32
    private typealias Call = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafePointer<CChar>?
    private let library: UnsafeMutableRawPointer

    init?(path: String) {
        guard let library = dlopen(path, RTLD_NOW) else { return nil }
        self.library = library
    }

    private func find<T>(_ name: String, as type: T.Type) -> T { unsafeBitCast(dlsym(library, name), to: type) }
    private func text(_ name: String) -> String { find(name, as: Text.self)().map { String(cString: $0) } ?? "" }
    func boot(database: String) -> Bool { find("ir_boot", as: Open.self)(database) == 0 }
    func open(database: String) -> Bool { find("ir_open", as: Open.self)(database) == 0 }
    func call(_ entry: String, _ input: String) -> String? { find("ir_call", as: Call.self)(entry, input).map { String(cString: $0) } }
    func notice() -> String { text("ir_notice") }
    func error() -> String { text("ir_error") }
    func onExchange(_ answer: @escaping (String) -> String) {}
}

@MainActor
final class CompiledPagesTests: XCTestCase {
    private func wait(_ what: String, _ until: () async throws -> Bool) async throws {
        for _ in 0..<400 {
            if (try? await until()) == true { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Waited in vain: \(what)")
    }

    func testRailsDrawsAPageAndKeepsAFormsWriteWithNoServer() async throws {
        guard let path = ProcessInfo.processInfo.environment["INSTANT_RECORD_DYLIB"] else { throw XCTSkip("Set INSTANT_RECORD_DYLIB to run this.") }
        let engine = try XCTUnwrap(DylibEngine(path: path))
        let database = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite3").path
        let app = AppHost(engine: engine, root: Route("feedback"), store: { _ in AppHost.Store(database: database, endpoint: "http://localhost:1/instant_record") }, exchange: { _ in "0\n" }, reachability: ManualReachability())
        app.start()
        let site = HybridSite(server: URL(string: "http://localhost:1")!, data: .nonPersistent(), outside: { _ in })
        site.draw(with: app)
        let tab = HybridTab(site: site, path: "/todo")
        tab.load()
        func js(_ script: String) async throws -> Any? { try await tab.web.callAsyncJavaScript(script, contentWorld: .page) }
        try await wait("the page") { try await js("return document.querySelectorAll('form input').length > 0") as? Bool == true }
        XCTAssertEqual(tab.web.url?.absoluteString, "instant-record://app/todo")
        _ = try await js("""
        const form = [...document.forms].find(form => [...form.elements].some(field => field.name.includes('[title]')))
        const field = [...form.elements].find(field => field.name.includes('[title]'))
        field.value = 'Milk & tea, offline'
        form.submit()
        """)
        try await wait("the new record") { (try await js("return document.body.innerHTML") as? String ?? "").contains("Milk &amp; tea, offline") }
        app.sync()
        let again = await app.page("GET /todo HTTP/1.1\r\nHost: app\r\n\r\n")
        XCTAssertEqual(again?.status, 200)
    }
}
