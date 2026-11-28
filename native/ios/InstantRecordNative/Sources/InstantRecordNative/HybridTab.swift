import Foundation
import WebKit
#if canImport(UIKit)
import UIKit
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
        configuration.applicationNameForUserAgent = Self.agent
        configuration.userContentController.addUserScript(
            WKUserScript(source: HybridBridge.script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: configuration)
        super.init()
        configuration.userContentController.add(Ears(self), contentWorld: .page, name: HybridBridge.handler)
        web.navigationDelegate = self
        web.uiDelegate = self
        // The edge swipe would stop at forms, which Back passes over.
        web.allowsBackForwardNavigationGestures = false
        watching = [
            web.observe(\.url) { [weak self] _, _ in DispatchQueue.main.async { self?.moved() } },
            web.observe(\.canGoBack) { [weak self] _, _ in DispatchQueue.main.async { self?.moved() } },
        ]
        site.watch(self) { [weak self] in self?.tellRoutes() }
        #if DEBUG
        web.isInspectable = true
        #endif
    }

    deinit {
        let site = site, id = ObjectIdentifier(self)
        Task { @MainActor in site.unwatch(id) }
    }

    /// What the ruby_native gem's `native_app?`, `native_platform` and
    /// `native_version` read. The last word tells this shell from others.
    static var agent: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info["CFBundleVersion"] as? String ?? "1"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "Ruby Native iOS/\(version)/\(build) iOS/\(os.majorVersion).\(os.minorVersion).\(os.patchVersion) RubyNative/0.21.1 InstantRecord/1"
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
        switch HybridNavigation.decide(url, server: server) {
        case .outside: site.outside(url)
        case .refuse: break
        case .stay:
            asked = url
            // A page that is there moves itself, so that Turbo and history
            // are its own. Without one the web view loads.
            guard web.url != nil, failure == nil else { web.load(URLRequest(url: url)); return }
            run("window.instantRecordHybrid.visit(url, replace)", ["url": url.absoluteString, "replace": replace])
        }
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
        item.shareURL.flatMap { URL(string: $0, relativeTo: web.url ?? server)?.absoluteURL } ?? web.url ?? server
    }

    func dismissToast() { toast = nil }

    private func target() -> WKBackForwardListItem? {
        let earlier = web.backForwardList.backList
        return HybridNavigation.back(over: earlier.map(forms.contains)).map { earlier[$0] }
    }

    private func tellRoutes() {
        run("window.instantRecordHybrid?.routes(patterns)", ["patterns": site.routes.map(\.pattern)])
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

    fileprivate func hear(_ message: WKScriptMessage) {
        let from = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame,
              Origin(scheme: from.protocol, host: from.host, port: from.port) == Origin(server),
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
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
        guard let url = URL(string: address, relativeTo: web.url ?? server)?.absoluteURL, Origin(url) != nil else { return }
        sharing = url
    }

    private func feel(_ feedback: String) {
        #if os(iOS)
        switch feedback {
        case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
        case "selection": UISelectionFeedbackGenerator().selectionChanged()
        case "light": UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case "medium": UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case "heavy": UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        default: UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        #endif
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

extension HybridTab: WKNavigationDelegate, WKUIDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        // No target frame is a new window, which this app has none of.
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        switch HybridNavigation.decide(url, server: server, mainFrame: mainFrame, method: action.request.httpMethod ?? "GET") {
        case .stay:
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
        if let url = action.request.url, HybridNavigation.decide(url, server: server) == .stay { webView.load(action.request) }
        return nil
    }

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
    #endif
}
