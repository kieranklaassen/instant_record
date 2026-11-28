import SwiftUI

/// The whole app: the first screen in a navigation stack, with every screen a
/// row links to pushed over it. Over it, one line says what went wrong, or
/// that the app is offline, or how many changes are waiting to be sent.
public struct AppView: View {
    @ObservedObject private var host: AppHost
    @Environment(\.scenePhase) private var phase
    private let waiting: String
    private let theme: Theme

    /// `waiting` is what the first screen says while a database that has
    /// never synced is being filled, such as "Getting your mail". `theme`
    /// is how the app looks: the system's own look unless it is given one.
    public init(host: AppHost, waiting: String = "Loading", theme: Theme = .system) {
        self.host = host
        self.waiting = waiting
        self.theme = theme
        theme.styleBars()
    }

    public var body: some View {
        // The status line sits over the navigation bar, not on it: as an
        // inset of the stack it was drawn across the bar's buttons.
        VStack(spacing: 0) {
            AppBanners(host: host, theme: theme)
            NavigationStack(path: $host.path) {
                // A first screen put in another's place starts afresh.
                ScreenView(route: host.root, host: host, first: true, waiting: waiting)
                    .id(host.root)
                    .navigationDestination(for: Route.self) { PlaceView(route: $0, host: host, site: host.site, views: host.views) }
            }
        }
        .background { theme.page?.ignoresSafeArea() }
        .sheet(isPresented: Binding(get: { host.sheet != nil }, set: { if !$0 { host.sheet = nil } })) {
            if let route = host.sheet { SheetView(route: route, host: host, site: host.site, views: host.views, theme: theme) }
        }
        .tint(theme.tint)
        .environment(\.theme, theme)
        .environment(\.opens, Opens(push: { host.path.append($0) }, sheet: { host.sheet = $0 }))
        .onChange(of: phase, initial: true) { _, now in host.front(now == .active) }
        .onChange(of: host.status.message) { _, now in
            if let now { AccessibilityNotification.Announcement(now).post() }
        }
    }
}

/// What the app has to say over whatever is on show: what went wrong, that
/// it is offline, what waits, and the writes that need a look.
struct AppBanners: View {
    @ObservedObject var host: AppHost
    let theme: Theme
    @State private var showingNotices = false

    var body: some View {
        VStack(spacing: 0) {
            banner
            noticesBanner
        }
        .sheet(isPresented: $showingNotices) { SyncNoticesSheet(host: host, theme: theme) }
    }

    @ViewBuilder private var banner: some View {
        if let message = host.status.message {
            let failed = !host.status.error.isEmpty || !host.status.syncError.isEmpty
            HStack(alignment: .firstTextBaseline) {
                Label(message, systemImage: failed ? "exclamationmark.triangle" : host.status.offline ? "wifi.slash" : "arrow.triangle.2.circlepath")
                    .font(.footnote)
                    .fontDesign(theme.ui)
                    .foregroundStyle(theme.ink)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("sync-status")
                Spacer()
                if failed { Button("Dismiss") { host.dismissError() }.font(.footnote).fontDesign(theme.ui) }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background((failed ? AnyShapeStyle(.yellow.opacity(0.25)) : theme.fill.map(AnyShapeStyle.init) ?? AnyShapeStyle(.bar)), ignoresSafeAreaEdges: .top)
            .background { theme.page?.ignoresSafeArea(edges: .top) }
        }
    }

    @ViewBuilder private var noticesBanner: some View {
        if !host.notices.isEmpty {
            let count = host.notices.count
            let summary = count == 1
                ? (host.notices[0].isConflict ? "1 sync conflict needs review" : "1 rejected change needs review")
                : "\(count) sync notices need review"
            HStack(alignment: .firstTextBaseline) {
                Label(summary, systemImage: "exclamationmark.bubble")
                    .font(.footnote)
                    .fontDesign(theme.ui)
                    .foregroundStyle(theme.ink)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("sync-notices-banner")
                Spacer()
                Button("Review") { showingNotices = true }
                    .font(.footnote.weight(.medium))
                    .fontDesign(theme.ui)
                    .accessibilityIdentifier("sync-notices-review")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.18), ignoresSafeAreaEdges: host.status.message == nil ? .top : [])
        }
    }
}

/// A place brought up as a sheet, in a stack of its own, so that what it
/// links to opens over it. A screen that is a single Swift view is shown as
/// it is: such a view brings its own bar, and a stack inside a stack is not
/// allowed.
struct SheetView: View {
    let host: AppHost?
    let site: HybridSite?
    let views: Screens
    let theme: Theme
    private final class Token: ObservableObject {}
    @StateObject private var token = Token()
    @State private var route: Route
    @State private var path: [Route] = []
    @State private var over: Route?

