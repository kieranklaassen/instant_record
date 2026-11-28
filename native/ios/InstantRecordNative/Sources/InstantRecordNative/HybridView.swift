#if os(iOS)
import SwiftUI
import WebKit

/// A hybrid app's whole interface: pages Rails serves, with the tabs, bars,
/// buttons and menus they ask for drawn natively.
///
///     HybridView(host: HybridHost(server: server) { UIApplication.shared.open($0) })
public struct HybridView: View {
    @ObservedObject private var host: HybridHost
    @Environment(\.scenePhase) private var phase
    private let theme: Theme
    /// What the page last on show asked for. It stands for a tab whose page
    /// is still loading, so that the tab bar stays through the wait.
    @State private var latest: PageSignals?

    public init(host: HybridHost, theme: Theme = .system) {
        self.host = host
        self.theme = theme
    }

    public var body: some View {
        TabView(selection: $host.selected) {
            ForEach(host.shown) { shown in
                content(shown)
                    .tabItem { Label(shown.tab.title, systemImage: shown.tab.icon) }
                    .badge(latest?.badge(for: shown.tab).map { Text(verbatim: $0) })
                    .tag(shown.id)
            }
        }
        .tint(tint)
        .environment(\.theme, theme)
        .onChange(of: phase, initial: true) { _, now in
            if now == .active { host.front() }
            // Also where no Ruby tab has been on show: a page may open a screen.
            host.app?.front(now == .active)
        }
    }

    @ViewBuilder private func content(_ shown: HybridHost.Shown) -> some View {
        switch shown.kind {
        case .screen(let app): AppView(host: app, theme: theme)
        case .view(let name):
            NavigationStack { PlaceView(route: .view(name), host: host.app, site: host.site, views: host.views, pushed: false) }
        case .page(let page):
            PageStack(page: page, host: host.app, site: host.site, views: host.views, theme: theme,
                      tabs: host.shown.count, latest: latest) { signals in
                if let signals, shown.id == host.selected { latest = signals }
            }
        }
    }

    private var tint: Color {
        guard let tint = host.config.tint else { return theme.tint }
        return Color(Theme.Shade(light: tint.light, dark: tint.dark))
    }
}

/// A tab's page, with the native places it opens pushed over it.
private struct PageStack: View {
    @ObservedObject var page: HybridTab
    let host: AppHost?
    let site: HybridSite
    let views: Screens
    let theme: Theme
    let tabs: Int
    let latest: PageSignals?
    let changed: (PageSignals?) -> Void

    private var bar: Bool { tabBarShows(tabs: tabs, screen: !page.path.isEmpty, signals: page.signals ?? latest) }

    var body: some View {
        VStack(spacing: 0) {
            if let host, page.path.contains(where: \.isScreen) { AppBanners(host: host, theme: theme) }
            NavigationStack(path: $page.path) {
                HybridPage(page: page)
                    .navigationDestination(for: Route.self) { PlaceView(route: $0, host: host, site: site, views: views) }
            }
        }
        .toolbar(bar ? .visible : .hidden, for: .tabBar)
        .modifier(PageSheet(page: page, host: host, site: site, views: views, theme: theme))
        .environment(\.opens, Opens(push: { page.path.append($0) }, sheet: { page.sheet = $0 }, replace: { if !page.path.isEmpty { page.path[page.path.count - 1] = $0 } }))
        .onAppear { changed(page.signals) }
        .onChange(of: page.signals) { _, now in changed(now) }
        .onChange(of: page.path) { visited() }
        .onChange(of: page.sheet) { visited() }
    }

    private func visited() {
        host?.visited(page.path + (page.sheet.map { [$0] } ?? []), in: ObjectIdentifier(page))
    }
}

private struct PageSheet: ViewModifier {
    @ObservedObject var page: HybridTab
    let host: AppHost?
    let site: HybridSite
    let views: Screens
    let theme: Theme

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { page.sheet != nil }, set: { if !$0 { page.sheet = nil } })) {
            if let route = page.sheet { SheetView(route: route, host: host, site: site, views: views, theme: theme) }
        }
    }
}

/// A page that a native stack, a sheet or a Ruby screen holds. What it opens
/// goes where its holder's links go.
struct PagePlace: View {
    @StateObject private var page: HybridTab
    private let pushed: Bool
    @Environment(\.opens) private var opens
    @Environment(\.embedded) private var embedded

    init(site: HybridSite, path: String, pushed: Bool = true) {
        _page = StateObject(wrappedValue: HybridTab(site: site, path: path))
        self.pushed = pushed
    }

    var body: some View {
        content
            .onChange(of: page.path) { _, now in
                if let route = now.last { page.path = []; opens.push?(route) }
            }
            .onChange(of: page.sheet) { _, now in
                if let route = now { page.sheet = nil; opens.sheet?(route) }
            }
    }

    @ViewBuilder private var content: some View {
        if embedded {
            HybridPage(page: page, bar: .none)
        } else if pushed {
            HybridPage(page: page, bar: .always)
        } else {
            NavigationStack { HybridPage(page: page, bar: .always) }
        }
    }
}

/// One page under its native bar.
private struct HybridPage: View {
    enum Bar { case asked, always, none }
    @ObservedObject var page: HybridTab
    /// `asked`: a bar when the page asks for one. `always`: also without,
    /// for the way back. `none`: the holder's.
    var bar = Bar.asked
    @Environment(\.theme) private var theme

    private var navbar: PageSignals.Navbar? { page.failure == nil ? page.signals?.navbar : nil }

