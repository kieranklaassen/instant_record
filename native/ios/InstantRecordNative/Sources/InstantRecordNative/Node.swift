import Foundation

/// One element of a screen, as the Ruby view layer writes it
/// (lib/instant_record/native/node.rb). Every element has the same fields and
/// the renderer switches on `kind`.
public struct Node: Decodable, Equatable {
    public let kind: String
    public let id: String
    public let text: String
    public let action: String
    public let arg: String
    public let props: [String: String]
    public let children: [Node]

    public init(json: String) throws {
        self = try JSONDecoder().decode(Node.self, from: Data(json.utf8))
    }

    public func prop(_ name: String) -> String { props[name] ?? "" }
    public func children(of kind: String) -> [Node] { children.filter { $0.kind == kind } }
    public func children(except kinds: String...) -> [Node] { children.filter { !kinds.contains($0.kind) } }

    /// The children with the identity a list keeps them by: a node's `id`
    /// when it has one, which for a row is its record, or else its place.
    public var keyed: [Keyed] {
        children.enumerated().map { Keyed(key: $0.element.id.isEmpty ? "#\($0.offset)" : $0.element.id, node: $0.element) }
    }

    public struct Keyed: Identifiable, Equatable {
        public let key: String
        public let node: Node
        public var id: String { key }
    }
}

/// A screen and the argument it was opened with.
public struct Route: Hashable {
    public let screen: String
    public let arg: String

    public init(_ screen: String, _ arg: String) {
        self.screen = screen
        self.arg = arg
    }
}
