import Foundation
import WebKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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
    public convenience init(server: URL, app: AppHost? = nil, screens: Set<String> = [], views: Screens = Screens(), capabilities: Capabilities? = nil, outside: @escaping @MainActor (URL) -> Void = HybridHost.open) {
        let site = HybridSite(server: server, outside: outside)
        // Given none, the standard ones. An empty one allows none.
        let capabilities = capabilities ?? Capabilities()
        site.capabilities = capabilities
        if app?.capabilities == nil { app?.capabilities = capabilities }
        self.init(site: site, app: app, screens: screens, views: views, defaults: .standard, exchange: Transport().exchange)
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

    /// In the browser, or whichever app an address is.
    public static func open(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
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
        let drawn = config.screenTab(root: app?.home)
        let dropped = shown.compactMap(\.page)
        let entry = config.tabs.firstIndex { $0.path == config.entryPath }
        let before = Dictionary(shown.map { ($0.id, $0) }) { first, _ in first }
        var seen: [String: Int] = [:]
        func id(_ kind: String, _ name: String) -> String {
            seen[kind + name, default: 0] += 1
            return "\(kind) \(name) \(seen[kind + name]!)"
        }
        var entered = false
        shown = config.tabs.enumerated().map { n, tab in
            if n == drawn, let app { return Shown(id: id("screen", ""), tab: tab, kind: .screen(app)) }
            if let view = tab.view, views.has(view) { return Shown(id: id("view", view), tab: tab, kind: .view(view)) }
            // An entry that is no tab's own page is where the first page begins.
            let first = entry == nil && !entered ? config.entryPath : tab.path
            entered = true
            let id = id("page", first)
            return Shown(id: id, tab: tab, kind: .page(before[id]?.page ?? HybridTab(site: site, path: first)))
        }
        self.config = config
        // What a tab that is gone had opened is no longer on show.
        let kept = Set(shown.compactMap(\.page).map(ObjectIdentifier.init))
        for page in dropped where !kept.contains(ObjectIdentifier(page)) { app?.visited([], in: ObjectIdentifier(page)) }
        if !shown.contains(where: { $0.id == selected }) { selected = shown[entry ?? 0].id }
        for tab in shown where tab.tab.eager { tab.page?.load() }
    }
}
