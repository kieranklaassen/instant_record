import InstantRecordNative
import SwiftUI

/// The Inbox demo on iPhone. Its screens are Ruby, in demo/app/screens. This
/// file names the first one, says where a mailbox keeps its data, and
/// registers the two views that screens ask for by name.
///
/// Launch arguments:
///   -server http://localhost:3000   the Rails demo
///   -member maya -inbox support     who is reading which inbox
///   -token <token>                  from bin/rails 'inbox:token[maya]'
///   -dev YES                        ask Rails for each screen: no rebuild after an edit
///   -poll 0                         seconds between syncs while in front; 0 for none
///   -reset YES                      start from an empty local database
@main
struct InboxApp: App {
    @StateObject private var host: AppHost

    init() {
        var views = Screens()
        views.register("ConversationView") { props, actions in ConversationView(props: props, actions: actions) }
        views.register("InboxSummary") { props, _ in InboxSummary(props: props) }

        let defaults = UserDefaults.standard
        let server = defaults.string(forKey: "server") ?? "http://localhost:3000"
        let first = Route("mailbox", ["member": defaults.string(forKey: "member") ?? "maya", "inbox": defaults.string(forKey: "inbox") ?? "support"])
        let transport = Transport(token: defaults.string(forKey: "token"))
        let folder = URL.applicationSupportDirectory.appending(path: "mail")
        if defaults.bool(forKey: "reset") { try? FileManager.default.removeItem(at: folder) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let engine: Engine = defaults.bool(forKey: "dev") ? HTTPEngine(server: server + "/instant_record", transport: transport) : LibraryEngine()
        var pace = SyncSchedule.Pace()
        if defaults.object(forKey: "poll") != nil { pace.poll = defaults.double(forKey: "poll") }
        // Each member's inbox has its own file, because each syncs with its
        // own address. Everything else in a screen's params is how to show it.
        let host = AppHost(engine: engine, root: first, views: views, store: { route in
            let member = route.params["member"] ?? "", inbox = route.params["inbox"] ?? ""
            return AppHost.Store(database: folder.appending(path: "\(member)-\(inbox).sqlite3").path,
                                 endpoint: "\(server)/email/sync/\(member)/\(inbox)")
        }, exchange: transport.exchange, pace: pace)
        host.start()
        _host = StateObject(wrappedValue: host)
    }

    var body: some Scene {
        WindowGroup { AppView(host: host) }
    }
}
