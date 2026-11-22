import Feedback
import InstantRecordNative
import SwiftUI

/// The Inbox demo on iPhone. Its screens are Ruby, in demo/app/screens. This
/// file names the first one, says where a mailbox keeps its data, and
/// registers the views that screens ask for by name.
///
/// Launch arguments:
///   -server http://localhost:3000   the Rails demo
///   -member maya -inbox support     who is reading which inbox
///   -token <token>                  from bin/rails 'inbox:token[maya]'
///   -dev YES                        ask Rails for each screen: no rebuild after an edit
///   -follow NO                      do not follow the server's events while in front
///   -reset YES                      start from an empty local database
///   -relay http://localhost:8787    where the feedback form sends its notes
///
/// The server, member, inbox and token it was launched with are kept, and
/// used the next time it is opened with none given, as it is from the home
/// screen.
@main
struct InboxApp: App {
    @StateObject private var host: AppHost

    init() {
        var views = Screens()
        views.register("ConversationView") { props, actions in ConversationView(props: props, actions: actions) }
        views.register("InboxSummary") { props, _ in InboxSummary(props: props) }
        views.register("FeedbackForm") { props, _ in FeedbackScreen(props: props) }

        let defaults = UserDefaults.standard
        // A launch argument is read like a setting but is gone at the next
        // launch. Keep these four as settings of the app's own.
        let given = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        for name in ["server", "member", "inbox", "token"] {
            if let value = given[name] as? String { defaults.set(value, forKey: name) }
        }
        // The form is the Feedback library's (EveryInc/swift-libraries). Its
        // relay files a note only for the products it lists, and this one is
        // not listed yet, so Send is answered with the relay's refusal.
        Feedback.setUp(product: "instant-record-inbox",
                       relay: URL(string: defaults.string(forKey: "relay") ?? "https://feedback-relay.jolly-math-3be9.workers.dev")!)
        let server = defaults.string(forKey: "server") ?? "http://localhost:3000"
        let first = Route("mailbox", ["member": defaults.string(forKey: "member") ?? "maya", "inbox": defaults.string(forKey: "inbox") ?? "support"])
        // Every request says who is asking, when the app was given a token.
        let token = defaults.string(forKey: "token") ?? ""
        let transport = Transport(prepare: { request in
            if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        })
        let folder = URL.applicationSupportDirectory.appending(path: "mail")
        if defaults.bool(forKey: "reset") { try? FileManager.default.removeItem(at: folder) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let engine: Engine = defaults.bool(forKey: "dev") ? HTTPEngine(server: server + "/instant_record", transport: transport) : LibraryEngine()
        // Each member's inbox has its own SQLite file (via ir_open) and syncs
        // through the core /instant_record engine using partition & member headers.
        let host = AppHost(engine: engine, root: first, views: views, store: { route in
            let member = route.params["member"] ?? "", inbox = route.params["inbox"] ?? ""
            return AppHost.Store(database: folder.appending(path: "\(member)-\(inbox).sqlite3").path,
                                 endpoint: "\(server)/instant_record",
                                 headers: [
                                    "X-Instant-Record-Partition": "mailbox_id:\(inbox)",
                                    "X-Instant-Record-Member": member,
                                 ])
        }, transport: transport, follows: defaults.object(forKey: "follow") == nil || defaults.bool(forKey: "follow"))
        host.start()
        _host = StateObject(wrappedValue: host)
    }

    var body: some Scene {
        WindowGroup { AppView(host: host, waiting: "Getting your mail", theme: .cora) }
    }
}

/// The Feedback library's form for the screen `feedback`, which the mailbox
/// brings up as a sheet. The form has its own bar, with Cancel and Send, and
/// closes the sheet itself. Who is writing, and from which inbox, go with
/// the note and are shown under it like the rest. The face is the app's.
/// What the form draws inside is the library's own.
private struct FeedbackScreen: View {
    let props: Props
    @Environment(\.theme) private var theme

    var body: some View {
        FeedbackForm(details: ["From": props["from"], "Inbox": props["inbox"]]).fontDesign(theme.ui)
    }
}
