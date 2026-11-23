import InstantRecordNative
import SwiftUI

/// A conversation as bubbles, written by hand in SwiftUI. ThreadScreen
/// (demo/app/screens/thread_screen.rb) declares its typed contract
/// (`ConversationViewProps` / `ConversationViewAction`), compiled by Prism
/// into `InstantRecordContracts.swift`.
///
/// The reply box under it is not part of this view: the screen draws it.
struct ConversationView: View {
    let props: ConversationViewProps
    let actions: TypedActions<ConversationViewAction>
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    // What is read is set in the reading face: the subject and each message.
                    Text(props.subject).font(.title2.bold()).fontDesign(theme.reading).foregroundStyle(theme.ink)
                    Label(props.participants, systemImage: "person.2").font(.subheadline).fontDesign(theme.ui).foregroundStyle(theme.muted)
                    if props.archived {
                        Label("Archived", systemImage: "archivebox").font(.caption).fontDesign(theme.ui).foregroundStyle(theme.muted)
                    }
                }
                ForEach(Array(props.messages.enumerated()), id: \.offset) { bubble($0.element) }
            }
            .padding()
        }
        .background { theme.page?.ignoresSafeArea() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !props.archived {
                Button("Archive", systemImage: "archivebox", role: .destructive) {
                    actions.send(.archive)
                }
            }
        }
    }

    private func bubble(_ message: ConversationViewProps.Message) -> some View {
        let mine = message.mine
        return VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(message.author).font(.footnote.weight(.semibold)).foregroundStyle(theme.ink)
                if !message.address.isEmpty { Text(message.address).font(.footnote).foregroundStyle(theme.muted) }
                Text(message.date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.footnote).foregroundStyle(theme.muted)
            }
            .fontDesign(theme.ui)
            // Your own words on the accent, the others' on the quiet fill
            // with a hairline. Flat: no shadow under either.
            Text(message.body)
                .fontDesign(theme.reading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(mine ? theme.onAccent : theme.ink)
                .background(mine ? AnyShapeStyle(theme.accent) : theme.fill.map(AnyShapeStyle.init) ?? AnyShapeStyle(.fill.tertiary), in: RoundedRectangle(cornerRadius: 18))
                .overlay { if !mine, let line = theme.hairline { RoundedRectangle(cornerRadius: 18).strokeBorder(line) } }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(mine ? .leading : .trailing, 40)
    }
}
