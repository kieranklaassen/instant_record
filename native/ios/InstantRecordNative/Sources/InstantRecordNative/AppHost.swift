import Combine
import Foundation

/// Runs a compiled InstantRecord app behind its screens: boots it, keeps the
/// screens on show drawn from its local database, sends it taps and keeps it
/// in sync with the server. It knows a screen only by name and params.
///
/// Every call into the app runs on one thread, and none of them waits for
/// the network. A sync pass asks the app what it needs, fetches that on
/// another queue, and only then hands the answers over, so a tap made
/// meanwhile is performed and drawn first.
public final class AppHost: ObservableObject {
    /// Where a first screen keeps its data: the SQLite file, the sync endpoint,
    /// and any per-store headers (e.g. X-Instant-Record-Partition).
    public struct Store: Equatable {
        public let database: String
        public let endpoint: String
        public let headers: [String: String]

        public init(database: String, endpoint: String, headers: [String: String] = [:]) {
            self.database = database
            self.endpoint = endpoint
            self.headers = headers
        }
    }

    /// What the app's one line says: what went wrong with a tap or a screen,
    /// then what went wrong with sync, then whether it is offline, then how
    /// many changes wait.
    public struct Status: Equatable {
        public var pending = 0
        public var offline = false
        /// What a tap, an opened screen or a draw reported. It stays until it
        /// is dismissed, or, for a screen that could not be drawn, until it can.
        public var error = ""
        /// What the last sync pass reported. The next pass that succeeds clears it.
        public var syncError = ""

        public var message: String? {
            if !error.isEmpty { return error }
            if !syncError.isEmpty { return syncError }
            if offline { return "Offline. Changes will send when you are back." }
            if pending > 0 { return pending == 1 ? "1 change waiting to send" : "\(pending) changes waiting to send" }
            return nil
        }
    }

    /// How a list's next page stands, by the key its `more` element gave.
    public enum Paging: Equatable {
        case loading, failed
    }

    /// The screens on show, as the app last described them.
    @Published public private(set) var screens: [Route: Node] = [:]
    @Published public private(set) var status = Status()
    /// Quarantined offline writes the server rejected or LWW overwrote.
    @Published public private(set) var notices: [SyncNotice] = []
    /// True from launch until the first sync of a database that has never
    /// synced has ended: there is nothing to show yet, and that is not "empty".
    @Published public private(set) var fetchingFirst = false
    @Published public private(set) var paging: [String: Paging] = [:]
    /// What has been typed into each screen's fields and not yet sent.
    @Published public var typed: [Route: [String: String]] = [:]
    /// The first screen.
    @Published public private(set) var root: Route
    /// The screens pushed over the first one.
    @Published public var path: [Route] = [] {
        didSet {
            // A screen pushed over the others is told it opened, before it is drawn.
            if path.count == oldValue.count + 1, Array(path.dropLast()) == oldValue, let opened = path.last { tellOpened(opened) }
            show()
        }
    }
    /// The screen brought up as a sheet over the others, if one is. It is
    /// told it opened, like a pushed one, and forgotten once it is put away.
    @Published public var sheet: Route? {
        didSet {
            guard sheet != oldValue else { return }
            if let sheet { tellOpened(sheet) }
            show()
        }
    }
    // Screens on show in another's stack, such as one a web page opened.
    private var guests: [ObjectIdentifier: [Route]] = [:]
    private var showing: [Route] {
        ([root] + path + (sheet.map { [$0] } ?? []) + guests.values.flatMap { $0 }).filter(\.isScreen)
    }

    /// The server whose pages this app's screens can link to (`page:/orders`)
    /// and hold (`web`). A HybridHost sets it.
    public var site: HybridSite?

