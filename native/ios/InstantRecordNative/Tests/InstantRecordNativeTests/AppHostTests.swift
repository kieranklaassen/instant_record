import XCTest
@testable import InstantRecordNative

final class AppHostTests: XCTestCase {
    private let mailbox = Route("mailbox", ["member": "maya", "inbox": "support"])
    private let thread = Route("thread", ["member": "maya", "inbox": "support", "thread": "m2"])
    private let billing = Route("mailbox", ["member": "maya", "inbox": "billing"])
    private var engine = FakeEngine()
    private let clock = ManualClock()
    private let network = ManualReachability()
    private var fetched: [String] = []
    private let lock = NSLock()
    private let support = "http://example.test/maya-support"
    private let renderMailbox = "render mailbox inbox=support,member=maya"

    /// A host whose network is `answer`. Every request it makes is kept, as "METHOD path".
    private func host(leaveWithin: TimeInterval = 1, answer: @escaping (String) -> String = { _ in "200\n" }) -> AppHost {
        let host = AppHost(engine: engine, root: mailbox, store: { route in
            let place = (route.params["member"] ?? "") + "-" + (route.params["inbox"] ?? "")
            return AppHost.Store(database: "/tmp/\(place).sqlite3", endpoint: "http://example.test/" + place)
        }, leaveWithin: leaveWithin, exchange: { request in
            self.lock.withLock { self.fetched.append(String(request.prefix { $0 != "\n" }).replacingOccurrences(of: "http://example.test", with: "")) }
            return answer(request)
        }, clock: clock, reachability: network)
        host.start()
        pass(host)
        return host
    }

    /// Let the planned sync pass run, and its results land.
    private func pass(_ host: AppHost) {
        host.settle()
        clock.fire()
        host.settle()
    }

    func testItDrawsFromTheDatabaseBeforeItSyncsAndFetchesOffTheAppsThread() {
        let host = host()

        XCTAssertEqual(["boot /tmp/maya-support.sqlite3", renderMailbox, "sync_plan", "sync " + support, renderMailbox], engine.calls)
        XCTAssertEqual(["GET /maya-support/events?after=7&window=0"], fetched)
        XCTAssertEqual(["GET \(support)/events?after=7&window=0 -> 200"], engine.answered, "the app was not answered from what was fetched")
        XCTAssertEqual(["m2", "m1"], host.screens[mailbox]?.children.map(\.id))
        XCTAssertNil(host.status.message)
    }

    func testADatabaseThatHasNeverSyncedIsFetchedInFullAndSaysSoMeanwhile() {
        engine.bootstrapped = false
        let host = AppHost(engine: engine, root: mailbox, store: { _ in AppHost.Store(database: "/tmp/new.sqlite3", endpoint: self.support) },
                           exchange: { _ in "200\n" }, clock: clock, reachability: network)
        host.start()
        host.settle()
        XCTAssertTrue(host.fetchingFirst)

        pass(host)

        XCTAssertFalse(host.fetchingFirst)
        XCTAssertEqual(["GET \(support)/bootstrap -> 200"], engine.answered)
    }

    func testATapIsPerformedWithItsArgumentsThenDrawnThenSynced() {
        let host = host()
        engine.calls = []
        fetched = []

        host.perform("archive", args: ["id": "m2"], on: mailbox)
        pass(host)

        XCTAssertEqual(["action mailbox inbox=support,member=maya archive id=m2", renderMailbox, "sync_plan", "sync " + support, renderMailbox], engine.calls)
        XCTAssertEqual(["POST /maya-support/mutations", "GET /maya-support/events?after=7&window=0"], fetched)
        XCTAssertEqual(["m1"], host.screens[mailbox]?.children.map(\.id))
        XCTAssertNil(host.status.message)
    }

