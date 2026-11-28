import Foundation

/// What the device can do, by name, for all three ways to write an app:
///
///     Ruby      button "Buzz", action: "native:haptics.play", args: { "style" => "success" }
///     a page    await InstantRecord.call("haptics.play", { style: "success" })
///     SwiftUI   try await capabilities.call("haptics.play", ["style": "success"])
///
/// Any Apple API is added the same way, in a few lines:
///
///     capabilities.add("health.steps") { arguments in ["count": try await steps()] }
///
/// Nothing else can be called. A page is what a server sent, so it reaches
/// only names the app added: the standard ones ask for nothing and keep no
/// secret, and the rest are added by group (`capabilities.allow(.location)`).
@MainActor
public final class Capabilities {
    public typealias Arguments = [String: String]
    public typealias Handler = @MainActor (Arguments) async throws -> [String: Any]

    public struct Failure: LocalizedError, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// Those that ask the person, or hand over what is theirs.
    public enum Group: CaseIterable, Sendable {
        case biometrics, clipboardReading, keychain, location, notifications, recording
    }

    private var handlers: [String: Handler] = [:]

    /// `standard` adds the capabilities that ask for no permission.
    public init(standard: Bool = true) {
        if standard { addStandard() }
        add("capabilities.list") { [unowned self] _ in ["names": self.names] }
    }

    public var names: [String] { handlers.keys.sorted() }

    /// Add one, or take the place of one.
    public func add(_ name: String, _ handler: @escaping Handler) { handlers[name] = handler }

    /// Let Ruby, pages and views use a group that is not standard.
    @discardableResult
    public func allow(_ groups: Group...) -> Capabilities {
        groups.forEach(addGroup)
        return self
    }

    @discardableResult
    public func call(_ name: String, _ arguments: Arguments = [:]) async throws -> [String: Any] {
        guard let handler = handlers[name] else { throw Failure("This app has no \(name)") }
        return try await handler(arguments)
    }

    /// A page's arguments as strings by name. What is not a plain value is left out.
    static func arguments(_ from: Any?) -> Arguments {
        (from as? [String: Any] ?? [:]).compactMapValues(text)
    }

    /// An answer as strings by name, as Ruby takes them.
    static func strings(_ answer: [String: Any]) -> Arguments {
        answer.compactMapValues { value in
            text(value) ?? (try? JSONSerialization.data(withJSONObject: value)).map { String(decoding: $0, as: UTF8.self) }
        }
    }

    private static func text(_ value: Any) -> String? {
        switch value {
        case let text as String: text
        case let number as NSNumber: CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
        default: nil
        }
    }
}
