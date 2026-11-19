import InstantRecordNative
import SwiftUI

/// A card at the head of the mailbox's list, written by hand in SwiftUI.
/// MailboxScreen (demo/app/screens/mailbox_screen.rb) hands it its props:
///
///   inbox, unread (a count), showing (a count), filter ("all" or "unread")
struct InboxSummary: View {
    let props: Props

    var body: some View {
        HStack(spacing: 14) {
            Text(props["unread"])
                .font(.system(.largeTitle, design: .rounded).bold())
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("unread in \(props["inbox"])").font(.headline)
                Text(props["filter"] == "unread" ? "Showing unread only" : "Showing \(props["showing"]) open")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "tray.full").font(.title2).foregroundStyle(.tint)
        }
        .padding(.vertical, 6)
    }
}
