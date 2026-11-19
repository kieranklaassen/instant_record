import Foundation

/// The network, for an app that never opens a connection itself. A request is
/// "METHOD URL\n" and then the body. The answer is the status on the first
/// line and then the response body, or "0\n" when the network failed. With a
/// token, every request says who is asking.
public struct Transport {
    public static let offline = "0\n"
    private let session: URLSession
    private let token: String?

    public init(timeout: TimeInterval = 10, token: String? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
        self.token = token?.isEmpty == false ? token : nil
    }

    /// The request as it goes out, or nil when it cannot be read.
    func request(_ exchange: String) -> URLRequest? {
        let parts = exchange.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let line = parts[0].split(separator: " ", maxSplits: 1)
        guard line.count == 2, let url = URL(string: String(line[1])), url.scheme != nil else { return nil }
        var call = URLRequest(url: url)
        call.httpMethod = String(line[0])
        if call.httpMethod != "GET" {
            call.httpBody = Data((parts.count > 1 ? parts[1] : "").utf8)
            call.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { call.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        return call
    }

    /// Blocks the calling thread, which is the engine's and never the main one.
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
