import Foundation

/// One element of a screen, as the Ruby view layer writes it
/// (lib/instant_record/native/node.rb). Every element has the same fields and
/// the renderer switches on `kind`. `params` are what the screen a link
/// leads to is opened with, and `args` are what the element's action is
/// performed with.
public struct Node: Decodable, Equatable {
    public let kind: String
    public let id: String
    public let text: String
    public let action: String
    public let params: [String: String]
    public let args: [String: String]
    public let props: [String: String]
    public let children: [Node]

    public init(json: String) throws {
        self = try JSONDecoder().decode(Node.self, from: Data(json.utf8))
    }

    public func prop(_ name: String) -> String { props[name] ?? "" }
    public func children(of kind: String) -> [Node] { children.filter { $0.kind == kind } }

    /// The children with the identity a list keeps them by: a node's `id`
    /// when it has one, which for a row is its record, or else its place.
    public var keyed: [Keyed] { Node.keyed(children) }

    public static func keyed(_ nodes: [Node]) -> [Keyed] {
        nodes.enumerated().map { Keyed(key: $0.element.id.isEmpty ? "#\($0.offset)" : $0.element.id, node: $0.element) }
    }

    public struct Keyed: Identifiable, Equatable {
        public let key: String
        public let node: Node
        public var id: String { key }
    }
}

/// A screen and the named values it was opened with.
public struct Route: Hashable {
    public let screen: String
    public let params: [String: String]

    public init(_ screen: String, _ params: [String: String] = [:]) {
        self.screen = screen
        self.params = params
    }

    /// What a render or an action is asked with: one JSON object, so that no
    /// value's meaning depends on what characters it holds.
    /// An action carries the arguments of the element that was tapped and the
    /// values of the screen's fields, each under its own name.
    func input(action: String? = nil, args: [String: String] = [:], values: [String: String] = [:]) -> String {
        var object: [String: Any] = ["screen": screen, "params": params]
        if let action {
            object["action"] = action
            object["args"] = args
            object["values"] = values
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
