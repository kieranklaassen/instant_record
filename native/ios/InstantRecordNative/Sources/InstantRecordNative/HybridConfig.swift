import Foundation

/// What `/native/config.json` says about the app: its tabs and its tint. The
/// file behind it is `config/ruby_native.yml`, which the ruby_native gem
/// serves, so a deploy changes the app's tabs. Keys this shell has no use for
/// are ignored.
public struct HybridConfig: Equatable {
    public struct Tab: Equatable {
        public let title: String
        public let path: String
        /// An SF Symbol's name.
        public let icon: String
        public let key: String
        /// Whether a page's plain badge count goes on this tab.
        public let badge: Bool
        /// Whether the tab loads before it is first chosen.
        public let eager: Bool
        /// The Ruby screen that draws the tab in an app that has it. Ruby
        /// Native's own apps ignore the key and load `path`.
        public let screen: String?
    }

    public let tabs: [Tab]
    public let entryPath: String
    public let tint: (light: UInt32, dark: UInt32)?

    /// The app as one page, for a server with no config.
    static let bare = HybridConfig(tabs: [Tab(title: "Home", path: "/", icon: "house", key: "", badge: false, eager: false, screen: nil)], entryPath: "/", tint: nil)

    private init(tabs: [Tab], entryPath: String, tint: (light: UInt32, dark: UInt32)?) {
        self.tabs = tabs
        self.entryPath = entryPath
        self.tint = tint
    }

    /// Nil for what is not a config with a tab that can be shown, so that an
    /// error's JSON never takes the place of a good copy.
    public init?(json: Data, languages: [String] = Locale.preferredLanguages) {
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
        let listed = (object["tabs"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap { Self.tab($0, languages) } }
        guard let first = listed.first else { return nil }
        let entry = (object["app"] as? [String: Any])?["entry_path"] as? String ?? ""
        let appearance = object["appearance"] as? [String: Any]
        self.init(tabs: listed, entryPath: entry.hasPrefix("/") ? entry : first.path, tint: Self.tint(appearance?["tint_color"]))
    }

    public static func == (a: HybridConfig, b: HybridConfig) -> Bool {
        a.tabs == b.tabs && a.entryPath == b.entryPath && a.tint?.light == b.tint?.light && a.tint?.dark == b.tint?.dark
    }

    /// The tab a Ruby screen draws: the first whose screen this app has.
    /// The compiled library opens one database at a time, so there is one.
    func screenTab(registered: Set<String>) -> Int? {
        tabs.firstIndex { $0.screen.map(registered.contains) ?? false }
    }

    private static func tab(_ from: [String: Any], _ languages: [String]) -> Tab? {
        guard let path = from["path"] as? String, path.hasPrefix("/"), !path.hasPrefix("//") else { return nil }
        let titles = from["titles"] as? [String: String] ?? [:]
        let icons = from["icons"] as? [String: Any] ?? [:]
        let title = languages.lazy.compactMap { titles[$0] ?? titles[String($0.prefix { $0 != "-" })] }.first
        return Tab(title: title ?? from["title"] as? String ?? "", path: path,
                   icon: icons["ios"] as? String ?? from["icon"] as? String ?? "circle",
                   key: from["key"] as? String ?? "", badge: from["badge"] as? Bool ?? false,
                   eager: from["eager"] as? Bool ?? false, screen: from["screen"] as? String)
    }

    private static func tint(_ value: Any?) -> (light: UInt32, dark: UInt32)? {
        if let one = value as? String { return hex(one).map { ($0, $0) } }
        guard let pair = value as? [String: String] else { return nil }
        guard let light = hex(pair["light"] ?? pair["dark"] ?? ""), let dark = hex(pair["dark"] ?? pair["light"] ?? "") else { return nil }
        return (light, dark)
    }

    private static func hex(_ text: String) -> UInt32? {
        guard text.hasPrefix("#"), text.count == 7 else { return nil }
        return UInt32(text.dropFirst(), radix: 16)
    }
}

/// The last good config of a server, kept for the next launch and for when
/// the server cannot be reached.
struct HybridConfigStore {
    let server: URL
    let defaults: UserDefaults
    /// Asks for the config: a request in, "status\nbody" out (Transport.exchange).
    let exchange: (String) -> String
    private var key: String { "instant-record-hybrid-config " + server.absoluteString }

    func kept() -> HybridConfig? {
        defaults.data(forKey: key).flatMap { HybridConfig(json: $0) }
    }

    /// The server's config now. Nil, and nothing kept, unless it is a good one.
    func fetch() -> HybridConfig? {
        guard let address = URL(string: "/native/config.json", relativeTo: server)?.absoluteString else { return nil }
        let reply = Reply(exchange("GET \(address)\n"))
        let body = Data(reply.body.utf8)
        guard reply.status == 200, let config = HybridConfig(json: body) else { return nil }
        defaults.set(body, forKey: key)
        return config
    }
}
