import Foundation

/// The app behind the screens. The app target supplies the one that calls
/// the compiled C library (instant_record_native.h), and `HTTPEngine` asks a
/// Rails server instead, so this package builds and tests without either.
public protocol Engine: AnyObject {
    /// Start the app on a SQLite file. False when it did not come up.
    func boot(database: String) -> Bool
    /// Close the open database and open another. False when it could not.
    func open(database: String) -> Bool
    /// Run one entry point. Nil when Ruby raised, and `error` says what.
    func call(_ entry: String, _ input: String) -> String?
    /// What changed during the last call.
    func notice() -> String
    func error() -> String
    /// Who answers when the app asks for the network during a call.
    func onExchange(_ answer: @escaping (String) -> String)
    /// False for an engine that keeps nothing on the phone: there is then
    /// nothing to sync and no stream to follow.
    var syncs: Bool { get }
}

public extension Engine {
    var syncs: Bool { true }
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
