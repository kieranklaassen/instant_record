/// Icons by what they mean. A screen names the meaning, so the same Ruby can
/// be drawn by a renderer for another platform, and this table picks the
/// SF Symbol. A name that is not here is used as an SF Symbol name as given.
enum Icons {
    private static let symbols = [
        "person": "person.crop.circle",
        "filter": "slider.horizontal.3",
        "archive": "archivebox",
        "inbox": "tray",
        "unread": "circle.fill",
        "read": "envelope.open",
        "send": "arrow.up.circle.fill",
        "compose": "square.and.pencil",
    ]

    static func symbol(_ name: String) -> String { symbols[name] ?? name }
}
