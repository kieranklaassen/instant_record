import InstantRecordNative
import SwiftUI

/// The Inbox demo on iPhone. Its screens are Ruby, in demo/app/screens. This
/// file names the first one, says where a mailbox keeps its data, and
/// registers the two views that screens ask for by name.
///
/// Launch arguments, for a server or a member other than the demo's:
///   -server http://localhost:3000 -mailbox maya/support
@main
struct InboxApp: App {
    @StateObject private var host: AppHost

    init() {
        Screens.register("ConversationView") { props, actions in ConversationView(props: props, actions: actions) }
        Screens.register("InboxSummary") { props, _ in InboxSummary(props: props) }

        let defaults = UserDefaults.standard
        let server = defaults.string(forKey: "server") ?? "http://localhost:3000"
        let mailbox = defaults.string(forKey: "mailbox") ?? "maya/support"
        let folder = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A mailbox is "member/inbox", and what follows is how to show it.
        // Each one has its own file, because each syncs with its own address.
        let host = AppHost(engine: LibraryEngine(), root: Route("mailbox", mailbox)) { route in
            let place = route.arg.split(separator: "/").prefix(2)
            return AppHost.Store(database: folder.appending(path: place.joined(separator: "-") + ".sqlite3").path,
                                 endpoint: "\(server)/email/sync/\(place.joined(separator: "/"))")
        }
        host.start()
        _host = StateObject(wrappedValue: host)
    }

    var body: some Scene {
        WindowGroup { AppView(host: host) }
    }
}
