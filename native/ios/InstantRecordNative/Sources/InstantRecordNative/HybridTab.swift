import Foundation
import WebKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// One tab of a hybrid app: a web view with its own history, the native
/// elements its page asks for, and what a tap on one of them does.
@MainActor
public final class HybridTab: NSObject, ObservableObject {
    @Published public private(set) var signals: PageSignals?
    @Published public private(set) var canGoBack = false
    /// Why the page could not be loaded, if it could not.
    @Published public private(set) var failure: String?
    @Published public private(set) var toast: PageSignals.Toast?
    /// An address a page asked to share.
    @Published public var sharing: URL?

    /// The native places this page opened over itself, oldest first.
    @Published var path: [Route] = []
    @Published var sheet: Route?

    public let web: WKWebView
    private let site: HybridSite
    private let start: String
    private var server: URL { site.server }
    private var started = false
    private var asked: URL?
    private var watching: [NSKeyValueObservation] = []
    private let forms = NSHashTable<WKBackForwardListItem>.weakObjects()

    init(site: HybridSite, path: String) {
        self.site = site
        start = path
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = site.data
        if let local = site.local { configuration.setURLSchemeHandler(local, forURLScheme: LocalPages.scheme) }
        configuration.applicationNameForUserAgent = Self.agent
        configuration.userContentController.addUserScript(
            WKUserScript(source: HybridBridge.script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: configuration)
        super.init()
        configuration.userContentController.add(Ears(self), contentWorld: .page, name: HybridBridge.handler)
        configuration.userContentController.addScriptMessageHandler(Answers(self), contentWorld: .page, name: HybridBridge.caller)
        web.navigationDelegate = self
        web.uiDelegate = self
        // The edge swipe would stop at forms, which Back passes over.
        web.allowsBackForwardNavigationGestures = false
        watching = [
            web.observe(\.url) { [weak self] _, _ in DispatchQueue.main.async { self?.moved() } },
            web.observe(\.canGoBack) { [weak self] _, _ in DispatchQueue.main.async { self?.moved() } },
        ]
        site.hold(self)
        site.watch(self) { [weak self] in self?.tellRoutes() }
        #if DEBUG
        web.isInspectable = true
        #endif
    }

    deinit {
        let site = site, id = ObjectIdentifier(self)
        Task { @MainActor in site.unwatch(id) }
    }

    /// What `native_app?` reads, and a server's log.
    static var agent: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if os(iOS)
        let system = "iOS"
        #else
        let system = "macOS"
        #endif
        return "InstantRecordNative/1 \(system)/\(os.majorVersion).\(os.minorVersion) App/\(info["CFBundleShortVersionString"] as? String ?? "1.0")"
    }

    /// Load the tab's first page, once.
    func load() {
        guard !started else { return }
        started = true
        go(start)
    }

    public func retry() {
        failure = nil
        if let asked { web.load(URLRequest(url: asked)) } else { go(start) }
    }

    public func reload() {
        if failure == nil, web.url != nil { web.reload() } else { retry() }
    }

    /// Go to an address, written as a page would write it: a native place
    /// when the address is one's, and a page otherwise.
    public func visit(_ href: String, replace: Bool = false) {
        guard let url = URL(string: href, relativeTo: web.url ?? server)?.absoluteURL else { return }
        if let place = site.place(at: url) {
            if place.sheet { sheet = place.route } else { path.append(place.route) }
            return
        }
        go(href, replace: replace)
    }

    private func go(_ href: String, replace: Bool = false) {
        guard let url = URL(string: href, relativeTo: web.url ?? server)?.absoluteURL else { return }
        switch decide(url) {
        case .outside: site.outside(url)
        case .refuse: break
        case .stay:
            if let local = site.local {
                let here = LocalPages.local(url)
                Task {
                    let target = await local.has(here) ? here : LocalPages.remote(url, server: server)
                    self.move(to: target, replace: replace)
                }
                return
            }
            move(to: url, replace: replace)
        }
    }

    private func decide(_ url: URL, mainFrame: Bool = true, method: String = "GET") -> HybridNavigation {
        site.owns(url) ? .stay : HybridNavigation.decide(url, server: server, mainFrame: mainFrame, method: method)
    }

