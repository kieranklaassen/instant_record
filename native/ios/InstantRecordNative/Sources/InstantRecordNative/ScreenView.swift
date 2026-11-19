import SwiftUI

/// The whole app: the first screen in a navigation stack, with every screen a
/// row links to pushed over it. Under it, a line says when the app is offline
/// or has changes waiting, and over it, what last went wrong.
public struct AppView: View {
    @ObservedObject private var host: AppHost
    @Environment(\.scenePhase) private var phase

    public init(host: AppHost) {
        self.host = host
    }

    public var body: some View {
        NavigationStack(path: $host.path) {
            // A first screen put in another's place starts afresh: what was
            // typed for one account must not be sent as another.
            ScreenView(route: host.root, host: host, first: true)
                .id(host.root)
                .navigationDestination(for: Route.self) { ScreenView(route: $0, host: host, first: false) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { status }
        .safeAreaInset(edge: .top, spacing: 0) { failure }
        .onChange(of: phase, initial: true) { _, now in host.front(now == .active) }
    }

    @ViewBuilder private var status: some View {
        if !host.online || host.pending > 0 {
            Label(Wording.status(online: host.online, pending: host.pending), systemImage: host.online ? "arrow.triangle.2.circlepath" : "wifi.slash")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.bar)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("sync-status")
        }
    }

    @ViewBuilder private var failure: some View {
        if !host.failure.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Label(host.failure, systemImage: "exclamationmark.triangle").font(.footnote)
                Spacer()
                Button("Dismiss") { host.dismissFailure() }.font(.footnote)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.yellow.opacity(0.25))
            .accessibilityIdentifier("failure")
        }
    }
}

/// What the status line says.
enum Wording {
    static func status(online: Bool, pending: Int) -> String {
        let waiting = pending == 1 ? "1 change waiting" : "\(pending) changes waiting"
        if online { return waiting + " to sync" }
        return pending > 0 ? "Offline · " + waiting : "Offline"
    }
}

/// One screen, drawn from the description the app last gave for it. It keeps
/// what is typed into its fields until an action from the same form sends it.
struct ScreenView: View {
    let route: Route
    let host: AppHost
    let first: Bool
    @ObservedObject private var watched: AppHost
    @State private var typed: [String: String] = [:]

    init(route: Route, host: AppHost, first: Bool) {
        self.route = route
        self.host = host
        self.first = first
        watched = host
    }

    var body: some View {
        if let screen = host.screens[route] {
            NodeView(node: screen, route: route, host: host, typed: $typed, first: first)
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
    let host: AppHost
    @Binding var typed: [String: String]
    var first = false
    /// The fields beside this node in the same container, each with the text
    /// it started with: a button sends what they show with its action, then
    /// forgets what was typed into them.
    var form: [String: String] = [:]

    var body: some View {
        switch node.kind {
        case "screen", "navigation": page
        case "list": list
        case "section": section
        case "row": row
        case "stack": stack
        case "spacer": Spacer(minLength: 8)
        case "text": text
        case "date": Text(Moment.written(node.text)).font(font).foregroundStyle(tone)
        case "image": Image(systemName: Icons.symbol(node.text)).imageScale(.small).foregroundStyle(tone)
        case "button": button
        case "item": item
        case "field": field
        case "swift": swift
        default: EmptyView()
        }
    }

    private func each(_ items: [Node.Keyed]) -> some View {
        let fields = Dictionary(items.filter { $0.node.kind == "field" }.map { ($0.node.id, $0.node.text) }) { first, _ in first }
        return ForEach(items) { NodeView(node: $0.node, route: route, host: host, typed: $typed, first: first, form: fields) }
    }

    private func keyed(except kinds: String...) -> [Node.Keyed] {
        node.keyed.filter { !kinds.contains($0.node.kind) }
    }

    private func send(_ action: String) {
        var with = node.params
        for (name, shown) in form { with[name] = typed[name] ?? shown }
        host.perform(action, with: with, on: route)
        for name in form.keys { typed[name] = nil }
    }

    // The screen itself, or its navigation: content, with a title and bar
    // buttons when it names them, and a bar pinned under it when it has one.
    private var page: some View {
        let content = keyed(except: "toolbar", "bottom")
        let controls = node.children(of: "toolbar").flatMap(\.children)
        let leading = Node.keyed(controls.filter { $0.prop("position") == "leading" })
        let trailing = Node.keyed(controls.filter { $0.prop("position") != "leading" })
        let under = node.children(of: "bottom").flatMap(\.keyed)
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
                HStack(alignment: .bottom, spacing: 10) { each(under) }
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

    // A row's children one under another. With a `link` the row is a
    // navigation link to that screen, opened with the params the row carries.
    @ViewBuilder private var row: some View {
        let content = VStack(alignment: .leading, spacing: 3) { each(keyed(except: "swipe")) }
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
        return ForEach(items) { NodeView(node: $0.node, route: route, host: host, typed: $typed).button }
    }

    @ViewBuilder private var stack: some View {
        if node.prop("axis") == "horizontal" {
            HStack(alignment: .firstTextBaseline, spacing: 6) { each(node.keyed) }
        } else {
            VStack(alignment: .leading, spacing: 3) { each(node.keyed) }
        }
    }

    private var text: some View {
        Text(node.text).font(font).foregroundStyle(tone).lineLimit(Int(node.prop("lines")))
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
            Button { send(node.action) } label: { label(image: node.prop("image")) }
                .tint(role == .destructive ? .red : nil)
        } else if items.isEmpty {
            Button(role: role) { send(node.action) } label: { label(image: node.prop("image")) }
        } else {
            Menu { each(items) } label: { label(image: node.prop("image")) }
        }
    }

    // One line of a menu, ticked when it is the selected one. With a `link`
    // it puts that screen in the first one's place. Otherwise it is an action.
    private var item: some View {
        Button(role: role) {
            if node.prop("link").isEmpty {
                send(node.action)
            } else {
                host.replace(with: Route(node.prop("link"), node.params))
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

    // A box to type in. It starts with what the screen gave it.
    private var field: some View {
        TextField(node.prop("placeholder"), text: Binding(get: { typed[node.id] ?? node.text }, set: { typed[node.id] = $0 }), axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...5)
            .accessibilityIdentifier(node.id)
    }

    // A view the app wrote in SwiftUI, by the name it registered. A name
    // nobody registered says so on screen.
    @ViewBuilder private var swift: some View {
        if let view = host.views.view(node.text, Props(node), Actions(host: host, route: route)) {
            view
        } else {
            Label("No Swift view is registered as \(node.text)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

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
