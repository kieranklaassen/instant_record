import Foundation
import WebKit

/// The Rails server an app's pages come from, shared by every web view in
/// the app: its sign-in, and which of its addresses open as native places.
@MainActor
public final class HybridSite {
    public let server: URL
    let data: WKWebsiteDataStore
    let outside: (URL) -> Void
    /// The native place an address opens, if it opens one.
    private(set) var routes: [HybridConfig.Place] = [] {
        didSet { if routes != oldValue { changed.values.forEach { $0() } } }
    }
    private var changed: [ObjectIdentifier: () -> Void] = [:]

    /// `outside` opens what is another server's, or mail's, or the phone's.
    public convenience init(server: URL, outside: @escaping (URL) -> Void) {
        self.init(server: server, data: .default(), outside: outside)
    }

    init(server: URL, data: WKWebsiteDataStore, outside: @escaping (URL) -> Void) {
        self.server = server
        self.data = data
        self.outside = outside
    }

    func use(_ routes: [HybridConfig.Place]) { self.routes = routes }

    func place(at url: URL) -> (route: Route, sheet: Bool)? {
        guard Origin(url) == Origin(server) else { return nil }
        return routes.lazy.compactMap { place in place.route(for: url).map { ($0, place.sheet) } }.first
    }

    func watch(_ who: AnyObject, _ block: @escaping () -> Void) { changed[ObjectIdentifier(who)] = block }
    func unwatch(_ who: ObjectIdentifier) { changed[who] = nil }
}
