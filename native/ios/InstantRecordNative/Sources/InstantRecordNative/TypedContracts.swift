import Foundation
import SwiftUI

/// A strongly typed action a native view can dispatch back to its Ruby screen.
/// Generated action enums conform to this protocol.
public protocol NativeAction: Sendable {
    var actionName: String { get }
    var actionArgs: [String: String] { get }
    var actionValues: [String: String] { get }
}

/// Default action type for components that declare no actions.
public enum NoAction: NativeAction, Equatable, Sendable {
    public var actionName: String { "" }
    public var actionArgs: [String: String] { [:] }
    public var actionValues: [String: String] { [:] }
}

/// A strongly typed `Codable` props contract generated from a Ruby screen's
/// `contract` declaration.
public protocol NativeProps: Decodable, Equatable, Sendable {
    associatedtype Action: NativeAction = NoAction
    static var componentName: String { get }
}

/// An `@Observable` state container backed by a `NativeProps` snapshot and
/// typed action dispatcher, preserving view identity across `AppHost` redraws.
public protocol NativePropsState: AnyObject {
    associatedtype Props: NativeProps
    init(props: Props, actions: TypedActions<Props.Action>)
    func apply(_ props: Props)
}

/// Type-safe wrapper around `Actions` for dispatching generated `NativeAction`
/// cases (carrying both `args` and `values`) back to the Ruby screen.
public struct TypedActions<Action: NativeAction> {
    public let raw: Actions

    public init(_ actions: Actions) {
        self.raw = actions
    }

    public func send(_ action: Action) {
        raw.perform(action.actionName, action.actionArgs, values: action.actionValues)
    }

    public func callAsFunction(_ action: Action) {
        send(action)
    }
}

/// Canonical string encoding for non-string action parameters crossing into
/// the monomorphic `Hash[String, String]` Ruby bridge.
public enum NativeWire {
    public static func encode(_ value: String) -> String { value }
    public static func encode(_ value: Int) -> String { String(value) }
    public static func encode(_ value: Double) -> String { String(value) }
    public static func encode(_ value: Bool) -> String { value ? "true" : "false" }

    public static func encode(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }
}

/// Raised when a `Props` payload cannot be coerced to the target `Codable`
/// contract (for example, a malformed number or date string).
public enum PropsDecodingError: Error, LocalizedError, Equatable {
    case invalidValue(name: String, expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidValue(name, expected, actual):
            "Prop \(name) expected \(expected), got \(actual)"
        }
    }
}

public extension Props {
    /// Convert this typed `Props` tree into a canonical JSON object suitable
    /// for decoding any generated `Codable` props struct.
    func jsonObject() throws -> [String: Any] {
        var object: [String: Any] = [:]

        for (name, value) in values {
            object[name] = try Self.wireValue(value, name: name)
        }
        for (name, nested) in nestedObjects {
            object[name] = try nested.jsonObject()
        }
        for (name, records) in lists {
            object[name] = try records.map { try $0.jsonObject() }
        }
        for (name, items) in scalarLists {
            object[name] = try items.enumerated().map { index, item in
                try Self.wireValue(item, name: "\(name)[\(index)]")
            }
        }

        return object
    }

    /// Decode this `Props` tree into a strongly typed `Decodable` struct.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let object = try jsonObject()
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let parsed = Moment.date(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO 8601 date: \(raw)"
                )
            }
            return parsed
        }
        return try decoder.decode(T.self, from: data)
    }

    private static func wireValue(_ value: Value, name: String) throws -> Any {
        switch value.type {
        case "bool":
            if value.text == "true" { return true }
            if value.text == "false" { return false }
            throw PropsDecodingError.invalidValue(name: name, expected: "bool", actual: value.text)
        case "int":
            guard let parsed = Int(value.text) else {
                throw PropsDecodingError.invalidValue(name: name, expected: "int", actual: value.text)
            }
            return parsed
        case "float":
            guard let parsed = Double(value.text), parsed.isFinite else {
                throw PropsDecodingError.invalidValue(name: name, expected: "float", actual: value.text)
            }
            return parsed
        case "date", "string", "":
            return value.text
        default:
            return value.text
        }
    }
}

public extension Screens {
    /// Register a SwiftUI view bound directly to a generated `NativeProps`
    /// `Codable` struct and its typed `TypedActions` dispatcher.
    mutating func register<P: NativeProps, Content: View>(
        _ propsType: P.Type,
        @ViewBuilder _ view: @escaping (P, TypedActions<P.Action>) -> Content
    ) {
        register(P.componentName) { props, actions in
            TypedPropsView(props: props, actions: actions, propsType: propsType, content: view)
        }
    }

    /// Register a SwiftUI view bound to a generated `@Observable`
    /// `NativePropsState` store whose properties update in-place across redraws.
    mutating func register<S: NativePropsState, Content: View>(
        state stateType: S.Type,
        @ViewBuilder _ view: @escaping (S) -> Content
    ) {
        register(S.Props.componentName) { props, actions in
            TypedStateView(props: props, actions: actions, stateType: stateType, content: view)
        }
    }
}

private struct TypedPropsView<P: NativeProps, Content: View>: View {
    let props: Props
    let actions: Actions
    let propsType: P.Type
    let content: (P, TypedActions<P.Action>) -> Content

    var body: some View {
        switch decode() {
        case let .success(decoded):
            content(decoded, TypedActions(actions))
        case let .failure(error):
            ContractDecodeFailureView(component: P.componentName, error: error)
        }
    }

    private func decode() -> Result<P, Error> {
        Result { try props.decode(P.self) }
    }
}

private struct TypedStateView<S: NativePropsState, Content: View>: View {
    let props: Props
    let actions: Actions
    let stateType: S.Type
    let content: (S) -> Content

    var body: some View {
        switch Result(catching: { try props.decode(S.Props.self) }) {
        case let .success(decoded):
            NativeStateHost(decoded: decoded, actions: TypedActions(actions), content: content)
        case let .failure(error):
            ContractDecodeFailureView(component: S.Props.componentName, error: error)
        }
    }
}

/// Keeps the `@Observable` state instance alive in `@State` across redraws and
/// applies new decoded `NativeProps` snapshots in-place.
private struct NativeStateHost<S: NativePropsState, Content: View>: View {
    let decoded: S.Props
    let content: (S) -> Content
    @State private var state: S

    init(decoded: S.Props, actions: TypedActions<S.Props.Action>, content: @escaping (S) -> Content) {
        self.decoded = decoded
        self.content = content
        _state = State(initialValue: S(props: decoded, actions: actions))
    }

    var body: some View {
        content(state)
            .onChange(of: decoded) { _, next in
                state.apply(next)
            }
    }
}

private struct ContractDecodeFailureView: View {
    let component: String
    let error: Error

    var body: some View {
        Label("Could not decode \(component): \(error.localizedDescription)", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
    }
}