    /// The SwiftUI views a screen can ask for by name.
    public let views: Screens
    private let engine: Engine
    private let store: (Route) -> Store
    private let transport: Transport
    private let exchange: (String) -> String
    private let download: (String) -> (status: Int, data: Data)?
    private let shellFingerprint: String
    private let follows: Bool
    private let leaveWithin: TimeInterval
    private let thread = EngineThread()
    private let network = DispatchQueue(label: "instant-record-network", attributes: .concurrent)
    private let lock = NSLock()
    private var visible: [Route]
    private var schedule: SyncSchedule!
    private var stream: StreamClient!
    private var refreshing: [() -> Void] = []
    private var inFront = false
    // True while the error on show is a screen that could not be drawn.
    private var undrawn = false
    // Read and written on the engine's thread only.
    private var open: Store?
    private var prepared: [String: String]?
    private var unanswered = false

    /// `store` says where the first screen's data lives. It is asked again
    /// when a menu item puts another screen in the first one's place.
    /// `follows` is whether it follows the server's events while in front.
    /// `leaveWithin` is how long writes waiting in a database may hold up
    /// leaving it. `exchange` stands in for the network in tests.
    public init(engine: Engine, root: Route, views: Screens = Screens(), store: @escaping (Route) -> Store,
                transport: Transport = Transport(), follows: Bool = true, leaveWithin: TimeInterval = 1, exchange: ((String) -> String)? = nil,
                download: ((String) -> (status: Int, data: Data)?)? = nil, shellFingerprint: String = "",
                pace: SyncSchedule.Pace = SyncSchedule.Pace(), clock: Timekeeper = MainClock(), reachability: Reachability = NetworkPath()) {
        self.engine = engine
        self.root = root
        self.views = views
        self.store = store
        self.transport = transport
        self.follows = follows
        self.leaveWithin = leaveWithin
        self.exchange = exchange ?? transport.exchange
        self.download = download ?? transport.download
        self.shellFingerprint = shellFingerprint
        visible = [root]
        schedule = SyncSchedule(pace: pace, clock: clock) { [weak self] in self?.pass() }
        stream = StreamClient(transport: transport, address: { [weak self] in await self?.streamAddress() }, feed: { [weak self] in await self?.feed($0, from: $1) })
        reachability.watch { [weak self] in self?.schedule.reachable() }
    }

    /// Open the database, draw from it, then sync. The first screen does not
    /// wait for the network.
    public func start() {
        let store = store(root)
        thread.run {
            // During a pass the app is answered from what was fetched for it,
            // and anything else is "offline": the network is never asked here.
            self.engine.onExchange { request in
                if let answer = self.prepared?[request] { return answer }
                self.unanswered = true
                return Transport.offline
            }
            if self.engine.boot(database: store.database) { self.open = store } else { self.report() }
            let pos = self.engine.syncs ? self.position() : [:]
            let first = self.engine.syncs && pos["bootstrap"] == "needed"
            DispatchQueue.main.async { self.fetchingFirst = first }
            self.loadNoticesIfNeeded(from: pos)
            self.draw()
        }
        schedule.request()
    }

    /// Sync soon. Requests made close together run as one pass.
    public func sync() {
        schedule.request()
    }

    /// The app came to the front, or left it. In front it syncs at once and
    /// follows the server's events, which is how changes from elsewhere arrive.
    public func front(_ on: Bool) {
        schedule.front(on)
        inFront = on
        follow()
    }

    /// A pull on a list: sync now, and return when that pass has ended and
    /// the screens have been drawn again.
    @MainActor
    public func refresh() async {
        await withCheckedContinuation { done in
            refreshing.append { done.resume() }
            schedule.now()
        }
    }

