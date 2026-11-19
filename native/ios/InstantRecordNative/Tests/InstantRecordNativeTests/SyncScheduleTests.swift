import XCTest
@testable import InstantRecordNative

final class SyncScheduleTests: XCTestCase {
    private let clock = ManualClock()
    private var passes = 0
    private lazy var schedule = SyncSchedule(pace: .init(delay: 0.3, retry: 2, ceiling: 10, poll: 5), clock: clock) { self.passes += 1 }

    func testRequestsMadeCloseTogetherRunOnePass() {
        schedule.request()
        schedule.request()
        schedule.request()
        clock.fire()

        XCTAssertEqual(1, passes)
        XCTAssertEqual([0.3], clock.planned)
        XCTAssertFalse(clock.waiting)
    }

    func testARequestDuringAPassRunsOneMoreAfterIt() {
        schedule.request()
        clock.fire()
        schedule.request()
        schedule.request()
        XCTAssertEqual(1, passes)

        schedule.finished(ok: true, pending: 0)
        clock.fire()

        XCTAssertEqual(2, passes)
    }

    func testAPassThatCouldNotReachTheServerIsTriedAgainAfterLongerAndLonger() {
        schedule.request()
        for _ in 0..<5 {
            clock.fire()
            schedule.finished(ok: false, pending: 1)
        }

        XCTAssertEqual(5, passes)
        XCTAssertEqual([0.3, 2, 4, 8, 10, 10], clock.planned)
    }

    func testWritesStillWaitingAfterAPassAreTriedAgain() {
        schedule.request()
        clock.fire()
        schedule.finished(ok: true, pending: 2)

        XCTAssertEqual([0.3, 2], clock.planned)
        XCTAssertTrue(clock.waiting)
    }

    func testWritesAServerKeepsRefusingAreTriedLessAndLessOften() {
        schedule.request()
        for _ in 0..<5 {
            clock.fire()
            schedule.finished(ok: true, pending: 2)
        }

        XCTAssertEqual([0.3, 2, 4, 8, 10, 10], clock.planned)

        clock.fire()
        schedule.finished(ok: true, pending: 0)
        schedule.request()
        clock.fire()
        schedule.finished(ok: true, pending: 1)

        XCTAssertEqual(2, clock.planned.last, "the wait did not start over once everything had been sent")
    }

    func testTheNetworkComingBackRunsAPassAtOnceAndStartsTheWaitOver() {
        schedule.request()
        clock.fire()
        schedule.finished(ok: false, pending: 1)
        clock.fire()
        schedule.finished(ok: false, pending: 1)

        schedule.reachable()
        clock.fire()
        schedule.finished(ok: false, pending: 1)

        XCTAssertEqual(3, passes)
        XCTAssertEqual([0.3, 2, 4, 0, 2], clock.planned)
    }

    func testAGoodPassWithNothingWaitingPlansNothingInTheBackground() {
        schedule.request()
        clock.fire()
        schedule.finished(ok: true, pending: 0)

        XCTAssertFalse(clock.waiting)
    }

    func testInFrontAPassRunsAtOnceAndThenOnTheTimer() {
        schedule.front(true)
        clock.fire()
        schedule.finished(ok: true, pending: 0)
        clock.fire()
        schedule.finished(ok: true, pending: 0)

        XCTAssertEqual(2, passes)
        XCTAssertEqual([0, 5, 5], clock.planned)
    }

    func testLeavingTheFrontStopsTheTimer() {
        schedule.front(true)
        clock.fire()
        schedule.finished(ok: true, pending: 0)
        schedule.front(false)

        XCTAssertFalse(clock.waiting)
        XCTAssertEqual(1, passes)
    }

    func testASoonerPassReplacesALaterOne() {
        schedule.front(true)
        clock.fire()
        schedule.finished(ok: true, pending: 0)
        schedule.request()

        XCTAssertEqual([0, 5, 0.3], clock.planned)
    }
}