    init(route: Route, host: AppHost?, site: HybridSite?, views: Screens, theme: Theme) {
        _route = State(initialValue: route)
        self.host = host
        self.site = site
        self.views = views
        self.theme = theme
    }

    var body: some View {
        Group {
            if route.isScreen, let host {
                RubySheet(route: route, host: host) { stack }
            } else if route.viewName != nil {
                place(route)
            } else {
                stack
            }
        }
        .tint(theme.tint)
        .environment(\.theme, theme)
        .environment(\.opens, Opens(push: { path.append($0) }, sheet: { over = $0 }, replace: { if path.isEmpty { route = $0 } else { path[path.count - 1] = $0 } }))
        .presentationBackground(theme.page.map(AnyShapeStyle.init) ?? AnyShapeStyle(.background))
        .sheet(isPresented: Binding(get: { over != nil }, set: { if !$0 { over = nil } })) {
            // Erased, because the view is inside itself.
            if let over { AnyView(SheetView(route: over, host: host, site: site, views: views, theme: theme)) }
        }
        .onChange(of: [route] + path + (over.map { [$0] } ?? [])) { _, now in host?.visited(now, in: ObjectIdentifier(token)) }
        .onDisappear { host?.visited([], in: ObjectIdentifier(token)) }
    }

    private var stack: some View {
        NavigationStack(path: $path) { place(route).navigationDestination(for: Route.self) { place($0) } }
    }

    private func place(_ route: Route) -> some View {
        PlaceView(route: route, host: host, site: site, views: views)
    }
}

/// A Ruby screen's sheet, which waits for Ruby to say which kind it is: that
/// must not change under a view that holds what was typed.
private struct RubySheet<Stack: View>: View {
    let route: Route
    @ObservedObject var host: AppHost
    @ViewBuilder let stack: () -> Stack

    var body: some View {
        if host.screens[route] == nil {
            Color.clear
        } else if bare {
            ScreenView(route: route, host: host, first: false)
        } else {
            stack()
        }
    }

    private var bare: Bool {
        guard let screen = host.screens[route] else { return false }
        let holder = screen.children.first { $0.kind == "navigation" } ?? screen
        return !holder.children.isEmpty && holder.children.allSatisfy { $0.kind == "swift" }
    }
}

/// One screen, drawn from the description the app last gave for it.
struct ScreenView: View {
    let route: Route
    let host: AppHost
    let first: Bool
    let waiting: String
    @ObservedObject private var watched: AppHost
    @Environment(\.theme) private var theme

    init(route: Route, host: AppHost, first: Bool, waiting: String = "Loading") {
        self.route = route
        self.host = host
        self.first = first
        self.waiting = waiting
        watched = host
    }

    var body: some View {
        if host.fetchingFirst, first {
            ProgressView(waiting)
                .fontDesign(theme.ui)
                .foregroundStyle(theme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { theme.page?.ignoresSafeArea() }
        } else if let screen = host.screens[route] {
            NodeView(node: screen, route: route, host: host, first: first)
        } else {
            Color.clear
        }
    }
}

/// Draws one node with the stock control its `kind` names. A kind this
/// renderer does not know draws nothing. The host is handed down and not read
/// from the environment, which a swipe action's button does not inherit.
struct NodeView: View {
    let node: Node
    let route: Route
    /// Watched, because what a node draws also depends on what the host
    /// holds: what is typed into a field, and how a list's next page stands.
    @ObservedObject var host: AppHost
    var first = false
    /// True for what sits beside fields that are all blank: there is
    /// nothing to send yet.
    var idle = false
    @Environment(\.theme) private var theme
    @Environment(\.opens) private var opens

    var body: some View {
        switch node.kind {
        case "screen", "navigation": page
        case "list": list
        case "section": section
        case "row": row
        case "stack": stack
        case "spacer": Spacer(minLength: 8)
        case "text": Text(node.text).font(font).fontDesign(face).foregroundStyle(tone).lineLimit(Int(node.prop("lines")))
        case "date": Text(Moment.written(node.text)).font(font).fontDesign(theme.ui).foregroundStyle(tone)
        case "image": image
        case "button": button
        case "item": item
        case "field": field
        case "more": more
        case "swift": swift
        case "web": web
        default: EmptyView()
        }
    }

    private func each(_ items: [Node.Keyed], idle: Bool = false) -> some View {
        ForEach(items) { NodeView(node: $0.node, route: route, host: host, first: first, idle: idle) }
    }

    private func keyed(except kinds: String...) -> [Node.Keyed] {
        node.keyed.filter { !kinds.contains($0.node.kind) }
    }

    /// What a field shows: what was typed, or else what the screen gave it.
    private func shown(_ field: Node) -> String {
        host.typed[route]?[field.prop("name")] ?? field.text
    }

