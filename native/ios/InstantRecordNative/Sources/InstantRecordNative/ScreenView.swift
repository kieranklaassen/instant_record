import SwiftUI

/// The whole app: the first screen in a navigation stack, with every screen a
/// row links to pushed over it. Syncs when the app comes to the front.
public struct AppView: View {
    @ObservedObject private var host: AppHost
    @Environment(\.scenePhase) private var phase

    public init(host: AppHost) {
        self.host = host
    }

    public var body: some View {
        NavigationStack(path: $host.path) {
            ScreenView(route: host.root, first: true)
                .navigationDestination(for: Route.self) { ScreenView(route: $0, first: false) }
        }
        .environmentObject(host)
        .onChange(of: phase) { _, now in
            if now == .active { host.sync() }
        }
    }
}

/// One screen, drawn from the description the app last gave for it.
struct ScreenView: View {
    let route: Route
    let first: Bool
    @EnvironmentObject private var host: AppHost

    var body: some View {
        if let screen = host.screens[route] {
            ForEach(screen.keyed) { NodeView(node: $0.node, route: route, host: host, first: first) }
        } else if !host.failure.isEmpty {
            Text(host.failure).foregroundStyle(.secondary).padding()
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
    var first = false

    var body: some View {
        switch node.kind {
        case "navigation": navigation
        case "list": List { each(node.keyed) }
        case "section": section
        case "row": row
        case "stack": stack
        case "text": Text(node.text).font(font).foregroundStyle(tone)
        case "date": Text(Moment.written(node.text)).font(font).foregroundStyle(tone)
        case "image": Image(systemName: node.text).imageScale(.small).foregroundStyle(tone)
        case "button": button
        default: EmptyView()
        }
    }

    private func each(_ items: [Node.Keyed]) -> some View {
        ForEach(items) { NodeView(node: $0.node, route: route, host: host) }
    }

    private func keyed(except kinds: String...) -> [Node.Keyed] {
        node.keyed.filter { !kinds.contains($0.node.kind) }
    }

    // A title over the content, with the toolbar's controls in the bar.
    private var navigation: some View {
        let content = keyed(except: "toolbar")
        let controls = node.children(of: "toolbar").flatMap(\.keyed)
        return Group {
            if content.allSatisfy({ $0.node.kind == "list" }) {
                each(content)
            } else {
                VStack(alignment: .leading, spacing: 8) { each(content) }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .navigationTitle(node.prop("title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(first ? .large : .inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) { each(controls) }
        }
    }

    @ViewBuilder private var section: some View {
        if node.text.isEmpty {
            Section { each(node.keyed) }
        } else {
            Section(node.text) { each(node.keyed) }
        }
    }

    // A row's children one under another. With a `link` the row is a button
    // that opens that screen, and its text is a preview of two lines at most.
    @ViewBuilder private var row: some View {
        let content = VStack(alignment: .leading, spacing: 3) { each(keyed(except: "swipe")) }
        let link = node.prop("link")
        Group {
            if link.isEmpty {
                content
            } else {
                Button {
                    host.open(link, arg: node.arg, action: node.action, from: route)
                } label: {
                    HStack {
                        content.lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .swipeActions(edge: .trailing) { swipes(leading: false) }
        .swipeActions(edge: .leading) { swipes(leading: true) }
    }

    private func swipes(leading: Bool) -> some View {
        let items = node.keyed.filter { $0.node.kind == "swipe" && ($0.node.prop("edge") == "leading") == leading }
        return ForEach(items) { NodeView(node: $0.node, route: route, host: host).button }
    }

    // Side by side, the last element sits at the far edge.
    @ViewBuilder private var stack: some View {
        if node.prop("axis") == "horizontal" {
            let items = node.keyed
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                each(Array(items.dropLast()))
                if items.count > 1 { Spacer(minLength: 8) }
                each(Array(items.suffix(1)))
            }
        } else {
            VStack(alignment: .leading, spacing: 3) { each(node.keyed) }
        }
    }

    // A button or a swipe: both are a label and an action for this screen.
    private var button: some View {
        Button(role: node.prop("role") == "destructive" ? .destructive : nil) {
            host.perform(node.action, arg: node.arg, on: route)
        } label: {
            if node.prop("image").isEmpty {
                Text(node.text)
            } else {
                Label(node.text, systemImage: node.prop("image"))
            }
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

/// A moment the app wrote as ISO 8601, in the phone's language and time zone:
/// the time when it is today, or else the day.
enum Moment {
    static func written(_ iso8601: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso8601) ?? ISO8601DateFormatter().date(from: iso8601) else { return iso8601 }
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
