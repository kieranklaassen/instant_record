import Foundation
@testable import InstantRecordNative

/// A clock the test turns by hand. It holds at most one planned block, as the
/// schedule plans one pass at a time.
final class ManualClock: Timekeeper {
    private(set) var planned: [TimeInterval] = []
    private var block: (() -> Void)?

    func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) -> () -> Void {
        planned.append(seconds)
        self.block = block
        return { self.block = nil }
    }

    var waiting: Bool { block != nil }

    /// Let the planned time pass.
    func fire() {
        let due = block
        block = nil
        due?()
    }
}

final class ManualReachability: Reachability {
    private var reachable: () -> Void = {}
    func watch(_ reachable: @escaping () -> Void) { self.reachable = reachable }
    func comeBack() { reachable() }
}

/// Stands where the compiled app would be and keeps what it was asked, each
/// call as "entry screen name=value,... [action name=value,...]".
final class FakeEngine: Engine {
    var calls: [String] = []
    var rows = ["m2", "m1"]
    var noticeAfterSync = ""
    var raises = false
    var pending = 0
    var boots = true
    var answered: [String] = []
    private var last = ""
    private var answer: (String) -> String = { _ in Transport.offline }

    func boot(database: String) -> Bool {
        calls.append("boot " + database)
        return boots
    }

    func open(database: String) -> Bool {
        calls.append("open " + database)
        rows = database.contains("billing") ? ["b1"] : ["m2", "m1"]
        return !database.contains("locked")
    }

    func call(_ entry: String, _ input: String) -> String? {
        last = entry
        guard entry == "render" || entry == "action" else {
            calls.append(entry + " " + input)
            if raises { return nil }
            if entry == "sync" { answered.append(answer("GET " + input + "/events")) }
            return "changed pending=\(pending) cursor=7"
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [String: Any] ?? [:]
        let screen = object["screen"] as? String ?? "?"
        var line = entry + " " + screen + " " + FakeEngine.flat(object["params"])
        if let action = object["action"] as? String { line += " " + action + " " + FakeEngine.flat(object["with"]) }
        calls.append(line.trimmingCharacters(in: .whitespaces))
        if raises { return nil }
        if entry == "action", let id = (object["with"] as? [String: String])?["id"] { rows.removeAll { $0 == id } }
        return entry == "render" ? FakeEngine.screen(screen, rows) : ""
    }

    func notice() -> String { last == "sync" ? noticeAfterSync : "" }
    func error() -> String { "ArgumentError: No screen named nowhere" }
    func onExchange(_ answer: @escaping (String) -> String) { self.answer = answer }

    private static func flat(_ value: Any?) -> String {
        ((value as? [String: String]) ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }

    private static func screen(_ name: String, _ rows: [String]) -> String {
        let items = rows.map { "{\"kind\":\"row\",\"id\":\"\($0)\",\"text\":\"\",\"action\":\"\",\"params\":{},\"props\":{},\"children\":[]}" }
        return "{\"kind\":\"screen\",\"id\":\"\",\"text\":\"\(name)\",\"action\":\"\",\"params\":{},\"props\":{},\"children\":[\(items.joined(separator: ","))]}"
    }
}
