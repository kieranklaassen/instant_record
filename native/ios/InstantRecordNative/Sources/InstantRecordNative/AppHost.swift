import Combine
import Foundation

/// Runs a compiled InstantRecord app behind its screens: boots it, keeps the
/// screens on show drawn from its local database, sends it taps and syncs it
/// with the server. It knows a screen only by name and argument.
public final class AppHost: ObservableObject {
    /// The screens on show, as the app last described them.
    @Published public private(set) var screens: [Route: Node] = [:]
    /// The last thing the app raised, or empty.
    @Published public private(set) var failure = ""
    /// The screens pushed over the first one.
    @Published public var path: [Route] = [] {
        didSet {
            let showing = [root] + path
            lock.withLock { visible = showing }
            screens = screens.filter { showing.contains($0.key) }
            thread.run { self.draw() }
        }
    }

    public let root: Route
    private let engine: Engine
    private let endpoint: String
    private let exchange: (String) -> String
    private let thread = EngineThread()
    private let lock = NSLock()
    private var visible: [Route]

    /// `endpoint` is the sync address the app's server gives this member.
    public init(engine: Engine, root: Route, endpoint: String, exchange: @escaping (String) -> String = Transport().exchange) {
        self.engine = engine
        self.root = root
        self.endpoint = endpoint
        self.exchange = exchange
        visible = [root]
    }

    /// Open the database, draw from it, then sync. The first screen does not
    /// wait for the network.
    public func start(database: String) {
        thread.run {
            self.engine.onExchange(self.exchange)
            guard self.engine.boot(database: database) else { return self.report() }
            self.draw()
            self.pass()
        }
    }

    public func sync() {
        thread.run { self.pass() }
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

    // Everything below runs on the engine's thread.

    private func pass() {
        if engine.call("sync", endpoint) == nil { report() }
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