    var body: some View {
        Group {
            if bar == .none {
                content
            } else {
                content
                    .navigationTitle(navbar?.title ?? page.web.title ?? "")
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationBarBackButtonHidden(page.canGoBack)
                    .toolbar { if let navbar { items(navbar) } else if bar == .always { back } }
                    .toolbar(navbar == nil && bar == .asked ? .hidden : .visible, for: .navigationBar)
                    .modifier(TitleMenu(items: navbar?.buttons.first(where: \.inTitle)?.items ?? [], page: page))
            }
        }
        .overlay(alignment: .bottomTrailing) { fab }
        .overlay(alignment: .top) { toast }
        .sheet(isPresented: Binding(get: { page.sharing != nil }, set: { if !$0 { page.sharing = nil } })) {
            if let url = page.sharing { ShareSheet(url: url).presentationDetents([.medium, .large]) }
        }
        .onAppear { page.load() }
    }

    private var content: some View {
        ZStack {
            WebPage(page: page, pulls: bar != .none && page.signals?.navbar?.pullToRefresh ?? true)
                .ignoresSafeArea(edges: bar == .none ? [] : .all)
            if let failure = page.failure { failed(failure) }
        }
    }

    @ViewBuilder private var fab: some View {
        if page.failure == nil, let fab = page.signals?.fab {
            Button { page.tap(fab) } label: {
                Group {
                    if fab.title.isEmpty { Image(systemName: fab.icon) } else { Label(fab.title, systemImage: fab.icon) }
                }
                .font(.title3.weight(.semibold))
                .padding(16)
            }
            .foregroundStyle(.white)
            .background(fab.color.flatMap(HybridConfig.hex).map { Color(Theme.Shade(light: $0, dark: $0)) } ?? theme.tint, in: Capsule())
            .shadow(radius: 6, y: 2)
            .padding(16)
            .accessibilityIdentifier("hybrid-fab")
        }
    }

    @ToolbarContentBuilder private var back: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if page.canGoBack { Button { page.back() } label: { Label("Back", systemImage: "chevron.backward") } }
        }
    }

    private func failed(_ why: String) -> some View {
        ContentUnavailableView {
            Label("This page could not be loaded", systemImage: "wifi.slash")
        } description: {
            Text(why)
        } actions: {
            Button("Retry") { page.retry() }.accessibilityIdentifier("hybrid-retry")
        }
        .background(.background)
    }

    @ViewBuilder private var toast: some View {
        if let toast = page.toast {
            Label(toast.message, systemImage: toast.icon ?? "checkmark.circle.fill")
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityIdentifier("hybrid-toast")
                .task(id: toast) {
                    AccessibilityNotification.Announcement(toast.message).post()
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled { withAnimation { page.dismissToast() } }
                }
        }
    }

    @ToolbarContentBuilder private func items(_ navbar: PageSignals.Navbar) -> some ToolbarContent {
        back
        ToolbarItemGroup(placement: .topBarLeading) { buttons(navbar.buttons.filter(\.leading)) }
        if !navbar.segments.isEmpty {
            ToolbarItem(placement: .principal) {
                Picker(navbar.title, selection: segment(navbar.segments)) {
                    ForEach(Array(navbar.segments.enumerated()), id: \.offset) { Text($1.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            buttons(navbar.buttons.filter { !$0.leading && !$0.inTitle })
            if let submit = navbar.submit {
                Button(submit.title.isEmpty ? "Save" : submit.title) { page.tap(submit) }.fontWeight(.semibold)
            }
        }
    }

    private func segment(_ segments: [PageSignals.Item]) -> Binding<Int> {
        Binding(get: { segments.firstIndex(where: \.selected) ?? 0 }, set: { page.tap(segments[$0], replace: true) })
    }

    private func buttons(_ items: [PageSignals.Item]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            if item.share {
                ShareLink(item: page.shared(item)) { ItemLabel(item: item) }
            } else if item.items.isEmpty {
                Button { page.tap(item) } label: { ItemLabel(item: item) }
                    .fontWeight(item.selected ? .bold : nil)
            } else {
                Menu { Choices(items: item.items, page: page) } label: { ItemLabel(item: item) }
            }
        }
    }

}

/// A menu's lines.
private struct Choices: View {
    let items: [PageSignals.Item]
    let page: HybridTab

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            if item.share {
                ShareLink(item: page.shared(item)) { ItemLabel(item: item) }
            } else if item.selected {
                Toggle(isOn: Binding(get: { true }, set: { _ in page.tap(item) })) { ItemLabel(item: item) }
            } else {
                Button(role: item.destructive ? .destructive : nil) { page.tap(item) } label: { ItemLabel(item: item) }
            }
        }
    }
}

private struct ItemLabel: View {
    let item: PageSignals.Item
    var body: some View {
        if item.icon.isEmpty { Text(item.title) } else { Label(item.title, systemImage: item.icon) }
    }
}

/// A menu on the bar's title, when the page puts one there.
private struct TitleMenu: ViewModifier {
    let items: [PageSignals.Item]
    let page: HybridTab

    func body(content: Content) -> some View {
        if items.isEmpty { content } else { content.toolbarTitleMenu { Choices(items: items, page: page) } }
    }
}

/// The web view itself, with a pull that reloads it.
private struct WebPage: UIViewRepresentable {
    let page: HybridTab
    let pulls: Bool

    func makeUIView(context: Context) -> WKWebView { page.web }

    func updateUIView(_ web: WKWebView, context: Context) {
        if !pulls {
            web.scrollView.refreshControl = nil
        } else if web.scrollView.refreshControl == nil {
            let control = UIRefreshControl()
            control.addAction(UIAction { [weak page] _ in page?.reload() }, for: .valueChanged)
            web.scrollView.refreshControl = control
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