    /// The app's data changed: a page drawn from it is drawn again in place.
    func recordsChanged() {
        guard web.url?.scheme == LocalPages.scheme else { return }
        run("""
        const event = new CustomEvent("instant-record:records-changed", { cancelable: true })
        if (window.dispatchEvent(event) && window.Turbo?.session?.refresh && !document.activeElement?.closest?.("form")) window.Turbo.session.refresh(location.href)
        """)
    }

    private func move(to url: URL, replace: Bool) {
            asked = url
            // A page that is there moves itself, so that Turbo and history
            // are its own. Without one the web view loads.
            guard let at = web.url, at.scheme == url.scheme, failure == nil else { web.load(URLRequest(url: url)); return }
            run("window.instantRecordHybrid.visit(url, replace)", ["url": url.absoluteString, "replace": replace])
    }

    /// A tap on a native element.
    public func tap(_ item: PageSignals.Item, replace: Bool = false) {
        if let href = item.href {
            visit(href, replace: replace || item.replace)
        } else if let click = item.click {
            run("window.instantRecordHybrid.click(selector)", ["selector": click])
        }
    }

    public func back() {
        guard let earlier = target() else { return }
        web.go(to: earlier)
    }

    /// The address a share element shares: its own, or the page's.
    public func shared(_ item: PageSignals.Item) -> URL {
        (item.shareURL.flatMap { URL(string: $0, relativeTo: web.url ?? server)?.absoluteURL } ?? web.url ?? server).atServer(server)
    }

    func dismissToast() { toast = nil }

    private func target() -> WKBackForwardListItem? {
        let earlier = web.backForwardList.backList
        return HybridNavigation.back(over: earlier.map(forms.contains)).map { earlier[$0] }
    }

    private func tellRoutes() {
        run("window.instantRecordHybrid?.routes(patterns)", ["patterns": site.routes.map { ["pattern": $0.pattern, "page": $0.page] as [String: Any] }])
    }

    private func moved() {
        tellRoutes()
        canGoBack = target() != nil
        run("window.instantRecordHybrid?.back(can)", ["can": canGoBack])
        run("window.instantRecordHybrid?.gather()")
    }

    private func run(_ script: String, _ arguments: [String: Any] = [:]) {
        web.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { _ in }
    }

    // Only the main frame of the app's own server is listened to.
    private func trusts(_ message: WKScriptMessage) -> Bool {
        let from = message.frameInfo.securityOrigin
        if from.protocol == LocalPages.scheme { return message.frameInfo.isMainFrame && site.local != nil && from.host == "app" }
        return message.frameInfo.isMainFrame && Origin(scheme: from.protocol, host: from.host, port: from.port) == Origin(server)
    }

    fileprivate func answer(_ message: WKScriptMessage) async -> (Any?, String?) {
        guard trusts(message), let body = message.body as? [String: Any], let name = body["name"] as? String else { return (nil, "Not allowed") }
        guard let capabilities = site.capabilities else { return (nil, "This app was given no capabilities") }
        do { return (try await capabilities.call(name, Capabilities.arguments(body["arguments"])), nil) } catch { return (nil, error.localizedDescription) }
    }

    fileprivate func hear(_ message: WKScriptMessage) {
        guard trusts(message), let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "signals": receive(body["signals"] as? String ?? "")
        case "back": back()
        case "visit": visit(body["url"] as? String ?? "", replace: body["replace"] as? Bool ?? false)
        case "share": share(body["url"] as? String ?? "")
        case "haptic": feel(body["feedback"] as? String ?? "")
        default: break
        }
    }

    private func receive(_ json: String) {
        guard let said = try? JSONDecoder().decode(PageSignals.self, from: Data(json.utf8)) else { return }
        // A snapshot that arrives late is another page's.
        guard said.url == web.url?.absoluteString else { return }
        if said != signals { signals = said }
        if let new = said.toast { toast = new }
        if let current = web.backForwardList.currentItem {
            if said.form { forms.add(current) } else { forms.remove(current) }
        }
        canGoBack = target() != nil
    }

    private func share(_ address: String) {
        guard let url = URL(string: address, relativeTo: web.url ?? server)?.absoluteURL, site.owns(url) || Origin(url) != nil else { return }
        // What is shared is the server's address: the device's opens nowhere else.
        sharing = url.scheme == LocalPages.scheme ? LocalPages.remote(url, server: server) : url
    }

    private func feel(_ feedback: String) {
        Haptics.play(feedback)
    }
}

