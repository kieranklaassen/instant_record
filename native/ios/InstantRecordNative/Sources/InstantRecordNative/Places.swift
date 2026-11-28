import SwiftUI

/// A Route is the address of anything an app can show, whichever of the
/// three ways it was written:
///
///     thread              the Ruby screen named thread
///     swift:MapView       the SwiftUI view registered as MapView
///     page:/orders/1      the page Rails serves at /orders/1
///
/// A Ruby screen's name holds no colon, so the three cannot be confused. Ruby
/// writes the same addresses in `link:` and `sheet:`.
public extension Route {
    static func view(_ name: String, _ params: [String: String] = [:]) -> Route { Route("swift:" + name, params) }
    static func page(_ path: String) -> Route { Route("page:" + path) }

    internal var viewName: String? { after("swift:") }
    internal var pagePath: String? { after("page:") }
    /// Whether the app's Ruby draws it.
    internal var isScreen: Bool { viewName == nil && pagePath == nil }

    private func after(_ prefix: String) -> String? {
        screen.hasPrefix(prefix) ? String(screen.dropFirst(prefix.count)) : nil
    }
}

/// Where a link opens what it names: in the stack it is in, or as a sheet
/// over it. Set by whoever draws the stack.
struct Opens {
    var push: ((Route) -> Void)?
    var sheet: ((Route) -> Void)?
    /// Puts a place in the top one's place. Without one, in the app's first.
    var replace: ((Route) -> Void)?
}

private struct OpensKey: EnvironmentKey { static let defaultValue = Opens() }

extension EnvironmentValues {
    var opens: Opens {
        get { self[OpensKey.self] }
        set { self[OpensKey.self] = newValue }
    }
}

private struct EmbeddedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True for a page that is part of a screen, whose bar is the screen's.
    var embedded: Bool {
        get { self[EmbeddedKey.self] }
        set { self[EmbeddedKey.self] = newValue }
    }
}

/// Whatever a route names, drawn by its own kind.
struct PlaceView: View {
    let route: Route
    let host: AppHost?
    let site: HybridSite?
    let views: Screens
    /// Whether it stands in a stack that gives it a bar.
    var pushed = true

    var body: some View {
        if let name = route.viewName {
            if let view = views.view(name, Props(params: route.params), Actions(host: host, route: route)) {
                view
            } else {
                missing(NodeView.unregistered(name))
            }
        } else if let path = route.pagePath {
            if let site { PagePlace(site: site, path: path, pushed: pushed).id(path) } else { missing("This app was given no server to load pages from") }
        } else if let host {
            ScreenView(route: route, host: host, first: false)
        } else {
            missing("This app has no Ruby screens")
        }
    }

    private func missing(_ why: String) -> some View {
        Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
    }
}

#if !os(iOS)
/// Pages are drawn on iOS. The Mac builds this package for its tests.
struct PagePlace: View {
    let site: HybridSite
    let path: String
    var pushed = true
    var body: some View { EmptyView() }
}
#endif
