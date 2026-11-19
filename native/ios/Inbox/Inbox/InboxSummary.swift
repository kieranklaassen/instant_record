import InstantRecordNative
import SwiftUI

/// A card at the head of the mailbox's list, written by hand in SwiftUI.
/// MailboxScreen (demo/app/screens/mailbox_screen.rb) hands it its props:
///
///   inbox, unread and showing (numbers), filtered and more (flags)
struct InboxSummary: View {
    let props: Props
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        // At the largest text sizes the count sits over the words, not beside
        // them, so the words keep the row's whole width.
        let layout = size.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 14))
        layout {
            Text("\(props.int("unread"))")
                .font(.system(.largeTitle, design: .rounded).bold())
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("unread in \(props["inbox"])").font(.headline)
                Text(caption).font(.subheadline).foregroundStyle(.secondary)
            }
            if !size.isAccessibilitySize {
                Spacer()
                Image(systemName: "tray.full").font(.title2).foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("summary")
    }

    // What is on this phone, and whether the server holds more.
    private var caption: String {
        let showing = props.bool("filtered") ? "Showing unread only" : "\(props.int("showing")) on this phone"
        return props.bool("more") ? showing + ", more on the server" : showing
    }
}
