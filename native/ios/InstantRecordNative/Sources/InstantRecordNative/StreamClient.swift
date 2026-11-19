import Foundation

/// Follows the server's events while the app is in front, so a change made
/// elsewhere shows without a touch. It asks `<endpoint>/events?after=<cursor>`
/// and hands each event to the app as it arrives. A server that answers with
/// what it has and closes is asked again a second later. One that holds the
/// connection delivers as it goes. Only a failed request waits longer: five
/// seconds, then twice that, up to a minute.
final class StreamClient {
    private let transport: Transport
    private let address: () async -> String?
    private let feed: (String) async -> Void
    private let session: URLSession
    private var task: Task<Void, Never>?

    /// `address` is where to ask from the app's present cursor, or nil while
    /// there is nothing to follow. `feed` takes one event's text.
    init(transport: Transport, address: @escaping () async -> String?, feed: @escaping (String) async -> Void) {
        self.transport = transport
        self.address = address
        self.feed = feed
        // A held stream is quiet between events, so it gets longer than a request does.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        session = URLSession(configuration: configuration)
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.follow() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func follow() async {
        var wait: UInt64 = 5
        while !Task.isCancelled {
            do {
                guard let address = await address(), let request = transport.request("GET " + address + "\n") else {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
                var event: [UInt8] = []
                for try await byte in bytes {
                    event.append(byte)
                    if event.count >= 2, event[event.count - 1] == 10, event[event.count - 2] == 10 {
                        await feed(String(decoding: event, as: UTF8.self))
                        event = []
                    }
                }
                wait = 5
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
                wait = min(wait * 2, 60)
            }
        }
    }
}
