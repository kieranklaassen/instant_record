import Combine
import Foundation

/// Runs a compiled InstantRecord app behind its screens: boots it, keeps the
/// screens on show drawn from its local database, sends it taps and syncs it
/// with the server. It knows a screen only by name and argument.
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
    /// The last thing the app raised, or empty.
    @Published public private(set) var failure = ""
    /// The first screen.
    @Published public private(set) var root: Route
    /// The screens pushed over the first one.
    @Published public var path: [Route] = [] {
        didSet { show() }
    }

    private let engine: Engine
    private let store: (Route) -> Store
    private let exchange: (String) -> String
    private let thread = EngineThread()
    private let lock = NSLock()
    private var visible: [Route]
    private var open: Store?  // the engine thread's

    /// `store` says where the first screen's data lives. It is asked again
    /// when a menu item puts another screen in the first one's place.
    public init(engine: Engine, root: Route, store: @escaping (Route) -> Store, exchange: @escaping (String) -> String = Transport().exchange) {
        self.engine = engine
        self.root = root
        self.store = store
        self.exchange = exchange
        visible = [root]
    }

    /// Open the database, draw from it, then sync. The first screen does not
    /// wait for the network.
    public func start() {
        let store = store(root)
        thread.run {
            self.engine.onExchange(self.exchange)
            self.boot(store)
            self.draw()
            self.pass()
        }
    }

    public func sync() {
        thread.run { self.pass() }
    }

    /// A pull on a list: sync, then draw whether or not anything changed.
    public func refresh() async {
        await withCheckedContinuation { done in
            thread.run {
                self.pass()
                self.draw()
                done.resume()
            }
        }
    }

    /// A tap: the screen at `route` performs `action`, the screens are drawn
    /// again from the local database, and the write goes to the server.
    public func perform(_ action: String, arg: String, on route: Route) {
        thread.run {
            let input = [route.screen, route.arg, action, arg].joined(separator: "\n")
            if self.engine.call("action", input) == nil { self.report() }
            self.draw()
            self.pass()
        }
    }

    /// A tap on a row that leads somewhere: its action, if it has one, is
    /// performed before the screen it names opens.
    public func open(_ screen: String, arg: String, action: String, from route: Route) {
        if !action.isEmpty { perform(action, arg: arg, on: route) }
        path.append(Route(screen, arg))
    }

    /// Put another screen in the first one's place, as choosing another
    /// account does. Its data may live in another database.
    public func replace(with route: Route) {
        let store = store(route)
        thread.run { self.boot(store) }
        root = route
        path = []
        sync()
    }

    /// Returns when everything asked of the app so far has run and its
    /// results have been published.
    public func settle() {
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

    // Everything below runs on the engine's thread.

    private func boot(_ store: Store) {
        if store.database == open?.database || engine.boot(database: store.database) {
            open = store
        } else {
            report()
        }
    }

    private func pass() {
        guard let open else { return }
        if engine.call("sync", open.endpoint) == nil { report() }
        if engine.notice().hasPrefix("records_changed") { draw() }
    }

    private func draw() {
        let routes = lock.withLock { visible }
        var drawn: [Route: Node] = [:]
        for route in routes {
            guard let json = engine.call("render", route.screen + "\n" + route.arg) else { report(); continue }
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
