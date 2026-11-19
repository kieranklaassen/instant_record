import Foundation

/// The app's screens, asked of a running Rails server: for development, so
/// that editing a screen's Ruby shows on the phone after a pull, with no
/// rebuild. The server runs the same screen classes and answers with the same
/// JSON as the compiled library (config.instant_record.native_dev). There is
/// no database on the phone in this mode and nothing to sync.
public final class HTTPEngine: Engine {
    private let server: String
    private let transport: Transport
    private var problem = ""

    /// `server` is where the gem's engine is mounted, such as
    /// http://localhost:3000/instant_record.
    public init(server: String, transport: Transport = Transport()) {
        self.server = server
        self.transport = transport
    }

    public var syncs: Bool { false }
    public func boot(database: String) -> Bool { true }
    public func open(database: String) -> Bool { true }
    public func notice() -> String { "" }
    public func error() -> String { problem }
    public func onExchange(_ answer: @escaping (String) -> String) {}

    public func call(_ entry: String, _ input: String) -> String? {
        // Nothing is kept on the phone in this mode: only screens and taps go to the server.
        guard entry == "render" || entry == "action" else { return "" }
        let reply = Reply(transport.exchange("POST \(server)/native/\(entry)\n\(input)"))
        // An action answers with no content, a render with the screen.
        if reply.ok { return reply.body }
        problem = reply.status == 0 ? "The server at \(server) did not answer." : reply.body
        return nil
    }
}
