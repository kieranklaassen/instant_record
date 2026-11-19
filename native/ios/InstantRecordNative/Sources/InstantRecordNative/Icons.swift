/// Icons by what they mean. A screen names the meaning, so the same Ruby can
/// be drawn by a renderer for another platform, and this table picks the
/// SF Symbol and what it is called aloud. A name that is not here is used as
/// an SF Symbol name as given, and is not spoken.
enum Icons {
    private static let symbols = [
        "person": ("person.crop.circle", "Account"),
        "filter": ("slider.horizontal.3", "View"),
        "archive": ("archivebox", "Archive"),
        "inbox": ("tray", "Inbox"),
        "unread": ("circle.fill", "Unread"),
        "read": ("envelope.open", "Read"),
        "send": ("arrow.up.circle.fill", "Send"),
        "compose": ("square.and.pencil", "Compose"),
    ]

    static func symbol(_ name: String) -> String { symbols[name]?.0 ?? name }
    static func spoken(_ name: String) -> String { symbols[name]?.1 ?? "" }
}