    /// A tap: the screen at `route` performs `action` with the arguments the
    /// element carried and whatever is typed into the screen's fields (plus
    /// any explicit `values` passed by a typed native view). The screens are
    /// drawn again from the local database, and the write goes to the server
    /// soon after.
    public func perform(_ action: String, args: [String: String] = [:], values: [String: String] = [:], on route: Route) {
        guard route.isScreen else { return }
        let fieldValues = typed[route] ?? [:]
        let mergedValues = values.isEmpty ? fieldValues : fieldValues.merging(values) { _, explicit in explicit }
        thread.run {
            let performed = self.act(action, args, mergedValues, on: route)
            self.draw()
            // What was typed is forgotten once it has been handed over, unless
            // more was typed since.
            if performed, !fieldValues.isEmpty {
                DispatchQueue.main.async { if self.typed[route] == fieldValues { self.typed[route] = nil } }
            }
        }
        schedule.request()
    }

    /// Put another screen in the first one's place, as choosing another
    /// account does. Its data may live in another database, which is opened
    /// and drawn at once from what is on the phone: no network stands
    /// between the tap and the rows. It syncs afterwards, as any pass does.
    ///
    /// Writes still waiting in the database being left get one pass first,
    /// for at most `leaveWithin` seconds. Whatever comes of it the switch
    /// happens, and what did not go out stays in that file until it is
    /// opened again.
    public func replace(with route: Route) {
        let next = store(route)
        thread.run {
            let leaving = self.open
            if leaving?.database == next.database || !self.engine.syncs {
                self.open = next
                return self.arrive(at: route)
            }
            var changed = false
            let change = {
                guard !changed else { return }
                changed = true
                if self.engine.open(database: next.database) {
                    self.open = next
                    self.arrive(at: route)
                } else {
                    // The app has gone back to the database it had, so the
                    // screen stays where it was.
                    self.report()
                }
            }
            guard let leaving, self.pending() > 0 else { return change() }
            self.run(leaving) { _ in change() }
            self.network.asyncAfter(deadline: .now() + self.leaveWithin) { self.thread.run(change) }
        }
    }

