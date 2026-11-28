import Foundation

/// The app's tabs, routes and tint: `config/native.yml`, which the gem serves
/// at `native/config`, so a deploy changes them. Keys this app has no use for
/// are ignored, so that an older app reads a newer file.
public struct HybridConfig: Equatable {
    public struct Tab: Equatable {
        public let title: String
        public let path: String
        /// An SF Symbol's name.
        public let icon: String
        public let key: String
        /// Whether the tab loads before it is first chosen.
        public let eager: Bool
        /// The Ruby screen that draws the tab, in an app that has it.
        public let screen: String?
        /// The SwiftUI view that draws it, in an app that registered it.
        public let view: String?
    }

    /// An address that opens a native place in an app that has it, and is an
    /// ordinary page in one that does not, and on the web.
    public struct Place: Equatable {
        /// "/orders/:id": a word after a colon is a param of the place.
        public let path: String
        public let screen: String?
        public let view: String?
        public let sheet: Bool
        /// An address that stays a page though a later route would take it.
        public var page = false

        private var parts: [Substring] { path.split(separator: "/") }

        /// The place's route at an address, with the address's own words and
        /// its query as params. A word in the path wins over the query.
        func route(for url: URL) -> Route? {
            guard let params = params(for: url) else { return nil }
            if let screen { return Route(screen, params) }
            return view.map { Route.view($0, params) }
        }

        /// The params of an address that matches, page or place.
        func params(for url: URL) -> [String: String]? {
            guard let parsed = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
            let words = parsed.percentEncodedPath.split(separator: "/")
            guard words.count == parts.count else { return nil }
            var params = Dictionary((parsed.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { $1 }
            for (part, word) in zip(parts, words) {
                let word = word.removingPercentEncoding ?? String(word)
                if part.hasPrefix(":") { params[String(part.dropFirst())] = word } else if String(part) != word { return nil }
            }
            return params
        }

        /// The same match, for the page script, which must decide at once.
        var pattern: String {
            "^/" + parts.map { $0.hasPrefix(":") ? "[^/]+" : NSRegularExpression.escapedPattern(for: String($0)).replacingOccurrences(of: "/", with: "\\/") }.joined(separator: "/") + "/?$"
        }
    }

    public let tabs: [Tab]
    public let routes: [Place]
    public let entryPath: String
    public let tint: (light: UInt32, dark: UInt32)?

    /// The app as one page, for a server with no config.
    static let bare = HybridConfig(tabs: [Tab(title: "Home", path: "/", icon: "house", key: "", eager: false, screen: nil, view: nil)], routes: [], entryPath: "/", tint: nil)

    private init(tabs: [Tab], routes: [Place], entryPath: String, tint: (light: UInt32, dark: UInt32)?) {
        self.tabs = tabs
        self.routes = routes
        self.entryPath = entryPath
        self.tint = tint
    }

    /// Nil for what is not a config with a tab that can be shown, so that an
    /// error's JSON never takes the place of a good copy.
    public init?(json: Data, languages: [String] = Locale.preferredLanguages) {
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
        let listed = (object["tabs"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap { Self.tab($0, languages) } }
        guard let first = listed.first else { return nil }
        let entry = object["start"] as? String ?? ""
        let routes = (object["routes"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(Self.place) }
        self.init(tabs: listed, routes: routes, entryPath: entry.hasPrefix("/") ? entry : first.path, tint: Self.tint(object["tint"]))
    }

    public static func == (a: HybridConfig, b: HybridConfig) -> Bool {
        a.tabs == b.tabs && a.routes == b.routes && a.entryPath == b.entryPath && a.tint?.light == b.tint?.light && a.tint?.dark == b.tint?.dark
    }

    /// The tab Ruby draws: the first that names the app's first screen.
    func screenTab(root: String?) -> Int? {
        tabs.firstIndex { $0.screen != nil && $0.screen == root }
    }

    /// The routes this app can open. An older app than the config leaves out
    /// those it lacks, and their addresses stay pages.
    func places(screens: Set<String>, views: Screens) -> [Place] {
        routes.filter { $0.page || ($0.screen.map(screens.contains) ?? $0.view.map(views.has) ?? false) }
    }

    private static func place(_ from: [String: Any]) -> Place? {
        guard let path = from["path"] as? String, path.hasPrefix("/"), !path.hasPrefix("//") else { return nil }
        let screen = from["screen"] as? String, view = from["view"] as? String
        let page = from["page"] as? Bool ?? false
        // One of the three. More is a mistake with no right reading.
        guard [screen != nil, view != nil, page].filter({ $0 }).count == 1 else { return nil }
        return Place(path: path, screen: screen, view: view, sheet: from["sheet"] as? Bool ?? false, page: page)
    }

    private static func tab(_ from: [String: Any], _ languages: [String]) -> Tab? {
        guard let path = from["path"] as? String, path.hasPrefix("/"), !path.hasPrefix("//") else { return nil }
        let titles = from["titles"] as? [String: String] ?? [:]
        let title = languages.lazy.compactMap { titles[$0] ?? titles[String($0.prefix { $0 != "-" })] }.first
        return Tab(title: title ?? from["title"] as? String ?? "", path: path,
                   icon: from["icon"] as? String ?? "circle",
                   key: from["key"] as? String ?? "",
                   eager: from["eager"] as? Bool ?? false, screen: from["screen"] as? String, view: from["view"] as? String)
    }

    private static func tint(_ value: Any?) -> (light: UInt32, dark: UInt32)? {
        if let one = value as? String { return hex(one).map { ($0, $0) } }
        guard let pair = value as? [String: String] else { return nil }
        guard let light = hex(pair["light"] ?? pair["dark"] ?? ""), let dark = hex(pair["dark"] ?? pair["light"] ?? "") else { return nil }
        return (light, dark)
    }

    static func hex(_ text: String) -> UInt32? {
        guard text.hasPrefix("#"), text.count == 7 else { return nil }
        return UInt32(text.dropFirst(), radix: 16)
    }
}

/// The last good config of a server, kept for the next launch and for when
/// the server cannot be reached.
struct HybridConfigStore {
    let server: URL
    /// Where the gem's engine is mounted.
    var mount = "/instant_record"
    let defaults: UserDefaults
    /// Asks for the config: a request in, "status\nbody" out (Transport.exchange).
    let exchange: (String) -> String
    private var key: String { "instant-record-hybrid-config " + server.absoluteString }

    func kept() -> HybridConfig? {
        defaults.data(forKey: key).flatMap { HybridConfig(json: $0) }
    }

    /// The server's config now. Nil, and nothing kept, unless it is a good one.
    func fetch() -> HybridConfig? {
        guard let address = URL(string: mount + "/native/config", relativeTo: server)?.absoluteString else { return nil }
        let reply = Reply(exchange("GET \(address)\n"))
        let body = Data(reply.body.utf8)
        guard reply.status == 200, let config = HybridConfig(json: body) else { return nil }
        defaults.set(body, forKey: key)
        return config
    }
}
