import CryptoKit
import Foundation
import WebKit

/// Pages the app's own Rails renders, on the device: the compiled library's
/// router, controllers and views, over the same SQLite file its Ruby screens
/// read. They need no network, and a form's write is queued and synced like
/// any other.
///
/// A web view asks for `instant-record://app/orders`. What the library has no
/// route for goes to the server, and what a page links beside (its scripts
/// and styles) comes from the app's bundle, or from the server once and then
/// from a copy.
@MainActor
final class LocalPages: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "instant-record"
    nonisolated static let root = URL(string: "instant-record://app/")!

    private let app: AppHost
    private let server: URL
    private let bundled: URL?
    private let copies: URL
    private var cookies: [String: String] = [:]
    private var running: Set<ObjectIdentifier> = []
    private(set) var routes: [LocalRoute] = []
    /// Where a page is sent that this app does not draw.
    nonisolated static let elsewhere = "X-Instant-Record-Location"

    init(app: AppHost, server: URL, bundled: URL? = Bundle.main.url(forResource: "Pages", withExtension: nil),
         copies: URL = URL.cachesDirectory.appending(path: "instant-record-pages")) {
        self.app = app
        self.server = server
        self.bundled = bundled
        self.copies = copies
    }

    /// The same address on the device, for one of the server's.
    nonisolated static func local(_ url: URL) -> URL {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: true)
        parts?.scheme = scheme
        parts?.host = "app"
        parts?.port = nil
        parts?.user = nil
        parts?.password = nil
        if parts?.path.isEmpty == true { parts?.path = "/" }
        return parts?.url ?? root
    }

    /// And the other way.
    nonisolated static func remote(_ url: URL, server: URL) -> URL {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: true)
        parts?.scheme = server.scheme
        parts?.host = server.host
        parts?.port = server.port
        return parts?.url ?? server
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        running.insert(id)
        Task {
            let answer = await self.answer(task.request)
            // A task that was stopped must not be answered.
            guard self.running.remove(id) != nil, let url = answer.url,
                  let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers) else { return }
            task.didReceive(response)
            task.didReceive(answer.body)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { running.remove(ObjectIdentifier(task)) }

    struct Answer {
        var url: URL?
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    /// Ask the library once which pages it draws.
    func learn() async { routes = LocalRoute.all(await app.routes()) }

    /// Another account's session is not this one's.
    func forget() { cookies = [:] }

    /// Whether the library draws what is at an address.
    func has(_ url: URL, method: String = "GET") -> Bool { routes.contains { $0.matches(method, url.path) } }

    /// A write is taken from this app's own pages. A frame, and a page of a
    /// server's, say another origin, or none.
    static func own(_ request: URLRequest) -> Bool {
        let method = request.httpMethod ?? "GET"
        if ["GET", "HEAD"].contains(method) { return true }
        if let origin = request.value(forHTTPHeaderField: "Origin") { return origin == "\(scheme)://app" }
        return request.value(forHTTPHeaderField: "Referer")?.hasPrefix("\(scheme)://app/") ?? false
    }

    private func plain(_ url: URL?, _ status: Int, _ text: String) -> Answer {
        Answer(url: url, status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8))
    }

    // To an address this app does not draw: the page script of a Turbo visit
    // reads the header, and a plain navigation runs the line.
    private func away(to target: URL, at url: URL) -> Answer {
        let json = (try? JSONEncoder().encode(target.absoluteString)).map { String(decoding: $0, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c") } ?? "\"\""
        return Answer(url: url, status: 200, headers: ["Content-Type": "text/html; charset=utf-8", Self.elsewhere: target.absoluteString],
                      body: Data("<!doctype html><script>window.InstantRecord.visit(\(json), { replace: true })</script>".utf8))
    }

    func answer(_ request: URLRequest) async -> Answer {
        guard let url = request.url, url.host == "app" else { return plain(request.url, 400, "Not this app's.") }
        guard Self.own(request) else { return plain(url, 403, "A write comes from this app's own pages.") }
        let get = request.httpMethod == nil || request.httpMethod == "GET"
        if get, let file = bundledFile(url.path) { return file.answer(for: url) }
        if get, isAsset(url.path) { return await asset(url) }
        if routes.isEmpty { await learn() }

        let sent = request.body
        guard let text = String(data: sent, encoding: .utf8), !text.contains("\0") else { return plain(url, 415, "A file cannot be sent from a page drawn on the device.") }
        let turbo = request.value(forHTTPHeaderField: "X-Turbo-Request-Id") != nil
        var method = HTTPText.method(request.httpMethod ?? "GET", type: request.value(forHTTPHeaderField: "Content-Type") ?? "", text: text)
        var (body, at) = (sent, url)
        guard has(url, method: method) else {
            return get ? away(to: Self.remote(url, server: server), at: url) : plain(url, 404, "This app draws no such page.")
        }
        // A redirect is followed here: a web view follows none of a scheme's.
        for _ in 0..<5 {
            let said = await app.page(HTTPText.request(method: method, path: Self.path(at), headers: request.allHTTPHeaderFields ?? [:], body: body, host: Self.root.host!, cookies: cookies))
            guard let said else { return plain(at, 500, "The app could not draw this page.") }
            keep(said.cookies)
            guard [301, 302, 303, 307, 308].contains(said.status), let to = said.headers["location"].flatMap({ URL(string: $0, relativeTo: at)?.absoluteURL }) else {
                var headers = said.headers
                headers["content-type"] = headers["content-type"] ?? "text/html; charset=utf-8"
                headers["content-length"] = String(said.body.count)
                return Answer(url: at, status: said.status, headers: headers, body: said.body)
            }
            let ours = (to.scheme == Self.scheme && to.host == "app") || Origin(to) == Origin(server) || (Origin(to) != nil && to.host == "app")
            guard ours, has(Self.local(to)) || said.status >= 307 else {
                return away(to: ours ? Self.remote(to, server: server) : to, at: at)
            }
            // Turbo takes a form's answer only as a redirect it saw itself.
            if turbo, !get { return away(to: Self.local(to), at: at) }
            at = Self.local(to)
            if said.status < 307 { (method, body) = ("GET", Data()) }
        }
        return plain(at, 508, "Too many redirects.")
    }

    private static func path(_ url: URL) -> String {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: true)
        let path = parts?.percentEncodedPath ?? ""
        return (path.isEmpty ? "/" : path) + (parts?.percentEncodedQuery.map { "?" + $0 } ?? "")
    }

    private func keep(_ set: [String]) {
        for cookie in set {
            let parts = cookie.split(separator: ";")
            guard let pair = parts.first?.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false), pair.count == 2 else { continue }
            let gone = parts.dropFirst().contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "max-age=0" }
            cookies[String(pair[0])] = gone ? nil : String(pair[1])
        }
    }

    // MARK: what a page links beside

    private func isAsset(_ path: String) -> Bool {
        path.hasPrefix("/assets/") || path.hasPrefix("/vite/") || ["css", "js", "png", "jpg", "jpeg", "svg", "webp", "gif", "ico", "woff", "woff2"].contains((path as NSString).pathExtension.lowercased())
    }

    private func bundledFile(_ path: String) -> File? {
        guard let bundled, path.count > 1 else { return nil }
        let file = bundled.appending(path: String(path.dropFirst())).standardizedFileURL
        // A path with .. in it names nothing outside.
        guard file.path.hasPrefix(bundled.standardizedFileURL.path + "/"), let data = try? Data(contentsOf: file) else { return nil }
        return File(data: data, type: File.type(path))
    }

    private func asset(_ url: URL) async -> Answer {
        let copy = copies.appending(path: SHA256.hash(data: Data(Self.remote(url, server: server).absoluteString.utf8)).map { String(format: "%02x", $0) }.joined())
        let fingerprinted = url.path.range(of: #"-[0-9a-f]{8,}\.\w+$"#, options: .regularExpression) != nil
        if fingerprinted, let data = try? Data(contentsOf: copy) { return File(data: data, type: File.type(url.path)).answer(for: url) }
        if let (data, response) = try? await URLSession.shared.data(from: Self.remote(url, server: server)), (response as? HTTPURLResponse)?.statusCode == 200 {
            try? FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
            try? data.write(to: copy)
            return File(data: data, type: File.type(url.path)).answer(for: url)
        }
        if let data = try? Data(contentsOf: copy) { return File(data: data, type: File.type(url.path)).answer(for: url) }
        return Answer(url: url, status: 404, headers: [:], body: Data())
    }

    struct File {
        let data: Data
        let type: String

        func answer(for url: URL) -> Answer {
            Answer(url: url, status: 200, headers: ["Content-Type": type, "Content-Length": String(data.count), "Access-Control-Allow-Origin": "instant-record://app"], body: data)
        }

        static func type(_ path: String) -> String {
            switch (path as NSString).pathExtension.lowercased() {
            case "css": "text/css; charset=utf-8"
            case "js", "mjs": "text/javascript; charset=utf-8"
            case "json": "application/json"
            case "svg": "image/svg+xml"
            case "png": "image/png"
            case "jpg", "jpeg": "image/jpeg"
            case "webp": "image/webp"
            case "gif": "image/gif"
            case "woff": "font/woff"
            case "woff2": "font/woff2"
            default: "application/octet-stream"
            }
        }
    }
}

