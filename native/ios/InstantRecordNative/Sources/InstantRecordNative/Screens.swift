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

    func view(_ name: String, _ props: Props, _ actions: Actions) -> AnyView? {
        views[name]?(props, actions)
    }
}

/// What a Ruby screen handed a Swift view: values by name, and lists of
/// records that are themselves Props.
///
///   props["subject"]                      // "" when the screen gave none
///   props.bool("archived")                // from `flag`
///   props.int("unread")                   // from `number`
///   props.date("sent")                    // from ISO 8601
///   props.list("messages").map { $0["author"] }
public struct Props: Equatable {
    private let values: [String: String]
    private let lists: [String: [Props]]

    public init(_ node: Node) {
        let single = node.children.filter { ["prop", "flag", "number"].contains($0.kind) }
        values = Dictionary(single.map { ($0.id, $0.text) }) { $1 }
        lists = Dictionary(node.children(of: "props").map { ($0.id, $0.children(of: "record").map(Props.init)) }) { $1 }
    }

    public subscript(name: String) -> String { values[name] ?? "" }
    public func bool(_ name: String) -> Bool { values[name] == "true" }
    public func int(_ name: String) -> Int { Int(values[name] ?? "") ?? 0 }
    public func list(_ name: String) -> [Props] { lists[name] ?? [] }
    /// A moment the screen wrote as ISO 8601, or nil when it is not one.
    public func date(_ name: String) -> Date? { Moment.date(self[name]) }
}

/// How a Swift view sends a tap back to the Ruby screen that drew it. It
/// takes the same road as a tap on a Ruby-drawn button: the screen performs
/// it, the screens are drawn again, and the write syncs.
public struct Actions {
    let host: AppHost
    let route: Route

    public func perform(_ action: String, _ with: [String: String] = [:]) {
        host.perform(action, with: with, on: route)
    }
}