    func testATapMadeWhileAPassIsFetchingIsPerformedAndDrawnBeforeThePassEnds() {
        let fetching = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let hold = Flag()
        let host = host(answer: { _ in
            if hold.on {
                fetching.signal()
                release.wait()
            }
            return "200\n"
        })
        engine.calls = []
        hold.on = true

        host.sync()
        clock.fire()
        fetching.wait()
        host.perform("archive", args: ["id": "m2"], on: mailbox)
        let drawn = expectation(description: "the row left while the network was still out")
        DispatchQueue.global().async {
            while self.engine.calls.filter({ $0 == self.renderMailbox }).isEmpty { usleep(1000) }
            drawn.fulfill()
        }
        wait(for: [drawn], timeout: 5)
        XCTAssertFalse(engine.calls.contains("sync " + support), "the tap waited for the network")
        hold.on = false
        release.signal()
        pass(host)

        XCTAssertEqual(["sync_plan", "action mailbox inbox=support,member=maya archive id=m2", renderMailbox, "sync " + support], Array(engine.calls.prefix(4)))
        XCTAssertEqual(0, host.status.pending, "the tap's write did not go out with a pass of its own")
    }

    func testDuringAPassTheAppIsAnsweredOnlyFromWhatWasFetched() {
        let fetching = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let hold = Flag()
        let host = host(answer: { _ in
            if hold.on {
                fetching.signal()
                release.wait()
            }
            return "200\n"
        })
        engine.answered = []
        fetched = []
        hold.on = true

        // The pass plans with nothing to send. A write is made while it fetches.
        host.sync()
        clock.fire()
        fetching.wait()
        host.perform("archive", args: ["id": "m2"], on: mailbox)
        hold.on = false
        release.signal()
        host.settle()

        XCTAssertEqual(["POST \(support)/mutations -> 0"], engine.answered, "the app was given an answer nobody fetched for that request")
        XCTAssertEqual(["GET /maya-support/events?after=7&window=0"], fetched)
        XCTAssertFalse(host.status.offline, "a request nobody fetched is not the network being down")

        pass(host)

        XCTAssertEqual(["POST /maya-support/mutations", "GET /maya-support/events?after=7&window=0"], Array(fetched.suffix(2)))
        XCTAssertEqual(0, host.status.pending)
    }

    func testAValueWithANewlineASlashAndAQuoteReachesTheAppAsItIs() {
        let odd = "a/b\n\"c\""
        let input = Route("thread", ["thread": odd]).input(action: "reply", args: ["id": odd], values: ["body": odd])
        let object = try? JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any]

