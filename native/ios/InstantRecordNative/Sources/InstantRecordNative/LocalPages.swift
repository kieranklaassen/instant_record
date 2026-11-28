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

    func answer(_ request: URLRequest) async -> Answer {
        guard let url = request.url, url.host == "app" else { return Answer(url: request.url, status: 400, headers: [:], body: Data()) }
        let get = request.httpMethod == nil || request.httpMethod == "GET"
        if get, let file = bundledFile(url.path) { return file.answer(for: url) }
        if get, isAsset(url.path) { return await asset(url) }

        var (method, path, body, at) = (request.httpMethod ?? "GET", Self.path(url), request.body, url)
        // A redirect is followed here: a web view follows none of a scheme's.
        for _ in 0..<5 {
            let said = await app.page(HTTPText.request(method: method, path: path, headers: request.allHTTPHeaderFields ?? [:], body: body, host: Self.root.host!, cookies: cookies))
            guard let said else { return Answer(url: at, status: 500, headers: ["Content-Type": "text/plain"], body: Data("The app could not draw this page.".utf8)) }
            keep(said.cookies)
            guard (301...308).contains(said.status), said.status != 304, let to = said.headers["location"].flatMap({ URL(string: $0, relativeTo: at)?.absoluteURL }) else {
                var headers = said.headers
                headers["content-type"] = headers["content-type"] ?? "text/html; charset=utf-8"
                headers["content-length"] = String(said.body.count)
                return Answer(url: at, status: said.status, headers: headers, body: said.body)
            }
            at = Self.local(to)
            path = Self.path(at)
            if said.status < 307 { (method, body) = ("GET", Data()) }
        }
        return Answer(url: at, status: 508, headers: [:], body: Data())
    }

    /// Whether the library has a page at an address. Asked before a web view
    /// goes there, so that one it lacks is the server's.
    func has(_ url: URL) async -> Bool {
        let said = await app.page(HTTPText.request(method: "GET", path: Self.path(url), headers: ["Accept": "text/html"], body: Data(), host: Self.root.host!, cookies: cookies))
        return said.map { $0.status != 404 } ?? false
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
        let copy = copies.appending(path: Data(url.absoluteString.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").suffix(200).description)
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
            Answer(url: url, status: 200, headers: ["Content-Type": type, "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*"], body: data)
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

    static func request(method: String, path: String, headers: [String: String], body: Data, host: String, cookies: [String: String]) -> String {
        let type = headers.first { $0.key.lowercased() == "content-type" }?.value ?? "application/x-www-form-urlencoded"
        let text = String(decoding: body, as: UTF8.self)
        var verb = method
        // Rails forms send PATCH and DELETE as POST and a _method. The server
        // that reads that is not between here and the app.
        if verb == "POST", type.hasPrefix("application/x-www-form-urlencoded"),
           let override = URLComponents(string: "?" + text)?.queryItems?.first(where: { $0.name == "_method" })?.value?.uppercased(), ["PATCH", "PUT", "DELETE"].contains(override) { verb = override }
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
