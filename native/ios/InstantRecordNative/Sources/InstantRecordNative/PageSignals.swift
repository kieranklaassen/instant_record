import Foundation

/// The native elements one page asks for, as the page script gathered them
/// from its `data-native` elements (HybridBridge).
public struct PageSignals: Decodable, Equatable {
    public struct Item: Decodable, Equatable {
        public var title = ""
        public var icon = ""
        public var href: String?
        public var click: String?
        public var leading = false
        /// Belongs to the bar's title, as a menu on it.
        public var inTitle = false
        /// A floating button's fill: "#rrggbb", or the tint when there is none.
        public var color: String?
        public var selected = false
        public var destructive = false
        public var replace = false
        public var share = false
        public var shareURL: String?
        public var items: [Item] = []

        enum CodingKeys: CodingKey { case title, icon, href, click, leading, inTitle, color, selected, destructive, replace, share, shareURL, items }

        public init(from decoder: Decoder) throws {
            let from = try decoder.container(keyedBy: CodingKeys.self)
            title = try from.decodeIfPresent(String.self, forKey: .title) ?? ""
            icon = try from.decodeIfPresent(String.self, forKey: .icon) ?? ""
            href = try from.decodeIfPresent(String.self, forKey: .href)
            click = try from.decodeIfPresent(String.self, forKey: .click)
            leading = try from.decodeIfPresent(Bool.self, forKey: .leading) ?? false
            inTitle = try from.decodeIfPresent(Bool.self, forKey: .inTitle) ?? false
            color = try from.decodeIfPresent(String.self, forKey: .color)
            selected = try from.decodeIfPresent(Bool.self, forKey: .selected) ?? false
            destructive = try from.decodeIfPresent(Bool.self, forKey: .destructive) ?? false
            replace = try from.decodeIfPresent(Bool.self, forKey: .replace) ?? false
            share = try from.decodeIfPresent(Bool.self, forKey: .share) ?? false
            shareURL = try from.decodeIfPresent(String.self, forKey: .shareURL)
            items = try from.decodeIfPresent([Item].self, forKey: .items) ?? []
        }
    }

    public struct Navbar: Decodable, Equatable {
        public let title: String
        public let pullToRefresh: Bool
        public let buttons: [Item]
        public let segments: [Item]
        public let submit: Item?
    }

    public struct Toast: Decodable, Equatable {
        public let message: String
        public let icon: String?
    }

    /// The page's address when this was gathered.
    public let url: String
    /// The page carries `native_tabs`.
    public let tabs: Bool
    /// The page is a form, which Back passes over.
    public let form: Bool
    public let navbar: Navbar?
    public let fab: Item?
    public let badges: [String: String]
    public let toast: Toast?

    /// The badge for a tab, as drawn: a count, a short word, or a dot. A dot
    /// is a blank, which iOS draws as one. Nothing for zero or false.
    func badge(for tab: HybridConfig.Tab) -> String? {
        let said = badges[tab.key]
        switch said {
        case nil, "", "0", "false": return nil
        case "true": return " "
        default: return said
        }
    }
}

/// Where the tab bar shows: on a page that asks for it, and on a Ruby
/// screen, which has no page to ask and would otherwise be a dead end.
func tabBarShows(tabs: Int, screen: Bool, signals: PageSignals?) -> Bool {
    tabs >= 2 && (screen || signals?.tabs ?? false)
}
