import XCTest
@testable import InstantRecordNative

final class TransportTests: XCTestCase {
    func testEveryRequestPassesThroughWhatTheAppPreparesItWith() {
        let transport = Transport(prepare: { $0.setValue("Bearer abc.def", forHTTPHeaderField: "Authorization") })

        let get = transport.request("GET http://example.test/instant_record/events?after=3\nX-Instant-Record-Partition: mailbox_id:support\n\n")
        let post = transport.request("POST http://example.test/instant_record/mutations\nX-Instant-Record-Partition: mailbox_id:support\n\n{\"mutations\":[]}")

        XCTAssertEqual("Bearer abc.def", get?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual("Bearer abc.def", post?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual("mailbox_id:support", get?.value(forHTTPHeaderField: "X-Instant-Record-Partition"))
        XCTAssertEqual("mailbox_id:support", post?.value(forHTTPHeaderField: "X-Instant-Record-Partition"))
        XCTAssertEqual(["GET", "POST"], [get?.httpMethod, post?.httpMethod])
        XCTAssertEqual("{\"mutations\":[]}", post?.httpBody.map { String(decoding: $0, as: UTF8.self) })
        XCTAssertEqual("application/json", post?.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertNil(get?.httpBody)
    }

    func testARequestNobodyPreparedCarriesNoAuthorization() {
        XCTAssertNil(Transport().request("GET http://example.test/events\n")?.value(forHTTPHeaderField: "Authorization"))
    }

    func testAnAnswerIsReadApartIntoItsStatusAndBody() {
        XCTAssertEqual([200, 204, 401, 0], ["200\n{}", "204\n", "401\nno", Transport.offline].map { Reply($0).status })
        XCTAssertEqual([true, true, false, false], ["200\n{}", "204\n", "401\nno", Transport.offline].map { Reply($0).ok })
        XCTAssertEqual("line one\nline two", Reply("200\nline one\nline two").body)
    }

    func testWithNoNetworkTheAppIsToldSoAndNotKeptWaiting() {
        // Nothing listens on port 9, so the connection is refused at once.
        let transport = Transport(timeout: 2)

        XCTAssertEqual(Transport.offline, transport.exchange("GET http://127.0.0.1:9/events\n"))
        XCTAssertEqual(Transport.offline, transport.exchange("nonsense"))
        XCTAssertNil(transport.download("http://127.0.0.1:9/shell/file?token=x"))
        XCTAssertNil(transport.download("not-a-url"))
    }

    func testTheDevEngineAsksTheServerAndSaysWhenItDoesNotAnswer() {
        let engine = HTTPEngine(server: "http://127.0.0.1:9/instant_record", transport: Transport(timeout: 2))

        XCTAssertTrue(engine.boot(database: "") && engine.open(database: ""))
        XCTAssertNil(engine.call("render", "{\"screen\":\"mailbox\",\"params\":{}}"))
        XCTAssertEqual("The server at http://127.0.0.1:9/instant_record did not answer.", engine.error())
        XCTAssertEqual("", engine.call("sync", "http://example.test"))
        XCTAssertFalse(engine.syncs)
    }
}
