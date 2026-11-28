import SwiftUI

/// Views written in SwiftUI by hand, for a screen that asks for one by name:
///
///   # Ruby                                  // Swift, once at launch
///   swift "ConversationView" do             var views = Screens()
///     prop "subject", message.subject       views.register("ConversationView") { props, actions in
///     flag "archived", archived?                ConversationView(props: props, actions: actions)
///   end                                     }
///
/// The app fills one and hands it to its `AppHost`. The renderer looks the
/// name up when it meets the element. This package knows none of the views.
public struct Screens {
    private var views: [String: (Props, Actions) -> AnyView] = [:]

    public init() {}

    public mutating func register<Content: View>(_ name: String, @ViewBuilder _ view: @escaping (Props, Actions) -> Content) {
        views[name] = { AnyView(view($0, $1)) }
    }

    func has(_ name: String) -> Bool { views[name] != nil }

    func view(_ name: String, _ props: Props, _ actions: Actions) -> AnyView? {
        views[name]?(props, actions)
    }
}

/// What a Ruby screen handed a Swift view: values by name, each the kind the
/// screen said it was, and lists of records that are themselves Props. A
/// prop that was not sent reads as empty, false, zero or nil.
///
///   props["subject"]                      // from `prop`
///   props.bool("archived")                // from `flag`
///   props.int("unread")                   // from `number`
///   props.date("sent")                    // from `time`
///   props.list("messages").map { $0["author"] }
public struct Props: Equatable {
    struct Value: Equatable {
        let type: String
        let text: String
    }

    let values: [String: Value]
    let nestedObjects: [String: Props]
    let lists: [String: [Props]]
    let scalarLists: [String: [Value]]

    public init(_ node: Node) {
        values = Dictionary(node.children(of: "prop").map { ($0.prop("name"), Value(type: $0.prop("type"), text: $0.text)) }) { $1 }
        nestedObjects = Dictionary(
            node.children(of: "record")
                .filter { !$0.prop("name").isEmpty }
                .map { ($0.prop("name"), Props($0)) }
        ) { $1 }

        var recordLists: [String: [Props]] = [:]
        var valueLists: [String: [Value]] = [:]
        for listNode in node.children(of: "props") {
            let name = listNode.prop("name")
            let propItems = listNode.children(of: "prop")
            if !propItems.isEmpty && listNode.children(of: "record").isEmpty {
                valueLists[name] = propItems.map { Value(type: $0.prop("type"), text: $0.text) }
            } else {
                recordLists[name] = listNode.children(of: "record").map(Props.init)
            }
        }
        lists = recordLists
        scalarLists = valueLists
    }

    /// A view opened by its address has the address's params, all strings.
    init(params: [String: String]) {
        values = params.mapValues { Value(type: "string", text: $0) }
        nestedObjects = [:]
        lists = [:]
        scalarLists = [:]
    }

    public subscript(name: String) -> String { values[name]?.text ?? "" }
    public func bool(_ name: String) -> Bool { value(name, "bool") == "true" }
    public func int(_ name: String) -> Int { Int(value(name, "int") ?? "") ?? 0 }
    public func double(_ name: String) -> Double { Double(value(name, "float") ?? "") ?? 0 }
    public func date(_ name: String) -> Date? { value(name, "date").flatMap(Moment.date) }
    public func nested(_ name: String) -> Props? { nestedObjects[name] }
    public func list(_ name: String) -> [Props] { lists[name] ?? [] }

    // A value read as another kind than the screen sent is not there.
    private func value(_ name: String, _ type: String) -> String? {
        values[name].flatMap { $0.type == type ? $0.text : nil }
    }
}

/// How a Swift view sends a tap back to the Ruby screen that drew it. It
/// takes the same road as a tap on a Ruby-drawn button: the screen performs
/// it, the screens are drawn again, and the write syncs.
public struct Actions {
    let host: AppHost?
    let route: Route

    public func perform(_ action: String, _ args: [String: String] = [:], values: [String: String] = [:]) {
        // A view opened by its address has no Ruby screen behind it.
        host?.perform(action, args: args, values: values, on: route)
    }
}