/// One of the library's routes.
struct LocalRoute: Equatable {
    let verb: String
    let parts: [String]

    static func all(_ text: String) -> [LocalRoute] {
        text.components(separatedBy: "\n").compactMap { line in
            let words = line.split(separator: " ", maxSplits: 1)
            guard words.count == 2, words[1].hasPrefix("/") else { return nil }
            return LocalRoute(verb: String(words[0]), parts: words[1].split(separator: "/").map(String.init))
        }
    }

    func matches(_ method: String, _ path: String) -> Bool {
        let words = path.split(separator: "/")
        guard (method == "HEAD" ? "GET" : method) == verb, words.count == parts.count else { return false }
        return zip(parts, words).allSatisfy { $0.hasPrefix(":") || $0 == $1 }
    }

    /// The same match, for the page script.
    var pattern: String {
        "^/" + parts.map { $0.hasPrefix(":") ? "[^/]+" : NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "/") + "/?$"
    }
}

extension URLRequest {
    var body: Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var all = Data(), piece = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = stream.read(&piece, maxLength: piece.count)
            if count <= 0 { return all }
            all.append(contentsOf: piece[0..<count])
        }
    }
}

/// HTTP as the compiled app reads and writes it.
enum HTTPText {
    struct Reply {
        let status: Int
        let headers: [String: String]
        let cookies: [String]
        let body: Data
    }

