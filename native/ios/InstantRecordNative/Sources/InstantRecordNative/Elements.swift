import AVKit
import Charts
import MapKit
import SceneKit
import SwiftUI

/// The elements beyond lists and text: controls, pictures, charts, maps,
/// video and 3D. A control's value is kept as what is typed into a field is,
/// and reaches `perform` in `values` under its name. One with an `action`
/// performs it at once.
struct ElementView: View {
    static let kinds: Set<String> = ["toggle", "slider", "stepper", "picker", "dates", "colors", "progress", "gauge", "divider", "scroll", "grid",
                                     "disclosure", "label", "picture", "share", "chart", "map", "video", "model", "pages", "card"]
    let node: Node
    let route: Route
    @ObservedObject var host: AppHost
    @Environment(\.theme) private var theme

    var body: some View {
        switch node.kind {
        case "toggle": Toggle(node.text, isOn: Binding(get: { value == "true" }, set: { put($0 ? "true" : "false") }))
        case "slider": slider
        case "stepper":
            Stepper("\(node.text) \(value)", value: number, in: range, step: step)
        case "picker": picker
        case "dates":
            DatePicker(node.text, selection: Binding(get: { Moment.date(value) ?? Date() }, set: { put($0.formatted(.iso8601)) }),
                       displayedComponents: node.prop("time") == "true" ? [.date, .hourAndMinute] : .date)
        case "colors":
            ColorPicker(node.text, selection: Binding(get: { Color(hex: value) ?? .accentColor }, set: { put($0.hex) }), supportsOpacity: false)
        case "progress":
            if node.prop("value").isEmpty { ProgressView(node.text) } else { ProgressView(node.text, value: min(max(amount("value"), 0), total), total: total) }
        case "gauge":
            Gauge(value: min(max(amount("value"), 0), total), in: 0...total) { Text(node.text) } currentValueLabel: { Text(node.prop("value")) }
                .gaugeStyle(.accessoryCircularCapacity)
        case "divider": Divider()
        case "scroll":
            ScrollView(node.prop("axis") == "horizontal" ? .horizontal : .vertical) {
                if node.prop("axis") == "horizontal" { LazyHStack(spacing: 12) { children } } else { LazyVStack(alignment: .leading, spacing: 12) { children }.padding(.horizontal) }
            }
        case "grid":
            LazyVGrid(columns: [GridItem(.adaptive(minimum: max(40, amount("width"))), spacing: 12)], spacing: 12) { children }
        case "disclosure": DisclosureGroup(node.text) { children }
        case "label": Label(node.text, systemImage: Icons.symbol(node.prop("image")))
        case "picture":
            AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { theme.fill ?? Color.gray.opacity(0.15) }
                .frame(maxHeight: node.prop("height").isEmpty ? nil : amount("height"))
                .accessibilityLabel(node.prop("label"))
        case "share": if let url { ShareLink(node.text, item: url) }
        case "chart": chart
        case "map": map
        case "video": if let url { Film(url: url).frame(height: height(220)) }
        case "model": if let url { Model(url: url).frame(height: height(280)).accessibilityLabel(node.prop("label")) }
        case "pages": pages
        case "card":
            VStack(alignment: .leading, spacing: 8) { children }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surface ?? Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        default: EmptyView()
        }
    }

    private var children: some View {
        ForEach(node.keyed) { NodeView(node: $0.node, route: route, host: host) }
    }

    private var value: String { host.typed[route]?[node.prop("name")] ?? node.prop("value") }

    private func put(_ value: String) {
        host.typed[route, default: [:]][node.prop("name")] = value
        if !node.action.isEmpty { host.perform(node.action, args: node.args, on: route) }
    }

    private func amount(_ name: String) -> Double {
        let number = Double(node.prop(name)) ?? 0
        return number.isFinite ? number : 0
    }

    private func height(_ usual: Double) -> Double { amount("height") > 0 ? amount("height") : usual }
    private var total: Double { amount("total") > 0 ? amount("total") : 1 }
    private var step: Double { amount("step") > 0 ? amount("step") : 1 }
    // A range that ends before it starts would stop the app.
    private var range: ClosedRange<Double> { amount("min")...max(amount("max"), amount("min")) }
    private var number: Binding<Double> {
        Binding(get: { min(max(Double(value) ?? range.lowerBound, range.lowerBound), range.upperBound) }, set: { put(Self.written($0)) })
    }
    private var url: URL? {
        URL(string: node.prop("url"), relativeTo: host.site?.server)?.absoluteURL.web
    }

