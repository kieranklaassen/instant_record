import Foundation

/// The network, for an app that never opens a connection itself. A request is
/// "METHOD URL\n" and then the body. The answer is the status on the first
/// line and then the response body, or "0\n" when the network failed.
public struct Transport {
    public static let offline = "0\n"
    private let session: URLSession

    public init(timeout: TimeInterval = 10) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    /// Blocks the calling thread, which is the engine's and never the main one.
    public func exchange(_ request: String) -> String {
        let parts = request.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let line = parts[0].split(separator: " ", maxSplits: 1)
        guard line.count == 2, let url = URL(string: String(line[1])) else { return Transport.offline }
        var call = URLRequest(url: url)
        call.httpMethod = String(line[0])
        if call.httpMethod != "GET" {
            call.httpBody = Data((parts.count > 1 ? parts[1] : "").utf8)
            call.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
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
