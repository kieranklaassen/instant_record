import SwiftUI

/// Views written in SwiftUI by hand, for a screen that asks for one by name:
///
///   # Ruby                                  // Swift, once at launch
///   swift "ConversationView" do             Screens.register("ConversationView") { props, actions in
///     prop "subject", message.subject           ConversationView(props: props, actions: actions)
///   end                                     }
///
/// The renderer looks the name up when it meets the element. The views live
/// in the app, and this package knows none of them.
public enum Screens {
    private static var views: [String: (Props, Actions) -> AnyView] = [:]

    public static func register<Content: View>(_ name: String, @ViewBuilder _ view: @escaping (Props, Actions) -> Content) {
        views[name] = { AnyView(view($0, $1)) }
    }

    static func view(_ name: String, _ props: Props, _ actions: Actions) -> AnyView? {
        views[name]?(props, actions)
    }
}

/// What a Ruby screen handed a Swift view: strings by name, and lists of
/// records that are themselves Props.
///
///   props["subject"]                      // "" when the screen gave none
///   props.list("messages").map { $0["author"] }
///   props.date("sent")                    // from ISO 8601
public struct Props: Equatable {
    private let values: [String: String]
    private let lists: [String: [Props]]

    public init(_ node: Node) {
        values = Dictionary(node.children(of: "prop").map { ($0.id, $0.text) }) { $1 }
        lists = Dictionary(node.children(of: "props").map { ($0.id, $0.children(of: "record").map(Props.init)) }) { $1 }
    }

    public subscript(name: String) -> String { values[name] ?? "" }
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

    public func perform(_ action: String, _ arg: String = "") {
        host.perform(action, arg: arg, on: route)
    }
}
