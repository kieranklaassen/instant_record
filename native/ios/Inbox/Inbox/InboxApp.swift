import InstantRecordNative
import SwiftUI

/// The Inbox demo on iPhone. Its screens are Ruby, in demo/app/screens. All
/// this file knows of them is the first one's name and where the app syncs.
///
/// Launch arguments, for a server or a member other than the demo's:
///   -server http://localhost:3000 -mailbox maya/support
@main
struct InboxApp: App {
    @StateObject private var host: AppHost

    init() {
        let defaults = UserDefaults.standard
        let server = defaults.string(forKey: "server") ?? "http://localhost:3000"
        let mailbox = defaults.string(forKey: "mailbox") ?? "maya/support"
        let host = AppHost(engine: LibraryEngine(), root: Route("mailbox", mailbox), endpoint: "\(server)/email/sync/\(mailbox)")
        let folder = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        host.start(database: folder.appending(path: "inbox.sqlite3").path)
        _host = StateObject(wrappedValue: host)
    }

    var body: some Scene {
        WindowGroup { AppView(host: host) }
    }
}