    // The screen itself, or its navigation: content, with a title and bar
    // buttons when it names them, and a bar pinned under it when it has one.
    private var page: some View {
        let content = keyed(except: "toolbar", "bottom")
        let controls = node.children(of: "toolbar").flatMap(\.children)
        let leading = Node.keyed(controls.filter { $0.prop("position") == "leading" })
        let trailing = Node.keyed(controls.filter { $0.prop("position") != "leading" })
        let under = node.children(of: "bottom").flatMap(\.children)
        let fields = under.filter { $0.kind == "field" }
        let blank = !fields.isEmpty && fields.allSatisfy { shown($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return Group {
            if content.allSatisfy({ ["list", "navigation", "swift", "web"].contains($0.node.kind) }) {
                each(content)
            } else {
                VStack(alignment: .leading, spacing: 8) { each(content) }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background { theme.page?.ignoresSafeArea() }
            }
        }
        .modifier(Titled(title: node.kind == "navigation" ? node.prop("title") : nil, large: first))
        .toolbar {
            ToolbarItemGroup(placement: NodeView.leadingEdge) { each(leading) }
            ToolbarItemGroup(placement: .primaryAction) { each(trailing) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !under.isEmpty {
                HStack(alignment: .bottom, spacing: 10) { each(Node.keyed(under), idle: blank) }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(theme.page.map(AnyShapeStyle.init) ?? AnyShapeStyle(.bar))
                    .overlay(alignment: .top) { theme.hairline.frame(height: 1) }
            }
        }
    }

    // Pulling a list that asks for it syncs and draws the screens again.
    @ViewBuilder private var list: some View {
        let rows = List { each(node.keyed).listRowBackground(theme.surface).listRowSeparatorTint(theme.hairline) }
            .scrollContentBackground(theme.page == nil ? .automatic : .hidden)
            .background { theme.page?.ignoresSafeArea() }
        if node.prop("refresh") == "true" {
            rows.refreshable { await host.refresh() }
        } else {
            rows
        }
    }

    @ViewBuilder private var section: some View {
        if node.text.isEmpty {
            Section { each(node.keyed) }
        } else {
            Section(node.text) { each(node.keyed) }
        }
    }

    // A row's children one under another, read aloud as one thing. With a
    // `link` the row is a navigation link to that screen, opened with the
    // params the row carries.
    @ViewBuilder private var row: some View {
        let content = VStack(alignment: .leading, spacing: 3) { each(keyed(except: "swipe")) }
            .accessibilityElement(children: .combine)
        Group {
            if node.prop("link").isEmpty {
                content
            } else {
                NavigationLink(value: Route(node.prop("link"), node.params)) { content }
            }
        }
        .accessibilityIdentifier(node.id)
        .swipeActions(edge: .trailing) { swipes(leading: false) }
        .swipeActions(edge: .leading) { swipes(leading: true) }
    }

    private func swipes(leading: Bool) -> some View {
        let items = node.keyed.filter { $0.node.kind == "swipe" && ($0.node.prop("edge") == "leading") == leading }
        return ForEach(items) { NodeView(node: $0.node, route: route, host: host).button }
    }

    @ViewBuilder private var stack: some View {
        if node.prop("axis") == "horizontal" {
            HStack(alignment: .firstTextBaseline, spacing: 6) { each(node.keyed) }
        } else {
            VStack(alignment: .leading, spacing: 3) { each(node.keyed) }
        }
    }

    // An icon by what it means, called that aloud. One the table does not
    // know is decoration.
    @ViewBuilder private var image: some View {
        let picture = Image(systemName: Icons.symbol(node.text)).imageScale(.small).foregroundStyle(tone)
        if Icons.spoken(node.text).isEmpty {
            picture.accessibilityHidden(true)
        } else {
            picture.accessibilityLabel(Icons.spoken(node.text))
        }
    }

    #if os(iOS)
    private static let leadingEdge = ToolbarItemPlacement.topBarLeading
    #else
    private static let leadingEdge = ToolbarItemPlacement.navigation
    #endif

    // A button or a swipe: both are a label and an action for this screen.
    // A button that holds items opens them as a menu.
    @ViewBuilder var button: some View {
        let items = node.keyed.filter { $0.node.kind == "item" }
        if node.kind == "swipe" {
            // Not the destructive role: with it the list takes the row out
            // itself, at once, and the app's own answer arrives a moment
            // later from another thread. The two updates can collide. A red
            // tint says the same, and the row leaves when Ruby says it has.
            Button { host.perform(node.action, args: node.args, on: route) } label: { label(image: node.prop("image")) }
                .tint(role == .destructive ? .red : nil)
        } else if items.isEmpty {
            Button(role: role) { host.perform(node.action, args: node.args, on: route) } label: { label(image: node.prop("image")) }
                .disabled(idle)
        } else {
            Menu { each(items) } label: { label(image: node.prop("image")) }
        }
    }

    // One line of a menu, ticked when it is the selected one. With `replace`
    // it puts that screen in the first one's place, with `sheet` it brings
    // it up as a sheet, with `link` it opens it over this one, and
    // otherwise it is an action.
    private var item: some View {
        Button(role: role) {
            if !node.prop("replace").isEmpty {
                let route = Route(node.prop("replace"), node.params)
                if let replace = opens.replace { replace(route) } else { host.replace(with: route) }
            } else if !node.prop("sheet").isEmpty {
                let route = Route(node.prop("sheet"), node.params)
                if let sheet = opens.sheet { sheet(route) } else { host.sheet = route }
            } else if !node.prop("link").isEmpty {
                let route = Route(node.prop("link"), node.params)
                if let push = opens.push { push(route) } else { host.path.append(route) }
            } else {
                host.perform(node.action, args: node.args, on: route)
            }
        } label: {
            label(image: node.prop("selected") == "true" ? "checkmark" : node.prop("image"))
        }
    }

    private var role: ButtonRole? { node.prop("role") == "destructive" ? .destructive : nil }

    private func label(image: String) -> some View {
        Group {
            if image.isEmpty {
                Text(node.text)
            } else {
                Label(node.text, systemImage: Icons.symbol(image))
            }
        }
        .fontDesign(theme.ui)
    }

    // A box to type in. What is typed is the host's to keep, by screen, so
    // it is still there after a redraw or a trip back and forth.
    private var field: some View {
        let name = node.prop("name")
        let text = Binding(get: { shown(node) }, set: { host.typed[route, default: [:]][name] = $0 })
        let box = Group {
            if node.prop("multiline") == "true" {
                TextField(node.prop("label"), text: text, axis: .vertical).lineLimit(1...5)
            } else {
                TextField(node.prop("label"), text: text)
            }
        }
        .accessibilityIdentifier(name)
        return Group {
            if let fill = theme.fill {
                // Flat, with a hairline: the theme's own box.
                box.textFieldStyle(.plain)
                    .fontDesign(theme.reading)
                    .foregroundStyle(theme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(fill, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.hairline ?? .clear))
            } else {
                box.textFieldStyle(.roundedBorder)
            }
        }
    }

    // The list goes on at the server. Coming into view fetches the next page.
    @ViewBuilder private var more: some View {
        if host.paging[node.id] == .failed {
            Button("Could not load more. Tap to retry") { host.loadMore(node.id, query: node.prop("query")) }
                .font(.footnote)
                .fontDesign(theme.ui)
                .accessibilityIdentifier("more-failed")
        } else {
            HStack {
                Spacer()
                ProgressView().tint(theme.muted)
                Spacer()
            }
            .accessibilityIdentifier("more")
            .onAppear { host.loadMore(node.id, query: node.prop("query")) }
        }
    }

    // A view the app wrote in SwiftUI, by the name it registered. A name
    // nobody registered says so on screen.
    @ViewBuilder private var swift: some View {
        if let view = host.views.view(node.text, Props(node), Actions(host: host, route: route)) {
            view
        } else {
            Label(NodeView.unregistered(node.text), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }

    // A Rails page among native elements, with no bar of its own.
    @ViewBuilder private var web: some View {
        PlaceView(route: .page(node.text), host: host, site: host.site, views: host.views, pushed: false)
            .environment(\.embedded, true)
    }

    static func unregistered(_ name: String) -> String { "No Swift view is registered as \(name)" }

    private var font: Font {
        switch node.prop("style") {
        case "title": .title
        case "headline": .headline
        case "subheadline": .subheadline
        case "caption": .caption
        default: .body
        }
    }

    // A text with no style is running text, set in the theme's reading
    // face. Every other style is a label, in the face of the controls.
    private var face: Font.Design { node.prop("style").isEmpty ? theme.reading : theme.ui }

    private var tone: Color {
        switch node.prop("tone") {
        case "secondary": theme.muted
        case "accent": theme.tint
        default: theme.ink
        }
    }
}

/// A navigation title: large on the first screen, inline on pushed ones. A
/// screen with no navigation of its own keeps whatever its Swift view sets.
private struct Titled: ViewModifier {
    let title: String?
    let large: Bool

    func body(content: Content) -> some View {
        if let title {
            content
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(large ? .large : .inline)
                #endif
        } else {
            content
        }
    }
}

/// A moment the app wrote as ISO 8601, in the phone's language and time zone:
/// the time when it is today, or else the day.
enum Moment {
    static func date(_ iso8601: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: iso8601) ?? ISO8601DateFormatter().date(from: iso8601)
    }

    static func written(_ iso8601: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date = date(iso8601) else { return iso8601 }
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
