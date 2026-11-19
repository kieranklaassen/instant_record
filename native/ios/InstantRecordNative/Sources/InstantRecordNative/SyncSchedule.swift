import Foundation
import Network

/// Something that can run a block later and take it back.
public protocol Timekeeper {
    func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) -> () -> Void
}

/// The main queue's clock.
public struct MainClock: Timekeeper {
    public init() {}

    public func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) -> () -> Void {
        let item = DispatchWorkItem(block: block)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return { item.cancel() }
    }
}

/// Tells when the network comes back.
public protocol Reachability {
    func watch(_ reachable: @escaping () -> Void)
}

/// The system's network path. It calls back on the main queue each time the
/// path becomes usable.
public final class NetworkPath: Reachability {
    private let monitor = NWPathMonitor()

    public init() {}

    public func watch(_ reachable: @escaping () -> Void) {
        monitor.pathUpdateHandler = { path in
            if path.status == .satisfied { DispatchQueue.main.async(execute: reachable) }
        }
        monitor.start(queue: DispatchQueue(label: "instant-record-path"))
    }
}

/// Decides when the app syncs, so that nothing else has to.
///
/// - Requests made close together run as one pass.
/// - A pass that failed, or left writes waiting, is tried again: after
///   `retry` seconds, then twice that, up to `ceiling`.
/// - With `poll` above zero a pass also runs that often while the app is in
///   front. An app that follows the server's events (StreamClient) leaves
///   it at zero.
///
/// It is used from the main thread only. `run` starts a pass, and the pass
/// reports back through `finished`.
public final class SyncSchedule {
    public struct Pace {
        public var delay: TimeInterval
        public var retry: TimeInterval
        public var ceiling: TimeInterval
        public var poll: TimeInterval

        public init(delay: TimeInterval = 0.3, retry: TimeInterval = 5, ceiling: TimeInterval = 60, poll: TimeInterval = 0) {
            self.delay = delay
            self.retry = retry
            self.ceiling = ceiling
            self.poll = poll
        }
    }

    private let pace: Pace
    private let clock: Timekeeper
    private let run: () -> Void
    private var cancel: (() -> Void)?
    private var due: TimeInterval?
    private var running = false
    private var wanted = false
    private var inFront = false
    private var wait: TimeInterval

    public init(pace: Pace = Pace(), clock: Timekeeper = MainClock(), run: @escaping () -> Void) {
        self.pace = pace
        self.clock = clock
        self.run = run
        wait = pace.retry
    }

    /// Something was written, or someone asked: sync soon.
    public func request() {
        plan(pace.delay)
    }

    /// Someone pulled to refresh: sync now.
    public func now() {
        plan(0)
    }

    /// The network is back: sync now, and forget how long we were waiting.
    public func reachable() {
        wait = pace.retry
        plan(0)
    }

    /// The app came to the front or left it.
    public func front(_ on: Bool) {
        inFront = on
        if on {
            plan(0)
        } else {
            cancel?()
            cancel = nil
            due = nil
        }
    }

    /// A pass ended. `ok` is false when the server could not be reached.
    public func finished(ok: Bool, pending: Int) {
        running = false
        // The wait starts over only when nothing is left to send. A server
        // that answers but keeps refusing the writes is asked less and less often.
        if ok && pending == 0 { wait = pace.retry }
        if wanted {
            wanted = false
            plan(pace.delay)
        } else if !ok || pending > 0 {
            plan(wait)
            wait = min(wait * 2, pace.ceiling)
        } else if inFront, pace.poll > 0 {
            plan(pace.poll)
        }
    }

    // One pass is planned at a time, and a sooner one replaces a later one.
    private func plan(_ seconds: TimeInterval) {
        if running {
            wanted = true
            return
        }
        if let due, due <= seconds { return }
        cancel?()
        due = seconds
        cancel = clock.after(seconds) { [weak self] in self?.start() }
    }

    private func start() {
        cancel = nil
        due = nil
        running = true
        run()
    }
}