// The web view keeps its message handler, so a tab that was its own would
// never go away.
private final class Ears: NSObject, WKScriptMessageHandler {
    weak var tab: HybridTab?
    init(_ tab: HybridTab) { self.tab = tab }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { tab?.hear(message) }
    }
}

private final class Answers: NSObject, WKScriptMessageHandlerWithReply {
    weak var tab: HybridTab?
    init(_ tab: HybridTab) { self.tab = tab }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let tab else { return (nil, "Closed") }
        return await tab.answer(message)
    }
}

extension HybridTab: WKNavigationDelegate, WKUIDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        // No target frame is a new window, which this app has none of.
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        let method = action.request.httpMethod ?? "GET"
        switch decide(url, mainFrame: mainFrame, method: method) {
        case .stay:
            // A link from a page on the device to one the library lacks.
            if mainFrame, method == "GET", url.scheme == LocalPages.scheme, action.navigationType == .linkActivated, let local = site.local {
                decisionHandler(.cancel)
                Task {
                    let here = await local.has(url)
                    self.asked = here ? url : LocalPages.remote(url, server: server)
                    self.web.load(URLRequest(url: self.asked!))
                }
                return
            }
            if mainFrame { asked = url }
            decisionHandler(.allow)
        case .outside:
            site.outside(url)
            decisionHandler(.cancel)
        case .refuse: decisionHandler(.cancel)
        }
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // decidePolicyFor has sent an address of another server outside.
        if let url = action.request.url, decide(url) == .stay { webView.load(action.request) }
        return nil
    }

    // Before the page's images have come: it is already there to be tapped.
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { moved() }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        failure = nil
        ended()
        moved()
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { reload() }

    private func failed(_ error: Error) {
        ended()
        let error = error as NSError
        // Not failures: a load another took the place of, and one that became
        // something else (the policy said no).
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain", error.code == 102 { return }
        failure = error.localizedDescription
    }

    private func ended() {
        #if os(iOS)
        web.scrollView.refreshControl?.endRefreshing()
        #endif
    }

    #if os(iOS)
    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        ask(message, [("OK", .default, { _ in completionHandler() })], otherwise: completionHandler)
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        ask(message, [("Cancel", .cancel, { _ in completionHandler(false) }), ("OK", .default, { _ in completionHandler(true) })],
            otherwise: { completionHandler(false) })
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        ask(prompt, field: defaultText ?? "", [("Cancel", .cancel, { _ in completionHandler(nil) }), ("OK", .default, { completionHandler($0.textFields?.first?.text) })],
            otherwise: { completionHandler(nil) })
    }

    // WebKit must be answered exactly once, also when nothing can be shown.
    private func ask(_ message: String, field: String? = nil, _ choices: [(String, UIAlertAction.Style, (UIAlertController) -> Void)], otherwise: () -> Void) {
        var top = web.window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        guard let top else { return otherwise() }
        let panel = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        if let field { panel.addTextField { $0.text = field } }
        for (title, style, answer) in choices {
            panel.addAction(UIAlertAction(title: title, style: style) { [unowned panel] _ in answer(panel) })
        }
        top.present(panel, animated: true)
    }
    #elseif os(macOS)
    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        let panel = NSAlert()
        panel.messageText = message
        panel.runModal()
        completionHandler()
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        let panel = NSAlert()
        panel.messageText = message
        panel.addButton(withTitle: "OK")
        panel.addButton(withTitle: "Cancel")
        completionHandler(panel.runModal() == .alertFirstButtonReturn)
    }
    #endif
}

private extension URL {
    func atServer(_ server: URL) -> URL { scheme == LocalPages.scheme ? LocalPages.remote(self, server: server) : self }
}
