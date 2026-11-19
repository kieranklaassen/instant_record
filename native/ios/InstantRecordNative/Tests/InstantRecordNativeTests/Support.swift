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
/// call as "entry screen name=value,... [action args [values]]". It syncs as
/// the library does: it asks the host for each answer from inside `sync`.
final class FakeEngine: Engine {
    var calls: [String] = []
    var rows = ["m2", "m1"]
    var noticeAfter: [String: String] = [:]
    var raises: Set<String> = []
    var unreadable = false
    var push = ""
    var bootstrapped = true
    var boots = true
    var syncs = true
    /// What the host answered each request the library made during `sync`.
    var answered: [String] = []
    private var last = ""
    private var endpoint = ""
    private var answer: (String) -> String = { _ in Transport.offline }

    func boot(database: String) -> Bool {
        calls.append("boot " + database)
        return boots
    }

    func open(database: String) -> Bool {
        calls.append("open " + database)
        guard !database.contains("locked") else { return false }
        rows = database.contains("billing") ? ["b1"] : ["m2", "m1"]
        return true
    }

    func call(_ entry: String, _ input: String) -> String? {
        last = entry
        switch entry {
        case "render", "action":
            let object = (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [String: Any] ?? [:]
            let screen = object["screen"] as? String ?? "?"
            var line = entry + " " + screen + " " + FakeEngine.flat(object["params"])
            if let action = object["action"] as? String {
                line += " " + action + " " + FakeEngine.flat(object["args"])
                if !FakeEngine.flat(object["values"]).isEmpty { line += " values " + FakeEngine.flat(object["values"]) }
            }
            calls.append(line.trimmingCharacters(in: .whitespaces))
            if raises.contains(entry) { return nil }
            if entry == "action" {
                if let id = (object["args"] as? [String: String])?["id"] { rows.removeAll { $0 == id } }
                push = "{\"mutations\":[\"" + (object["action"] as? String ?? "") + "\"]}"
                return ""
            }
            return unreadable ? "{\"kind\":" : FakeEngine.screen(screen, rows)
        case "sync_plan":
            calls.append("sync_plan")
            if raises.contains(entry) { return nil }
            return "{\"push\":\(FakeEngine.quoted(push)),\"bootstrap\":\(!bootstrapped)}"
        case "cursor":
            return "cursor=7 pending=\(push.isEmpty ? 0 : 1) bootstrap=\(bootstrapped ? "ready" : "needed") identity="
        case "sync":
            calls.append("sync " + input)
            if raises.contains(entry) { return nil }
            if !push.isEmpty {
                let reply = ask("POST \(input)/mutations\n\(push)")
                if reply.hasPrefix("2") { push = "" } else { return "unchanged" }
            }
            if ask(bootstrapped ? "GET \(input)/events?after=7&window=0\n" : "GET \(input)/bootstrap\n").hasPrefix("2") { bootstrapped = true }
            return "changed"
        default:
            calls.append(entry + " " + input)
            return raises.contains(entry) ? nil : ""
        }
    }

    func notice() -> String { noticeAfter[last] ?? "" }
    func error() -> String { "ArgumentError: No screen named nowhere" }
    func onExchange(_ answer: @escaping (String) -> String) { self.answer = answer }

    private func ask(_ request: String) -> String {
        let reply = answer(request)
        answered.append(String(request.prefix { $0 != "\n" }) + " -> " + String(reply.prefix { $0 != "\n" }))
        return reply
    }

    private static func flat(_ value: Any?) -> String {
        ((value as? [String: String]) ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }

    private static func quoted(_ text: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: [text])) ?? Data(), as: UTF8.self).dropFirst().dropLast().description
    }

    private static func screen(_ name: String, _ rows: [String]) -> String {
        let items = rows.map { "{\"kind\":\"row\",\"id\":\"\($0)\",\"text\":\"\",\"action\":\"\",\"params\":{},\"args\":{},\"props\":{},\"children\":[]}" }
        return "{\"kind\":\"screen\",\"id\":\"\",\"text\":\"\(name)\",\"action\":\"\",\"params\":{},\"args\":{},\"props\":{},\"children\":[\(items.joined(separator: ","))]}"
    }
}
