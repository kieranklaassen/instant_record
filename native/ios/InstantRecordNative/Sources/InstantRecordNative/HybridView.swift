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
                    .toolbar(tabBar(shown) ? .visible : .hidden, for: .tabBar)
                    .tabItem { Label(shown.tab.title, systemImage: shown.tab.icon) }
                    .badge(latest?.badge(for: shown.tab).map { Text(verbatim: $0) })
                    .tag(shown.id)
            }
        }
        .tint(tint)
        .environment(\.theme, theme)
        .onChange(of: phase, initial: true) { _, now in if now == .active { host.front() } }
    }

    @ViewBuilder private func content(_ shown: HybridHost.Shown) -> some View {
        if let screen = shown.screen {
            AppView(host: screen, theme: theme)
        } else if let page = shown.page {
            HybridPage(page: page) { signals in
                if let signals, shown.id == host.selected { latest = signals }
            }
        }
    }

    private func tabBar(_ shown: HybridHost.Shown) -> Bool {
        tabBarShows(tabs: host.shown.count, screen: shown.screen != nil, signals: shown.page?.signals ?? latest)
    }

    private var tint: Color {
        guard let tint = host.config.tint else { return theme.tint }
        return Color(Theme.Shade(light: tint.light, dark: tint.dark))
    }
}

/// One tab's page under its native bar.
private struct HybridPage: View {
    @ObservedObject var page: HybridTab
    let changed: (PageSignals?) -> Void

    private var navbar: PageSignals.Navbar? { page.failure == nil ? page.signals?.navbar : nil }

    var body: some View {
        NavigationStack {
            ZStack {
                WebPage(page: page, pulls: page.signals?.navbar?.pullToRefresh ?? true).ignoresSafeArea()
                if let failure = page.failure { failed(failure) }
            }
            .navigationTitle(navbar?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { if let navbar { items(navbar) } }
            .toolbar(navbar == nil ? .hidden : .visible, for: .navigationBar)
        }
        .overlay(alignment: .top) { toast }
        .sheet(isPresented: Binding(get: { page.sharing != nil }, set: { if !$0 { page.sharing = nil } })) {
            if let url = page.sharing { ShareSheet(url: url).presentationDetents([.medium, .large]) }
        }
        .onAppear {
            page.start()
            changed(page.signals)
        }
        .onChange(of: page.signals) { _, now in changed(now) }
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
        ToolbarItemGroup(placement: .topBarLeading) {
            if page.canGoBack {
                Button { page.back() } label: { Label("Back", systemImage: "chevron.backward") }
            }
            buttons(navbar.buttons.filter(\.leading))
        }
        ToolbarItem(placement: .principal) {
            if navbar.segments.isEmpty {
                Text(navbar.title).font(.headline).lineLimit(1)
            } else {
                Picker(navbar.title, selection: segment(navbar.segments)) {
                    ForEach(Array(navbar.segments.enumerated()), id: \.offset) { Text($1.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            buttons(navbar.buttons.filter { !$0.leading })
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
                ShareLink(item: page.shared(item)) { label(item) }
            } else if item.items.isEmpty {
                Button { page.tap(item) } label: { label(item) }
                    .fontWeight(item.selected ? .bold : nil)
            } else {
                Menu { choices(item.items) } label: { label(item) }
            }
        }
    }

    private func choices(_ items: [PageSignals.Item]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            if item.share {
                ShareLink(item: page.shared(item)) { label(item) }
            } else if item.selected {
                Toggle(isOn: Binding(get: { true }, set: { _ in page.tap(item) })) { label(item) }
            } else {
                Button(role: item.destructive ? .destructive : nil) { page.tap(item) } label: { label(item) }
            }
        }
    }

    @ViewBuilder private func label(_ item: PageSignals.Item) -> some View {
        if item.icon.isEmpty { Text(item.title) } else { Label(item.title, systemImage: item.icon) }
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