    static func written(_ number: Double) -> String { number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number) }

    // A slider says where it ended, and not every place on the way.
    private var slider: some View { SliderView(label: node.text, range: range, step: step, number: number) }

    private var options: [Node] { node.children(of: "option") }

    @ViewBuilder private var picker: some View {
        let chosen = Picker(node.text, selection: Binding(get: { value }, set: put)) {
            ForEach(Array(options.enumerated()), id: \.offset) { Text($1.text).tag($1.prop("value")) }
        }
        switch node.prop("style") {
        case "segmented": chosen.pickerStyle(.segmented)
        case "inline": chosen.pickerStyle(.inline)
        default: chosen.pickerStyle(.menu)
        }
    }

    private struct Point: Identifiable {
        let id: Int
        let label: String
        let value: Double
        let series: String
    }

    private var chart: some View {
        let points = node.children(of: "point").enumerated().map { Point(id: $0, label: $1.text, value: Double($1.prop("value")).flatMap { $0.isFinite ? $0 : nil } ?? 0, series: $1.prop("series")) }
        return Chart(points) { point in
            switch node.prop("style") {
            case "line": LineMark(x: .value("", point.label), y: .value("", point.value)).foregroundStyle(by: .value("", point.series))
            case "area": AreaMark(x: .value("", point.label), y: .value("", point.value)).foregroundStyle(by: .value("", point.series))
            case "point": PointMark(x: .value("", point.label), y: .value("", point.value)).foregroundStyle(by: .value("", point.series))
            case "pie": SectorMark(angle: .value("", max(0, point.value)), innerRadius: .ratio(0.5)).foregroundStyle(by: .value("", point.label))
            default: BarMark(x: .value("", point.label), y: .value("", point.value)).foregroundStyle(by: .value("", point.series))
            }
        }
        .chartLegend(node.prop("style") == "pie" || points.contains { !$0.series.isEmpty } ? .visible : .hidden)
        .frame(height: height(220))
    }

    private var map: some View {
        let pins = node.children(of: "pin").enumerated().compactMap { n, pin -> (Int, String, CLLocationCoordinate2D)? in
            guard let latitude = Double(pin.prop("latitude")), let longitude = Double(pin.prop("longitude")) else { return nil }
            let place = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            return CLLocationCoordinate2DIsValid(place) ? (n, pin.text, place) : nil
        }
        return Map { ForEach(pins, id: \.0) { Marker($0.1, coordinate: $0.2) } }.frame(height: height(260))
    }

    @ViewBuilder private var pages: some View {
        #if os(iOS)
        TabView { children }.tabViewStyle(.page(indexDisplayMode: .always)).frame(height: height(240))
        #else
        ScrollView(.horizontal) { HStack { children } }.frame(height: height(240))
        #endif
    }
}

private struct SliderView: View {
    let label: String
    let range: ClosedRange<Double>
    let step: Double
    @Binding var number: Double
    @State private var moving: Double?

    var body: some View {
        if range.upperBound > range.lowerBound {
            Slider(value: Binding(get: { moving ?? number }, set: { moving = $0 }), in: range, step: step) { Text(label) } onEditingChanged: { began in
                if !began, let end = moving {
                    moving = nil
                    number = end
                }
            }
        }
    }
}

private struct Film: View {
    let url: URL
    @State private var player: AVPlayer?
    var body: some View {
        VideoPlayer(player: player)
            .onAppear { if player == nil { player = AVPlayer(url: url) } }
            .onDisappear { player?.pause() }
    }
}

/// A 3D model that a finger turns: a USDZ, fetched once.
private struct Model: View {
    let url: URL
    @State private var scene: SCNScene?
    @State private var failed = false

    var body: some View {
        Group {
            if let scene {
                SceneView(scene: scene, options: [.allowsCameraControl, .autoenablesDefaultLighting])
            } else if failed {
                Label("The model could not be loaded", systemImage: "cube.transparent")
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            do {
                let (file, _) = try await URLSession.shared.download(from: url)
                let named = file.deletingPathExtension().appendingPathExtension("usdz")
                try FileManager.default.moveItem(at: file, to: named)
                defer { try? FileManager.default.removeItem(at: named) }
                scene = try SCNScene(url: named)
            } catch { failed = !Task.isCancelled }
        }
    }
}

extension URL {
    /// Itself when it is the web's. A screen names no file of the phone's.
    var web: URL? { ["http", "https"].contains(scheme ?? "") ? self : nil }
}

extension Color {
    init?(hex: String) {
        guard let value = HybridConfig.hex(hex) else { return nil }
        self.init(Theme.Shade(light: value, dark: value))
    }

    var hex: String {
        let parts = resolve(in: EnvironmentValues())
        let byte = { (part: Float) in Int((min(max(part, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(parts.red), byte(parts.green), byte(parts.blue))
    }
}
