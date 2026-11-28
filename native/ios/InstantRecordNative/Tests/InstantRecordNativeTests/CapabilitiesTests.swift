@testable import InstantRecordNative
import WebKit
import XCTest

@MainActor
final class CapabilitiesTests: XCTestCase {
    private func wait(_ what: String, _ until: () async throws -> Bool) async throws {
        for _ in 0..<200 {
            if try await until() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Waited in vain: \(what)")
    }

    func testWhatIsTheirsIsNotThereUntilItIsAllowed() async throws {
        let standard = Capabilities()
        let sensitive = ["biometrics.check", "clipboard.read", "keychain.get", "location.current", "notifications.schedule", "audio.record"]
        XCTAssertTrue(Set(standard.names).isDisjoint(with: sensitive), "\(standard.names)")
        standard.allow(.location)
        XCTAssertEqual(Set(standard.names).intersection(sensitive), ["location.current"])
        Capabilities.Group.allCases.forEach { standard.allow($0) }
        XCTAssertTrue(Set(standard.names).isSuperset(of: sensitive))
        XCTAssertEqual(Capabilities(standard: false).names, ["capabilities.list"])
    }

    func testAnAppAddsItsOwnAndAnUnknownNameIsRefused() async throws {
        let capabilities = Capabilities(standard: false)
        capabilities.add("steps.count") { ["count": Int($0["days"] ?? "")! * 10] }
        let answer = try await capabilities.call("steps.count", ["days": "3"])
        XCTAssertEqual(answer["count"] as? Int, 30)
        do {
            try await capabilities.call("other")
            XCTFail("called")
        } catch { XCTAssertEqual(error as? Capabilities.Failure, .init("This app has no other")) }
    }

    func testValuesCrossAsStrings() {
        XCTAssertEqual(Capabilities.arguments(["a": "x", "b": true, "c": 2, "d": 1.5, "e": ["no"], "f": NSNull()]), ["a": "x", "b": "true", "c": "2", "d": "1.5"])
        XCTAssertEqual(Capabilities.strings(["names": ["a"], "ok": false]), ["names": #"["a"]"#, "ok": "false"])
    }

    func testStandardAnswers() async throws {
        let device = try await Capabilities().call("device.info")
        XCTAssertEqual(device["system"] as? String, "macos")
        for url in ["file:///etc/hosts", "", "javascript:1"] {
            do { try await Capabilities().call("audio.play", ["url": url]); XCTFail(url) } catch {}
        }
    }

    func testAPageCallsAndIsAnsweredAndAnotherServersIsNot() async throws {
        func page(at base: String) -> HybridTab {
            let site = HybridSite(server: URL(string: "http://localhost:3999")!, data: .nonPersistent(), outside: { _ in })
            let capabilities = Capabilities(standard: false)
            capabilities.add("add") { ["sum": Int($0["a"]!)! + 1] }
            site.capabilities = capabilities
            let tab = HybridTab(site: site, path: "/")
            tab.web.navigationDelegate = nil
            tab.web.loadSimulatedRequest(URLRequest(url: URL(string: base)!), responseHTML: "<body></body>")
            return tab
        }
        let call = "try { return JSON.stringify(await InstantRecord.call(name, { a: 2 })) } catch (error) { return 'refused ' + error.message }"
        func said(_ tab: HybridTab, _ name: String) async throws -> String? {
            try await wait("the page") { try await tab.web.callAsyncJavaScript("return !!window.InstantRecord", contentWorld: .page) as? Bool == true }
            return try await tab.web.callAsyncJavaScript(call, arguments: ["name": name], contentWorld: .page) as? String
        }
        let ours = page(at: "http://localhost:3999/"), theirs = page(at: "http://evil.test/")
        let answer = try await said(ours, "add"), unknown = try await said(ours, "none"), refused = try await said(theirs, "add")
        XCTAssertEqual(answer, #"{"sum":3}"#)
        XCTAssertEqual(unknown, "refused This app has no none")
        XCTAssertEqual(refused, "refused Not allowed")
    }

    func testARubyScreenCallsAndHearsWhatCameOfIt() async throws {
        let engine = FakeEngine()
        let app = AppHost(engine: engine, root: Route("mailbox"), store: { _ in AppHost.Store(database: "d", endpoint: "e") }, exchange: { _ in "0\n" }, reachability: ManualReachability())
        app.capabilities = Capabilities(standard: false)
        app.capabilities?.add("echo") { ["said": $0["word"] ?? ""] }
        app.start()
        app.perform("native:echo", args: ["word": "hi"], on: Route("mailbox"))
        try await wait("the answer") { engine.calls.contains { $0.contains("native:echo") && $0.contains("said=hi") } }
        app.perform("native:none", on: Route("mailbox"))
        try await wait("the refusal") { engine.calls.contains { $0.contains("native:none") && $0.contains("error=") } }
    }

    func testColoursAndNumbersAreWrittenPlainly() {
        XCTAssertEqual(ElementView.written(3), "3")
        XCTAssertEqual(ElementView.written(0.5), "0.5")
        XCTAssertNil(URL(string: "file:///etc/hosts")?.web)
    }
}
