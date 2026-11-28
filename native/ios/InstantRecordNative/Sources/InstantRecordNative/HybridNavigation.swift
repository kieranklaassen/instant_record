import Foundation

/// A server, as far as trust goes: its scheme, host and port.
struct Origin: Equatable {
    let scheme: String
    let host: String
    let port: Int

    init?(_ url: URL) {
        self.init(scheme: url.scheme ?? "", host: url.host ?? "", port: url.port ?? 0)
    }

    /// A port of 0 is the scheme's own, as WebKit writes it.
    init?(scheme: String, host: String, port: Int) {
        let scheme = scheme.lowercased()
        guard ["http", "https"].contains(scheme), !host.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host.lowercased()
        self.port = port > 0 ? port : scheme == "https" ? 443 : 80
    }
}

enum HybridNavigation: Equatable {
    case stay
    /// Another app's: a browser, mail, the phone.
    case outside
    case refuse

    /// What becomes of a request the page or a native element makes.
    static func decide(_ url: URL, server: URL, mainFrame: Bool = true, method: String = "GET") -> HybridNavigation {
        guard mainFrame else { return .stay }
        if url.absoluteString == "about:blank" { return .stay }
        if let origin = Origin(url) {
            if origin == Origin(server) { return .stay }
            return method == "GET" ? .outside : .refuse
        }
        return ["mailto", "tel", "sms", "facetime"].contains(url.scheme?.lowercased() ?? "") ? .outside : .refuse
    }

    /// How far back to go: to the nearest earlier page that is not a form.
    /// `forms` is whether each earlier page is one, oldest first.
    static func back(over forms: [Bool]) -> Int? {
        forms.lastIndex(of: false)
    }
}
