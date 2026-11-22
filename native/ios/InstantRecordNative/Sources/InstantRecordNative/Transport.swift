import Foundation

/// The network, for an app that never opens a connection itself. A request is
/// "METHOD URL\n" and then the body. The answer is the status on the first
/// line and then the response body, or "0\n" when the network failed.
///
/// `prepare` sees every request before it goes: an app adds what says who is
/// asking there, such as an Authorization header.
public struct Transport {
    public static let offline = "0\n"
    let session: URLSession
    private let prepare: (inout URLRequest) -> Void

    public init(timeout: TimeInterval = 10, prepare: @escaping (inout URLRequest) -> Void = { _ in }) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
        self.prepare = prepare
    }

    /// Apply this transport's request preparation (for example Authorization
    /// headers) to an outgoing request.
    public func prepareRequest(_ request: inout URLRequest) {
        prepare(&request)
    }

    /// The request as it goes out, or nil when it cannot be read.
    /// Supports both "METHOD URL\n<body>" and "METHOD URL\nHeader: Value\n\n<body>".
    func request(_ exchange: String) -> URLRequest? {
        let parts = exchange.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let line = parts[0].split(separator: " ", maxSplits: 1)
        guard line.count == 2, let url = URL(string: String(line[1])), url.scheme != nil else { return nil }
        var call = URLRequest(url: url)
        call.httpMethod = String(line[0])
        var rest = parts.count > 1 ? String(parts[1]) : ""
        if let boundary = rest.range(of: "\n\n") {
            let candidate = rest[..<boundary.lowerBound].split(separator: "\n")
            if !candidate.isEmpty, candidate.allSatisfy({ $0.contains(": ") }) {
                for header in candidate {
                    if let colon = header.range(of: ": ") {
                        call.setValue(String(header[colon.upperBound...]), forHTTPHeaderField: String(header[..<colon.lowerBound]))
                    }
                }
                rest = String(rest[boundary.upperBound...])
            }
        }
        if call.httpMethod != "GET" {
            call.httpBody = Data(rest.utf8)
            if call.value(forHTTPHeaderField: "Content-Type") == nil {
                call.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        prepare(&call)
        return call
    }

    /// Blocks the calling thread until the answer is in. Never call it on the
    /// main thread, or on the engine's: a tap would wait behind it.
    public func exchange(_ exchange: String) -> String {
        guard let call = request(exchange) else { return Transport.offline }
        var answer = Transport.offline
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: call) { data, response, _ in
            if let response = response as? HTTPURLResponse, let data {
                answer = "\(response.statusCode)\n" + String(decoding: data, as: UTF8.self)
            }
            done.signal()
        }.resume()
        done.wait()
        return answer
    }
}

/// One answer from the network, read apart.
struct Reply {
    let status: Int
    let body: String

    init(_ answer: String) {
        let parts = answer.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        status = Int(parts[0]) ?? 0
        body = parts.count > 1 ? String(parts[1]) : ""
    }

    var ok: Bool { (200..<300).contains(status) }
}
