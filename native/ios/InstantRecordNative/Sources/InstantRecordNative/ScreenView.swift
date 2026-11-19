import SwiftUI

/// The whole app: the first screen in a navigation stack, with every screen a
/// row links to pushed over it. Over it, one line says what went wrong, or
/// that the app is offline, or how many changes are waiting to be sent.
public struct AppView: View {
    @ObservedObject private var host: AppHost
    @Environment(\.scenePhase) private var phase
    private let waiting: String

    /// `waiting` is what the first screen says while a database that has
    /// never synced is being filled, such as "Getting your mail".
    public init(host: AppHost, waiting: String = "Loading") {
        self.host = host
        self.waiting = waiting
    }

    public var body: some View {
        NavigationStack(path: $host.path) {
            // A first screen put in another's place starts afresh.
            ScreenView(route: host.root, host: host, first: true, waiting: waiting)
                .id(host.root)
                .navigationDestination(for: Route.self) { ScreenView(route: $0, host: host, first: false, waiting: waiting) }
        }
        .safeAreaInset(edge: .top, spacing: 0) { banner }
        .onChange(of: phase, initial: true) { _, now in host.front(now == .active) }
        .onChange(of: host.status.message) { _, now in
            if let now { AccessibilityNotification.Announcement(now).post() }
        }
    }

    @ViewBuilder private var banner: some View {
        if let message = host.status.message {
            let failed = !host.status.error.isEmpty || !host.status.syncError.isEmpty
            HStack(alignment: .firstTextBaseline) {
                Label(message, systemImage: failed ? "exclamationmark.triangle" : host.status.offline ? "wifi.slash" : "arrow.triangle.2.circlepath")
                    .font(.footnote)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("sync-status")
                Spacer()
                if failed { Button("Dismiss") { host.dismissError() }.font(.footnote) }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(failed ? AnyShapeStyle(.yellow.opacity(0.25)) : AnyShapeStyle(.bar))
        }
    }
}

/// One screen, drawn from the description the app last gave for it.
struct ScreenView: View {
    let route: Route
    let host: AppHost
    let first: Bool
    let waiting: String
    @ObservedObject private var watched: AppHost

    init(route: Route, host: AppHost, first: Bool, waiting: String = "Loading") {
        self.route = route
        self.host = host
        self.first = first
        self.waiting = waiting
        watched = host
    }

    var body: some View {
        if host.fetchingFirst, first {
            ProgressView(waiting).frame(maxWidth: .infinity, maxHeight: .infinity)
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

    var body: some View {
        switch node.kind {
        case "screen", "navigation": page
        case "list": list
        case "section": section
        case "row": row
        case "stack": stack
        case "spacer": Spacer(minLength: 8)
        case "text": Text(node.text).font(font).foregroundStyle(tone).lineLimit(Int(node.prop("lines")))
        case "date": Text(Moment.written(node.text)).font(font).foregroundStyle(tone)
        case "image": image
        case "button": button
        case "item": item
        case "field": field
        case "more": more
        case "swift": swift
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
            if content.allSatisfy({ ["list", "navigation", "swift"].contains($0.node.kind) }) {
                each(content)
            } else {
                VStack(alignment: .leading, spacing: 8) { each(content) }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                    .background(.bar)
            }
        }
    }

    // Pulling a list that asks for it syncs and draws the screens again.
    @ViewBuilder private var list: some View {
        if node.prop("refresh") == "true" {
            List { each(node.keyed) }.refreshable { await host.refresh() }
        } else {
            List { each(node.keyed) }
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
    // it puts that screen in the first one's place, with `link` it opens it
    // over this one, and otherwise it is an action.
    private var item: some View {
        Button(role: role) {
            if !node.prop("replace").isEmpty {
                host.replace(with: Route(node.prop("replace"), node.params))
            } else if !node.prop("link").isEmpty {
                host.path.append(Route(node.prop("link"), node.params))
            } else {
                host.perform(node.action, args: node.args, on: route)
            }
        } label: {
            label(image: node.prop("selected") == "true" ? "checkmark" : node.prop("image"))
        }
    }

    private var role: ButtonRole? { node.prop("role") == "destructive" ? .destructive : nil }

    @ViewBuilder private func label(image: String) -> some View {
        if image.isEmpty {
            Text(node.text)
        } else {
            Label(node.text, systemImage: Icons.symbol(image))
        }
    }

    // A box to type in. What is typed is the host's to keep, by screen, so
    // it is still there after a redraw or a trip back and forth.
    private var field: some View {
        let name = node.prop("name")
        let text = Binding(get: { shown(node) }, set: { host.typed[route, default: [:]][name] = $0 })
        return Group {
            if node.prop("multiline") == "true" {
                TextField(node.prop("label"), text: text, axis: .vertical).lineLimit(1...5)
            } else {
                TextField(node.prop("label"), text: text)
            }
        }
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier(name)
    }

    // The list goes on at the server. Coming into view fetches the next page.
    @ViewBuilder private var more: some View {
        if host.paging[node.id] == .failed {
            Button("Could not load more. Tap to retry") { host.loadMore(node.id, query: node.prop("query")) }
                .font(.footnote)
                .accessibilityIdentifier("more-failed")
        } else {
            HStack {
                Spacer()
                ProgressView()
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

    private var tone: AnyShapeStyle {
        switch node.prop("tone") {
        case "secondary": AnyShapeStyle(.secondary)
        case "accent": AnyShapeStyle(.tint)
        default: AnyShapeStyle(.primary)
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
