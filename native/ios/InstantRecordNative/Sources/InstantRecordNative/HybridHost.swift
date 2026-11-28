import Foundation
import WebKit

/// A hybrid app: the tabs the server's config names, each a web view or a
/// Ruby screen, and the config as it was last read.
@MainActor
public final class HybridHost: ObservableObject {
    /// One tab as shown.
    struct Shown: Identifiable {
        let id: String
        let tab: HybridConfig.Tab
        let page: HybridTab?
        let screen: AppHost?
    }

    @Published private(set) var config: HybridConfig
    @Published private(set) var shown: [Shown] = []
    @Published var selected = ""
    private let server: URL
    private let screens: [String: AppHost]
    private let store: HybridConfigStore
    private let data: WKWebsiteDataStore
    private let outside: (URL) -> Void
    private var reading = false

    /// `screens` are the Ruby screens this app has, by the name a tab's
    /// `screen:` gives. Its AppHost is started by the app.
    public convenience init(server: URL, screens: [String: AppHost] = [:], outside: @escaping (URL) -> Void) {
        self.init(server: server, screens: screens, data: .default(), defaults: .standard, exchange: Transport().exchange, outside: outside)
    }

    init(server: URL, screens: [String: AppHost], data: WKWebsiteDataStore, defaults: UserDefaults, exchange: @escaping (String) -> String, outside: @escaping (URL) -> Void) {
        self.server = server
        self.screens = screens
        self.data = data
        self.outside = outside
        store = HybridConfigStore(server: server, defaults: defaults, exchange: exchange)
        config = store.kept() ?? .bare
        show(config)
    }

    /// The app came to the front: read the config again.
    public func front() { Task { await refresh() } }

    func refresh() async {
        guard !reading else { return }
        reading = true
        defer { reading = false }
        let store = store
        let fresh = await Task.detached { store.fetch() }.value
        if let fresh, fresh != config { show(fresh) }
    }

    // A tab that is still listed keeps its web view, and where it was.
    private func show(_ config: HybridConfig) {
        let drawn = config.screenTab(registered: Set(screens.keys))
        let entry = config.tabs.firstIndex { $0.path == config.entryPath }
        var seen: [String: Int] = [:]
        let before = Dictionary(shown.map { ($0.id, $0) }) { first, _ in first }
        shown = config.tabs.enumerated().map { n, tab in
            let screen = n == drawn ? tab.screen.flatMap { screens[$0] } : nil
            let kind = screen == nil ? "page" : "screen"
            let same = "\(kind) \(tab.path)"
            seen[same, default: 0] += 1
            let id = "\(same) \(seen[same]!)"
            // An entry that is no tab's own page is where the first begins.
            let first = n == 0 && entry == nil ? config.entryPath : tab.path
            let page = screen == nil ? before[id]?.page ?? HybridTab(server: server, path: first, data: data, outside: outside) : nil
            return Shown(id: id, tab: tab, page: page, screen: screen)
        }
        self.config = config
        if !shown.contains(where: { $0.id == selected }) { selected = shown[entry ?? 0].id }
        for tab in shown where tab.tab.eager { tab.page?.start() }
    }
}
