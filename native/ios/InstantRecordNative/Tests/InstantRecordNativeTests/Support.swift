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

/// A yes or no that one thread sets and another reads.
final class Flag {
    private let lock = NSLock()
    private var value = false
    var on: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
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
///
/// The engine's thread writes what a test's thread reads, so everything a
/// test looks at is kept behind one lock and read as a copy.
final class FakeEngine: Engine {
    private let lock = NSLock()
    private var kept: (calls: [String], answered: [String], push: String, rows: [String]) = ([], [], "", ["m2", "m1"])
    var calls: [String] {
        get { lock.withLock { kept.calls } }
        set { lock.withLock { kept.calls = newValue } }
    }
    /// What the host answered each request the library made during `sync`.
    var answered: [String] {
        get { lock.withLock { kept.answered } }
        set { lock.withLock { kept.answered = newValue } }
    }
    var push: String {
        get { lock.withLock { kept.push } }
        set { lock.withLock { kept.push = newValue } }
    }
    var rows: [String] {
        get { lock.withLock { kept.rows } }
        set { lock.withLock { kept.rows = newValue } }
    }
    var noticeAfter: [String: String] = [:]
    var noticesCount = 0
    var noticesResponses: [String: String] = [:]
    var raises: Set<String> = []
    var unreadable = false
    var bootstrapped = true
    var boots = true
    var syncs = true
    var nextReleaseMs: Int? = nil
    var shellFingerprint = ""
    var cursorValue = 7
    var identityValue = ""
    var onOpen: ((String) -> Bool)?
    private var last = ""
    private var endpoint = ""
    private var answer: (String) -> String = { _ in Transport.offline }

    func boot(database: String) -> Bool {
        note("boot " + database)
        return boots
    }

    func open(database: String) -> Bool {
        note("open " + database)
        if let onOpen { return onOpen(database) }
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
            note(line.trimmingCharacters(in: .whitespaces))
            if raises.contains(entry) { return nil }
            if entry == "action" {
                if let id = (object["args"] as? [String: String])?["id"] { lock.withLock { kept.rows.removeAll { $0 == id } } }
                push = "{\"mutations\":[\"" + (object["action"] as? String ?? "") + "\"]}"
                return ""
            }
            return unreadable ? "{\"kind\":" : FakeEngine.screen(screen, rows)
        case "sync_plan":
            note("sync_plan")
            if raises.contains(entry) { return nil }
            let fp = shellFingerprint.isEmpty ? "" : ",\"fingerprint\":\(FakeEngine.quoted(shellFingerprint))"
            return "{\"push\":\(FakeEngine.quoted(push)),\"bootstrap\":\(!bootstrapped)\(fp)}"
        case "cursor":
            let release = nextReleaseMs.map { " next_release_ms=\($0)" } ?? ""
            return "cursor=\(cursorValue) pending=\(push.isEmpty ? 0 : 1) bootstrap=\(bootstrapped ? "ready" : "needed") identity=\(identityValue) notices=\(noticesCount)\(release)"
        case "notices":
            let object = (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [String: Any] ?? [:]
            let action = object["action"] as? String ?? "list"
            let id = object["id"] as? String ?? ""
            note(id.isEmpty ? "notices \(action)" : "notices \(action) \(id)")
            if raises.contains(entry) { return nil }
            return noticesResponses[action] ?? "{\"ok\":true,\"notices\":[]}"
        case "sync":
            note("sync " + input)
            if raises.contains(entry) { return nil }
            if !push.isEmpty {
                let reply = ask("POST \(input)/mutations\n\(push)")
                if reply.hasPrefix("2") { push = "" } else { return "unchanged" }
            }
            let who = identityValue.isEmpty ? "" : "&identity=\(identityValue)"
            if ask(bootstrapped ? "GET \(input)/events?after=\(cursorValue)&window=0\(who)\n" : "GET \(input)/bootstrap\n").hasPrefix("2") { bootstrapped = true }
            return "changed"
        default:
            note(entry + " " + input)
            return raises.contains(entry) ? nil : ""
        }
    }

    func notice() -> String { noticeAfter[last] ?? "" }
    func error() -> String { "ArgumentError: No screen named nowhere" }
    func onExchange(_ answer: @escaping (String) -> String) { self.answer = answer }

    private func note(_ call: String) { lock.withLock { kept.calls.append(call) } }
    private func heard(_ answer: String) { lock.withLock { kept.answered.append(answer) } }

    private func ask(_ request: String) -> String {
        let reply = answer(request)
        heard(String(request.prefix { $0 != "\n" }) + " -> " + String(reply.prefix { $0 != "\n" }))
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
