import Combine
import Foundation

/// Runs a compiled InstantRecord app behind its screens: boots it, keeps the
/// screens on show drawn from its local database, sends it taps and keeps it
/// in sync with the server. It knows a screen only by name and params.
public final class AppHost: ObservableObject {
    /// Where a first screen keeps its data: the SQLite file, and the sync
    /// address the app's server gives for it. One file syncs with one address.
    public struct Store: Equatable {
        public let database: String
        public let endpoint: String

        public init(database: String, endpoint: String) {
            self.database = database
            self.endpoint = endpoint
        }
    }

    /// The screens on show, as the app last described them.
    @Published public private(set) var screens: [Route: Node] = [:]
    /// The last thing the app raised, until it is dismissed, or empty.
    @Published public private(set) var failure = ""
    /// False after a sync pass could not reach the server.
    @Published public private(set) var online = true
    /// How many writes made here have not reached the server.
    @Published public private(set) var pending = 0
    /// The first screen.
    @Published public private(set) var root: Route
    /// The screens pushed over the first one.
    @Published public var path: [Route] = [] {
        didSet {
            // A screen pushed over the others is told it opened, before it is drawn.
            if path.count == oldValue.count + 1, Array(path.dropLast()) == oldValue, let opened = path.last {
                thread.run { self.act("open", [:], on: opened) }
            }
            show()
        }
    }

    /// The SwiftUI views a screen can ask for by name.
    public let views: Screens
    private let engine: Engine
    private let store: (Route) -> Store
    private let exchange: (String) -> String
    private let thread = EngineThread()
    private let lock = NSLock()
    private var visible: [Route]
    private var schedule: SyncSchedule!
    // Read and written on the engine's thread only.
    private var open: Store?
    private var unreachable = false

    /// `store` says where the first screen's data lives. It is asked again
    /// when a menu item puts another screen in the first one's place.
    public init(engine: Engine, root: Route, views: Screens = Screens(), store: @escaping (Route) -> Store,
                exchange: @escaping (String) -> String = Transport().exchange,
                pace: SyncSchedule.Pace = SyncSchedule.Pace(), clock: Timekeeper = MainClock(), reachability: Reachability = NetworkPath()) {
        self.engine = engine
        self.root = root
        self.views = views
        self.store = store
        self.exchange = exchange
        visible = [root]
        schedule = SyncSchedule(pace: pace, clock: clock) { [weak self] in self?.pass() }
        reachability.watch { [weak self] in self?.schedule.reachable() }
    }

    /// Open the database, draw from it, then sync. The first screen does not
    /// wait for the network.
    public func start() {
        let store = store(root)
        thread.run {
            self.engine.onExchange { request in
                let answer = self.exchange(request)
                if answer.hasPrefix(Transport.offline) { self.unreachable = true }
                return answer
            }
            if self.engine.boot(database: store.database) { self.open = store } else { self.report() }
            self.draw()
        }
        schedule.request()
    }

    /// Sync soon. Requests made close together run as one pass.
    public func sync() {
        schedule.request()
    }

    /// The app came to the front, or left it. In front it syncs at once and
    /// then every few seconds, which is how changes from elsewhere arrive.
    public func front(_ on: Bool) {
        schedule.front(on)
    }

    /// A pull on a list: sync now, then draw whether or not anything changed.
    public func refresh() async {
        await withCheckedContinuation { done in
            thread.run {
                self.exchangeOnce()
                self.draw()
                done.resume()
            }
        }
    }

    /// A tap: the screen at `route` performs `action` with the values it
    /// carried, the screens are drawn again from the local database, and the
    /// write goes to the server soon after.
    public func perform(_ action: String, with: [String: String] = [:], on route: Route) {
        thread.run {
            self.act(action, with, on: route)
            self.draw()
        }
        schedule.request()
    }

    /// Put another screen in the first one's place, as choosing another
    /// account does. Its data may live in another database.
    public func replace(with route: Route) {
        let store = store(route)
        thread.run {
            if store.database == self.open?.database || self.engine.open(database: store.database) {
                self.open = store
            } else {
                self.report()
            }
        }
        root = route
        path = []
        schedule.request()
    }

    /// The error on show has been read.
    public func dismissFailure() {
        failure = ""
    }

    /// Returns when everything asked of the app so far has run and its
    /// results have been published. For tests.
    func settle() {
        thread.wait()
        if Thread.isMainThread {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        } else {
            DispatchQueue.main.sync {}
        }
    }

    private func show() {
        let showing = [root] + path
        lock.withLock { visible = showing }
        screens = screens.filter { showing.contains($0.key) }
        thread.run { self.draw() }
    }

    // The schedule starts a pass on the main thread. It runs on the engine's.
    private func pass() {
        thread.run { self.exchangeOnce() }
    }

    // Everything below runs on the engine's thread.

    private func act(_ action: String, _ with: [String: String], on route: Route) {
        if engine.call("action", route.input(action: action, with: with)) == nil { report() }
    }

    private func exchangeOnce() {
        guard let open else { return }
        unreachable = false
        let result = engine.call("sync", open.endpoint)
        if result == nil { report() }
        if engine.notice().hasPrefix("records_changed") { draw() }
        let waiting = Int(result?.components(separatedBy: "pending=").dropFirst().first?.prefix { $0.isNumber } ?? "") ?? 0
        let reached = result != nil && !unreachable
        DispatchQueue.main.async {
            self.online = reached
            self.pending = waiting
            self.schedule.finished(ok: reached, pending: waiting)
        }
    }

    private func draw() {
        let routes = lock.withLock { visible }
        var drawn: [Route: Node] = [:]
        for route in routes {
            guard let json = engine.call("render", route.input()) else { report(); continue }
            guard let node = try? Node(json: json) else { continue }
            drawn[route] = node
        }
        DispatchQueue.main.async {
            let showing = [self.root] + self.path
            for (route, node) in drawn where showing.contains(route) && self.screens[route] != node {
                self.screens[route] = node
            }
        }
    }

    private func report() {
        let message = engine.error()
        DispatchQueue.main.async { self.failure = message }
    }
}