    /// Fetch the page a `more` element stands for and hand it to the app,
    /// which keeps it and says whether more lies below.
    public func loadMore(_ key: String, query: String) {
        guard paging[key] != .loading else { return }
        paging[key] = .loading
        thread.run {
            guard let store = self.open else { return self.paged(key, failed: true) }
            self.network.async {
                let reply = Reply(self.exchange(Self.withHeaders("GET \(store.endpoint)/records?\(query)\n", store.headers)))
                self.thread.run {
                    guard reply.ok, self.open == store else { return self.paged(key, failed: true) }
                    let input = (try? JSONSerialization.data(withJSONObject: ["key": key, "response": reply.body])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                    let kept = self.engine.call("history", input) != nil
                    if !kept { self.report() }
                    self.draw()
                    self.paged(key, failed: !kept)
                }
            }
        }
    }

    /// The error on show has been read.
    public func dismissError() {
        status.error = ""
        status.syncError = ""
        undrawn = false
    }

    /// Re-apply a quarantined local write so it queues a fresh outbox mutation.
    public func retryNotice(_ id: String, overrides: [String: String] = [:]) {
        resolveNotice("retry", id: id, overrides: overrides)
    }

    /// Fork a quarantined local write into a new record with a fresh UUID.
    public func forkNotice(_ id: String, overrides: [String: String] = [:]) {
        resolveNotice("fork", id: id, overrides: overrides)
    }

    /// Dismiss a quarantined sync notice without deleting its audit row.
    public func dismissNotice(_ id: String) {
        resolveNotice("dismiss", id: id, overrides: [:])
    }

    // Follow the server's events while in front, from the database now open.
    // Called again when another database opens, which drops the request
    // held for the one that was left.
    private func follow() {
        stream.stop()
        if inFront && engine.syncs && follows { stream.start() }
    }

    /// Returns when everything asked of the app so far has run and its
    /// results have been published. For tests.
    func settle() {
        for _ in 0..<3 {
            thread.wait()
            network.sync(flags: .barrier) {}
        }
        thread.wait()
        if Thread.isMainThread {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        } else {
            DispatchQueue.main.sync {}
        }
    }

    /// What another's stack shows over its own first page, oldest first. A
    /// screen that was just pushed there is told it opened.
    func visited(_ routes: [Route], in stack: ObjectIdentifier) {
        let before = guests[stack] ?? []
        guard routes != before else { return }
        guests[stack] = routes.isEmpty ? nil : routes
        if routes.count > before.count, let opened = routes.last { tellOpened(opened) }
        show()
    }

    private func tellOpened(_ route: Route) {
        guard route.isScreen else { return }
        thread.run { self.act("open", [:], [:], on: route) }
        // Opening may write, as marking a message read does.
        schedule.request()
    }

    private func show() {
        let showing = showing
        lock.withLock { visible = showing }
        screens = screens.filter { showing.contains($0.key) }
        typed = typed.filter { showing.contains($0.key) }
        thread.run { self.draw() }
    }

    // The schedule starts a pass on the main thread.
    private func pass() {
        thread.run {
            guard let store = self.open, self.engine.syncs else {
                // Nothing can sync. Say the pass ended, or the schedule
                // would wait for it and never start another.
                return self.ended(ok: self.engine.syncs == false, pending: 0, offline: false, error: nil, nextRelease: nil)
            }
            self.run(store) { outcome in
                self.ended(ok: outcome.ok, pending: outcome.pending, offline: outcome.offline, error: outcome.error, nextRelease: outcome.nextRelease)
                // A tap between the fetch and the hand-over changed what the
                // app wanted to send. It goes out with a pass of its own.
                if outcome.outdated { DispatchQueue.main.async { self.schedule.request() } }
            }
        }
    }

    // Where the stream client should ask, from the app's present cursor, and
    // the database that address belongs to.
    private func streamAddress() async -> (address: String, store: Store)? {
        await withCheckedContinuation { answer in
            thread.run {
                let position = self.position()
                guard let store = self.open, let cursor = position["cursor"], position["bootstrap"] == "ready" else { return answer.resume(returning: nil) }
                let who = (position["identity"] ?? "").isEmpty ? "" : "&identity=" + position["identity"]!
                answer.resume(returning: ("\(store.endpoint)/events?after=\(cursor)\(who)", store))
            }
        }
    }

    // One event from the server, handed to the app. The screens are drawn
    // again when it says records changed. An event read for a database that
    // has since been left is not this one's and is dropped.
    func feed(_ event: String, from store: Store) async {
        await withCheckedContinuation { done in
            thread.run {
                guard self.open == store else { return done.resume() }
                if self.engine.call("stream", event) == nil { self.report() }
                let signal = NoticeSignal.parse(self.engine.notice())
                if !signal.syncNotices.isEmpty { self.mergeNotices(signal.syncNotices) }
                if signal.recordsChanged { self.draw() }
                done.resume()
            }
        }
    }

    // Everything below runs on the engine's thread, unless it says otherwise.

    private struct Outcome {
        var ok = false
        var pending = 0
        var offline = false
        var outdated = false
        var error: String?
        var nextRelease: TimeInterval?
    }

    private static let sqliteHeader = Data("SQLite format 3\0".utf8)

    /// One sync pass for `store`: ask the app what it will want, fetch that
    /// off this thread, then let the app sync against the answers alone.
    /// When a brand-new database needs a bootstrap and carries a schema
    /// fingerprint, try hydrating from a prebuilt SQLite shell via `ir_open`
    /// first, falling back seamlessly to `/bootstrap` on any miss or error.
    /// `then` runs on this thread when the pass has ended.
    private func run(_ store: Store, allowShell: Bool = true, then: @escaping (Outcome) -> Void) {
        guard let plan = engine.call("sync_plan", "").flatMap(Self.object) else {
            return then(Outcome(pending: pending(), error: engine.error(), nextRelease: nextRelease()))
        }
        let push = (plan["push"] as? String) ?? ""
        let needsBootstrap = plan["bootstrap"] as? Bool == true
        let planFingerprint = (plan["fingerprint"] as? String) ?? ""
        let fingerprint = planFingerprint.isEmpty ? shellFingerprint : planFingerprint
        if allowShell, needsBootstrap, push.isEmpty, !fingerprint.isEmpty {
            return hydrateFromShell(store, fingerprint: fingerprint, then: then)
        }
        let position = position()
        var wanted: [String] = []
        if !push.isEmpty { wanted.append("POST \(store.endpoint)/mutations\n\(push)") }
        if needsBootstrap {
            wanted.append("GET \(store.endpoint)/bootstrap\n")
        } else {
            let who = (position["identity"] ?? "").isEmpty ? "" : "&identity=" + position["identity"]!
            wanted.append("GET \(store.endpoint)/events?after=\(position["cursor"] ?? "0")&window=0\(who)\n")
        }
        network.async {
            var replies: [String: String] = [:]
            var outcome = Outcome()
            for request in wanted {
                let answer = self.exchange(Self.withHeaders(request, store.headers))
                replies[request] = answer
                let reply = Reply(answer)
                if reply.status == 0 {
                    outcome.offline = true
                    break
                }
                if !reply.ok, outcome.error == nil {
                    outcome.error = "Could not sync: \(request.prefix { $0 != "\n" }.replacingOccurrences(of: store.endpoint, with: "")) answered \(reply.status)"
                }
            }
            self.thread.run {
                // The database may have been changed for another while the
                // answers were fetched. They are not this one's.
                guard self.open == store else { return then(outcome) }
                self.prepared = replies
                self.unanswered = false
                let synced = self.engine.call("sync", store.endpoint)
                self.prepared = nil
                if synced == nil { outcome.error = self.engine.error() }
                let signal = NoticeSignal.parse(self.engine.notice())
                if !signal.syncNotices.isEmpty { self.mergeNotices(signal.syncNotices) }
                if signal.recordsChanged { self.draw() }
                let state = self.position()
                outcome.pending = Int(state["pending"] ?? "") ?? 0
                outcome.nextRelease = Self.releaseDelay(from: state)
                outcome.outdated = self.unanswered && !outcome.offline
                outcome.ok = synced != nil && !outcome.offline && outcome.error == nil
                then(outcome)
            }
        }
    }

    private func hydrateFromShell(_ store: Store, fingerprint: String, then: @escaping (Outcome) -> Void) {
        let grantRequest = "GET \(store.endpoint)/shell?fingerprint=\(fingerprint)\n"
        network.async {
            let grantReply = Reply(self.exchange(grantRequest))
            if grantReply.status == 0 {
                return self.thread.run { then(Outcome(offline: true)) }
            }
            guard grantReply.status == 200,
                  let grant = Self.object(grantReply.body),
                  let filePath = grant["path"] as? String,
                  filePath.hasPrefix("/shell/file"),
                  let cursor = grant["cursor"] as? Int,
                  cursor >= 0,
                  let fetched = self.download(store.endpoint + filePath),
                  fetched.status == 200,
                  fetched.data.count >= Self.sqliteHeader.count,
                  fetched.data.prefix(Self.sqliteHeader.count) == Self.sqliteHeader
            else {
                return self.thread.run {
                    guard self.open == store else { return then(Outcome()) }
                    self.run(store, allowShell: false, then: then)
                }
            }
            let expectedIdentity = grant["identity"] as? String ?? ""
            let staged = store.database + ".shell.\(UUID().uuidString).tmp"
            let stagedURL = URL(fileURLWithPath: staged)
            do {
                try FileManager.default.createDirectory(at: stagedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fetched.data.write(to: stagedURL, options: .atomic)
            } catch {
                Self.removeSQLiteFiles(atPath: staged)
                return self.thread.run {
                    guard self.open == store else { return then(Outcome()) }
                    self.run(store, allowShell: false, then: then)
                }
            }
            self.thread.run {
                guard self.open == store else {
                    Self.removeSQLiteFiles(atPath: staged)
                    return then(Outcome())
                }
                let current = self.position()
                guard current["bootstrap"] == "needed", self.pending() == 0 else {
                    Self.removeSQLiteFiles(atPath: staged)
                    return self.run(store, allowShell: false, then: then)
                }
                guard self.engine.open(database: staged) else {
                    Self.removeSQLiteFiles(atPath: staged)
                    return self.run(store, allowShell: false, then: then)
                }
                let state = self.position()
                let validCursor = state["bootstrap"] == "ready" && Int(state["cursor"] ?? "") == cursor
                let validIdentity = expectedIdentity.isEmpty || state["identity"] == expectedIdentity
                guard validCursor && validIdentity else {
                    _ = self.engine.open(database: store.database)
                    Self.removeSQLiteFiles(atPath: staged)
                    return self.run(store, allowShell: false, then: then)
                }
                guard self.promoteShell(staged: staged, to: store.database) else {
                    _ = self.engine.open(database: store.database)
                    Self.removeSQLiteFiles(atPath: staged)
                    return self.run(store, allowShell: false, then: then)
                }
                self.draw()
                // Hydrated and drawn; schedule an immediate catch-up pass from the shell's cursor.
                then(Outcome(ok: true, pending: self.pending(), offline: false, outdated: true, error: nil, nextRelease: self.nextRelease()))
            }
        }
    }

    private func promoteShell(staged: String, to target: String) -> Bool {
        let fm = FileManager.default
        let backup = target + ".shell-backup.\(UUID().uuidString).tmp"
        let hadTarget = fm.fileExists(atPath: target)
        do {
            if hadTarget {
                try fm.moveItem(atPath: target, toPath: backup)
                for suffix in ["-wal", "-shm", "-journal"] {
                    try? fm.removeItem(atPath: target + suffix)
                }
            }
            try fm.moveItem(atPath: staged, toPath: target)
            guard engine.open(database: target) else {
                try? fm.removeItem(atPath: target)
                if hadTarget { try? fm.moveItem(atPath: backup, toPath: target) }
                return false
            }
            Self.removeSQLiteFiles(atPath: staged)
            if hadTarget { Self.removeSQLiteFiles(atPath: backup) }
            return true
        } catch {
            if !fm.fileExists(atPath: target), hadTarget, fm.fileExists(atPath: backup) {
                try? fm.moveItem(atPath: backup, toPath: target)
            }
            return false
        }
    }

    private static func removeSQLiteFiles(atPath path: String) {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? fm.removeItem(atPath: path + suffix)
        }
    }

    private func ended(ok: Bool, pending: Int, offline: Bool, error: String?, nextRelease: TimeInterval?) {
        draw()
        DispatchQueue.main.async {
            self.fetchingFirst = false
            self.status.pending = pending
            self.status.offline = offline
            if let error { self.status.syncError = error } else if ok { self.status.syncError = "" }
            self.schedule.finished(ok: ok, pending: pending, nextRelease: nextRelease)
            let waiting = self.refreshing
            self.refreshing = []
            waiting.forEach { $0() }
        }
    }

    // The first screen changes. It is drawn here, on the engine's thread,
    // from the database now open, and shown together with the change, so
    // its rows are on screen before anything is fetched. Only a database
    // that has never synced has nothing to show yet.
    private func arrive(at route: Route) {
        let drawn = engine.call("render", route.input()).flatMap { try? Node(json: $0) }
        let pos = engine.syncs ? position() : [:]
        let first = engine.syncs && pos["bootstrap"] == "needed"
        loadNoticesIfNeeded(from: pos)
        DispatchQueue.main.async {
            self.root = route
            if let drawn { self.screens[route] = drawn }
            self.fetchingFirst = first
            self.sheet = nil
            self.path = []
            self.follow()
            self.schedule.now()
        }
    }

    private func paged(_ key: String, failed: Bool) {
        DispatchQueue.main.async { self.paging[key] = failed ? .failed : nil }
    }

    @discardableResult
    private func act(_ action: String, _ args: [String: String], _ values: [String: String], on route: Route) -> Bool {
        if engine.call("action", route.input(action: action, args: args, values: values)) != nil { return true }
        report()
        return false
    }

    /// The app's own account of where it is: cursor, pending, bootstrap, identity.
    private func position() -> [String: String] {
        var fields: [String: String] = [:]
        for field in (engine.call("cursor", "") ?? "").split(separator: " ") {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
        }
        return fields
    }

    private func pending() -> Int {
        Int(position()["pending"] ?? "") ?? 0
    }

    private func nextRelease() -> TimeInterval? {
        Self.releaseDelay(from: position())
    }

    private static func releaseDelay(from state: [String: String]) -> TimeInterval? {
        guard let raw = state["next_release_ms"], let ms = Double(raw) else { return nil }
        return max(0, ms / 1000.0)
    }

    // A screen that cannot be drawn keeps the last one that could, and the
    // reason is shown.
    private func draw() {
        let routes = lock.withLock { visible }
        var drawn: [Route: Node] = [:]
        var problem: String?
        for route in routes {
            guard let json = engine.call("render", route.input()) else {
                problem = engine.error()
                continue
            }
            if let node = try? Node(json: json) { drawn[route] = node } else { problem = "The screen \(route.screen) could not be read." }
        }
        DispatchQueue.main.async {
            let showing = self.showing
            for (route, node) in drawn where showing.contains(route) && self.screens[route] != node {
                self.screens[route] = node
            }
            if let problem {
                self.status.error = problem
                self.undrawn = true
            } else if self.undrawn {
                self.status.error = ""
                self.undrawn = false
            }
        }
    }

    private func report() {
        let message = engine.error()
        DispatchQueue.main.async {
            self.status.error = message
            self.undrawn = false
        }
    }

    private func resolveNotice(_ action: String, id: String, overrides: [String: String]) {
        let payload: [String: Any] = ["action": action, "id": id, "overrides": overrides]
        let input = (try? JSONSerialization.data(withJSONObject: payload)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        thread.run {
            guard let raw = self.engine.call("notices", input) else {
                self.report()
                return
            }
            if let response = try? JSONDecoder().decode(SyncNoticesResponse.self, from: Data(raw.utf8)) {
                DispatchQueue.main.async {
                    if let list = response.notices { self.notices = list }
                    if !response.ok, let message = response.error {
                        self.status.error = message
                        self.undrawn = false
                    }
                }
            }
            self.draw()
        }
        if action == "retry" || action == "fork" {
            schedule.request()
        }
    }

    private func loadNoticesIfNeeded(from position: [String: String]) {
        let count = Int(position["notices"] ?? "") ?? 0
        guard count > 0 else {
            DispatchQueue.main.async { self.notices = [] }
            return
        }
        guard let raw = engine.call("notices", "{\"action\":\"list\"}"),
              let response = try? JSONDecoder().decode(SyncNoticesResponse.self, from: Data(raw.utf8)),
              let list = response.notices else { return }
        DispatchQueue.main.async { self.notices = list }
    }

    private func mergeNotices(_ incoming: [SyncNotice]) {
        DispatchQueue.main.async {
            var merged = incoming
            let incomingIds = Set(incoming.map(\.id))
            for existing in self.notices where !incomingIds.contains(existing.id) {
                merged.append(existing)
            }
            self.notices = merged
        }
    }

    private static func object(_ json: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    private static func withHeaders(_ request: String, _ headers: [String: String]) -> String {
        guard !headers.isEmpty, let newline = request.firstIndex(of: "\n") else { return request }
        let line = request[..<newline]
        let body = request[request.index(after: newline)...]
        let block = headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        return "\(line)\n\(block)\n\n\(body)"
    }
}
