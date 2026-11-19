import Foundation

/// The compiled app, as instant_record_native.h declares it. The app target
/// supplies the one implementation that calls the C library, so this package
/// builds and tests without it.
public protocol Engine: AnyObject {
    /// Open the SQLite file. False when the app did not come up.
    func boot(database: String) -> Bool
    /// Run one entry point. Nil when Ruby raised, and `error` says what.
    func call(_ entry: String, _ input: String) -> String?
    /// What changed during the last call.
    func notice() -> String
    func error() -> String
    /// Who answers when the app asks for the network during a call.
    func onExchange(_ answer: @escaping (String) -> String)
}

/// One thread that runs every call into the engine, in order. A thread and
/// not a dispatch queue: the compiled Ruby keeps to the thread it booted on,
/// and it gets a deeper stack than a queue's worker has.
final class EngineThread: Thread {
    private let pending = NSCondition()
    private var work: [() -> Void] = []

    override init() {
        super.init()
        name = "instant-record"
        stackSize = 16 << 20
        start()
    }

    func run(_ block: @escaping () -> Void) {
        pending.lock()
        work.append(block)
        pending.signal()
        pending.unlock()
    }

    /// Returns when everything asked for so far has run.
    func wait() {
        let done = DispatchSemaphore(value: 0)
        run { done.signal() }
        done.wait()
    }

    override func main() {
        while true {
            pending.lock()
            while work.isEmpty { pending.wait() }
            let block = work.removeFirst()
            pending.unlock()
            block()
        }
    }
}
