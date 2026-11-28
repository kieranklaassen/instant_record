import Foundation
import WebKit

/// A hybrid app: the tabs and routes the server's config names, each drawn
/// by a web page, a Ruby screen or a SwiftUI view, whichever this app has.
@MainActor
public final class HybridHost: ObservableObject {
    /// One tab as shown: one of the three.
    struct Shown: Identifiable {
        enum Kind { case page(HybridTab), screen(AppHost), view(String) }
        let id: String
        let tab: HybridConfig.Tab
        let kind: Kind
        var page: HybridTab? { if case .page(let page) = kind { page } else { nil } }
    }

    @Published private(set) var config: HybridConfig
    @Published private(set) var shown: [Shown] = []
    @Published var selected = ""
    public let site: HybridSite
    /// The app whose Ruby draws screens, when there is one.
    let app: AppHost?
    let views: Screens
    private let screens: Set<String>
    private let store: HybridConfigStore
    private var reading = false

    /// - app: the compiled app, started. A tab that names its first screen is
    ///   drawn by it.
    /// - screens: the Ruby screens a route may open, by name.
    /// - views: SwiftUI views for an app with no compiled Ruby. With `app`,
    ///   its own are used.
    public convenience init(server: URL, app: AppHost? = nil, screens: Set<String> = [], views: Screens = Screens(), outside: @escaping (URL) -> Void) {
        self.init(site: HybridSite(server: server, outside: outside), app: app, screens: screens, views: views, defaults: .standard, exchange: Transport().exchange)
    }

    init(site: HybridSite, app: AppHost?, screens: Set<String>, views: Screens, defaults: UserDefaults, exchange: @escaping (String) -> String) {
        self.site = site
        self.app = app
        self.screens = app == nil ? [] : screens
        self.views = app?.views ?? views
        store = HybridConfigStore(server: site.server, defaults: defaults, exchange: exchange)
        config = store.kept() ?? .bare
        app?.site = site
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
        site.use(config.places(screens: screens, views: views))
        let drawn = config.screenTab(root: app?.root.screen)
        let entry = config.tabs.firstIndex { $0.path == config.entryPath }
        let before = Dictionary(shown.map { ($0.id, $0) }) { first, _ in first }
        var seen: [String: Int] = [:]
        func id(_ kind: String, _ name: String) -> String {
            seen[kind + name, default: 0] += 1
            return "\(kind) \(name) \(seen[kind + name]!)"
        }
        shown = config.tabs.enumerated().map { n, tab in
            if n == drawn, let app { return Shown(id: id("screen", ""), tab: tab, kind: .screen(app)) }
            if let view = tab.view, views.has(view) { return Shown(id: id("view", view), tab: tab, kind: .view(view)) }
            let id = id("page", tab.path)
            // An entry that is no tab's own page is where the first begins.
            let first = n == 0 && entry == nil ? config.entryPath : tab.path
            return Shown(id: id, tab: tab, kind: .page(before[id]?.page ?? HybridTab(site: site, path: first)))
        }
        self.config = config
        if !shown.contains(where: { $0.id == selected }) { selected = shown[entry ?? 0].id }
        for tab in shown where tab.tab.eager { tab.page?.load() }
    }
}