        XCTAssertEqual(odd, (object?["params"] as? [String: String])?["thread"])
        XCTAssertEqual(odd, (object?["args"] as? [String: String])?["id"])
        XCTAssertEqual(odd, (object?["values"] as? [String: String])?["body"])
        XCTAssertEqual(["reply", "thread"], [object?["action"] as? String, object?["screen"] as? String])
        XCTAssertNil((try? JSONSerialization.jsonObject(with: Data(Route("thread").input().utf8)) as? [String: Any])?["action"])
    }

    func testTwoRoutesWithTheSameParamsAreTheSameRoute() {
        XCTAssertEqual(Route("mailbox", ["inbox": "support", "member": "maya"]), mailbox)
        XCTAssertNotEqual(Route("mailbox", ["inbox": "support", "member": "maya", "filter": "unread"]), mailbox)
        XCTAssertEqual(mailbox.input(), Route("mailbox", ["inbox": "support", "member": "maya"]).input())
    }

    func testWhatIsTypedGoesWithTheNextActionAsValuesAndIsThenForgotten() {
        let host = host()
        host.path = [thread]
        host.settle()
        engine.calls = []
        host.typed[thread] = ["body": "On it.\n\"Now\""]

        host.perform("reply", on: thread)
        host.settle()

        XCTAssertEqual("action thread inbox=support,member=maya,thread=m2 reply  values body=On it.\n\"Now\"", engine.calls.first)
        XCTAssertNil(host.typed[thread])
    }

    func testWhatIsTypedIsKeptWhenTheActionFailedAndWhenTheScreenIsRedrawn() {
        let host = host()
        host.path = [thread]
        host.settle()
        host.typed[thread] = ["body": "Draft"]
        engine.raises = ["action"]

        host.perform("reply", on: thread)
        host.sync()
        pass(host)

        XCTAssertEqual(["body": "Draft"], host.typed[thread])
    }

    func testSeveralTapsCloseTogetherSyncOnce() {
        let host = host()
        engine.calls = []

        host.perform("archive", args: ["id": "m2"], on: mailbox)
        host.perform("archive", args: ["id": "m1"], on: mailbox)
        host.sync()
        pass(host)

        XCTAssertEqual(1, engine.calls.filter { $0 == "sync " + support }.count)
        XCTAssertEqual(2, engine.calls.filter { $0.hasPrefix("action") }.count)
    }

    func testAPushedScreenIsToldItOpenedBeforeItIsDrawnAndASyncFollows() {
        let host = host()
        engine.calls = []

        host.path.append(thread)
        host.settle()

        XCTAssertEqual(["action thread inbox=support,member=maya,thread=m2 open", renderMailbox, "render thread inbox=support,member=maya,thread=m2"], engine.calls)
        XCTAssertEqual("thread", host.screens[thread]?.text)
        XCTAssertTrue(clock.waiting, "opening may write, and nothing was asked to carry it")
    }

    func testGoingBackTellsNobodyAndDropsTheScreenAndWhatWasTypedThere() {
        let host = host()
        host.path = [thread]
        host.settle()
        host.typed[thread] = ["body": "Draft"]
        engine.calls = []

        host.path = []
        host.settle()

        XCTAssertEqual([renderMailbox], engine.calls)
        XCTAssertNil(host.screens[thread])
        XCTAssertNil(host.typed[thread])
    }

    func testAScreenBroughtUpAsASheetIsToldItOpenedDrawnWithItsParamsAndForgottenWhenPutAway() {
        let host = host()
        let feedback = Route("feedback", ["member": "maya", "inbox": "support"])
        engine.calls = []

        host.sheet = feedback
        host.settle()

        XCTAssertEqual(["action feedback inbox=support,member=maya open", renderMailbox, "render feedback inbox=support,member=maya"], engine.calls)
        XCTAssertEqual("feedback", host.screens[feedback]?.text)
        XCTAssertEqual([], host.path, "a sheet is not pushed")
        XCTAssertNotNil(host.screens[mailbox], "the screen under the sheet is kept")

        host.typed[feedback] = ["note": "Draft"]
        engine.calls = []
        host.sheet = nil
        host.settle()

        XCTAssertEqual([renderMailbox], engine.calls)
        XCTAssertNil(host.screens[feedback])
        XCTAssertNil(host.typed[feedback])
    }

    func testAnotherInboxPutsTheSheetAway() {
        let host = host()
        host.sheet = Route("feedback", ["member": "maya", "inbox": "support"])
        host.settle()

        host.replace(with: billing)
        pass(host)

        XCTAssertNil(host.sheet)
        XCTAssertEqual([billing], Array(host.screens.keys))
    }

    /// Let the main queue run until `holds`, for at most a few seconds.
    private func until(_ holds: () -> Bool) {
        let limit = Date().addingTimeInterval(3)
        while !holds(), Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }

    func testWithNothingWaitingAnotherInboxIsOpenedAndDrawnBeforeAnythingIsFetched() {
        let hold = Flag(), release = DispatchSemaphore(value: 0)
        let host = host(answer: { _ in
            if hold.on { release.wait() }
            return "200\n"
        })
        host.path = [thread]
        host.settle()
        engine.push = ""
        engine.calls = []
        fetched = []
        hold.on = true

        // Every fetch from here on hangs. The rows must not wait for one.
        host.replace(with: billing)
        until { host.screens[self.billing] != nil }

        XCTAssertEqual(billing, host.root)
        XCTAssertEqual([], host.path)
        XCTAssertEqual(["b1"], host.screens[billing]?.children.map(\.id))
        XCTAssertEqual(["open /tmp/maya-billing.sqlite3", "render mailbox inbox=billing,member=maya"], Array(engine.calls.prefix(2)))
        XCTAssertFalse(lock.withLock { fetched }.contains { $0.contains("maya-support") }, "the inbox being left was synced first")
        XCTAssertFalse(engine.calls.contains { $0.hasPrefix("sync ") }, "a sync ended before the rows were drawn")

        hold.on = false
        (0..<4).forEach { _ in release.signal() }
        pass(host)

        XCTAssertEqual("sync http://example.test/maya-billing", engine.calls.filter { $0.hasPrefix("sync ") }.last)
        XCTAssertEqual([billing], Array(host.screens.keys))
    }

    func testWritesWaitingGetOneShortPassAndTheSwitchHappensWhateverComesOfIt() {
        let hold = Flag(), release = DispatchSemaphore(value: 0)
        let host = host(leaveWithin: 0.2, answer: { _ in
            if hold.on { release.wait() }
            return "200\n"
        })
        hold.on = true
        host.perform("archive", args: ["id": "m2"], on: mailbox)
        until { self.engine.push != "" }
        engine.calls = []
        fetched = []

        // The server never answers. The switch must not wait for it.
        let asked = Date()
        host.replace(with: billing)
        until { host.root == self.billing && host.screens[self.billing] != nil }
        let took = Date().timeIntervalSince(asked)

        XCTAssertEqual(billing, host.root)
        XCTAssertEqual(["b1"], host.screens[billing]?.children.map(\.id))
        XCTAssertLessThan(took, 1, "leaving waited for the network")
        XCTAssertGreaterThan(took, 0.15, "the waiting writes were given no time at all")
        XCTAssertTrue(lock.withLock { fetched }.contains("POST /maya-support/mutations"), "the waiting write was not tried")
        XCTAssertTrue(engine.calls.contains("open /tmp/maya-billing.sqlite3"))
        XCTAssertFalse(engine.calls.contains("sync http://example.test/maya-support"), "answers for the inbox that was left were handed to the app")

        hold.on = false
        (0..<6).forEach { _ in release.signal() }
        host.settle()
    }

    func testWritesWaitingGoOutBeforeTheSwitchWhenTheServerAnswersInTime() {
        let host = host()
        host.perform("archive", args: ["id": "m2"], on: mailbox)
        host.settle()
        engine.calls = []
        fetched = []

        host.replace(with: billing)
        pass(host)

        XCTAssertEqual(["sync_plan", "sync " + support, "open /tmp/maya-billing.sqlite3"], Array(engine.calls.prefix(3)))
        XCTAssertEqual("POST /maya-support/mutations", lock.withLock { fetched }.first)
        XCTAssertEqual(billing, host.root)
    }

    func testADatabaseThatHasNeverSyncedSaysSoOnArrivalAndOneThatHasDoesNot() {
        let host = host()
        engine.bootstrapped = false

        host.replace(with: billing)
        host.settle()
        XCTAssertTrue(host.fetchingFirst)

        pass(host)
        XCTAssertFalse(host.fetchingFirst)

        host.replace(with: mailbox)
        host.settle()
        XCTAssertFalse(host.fetchingFirst, "a file that has synced before has its mail to show")
    }

    func testAnotherViewOfTheSameDataDoesNotOpenItAgain() {
        let host = host()
        engine.calls = []
        let unread = Route("mailbox", ["member": "maya", "inbox": "support", "filter": "unread"])

        host.replace(with: unread)
        pass(host)

        XCTAssertEqual(unread, host.root)
        XCTAssertFalse(engine.calls.contains { $0.hasPrefix("open") })
        XCTAssertEqual("render mailbox filter=unread,inbox=support,member=maya", engine.calls.first)
    }

    func testADatabaseThatWillNotOpenIsReportedAndTheScreenStaysWhereItWas() {
        let host = host()
        engine.calls = []

        host.replace(with: Route("mailbox", ["member": "maya", "inbox": "locked"]))
        pass(host)

        XCTAssertEqual("ArgumentError: No screen named nowhere", host.status.error)
        XCTAssertEqual(mailbox, host.root)
        XCTAssertEqual(["m2", "m1"], host.screens[mailbox]?.children.map(\.id))
    }

    func testAnAppThatDidNotComeUpStillSyncsOnceADatabaseOpens() {
        engine.boots = false
        let host = host()
        XCTAssertFalse(engine.calls.contains { $0.hasPrefix("sync ") })
        engine.calls = []

        host.replace(with: billing)
        pass(host)

        XCTAssertEqual("sync http://example.test/maya-billing", engine.calls.filter { $0.hasPrefix("sync ") }.last, "the schedule is still waiting for a pass that never ran")
    }

    func testAPullSyncsAndReturnsOnceThePassHasEndedAndTheScreensAreDrawn() async {
        let host = await MainActor.run { self.host() }
        engine.calls = []

        let pull = Task { await host.refresh() }
        // The pull plans a pass. Wait until it has, then let the time pass.
        for _ in 0..<400 where await !MainActor.run(body: { self.clock.waiting }) { try? await Task.sleep(nanoseconds: 5_000_000) }
        await MainActor.run { self.clock.fire() }
        let returned = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await pull.value; return true }
            group.addTask { try? await Task.sleep(nanoseconds: 5_000_000_000); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        XCTAssertTrue(returned, "the pull never came back")
        XCTAssertEqual(["sync_plan", "sync " + support, renderMailbox], engine.calls)
    }

    func testOfflineWithAWriteWaitingIsSaidAndTriedAgainUntilItGoes() {
        var reachable = true
        let host = host(answer: { _ in reachable ? "200\n" : Transport.offline })
        reachable = false

        host.perform("archive", args: ["id": "m2"], on: mailbox)
        pass(host)

        XCTAssertEqual(AppHost.Status(pending: 1, offline: true, error: ""), host.status)
        XCTAssertEqual("Offline. Changes will send when you are back.", host.status.message)
        XCTAssertEqual(["m1"], host.screens[mailbox]?.children.map(\.id), "the row came back")
        XCTAssertEqual(5, clock.planned.last, "nothing is planned to try again")

        pass(host)
        XCTAssertEqual(10, clock.planned.last)

        reachable = true
        pass(host)

        XCTAssertEqual(AppHost.Status(), host.status)
        XCTAssertFalse(clock.waiting)
    }

    func testTheNetworkComingBackSyncsWithoutATouch() {
        var reachable = false
        let host = host(answer: { _ in reachable ? "200\n" : Transport.offline })
        engine.calls = []
        reachable = true

        network.comeBack()
        pass(host)

        XCTAssertTrue(engine.calls.contains("sync " + support))
        XCTAssertFalse(host.status.offline)
        XCTAssertEqual(0, clock.planned.last)
    }

    func testAServerThatAnswersAndRefusesIsNamedAndAskedLessOften() {
        var status = "401"
        let host = host(answer: { _ in status + "\nno" })
        XCTAssertEqual("Could not sync: GET /events?after=7&window=0 answered 401", host.status.message)

        host.perform("archive", args: ["id": "m2"], on: mailbox)
        pass(host)

        XCTAssertEqual("Could not sync: POST /mutations answered 401", host.status.syncError)
        XCTAssertEqual("", host.status.error)
        XCTAssertFalse(host.status.offline, "a server that answers is not offline")
        XCTAssertEqual(1, host.status.pending)
        XCTAssertEqual([0.3, 5, 0.3, 10], clock.planned)

        status = "200"
        pass(host)

        XCTAssertEqual(AppHost.Status(), host.status)
    }

    func testAnErrorCanBeDismissedAndComesFirstOnTheLine() {
        XCTAssertEqual("Boom", AppHost.Status(pending: 2, offline: true, error: "Boom", syncError: "Could not sync").message)
        XCTAssertEqual("Could not sync", AppHost.Status(pending: 2, offline: true, error: "", syncError: "Could not sync").message)
        XCTAssertEqual("Offline. Changes will send when you are back.", AppHost.Status(pending: 2, offline: true, error: "").message)
        XCTAssertEqual("2 changes waiting to send", AppHost.Status(pending: 2, offline: false, error: "").message)
        XCTAssertEqual("1 change waiting to send", AppHost.Status(pending: 1, offline: false, error: "").message)
        XCTAssertNil(AppHost.Status().message)

        let host = host()
        engine.raises = ["action"]
        host.perform("archive", args: ["id": "m2"], on: mailbox)
        host.settle()
        XCTAssertEqual("ArgumentError: No screen named nowhere", host.status.message)

        host.dismissError()

        XCTAssertNil(host.status.message)
    }

    func testWhatATapReportedIsStillShownAfterTheNextPassSucceeds() {
        let host = host()
        engine.raises = ["action"]

        host.perform("archive", args: ["id": "m2"], on: mailbox)
        host.settle()
        engine.raises = []
        pass(host)
        host.sync()
        pass(host)

        XCTAssertEqual("ArgumentError: No screen named nowhere", host.status.message, "a pass that went well took the tap's error away")
        XCTAssertEqual("", host.status.syncError)

        host.dismissError()

        XCTAssertNil(host.status.message)
    }

    func testASyncErrorIsClearedByThePassThatSucceedsAndAScreenErrorByTheDrawThatDoes() {
        var status = "500"
        let host = host(answer: { _ in status + "\n" })
        XCTAssertEqual("Could not sync: GET /events?after=7&window=0 answered 500", host.status.message)
        engine.raises = ["render"]
        host.sync()
        pass(host)
        XCTAssertEqual("ArgumentError: No screen named nowhere", host.status.message, "what is wrong with the screen comes first")

        engine.raises = []
        status = "200"
        host.sync()
        pass(host)

        XCTAssertNil(host.status.message)
    }

    func testAScreenThatCannotBeDrawnKeepsTheLastOneAndSaysWhy() {
        let host = host()
        engine.raises = ["render"]

        host.perform("archive", args: ["id": "m2"], on: mailbox)
        host.settle()

        XCTAssertEqual("ArgumentError: No screen named nowhere", host.status.error)
        XCTAssertEqual(["m2", "m1"], host.screens[mailbox]?.children.map(\.id))
    }

    func testATreeThatDoesNotDecodeKeepsTheLastOneAndSaysWhy() {
        let host = host()
        engine.unreadable = true

        host.perform("archive", args: ["id": "m2"], on: mailbox)
        host.settle()

        XCTAssertEqual("The screen mailbox could not be read.", host.status.error)
        XCTAssertEqual(["m2", "m1"], host.screens[mailbox]?.children.map(\.id))
    }

    func testTheNextPageIsFetchedOffTheAppsThreadAndHandedToItWithItsKey() {
        let host = host(answer: { request in request.contains("/records?") ? "200\n{\"records\":[],\"has_more\":false}" : "200\n" })
        engine.calls = []
        fetched = []

        host.loadMore("older:support", query: "type=MailEntry&before_id=m1")
        XCTAssertEqual(.loading, host.paging["older:support"])
        host.loadMore("older:support", query: "type=MailEntry&before_id=m1")
        host.settle()

        XCTAssertEqual(["GET /maya-support/records?type=MailEntry&before_id=m1"], fetched, "it was fetched twice")
        XCTAssertEqual("history", engine.calls.first?.prefix(7).description)
        let handed = try? JSONSerialization.jsonObject(with: Data((engine.calls.first ?? "").dropFirst(8).utf8)) as? [String: String]
        XCTAssertEqual(["key": "older:support", "response": "{\"records\":[],\"has_more\":false}"], handed)
        XCTAssertEqual(renderMailbox, engine.calls.last)
        XCTAssertNil(host.paging["older:support"])
    }

    func testAPageThatCouldNotBeFetchedSaysSoAndCanBeAskedForAgain() {
        var reachable = false
        let host = host(answer: { request in request.contains("/records?") && !reachable ? Transport.offline : "200\n{}" })
        engine.calls = []

        host.loadMore("older:support", query: "type=MailEntry")
        host.settle()
        XCTAssertEqual(.failed, host.paging["older:support"])
        XCTAssertFalse(engine.calls.contains { $0.hasPrefix("history") })

        reachable = true
        host.loadMore("older:support", query: "type=MailEntry")
        host.settle()

        XCTAssertNil(host.paging["older:support"])
        XCTAssertTrue(engine.calls.contains { $0.hasPrefix("history") })
    }

    func testAnEventFromTheServerIsHandedToTheAppAndDrawnWhenItChangedSomething() async {
        let host = host()
        engine.calls = []
        engine.rows = ["m3", "m2", "m1"]
        engine.noticeAfter = ["stream": "records_changed\nMailEntry:m3"]

        await host.feed("id: 8\nevent: change\ndata: {}\n\n", from: AppHost.Store(database: "/tmp/maya-support.sqlite3", endpoint: support))
        host.settle()

        XCTAssertEqual(["stream id: 8\nevent: change\ndata: {}\n\n", renderMailbox], engine.calls)
        XCTAssertEqual(["m3", "m2", "m1"], host.screens[mailbox]?.children.map(\.id))
    }

    func testAnEventReadForADatabaseThatWasLeftIsNotGivenToTheOneNowOpen() async {
        let host = await MainActor.run { () -> AppHost in
            let host = self.host()
            host.replace(with: self.billing)
            self.pass(host)
            return host
        }
        engine.calls = []

        await host.feed("id: 8\nevent: change\ndata: {}\n\n", from: AppHost.Store(database: "/tmp/maya-support.sqlite3", endpoint: support))
        await host.feed("id: 9\nevent: change\ndata: {}\n\n", from: AppHost.Store(database: "/tmp/maya-billing.sqlite3", endpoint: "http://example.test/maya-billing"))

        XCTAssertEqual(["stream id: 9\nevent: change\ndata: {}\n\n"], engine.calls.filter { $0.hasPrefix("stream") })
    }

    func testAnEngineThatKeepsNothingOnThePhoneIsNeverAskedToSync() {
        engine.syncs = false
        let host = host()
        engine.calls = []

        host.perform("archive", args: ["id": "m2"], on: mailbox)
        pass(host)

        XCTAssertEqual(["action mailbox inbox=support,member=maya archive id=m2", renderMailbox, renderMailbox], engine.calls)
        XCTAssertTrue(fetched.isEmpty)
        XCTAssertNil(host.status.message)
    }

    func testAHeldMutationPlansItsNextSyncPassAtNextReleaseMs() {
        engine.nextReleaseMs = 4500
        let host = host()

        XCTAssertEqual(4.5, clock.planned.last)
        XCTAssertTrue(clock.waiting)
        XCTAssertEqual(0, host.status.pending)
        XCTAssertNil(host.status.message)

        engine.nextReleaseMs = nil
        pass(host)
        XCTAssertFalse(clock.waiting)
    }

    func testColdStartHydratesFromPrebuiltShellViaIrOpenAndCatchesUpFromItsCursor() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ir-shell-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("support.sqlite3").path
        let sqliteBytes = Data("SQLite format 3\0payload".utf8)
        let fp = "fp123456"
        engine.bootstrapped = false
        engine.shellFingerprint = fp
        engine.rows = []
        engine.onOpen = { path in
            if path.contains(".shell.") || FileManager.default.contents(atPath: path) == sqliteBytes {
                self.engine.bootstrapped = true
                self.engine.cursorValue = 42
                self.engine.identityValue = "id-ada"
                self.engine.rows = ["shell-1", "shell-2"]
            }
            return true
        }

        var downloaded: [String] = []
        let host = AppHost(
            engine: engine,
            root: mailbox,
            store: { _ in AppHost.Store(database: dbPath, endpoint: self.support) },
            exchange: { request in
                let line = String(request.prefix { $0 != "\n" }).replacingOccurrences(of: "http://example.test", with: "")
                self.lock.withLock { self.fetched.append(line) }
                if line.contains("/shell?fingerprint=\(fp)") {
                    return "200\n{\"cursor\":42,\"identity\":\"id-ada\",\"path\":\"/shell/file?token=signed\"}"
                }
                return "200\n"
            },
            download: { url in
                self.lock.withLock { downloaded.append(url) }
                return (200, sqliteBytes)
            },
            clock: clock,
            reachability: network
        )
        host.start()
        host.settle()
        XCTAssertTrue(host.fetchingFirst)

        // First pass hydrates via shell + ir_open, draws immediately, and schedules catch-up.
        pass(host)

        XCTAssertFalse(host.fetchingFirst)
        XCTAssertEqual(["shell-1", "shell-2"], host.screens[mailbox]?.children.map(\.id))
        XCTAssertEqual([support + "/shell/file?token=signed"], downloaded)
        XCTAssertEqual(sqliteBytes, FileManager.default.contents(atPath: dbPath))
        XCTAssertFalse(fetched.contains { $0.contains("/bootstrap") }, "bootstrap should not run when shell hydrated")

        // Follow-up pass catches up from the shell's cursor with its identity.
        pass(host)
        XCTAssertEqual(["GET /maya-support/shell?fingerprint=\(fp)", "GET /maya-support/events?after=42&window=0&identity=id-ada"], fetched)
    }

    func testColdStartFallsBackToBootstrapWhenShellIsMissingOrInvalid() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ir-shell-fallback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("support.sqlite3").path
        let fp = "fp999"

        // Case 1: 204 No Content -> falls back directly to /bootstrap.
        engine.bootstrapped = false
        engine.shellFingerprint = fp
        let host204 = AppHost(
            engine: engine,
            root: mailbox,
            store: { _ in AppHost.Store(database: dbPath, endpoint: self.support) },
            exchange: { request in
                let line = String(request.prefix { $0 != "\n" }).replacingOccurrences(of: "http://example.test", with: "")
                self.lock.withLock { self.fetched.append(line) }
                return line.contains("/shell?") ? "204\n" : "200\n"
            },
            download: { _ in XCTFail("download should not be called on 204"); return nil },
            clock: clock,
            reachability: network
        )
        host204.start()
        pass(host204)
        XCTAssertEqual(["GET /maya-support/shell?fingerprint=\(fp)", "GET /maya-support/bootstrap"], fetched)

        // Case 2: cursor mismatch after ir_open -> rolls back to store.database and falls back to /bootstrap.
        fetched = []
        engine.bootstrapped = false
        engine.cursorValue = 7
        engine.onOpen = { path in
            if path.contains(".shell.") {
                self.engine.bootstrapped = true
                self.engine.cursorValue = 999 // mismatches grant cursor 42
            } else {
                self.engine.bootstrapped = false
                self.engine.cursorValue = 0
            }
            return true
        }
        let hostMismatch = AppHost(
            engine: engine,
            root: mailbox,
            store: { _ in AppHost.Store(database: dbPath, endpoint: self.support) },
            exchange: { request in
                let line = String(request.prefix { $0 != "\n" }).replacingOccurrences(of: "http://example.test", with: "")
                self.lock.withLock { self.fetched.append(line) }
                if line.contains("/shell?") {
                    return "200\n{\"cursor\":42,\"path\":\"/shell/file?token=signed\"}"
                }
                return "200\n"
            },
            download: { _ in (200, Data("SQLite format 3\0bad-cursor".utf8)) },
            clock: clock,
            reachability: network
        )
        hostMismatch.start()
        pass(hostMismatch)
        XCTAssertEqual(["GET /maya-support/shell?fingerprint=\(fp)", "GET /maya-support/bootstrap"], fetched)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(leftovers.filter { $0.contains(".shell.") }.isEmpty, "staging temp files must be cleaned up")
    }

    func testColdStartSkipsShellWhenPendingLocalWritesExist() {
        engine.bootstrapped = false
        engine.shellFingerprint = "fp-pending"
        engine.push = "{\"mutations\":[\"archive\"]}"
        let host = AppHost(
            engine: engine,
            root: mailbox,
            store: { _ in AppHost.Store(database: "/tmp/pending-shell.sqlite3", endpoint: self.support) },
            exchange: { request in
                let line = String(request.prefix { $0 != "\n" }).replacingOccurrences(of: "http://example.test", with: "")
                self.lock.withLock { self.fetched.append(line) }
                return "200\n"
            },
            download: { _ in XCTFail("shell must not overwrite pending local writes"); return nil },
            clock: clock,
            reachability: network
        )
        host.start()
        pass(host)
        XCTAssertFalse(fetched.contains { $0.contains("/shell?") })
        XCTAssertTrue(fetched.contains("POST /maya-support/mutations"))
        XCTAssertTrue(fetched.contains("GET /maya-support/bootstrap"))
    }
}
