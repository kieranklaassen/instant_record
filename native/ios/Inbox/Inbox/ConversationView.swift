import InstantRecordNative
import SwiftUI

/// A conversation as bubbles, written by hand in SwiftUI. ThreadScreen
/// (demo/app/screens/thread_screen.rb) hands it its props:
///
///   subject, participants, archived (a flag)
///   messages: author, address, date (ISO 8601), body, mine (a flag)
///
/// The reply box under it is not part of this view: the screen draws it.
struct ConversationView: View {
    let props: Props
    let actions: Actions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(props["subject"]).font(.title2.bold())
                    Label(props["participants"], systemImage: "person.2").font(.subheadline).foregroundStyle(.secondary)
                    if props.bool("archived") {
                        Label("Archived", systemImage: "archivebox").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(props.list("messages").enumerated()), id: \.offset) { bubble($0.element) }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !props.bool("archived") {
                Button("Archive", systemImage: "archivebox", role: .destructive) {
                    actions.perform("archive")
                }
            }
        }
    }

    private func bubble(_ message: Props) -> some View {
        let mine = message.bool("mine")
        return VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(message["author"]).font(.footnote.weight(.semibold))
                if !message["address"].isEmpty { Text(message["address"]).font(.footnote).foregroundStyle(.secondary) }
                if let date = message.date("date") {
                    Text(date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Text(message["body"])
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(mine ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(mine ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary), in: RoundedRectangle(cornerRadius: 18))
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(mine ? .leading : .trailing, 40)
    }
}
