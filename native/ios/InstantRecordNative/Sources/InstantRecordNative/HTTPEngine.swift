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

    public func boot(database: String) -> Bool { true }
    public func open(database: String) -> Bool { true }
    public func notice() -> String { "" }
    public func error() -> String { problem }
    public func onExchange(_ answer: @escaping (String) -> String) {}

    public func call(_ entry: String, _ input: String) -> String? {
        guard entry == "render" || entry == "action" else { return "unchanged pending=0" }
        let answer = transport.exchange("POST \(server)/native/\(entry)\n\(input)")
        let parts = answer.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let body = parts.count > 1 ? String(parts[1]) : ""
        // An action answers with no content, a render with the screen.
        if parts[0].hasPrefix("2") { return body }
        problem = parts[0] == "0" ? "The server at \(server) did not answer." : body
        return nil
    }
}
