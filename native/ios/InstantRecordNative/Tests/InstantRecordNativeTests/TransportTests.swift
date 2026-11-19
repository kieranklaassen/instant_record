import XCTest
@testable import InstantRecordNative

final class TransportTests: XCTestCase {
    func testARequestWithATokenSaysWhoIsAskingOnGetAndPost() {
        let transport = Transport(token: "abc.def")

        let get = transport.request("GET http://example.test/email/sync/maya/support/events?after=3\n")
        let post = transport.request("POST http://example.test/email/sync/maya/support/mutations\n{\"mutations\":[]}")

        XCTAssertEqual("Bearer abc.def", get?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual("Bearer abc.def", post?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(["GET", "POST"], [get?.httpMethod, post?.httpMethod])
        XCTAssertEqual("{\"mutations\":[]}", post?.httpBody.map { String(decoding: $0, as: UTF8.self) })
        XCTAssertEqual("application/json", post?.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertNil(get?.httpBody)
    }

    func testARequestWithNoTokenCarriesNoAuthorization() {
        XCTAssertNil(Transport().request("GET http://example.test/events\n")?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(Transport(token: "").request("GET http://example.test/events\n")?.value(forHTTPHeaderField: "Authorization"))
    }

    func testWithNoNetworkTheAppIsToldSoAndNotKeptWaiting() {
        // Nothing listens on port 9, so the connection is refused at once.
        let transport = Transport(timeout: 2)

        XCTAssertEqual(Transport.offline, transport.exchange("GET http://127.0.0.1:9/events\n"))
        XCTAssertEqual(Transport.offline, transport.exchange("nonsense"))
    }

    func testTheDevEngineAsksTheServerAndSaysWhenItDoesNotAnswer() {
        let engine = HTTPEngine(server: "http://127.0.0.1:9/instant_record", transport: Transport(timeout: 2))

        XCTAssertTrue(engine.boot(database: "") && engine.open(database: ""))
        XCTAssertNil(engine.call("render", "{\"screen\":\"mailbox\",\"params\":{}}"))
        XCTAssertEqual("The server at http://127.0.0.1:9/instant_record did not answer.", engine.error())
        XCTAssertEqual("unchanged pending=0", engine.call("sync", "http://example.test"))
    }
}