    /// Rails forms send PATCH and DELETE as POST and a _method. The server
    /// that reads that is not between here and the app.
    static func method(_ method: String, type: String, text: String) -> String {
        guard method == "POST" else { return method }
        var asked: String?
        if type.isEmpty || type.hasPrefix("application/x-www-form-urlencoded") {
            asked = URLComponents(string: "?" + text)?.queryItems?.first { $0.name == "_method" }?.value
        } else if type.hasPrefix("multipart/form-data"), let found = text.range(of: #"name="_method"\r\n\r\n[A-Za-z]+"#, options: .regularExpression) {
            asked = text[found].components(separatedBy: "\r\n").last
        }
        let verb = asked?.uppercased() ?? method
        return ["PATCH", "PUT", "DELETE"].contains(verb) ? verb : method
    }

    static func request(method: String, path: String, headers: [String: String], body: Data, host: String, cookies: [String: String]) -> String {
        let type = headers.first { $0.key.lowercased() == "content-type" }?.value ?? "application/x-www-form-urlencoded"
        let text = String(decoding: body, as: UTF8.self)
        let verb = method
        func line(_ value: String) -> String { value.components(separatedBy: .newlines).joined(separator: " ") }
        var head = "\(verb) \(path) HTTP/1.1\r\nHost: \(host)\r\n"
        if !cookies.isEmpty { head += "Cookie: " + cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ") + "\r\n" }
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) where !["host", "cookie", "content-type", "content-length"].contains(name.lowercased()) {
            head += "\(line(name)): \(line(value))\r\n"
        }
        if !body.isEmpty { head += "Content-Type: \(line(type))\r\nContent-Length: \(text.utf8.count)\r\n" }
        return head + "\r\n" + text
    }

    static func reply(_ text: String) -> Reply? {
        // By bytes: Swift takes \r\n for one character.
        let parts = text.range(of: "\n\n")
        let head = (parts.map { String(text[..<$0.lowerBound]) } ?? text).components(separatedBy: "\n")
        guard let status = head.first.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else { return nil }
        var headers: [String: String] = [:], cookies: [String] = []
        for line in head.dropFirst() {
            guard let colon = line.range(of: ": ") else { continue }
            let name = line[..<colon.lowerBound].lowercased(), value = String(line[colon.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "set-cookie" { cookies.append(value) } else { headers[name] = value }
        }
        return Reply(status: status, headers: headers, cookies: cookies, body: Data((parts.map { String(text[$0.upperBound...]) } ?? "").utf8))
    }
}
