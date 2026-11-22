import Foundation
import XCTest
@testable import InstantRecordNative

/// In-memory stand-in for `InstantRecord::FilesController` over `FileHTTPClient`.
final class FakeFilesServer: FileHTTPClient, @unchecked Sendable {
    struct RecordedRequest: Equatable {
        let method: String
        let path: String
        let key: String
        let isUploadCheck: Bool
        let range: String?
        let offset: String?
        let scope: String?
        let authorization: String?
        let bodySize: Int
    }

    private let lock = NSLock()
    var records: Set<String>
    var files: [String: (data: Data, contentType: String)] = [:]
    var partials: [String: Data] = [:]
    var requests: [RecordedRequest] = []
    var offline = false
    var failAfter: Int = .max
    var supportsRanges = true
    var maxSize: Int64 = .max
    var chunkSize: Int?
    var advertiseChunkSize = true
    var onRequest: ((URLRequest) async -> Void)?

    init(records: Set<String> = [], maxSize: Int64 = .max, chunkSize: Int? = nil, advertiseChunkSize: Bool = true) {
        self.records = records
        self.maxSize = maxSize
        self.chunkSize = chunkSize
        self.advertiseChunkSize = advertiseChunkSize
    }

    func hold(type: String, id: String, data: Data, contentType: String = "audio/wav") {
        lock.withLock {
            let key = "\(type)/\(id)"
            records.insert(key)
            files[key] = (data, contentType)
        }
    }

    func asked(_ method: String) -> [RecordedRequest] {
        lock.withLock {
            requests.filter { $0.method == method && !$0.isUploadCheck }
        }
    }

    func clearRequests() {
        lock.withLock { requests.removeAll() }
    }

    func fileData(for key: String) -> Data? {
        lock.withLock { files[key]?.data }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let hook = onRequest {
            await hook(request)
        }
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        let method = request.httpMethod ?? "GET"
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let rawPath = components?.percentEncodedPath ?? url.path

        guard let filesRange = rawPath.range(of: "/files/") else {
            return response(url: url, status: 404, body: Data())
        }
        let tail = String(rawPath[filesRange.upperBound...])
        let parts = tail.split(separator: "/").map(String.init)
        guard parts.count >= 2 else {
            return response(url: url, status: 404, body: Data())
        }
        let type = parts[0].removingPercentEncoding ?? parts[0]
        let id = parts[1].removingPercentEncoding ?? parts[1]
        let isUploadCheck = parts.count >= 3 && parts[2] == "upload"
        let key = "\(type)/\(id)"
        let body = request.httpBody ?? Data()

        let shouldFail: Bool = lock.withLock {
            if offline { return true }
            requests.append(RecordedRequest(
                method: method,
                path: rawPath,
                key: key,
                isUploadCheck: isUploadCheck,
                range: request.value(forHTTPHeaderField: "Range"),
                offset: query["offset"],
                scope: query["scope"],
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                bodySize: body.count
            ))
            return requests.count > failAfter
        }
        if shouldFail {
            throw URLError(.notConnectedToInternet)
        }

        if isUploadCheck || method == "PUT" {
            return lock.withLock {
                guard records.contains(key) else {
                    return response(url: url, status: 404, body: Data())
                }
                if let complete = files[key] {
                    return jsonResponse(url: url, status: 200, object: standingJSON(complete: true, offset: Int64(complete.data.count)))
                }
                guard let upload = query["upload"], !upload.isEmpty else {
                    return response(url: url, status: 400, body: Data())
                }
                let partialKey = "\(key).\(upload)"
                let held = partials[partialKey] ?? Data()
                if isUploadCheck {
                    return jsonResponse(url: url, status: 200, object: standingJSON(complete: false, offset: Int64(held.count)))
                }
                guard request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream" else {
                    return response(url: url, status: 415, body: Data())
                }
                let size = Int64(query["size"] ?? "") ?? 0
                let offset = Int64(query["offset"] ?? "") ?? -1
                if size > maxSize {
                    return jsonResponse(url: url, status: 413, object: ["error": "larger than this server takes"])
                }
                if let limit = chunkSize, body.count > limit {
                    return jsonResponse(url: url, status: 413, object: ["error": "piece larger than this server takes", "chunk_size": limit])
                }
                if offset != Int64(held.count) {
                    return jsonResponse(url: url, status: 409, object: standingJSON(complete: false, offset: Int64(held.count)))
                }
                var grown = held
                grown.append(body)
                if Int64(grown.count) < size {
                    partials[partialKey] = grown
                    return jsonResponse(url: url, status: 200, object: standingJSON(complete: false, offset: Int64(grown.count)))
                }
                partials.removeValue(forKey: partialKey)
                files[key] = (grown, "application/octet-stream")
                return jsonResponse(url: url, status: 200, object: standingJSON(complete: true, offset: Int64(grown.count)))
            }
        }

        return lock.withLock {
            guard records.contains(key), let held = files[key] else {
                return response(url: url, status: 404, body: Data())
            }
            var headers: [String: String] = [
                "Content-Type": held.contentType,
                "Content-Length": String(held.data.count),
            ]
            if let limit = chunkSize, advertiseChunkSize {
                headers["X-Instant-Record-Chunk-Size"] = String(limit)
            }
            if method == "HEAD" {
                return response(url: url, status: 200, headers: headers, body: Data())
            }
            guard supportsRanges, let range = request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes=") else {
                return response(url: url, status: 200, headers: headers, body: held.data)
            }
            let bounds = range.dropFirst("bytes=".count).split(separator: "-")
            let from = Int(bounds[0]) ?? 0
            let to = min(Int(bounds[1]) ?? (held.data.count - 1), held.data.count - 1)
            let slice = held.data.subdata(in: from..<(to + 1))
            headers["Content-Range"] = "bytes \(from)-\(to)/\(held.data.count)"
            headers["Content-Length"] = String(slice.count)
            return response(url: url, status: 206, headers: headers, body: slice)
        }
    }

    private func standingJSON(complete: Bool, offset: Int64) -> [String: Any] {
        var payload: [String: Any] = ["complete": complete, "offset": offset]
        if let limit = chunkSize, advertiseChunkSize {
            payload["chunk_size"] = limit
        }
        return payload
    }

    private func jsonResponse(url: URL, status: Int, object: [String: Any]) -> (Data, HTTPURLResponse) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return response(url: url, status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    private func response(url: URL, status: Int, headers: [String: String] = [:], body: Data) -> (Data, HTTPURLResponse) {
        let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (body, http)
    }
}

/// Deterministic manual clock for LRU eviction tests.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval

    init(_ start: TimeInterval = 1_700_000_000) {
        self.current = start
    }

    func now() -> Date {
        lock.withLock { Date(timeIntervalSince1970: current) }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }
}

/// Captures `FileEvent` values safely across concurrent tasks.
final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [FileEvent] = []

    func record(_ event: FileEvent) {
        lock.withLock { items.append(event) }
    }

    var events: [FileEvent] {
        lock.withLock { items }
    }
}

final class FileStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("instant-record-file-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(
        server: FakeFilesServer = FakeFilesServer(),
        chunkSize: Int = 4,
        budget: Int64? = nil,
        scope: String? = nil,
        name: String? = nil,
        touchInterval: TimeInterval = 0,
        clock: TestClock = TestClock()
    ) throws -> FileStore {
        try FileStore(
            directory: root,
            endpoint: "http://rails.test/instant_record",
            scope: scope,
            name: name,
            chunkSize: chunkSize,
            budget: budget,
            client: server,
            touchInterval: touchInterval,
            now: { clock.now() }
        )
    }

    func testDefaultChunkSizeIsProxySafeAndValidated() throws {
        XCTAssertEqual(512 * 1024, FileStore.defaultChunkSize)
        XCTAssertLessThan(FileStore.defaultChunkSize, 1024 * 1024)

        XCTAssertThrowsError(try FileStore(directory: root, endpoint: "http://rails.test/instant_record", chunkSize: 0)) { error in
            XCTAssertEqual(error as? FileStoreError, .invalidChunkSize(0))
        }
        XCTAssertThrowsError(try FileStore(directory: root, endpoint: "http://rails.test/instant_record", chunkSize: -8)) { error in
            XCTAssertEqual(error as? FileStoreError, .invalidChunkSize(-8))
        }
    }

    func testAttachPersistsLocallyAcrossReloadsAndSupportsStreamingFromFileURL() async throws {
        let server = FakeFilesServer()
        let store = try makeStore(server: server)

        let attached = try await store.attach(
            type: "Clip",
            id: "one",
            data: Data("a take of ten".utf8),
            filename: "take.wav",
            contentType: "audio/wav"
        )
        XCTAssertEqual(attached.filename, "take.wav")
        XCTAssertEqual(attached.contentType, "audio/wav")
        XCTAssertEqual(attached.byteSize, 13)
        XCTAssertEqual(try Data(contentsOf: attached.localURL), Data("a take of ten".utf8))

        let reloaded = try makeStore(server: server)
        let bytes = try await reloaded.get(type: "Clip", id: "one")
        XCTAssertEqual(bytes, Data("a take of ten".utf8))
        let meta = await reloaded.stat(type: "Clip", id: "one")
        XCTAssertEqual(meta?.local, true)
        XCTAssertEqual(meta?.uploaded, false)
        XCTAssertEqual(meta?.size, 13)

        // Streaming attach from an existing disk file URL.
        let sourceURL = root.appendingPathComponent("recording.wav")
        try Data("streamed payload".utf8).write(to: sourceURL)
        let streamed = try await reloaded.attach(type: "Clip", id: "two", fileURL: sourceURL, contentType: "audio/wav")
        XCTAssertEqual(streamed.filename, "recording.wav")
        XCTAssertEqual(streamed.byteSize, 16)
        let streamedBytes = try await reloaded.get(type: "Clip", id: "two")
        XCTAssertEqual(streamedBytes, Data("streamed payload".utf8))
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testAttachRejectsDuplicateAndEmptyFiles() async throws {
        let store = try makeStore()
        try await store.attach(type: "Clip", id: "one", data: Data("first".utf8))

        do {
            try await store.attach(type: "Clip", id: "one", data: Data("second".utf8))
            XCTFail("Expected alreadyAttached error")
        } catch let error as FileStoreError {
            XCTAssertEqual(error, .alreadyAttached(type: "Clip", id: "one"))
        }

        do {
            try await store.attach(type: "Clip", id: "two", data: Data())
            XCTFail("Expected emptyFile error")
        } catch let error as FileStoreError {
            XCTAssertEqual(error, .emptyFile)
        }
        let firstBytes = try await store.get(type: "Clip", id: "one")
        XCTAssertEqual(firstBytes, Data("first".utf8))
    }

    func testAttachedFileUploadsInChunksAndMarksUploaded() async throws {
        let server = FakeFilesServer(records: ["Clip/one"])
        let store = try makeStore(server: server)
        let recorder = EventRecorder()
        _ = await store.subscribe { recorder.record($0) }

        try await store.attach(type: "Clip", id: "one", data: Data("a take of ten".utf8))
        let result = await store.sync()

        XCTAssertEqual(result, FileSyncResult(sent: 1, waiting: 0))
        XCTAssertEqual(server.fileData(for: "Clip/one"), Data("a take of ten".utf8))
        XCTAssertEqual(server.asked("PUT").compactMap(\.offset), ["0", "4", "8", "12"])
        let stat = await store.stat(type: "Clip", id: "one")
        XCTAssertEqual(stat?.uploaded, true)
        XCTAssertTrue(recorder.events.contains(.added(type: "Clip", id: "one")))
        XCTAssertTrue(recorder.events.contains(.uploaded(type: "Clip", id: "one")))

        let before = server.requests.count
        let second = await store.sync()
        XCTAssertEqual(second, FileSyncResult(sent: 0, waiting: 0))
        XCTAssertEqual(server.requests.count, before)
    }

    func testUploadAdaptsToServerAdvertisedAnd413ChunkSizes() async throws {
        let server = FakeFilesServer(records: ["Clip/one"], chunkSize: 3)
        let store = try makeStore(server: server, chunkSize: 8)
        try await store.attach(type: "Clip", id: "one", data: Data("0123456789".utf8))

        let result = await store.sync()
        XCTAssertEqual(result, FileSyncResult(sent: 1, waiting: 0))
        XCTAssertEqual(server.fileData(for: "Clip/one"), Data("0123456789".utf8))
        XCTAssertEqual(server.asked("PUT").compactMap(\.offset), ["0", "3", "6", "9"])

        // When server does not advertise chunk_size on GET /upload, 413 shrinks the step and succeeds.
        let strictServer = FakeFilesServer(records: ["Clip/two"], chunkSize: 3, advertiseChunkSize: false)
        let store2 = try makeStore(server: strictServer, chunkSize: 8)
        try await store2.attach(type: "Clip", id: "two", data: Data("01234567".utf8))

        let result2 = await store2.sync()
        XCTAssertEqual(result2, FileSyncResult(sent: 1, waiting: 0))
        XCTAssertEqual(strictServer.fileData(for: "Clip/two"), Data("01234567".utf8))
        XCTAssertEqual(strictServer.asked("PUT").map(\.bodySize), [8, 3, 3, 2])
    }

    func testUploadWaitsForRecordAndResumesAfterInterruptionAndConflict() async throws {
        let server = FakeFilesServer()
        let store = try makeStore(server: server)
        try await store.attach(type: "Clip", id: "one", data: Data("0123456789abcdef".utf8))

        // Record not on server yet (404).
        let waiting = await store.sync()
        XCTAssertEqual(waiting, FileSyncResult(sent: 0, waiting: 1))
        XCTAssertTrue(server.asked("PUT").isEmpty)

        // Record arrives, connection drops after GET /upload + 2 PUTs.
        server.records.insert("Clip/one")
        server.clearRequests()
        server.failAfter = 3
        let interrupted = await store.sync()
        XCTAssertEqual(interrupted, FileSyncResult(sent: 0, waiting: 1))
        let interruptedStat = await store.stat(type: "Clip", id: "one")
        XCTAssertEqual(interruptedStat?.uploaded, false)

        // Reload and resume from offset 8.
        server.failAfter = .max
        server.clearRequests()
        let resumed = await (try makeStore(server: server)).sync()
        XCTAssertEqual(resumed, FileSyncResult(sent: 1, waiting: 0))
        XCTAssertEqual(server.asked("PUT").compactMap(\.offset), ["8", "12"])
        XCTAssertEqual(server.fileData(for: "Clip/one"), Data("0123456789abcdef".utf8))

        // 409 conflict reconciliation: server advances offset behind our back before first PUT.
        server.records.insert("Clip/raced")
        let store2 = try makeStore(server: server)
        try await store2.attach(type: "Clip", id: "raced", data: Data("0123456789".utf8))
        var injectedConflict = false
        server.onRequest = { request in
            guard request.httpMethod == "PUT", !injectedConflict, let url = request.url,
                  let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let upload = comps.queryItems?.first(where: { $0.name == "upload" })?.value else {
                return
            }
            injectedConflict = true
            server.partials["Clip/raced.\(upload)"] = Data("0123".utf8)
        }
        let reconciled = await store2.sync()
        server.onRequest = nil
        XCTAssertEqual(reconciled, FileSyncResult(sent: 1, waiting: 0))
        XCTAssertEqual(server.fileData(for: "Clip/raced"), Data("0123456789".utf8))
    }

    func testPermanentRefusalMarksFailedAndStopsRetrying() async throws {
        let server = FakeFilesServer(records: ["Clip/one"], maxSize: 8)
        let store = try makeStore(server: server)
        let recorder = EventRecorder()
        _ = await store.subscribe { recorder.record($0) }

        try await store.attach(type: "Clip", id: "one", data: Data("more than eight bytes".utf8))
        let first = await store.sync()
        XCTAssertEqual(first, FileSyncResult(sent: 0, waiting: 1))
        let stat = await store.stat(type: "Clip", id: "one")
        XCTAssertEqual(stat?.failed, "larger than this server takes")
        XCTAssertTrue(recorder.events.contains(.failed(type: "Clip", id: "one", reason: "larger than this server takes")))

        let before = server.requests.count
        let second = await store.sync()
        XCTAssertEqual(second, FileSyncResult(sent: 0, waiting: 0))
        XCTAssertEqual(server.requests.count, before)
        let keptBytes = try await store.get(type: "Clip", id: "one")
        XCTAssertEqual(keptBytes, Data("more than eight bytes".utf8))
    }

    func testDownloadFetchesInChunksCachesOfflineAndResumesAfterCutOff() async throws {
        let server = FakeFilesServer(chunkSize: 4)
        server.hold(type: "Clip", id: "theirs", data: Data("0123456789abcdef".utf8))
        let store = try makeStore(server: server, chunkSize: 16)

        // HEAD + 2 GETs, then cut off.
        server.failAfter = 3
        do {
            _ = try await store.open(type: "Clip", id: "theirs")
            XCTFail("Expected network failure")
        } catch {
            // Expected URLError.notConnectedToInternet
        }
        let incomplete = try await store.get(type: "Clip", id: "theirs")
        XCTAssertNil(incomplete)
        let partialStat = await store.stat(type: "Clip", id: "theirs")
        XCTAssertEqual(partialStat?.local, false)
        XCTAssertEqual(partialStat?.uploaded, true)

        // Reload and resume: only asks for bytes 8-11 and 12-15.
        server.failAfter = .max
        server.clearRequests()
        let reloaded = try makeStore(server: server, chunkSize: 16)
        let data = try await reloaded.open(type: "Clip", id: "theirs")
        XCTAssertEqual(data, Data("0123456789abcdef".utf8))
        XCTAssertEqual(server.asked("GET").compactMap(\.range), ["bytes=8-11", "bytes=12-15"])

        // Offline cache hit asks nothing of the server.
        server.offline = true
        let cached = try await reloaded.open(type: "Clip", id: "theirs")
        XCTAssertEqual(cached, Data("0123456789abcdef".utf8))
    }

    func testDownloadDeduplicatesConcurrentCallersAndHandlesNoRangeAndMissing() async throws {
        let server = FakeFilesServer()
        server.hold(type: "Clip", id: "shared", data: Data("from far away".utf8))
        let store = try makeStore(server: server)

        async let first = store.open(type: "Clip", id: "shared")
        async let second = store.open(type: "Clip", id: "shared")
        let results = try await [first, second]
        XCTAssertEqual(results[0], Data("from far away".utf8))
        XCTAssertEqual(results[1], Data("from far away".utf8))
        XCTAssertEqual(server.asked("HEAD").count, 1)
        XCTAssertEqual(server.asked("GET").count, 4)

        // Server without Range support still works.
        server.supportsRanges = false
        server.hold(type: "Clip", id: "whole", data: Data("0123456789".utf8))
        let whole = try await store.open(type: "Clip", id: "whole")
        XCTAssertEqual(whole, Data("0123456789".utf8))

        // Missing file throws fileMissing and leaves nothing on disk.
        do {
            _ = try await store.open(type: "Clip", id: "ghost")
            XCTFail("Expected fileMissing")
        } catch let error as FileStoreError {
            XCTAssertEqual(error, .fileMissing(type: "Clip", id: "ghost"))
        }
        let ghostStat = await store.stat(type: "Clip", id: "ghost")
        XCTAssertNil(ghostStat)
    }

    func testBudgetEvictsUploadedLeastRecentlyUsedAndNeverDropsUnsentOrPinned() async throws {
        let clock = TestClock()
        let server = FakeFilesServer(records: ["Clip/older", "Clip/old", "Clip/mine"])
        let store = try makeStore(server: server, budget: 30, clock: clock)
        let recorder = EventRecorder()
        _ = await store.subscribe { recorder.record($0) }

        try await store.attach(type: "Clip", id: "older", data: Data("0123456789".utf8))
        clock.advance(by: 10)
        try await store.attach(type: "Clip", id: "old", data: Data("0123456789".utf8))
        _ = await store.sync()

        // Touch "old" more recently than "older".
        clock.advance(by: 10)
        _ = try await store.get(type: "Clip", id: "old")
        clock.advance(by: 10)
        try await store.attach(type: "Clip", id: "mine", data: Data("0123456789".utf8)) // not synced yet

        // Adding 10 more bytes exceeds 30-byte budget -> "older" is evicted.
        clock.advance(by: 10)
        try await store.attach(type: "Clip", id: "new", data: Data("0123456789".utf8))

        let olderAfter = try await store.get(type: "Clip", id: "older")
        let oldAfter = try await store.get(type: "Clip", id: "old")
        let mineAfter = try await store.get(type: "Clip", id: "mine")
        XCTAssertNil(olderAfter)
        XCTAssertNotNil(oldAfter)
        XCTAssertNotNil(mineAfter)
        XCTAssertTrue(recorder.events.contains(.evicted(type: "Clip", id: "older")))

        // Pin "old": now nothing droppable remains (mine and new are unsent, old is pinned).
        _ = try await store.pin(type: "Clip", id: "old")
        do {
            try await store.attach(type: "Clip", id: "too-much", data: Data("0123456789".utf8))
            XCTFail("Expected noRoom error")
        } catch let error as FileStoreError {
            XCTAssertEqual(error, .noRoom(needed: 10))
        }
        let tooMuchStat = await store.stat(type: "Clip", id: "too-much")
        XCTAssertNil(tooMuchStat)

        // Unpinning allows eviction.
        _ = try await store.unpin(type: "Clip", id: "old")
        try await store.attach(type: "Clip", id: "fits", data: Data("0123456789".utf8))
        let oldEvicted = try await store.get(type: "Clip", id: "old")
        XCTAssertNil(oldEvicted)
    }

    func testOpenOverBudgetFallsBackToUncachedDownload() async throws {
        let server = FakeFilesServer()
        server.hold(type: "Clip", id: "big", data: Data("0123456789abcdef".utf8))
        let store = try makeStore(server: server, budget: 8)

        let bytes = try await store.open(type: "Clip", id: "big")
        XCTAssertEqual(bytes, Data("0123456789abcdef".utf8))
        let stat = await store.stat(type: "Clip", id: "big")
        XCTAssertNil(stat)
    }

    func testRemovePruneClearTidyUsageAndAccountNamespaces() async throws {
        let server = FakeFilesServer(records: ["Clip/a"])
        let store = try makeStore(server: server, scope: "ada-token", name: "ada")
        let otherAccount = try makeStore(server: server, scope: "ben-token", name: "ben")

        try await store.attach(type: "Clip", id: "a", data: Data("0123456789".utf8))
        _ = await store.sync()
        try await store.attach(type: "Clip", id: "b", data: Data("01234".utf8))
        try await store.attach(type: "Cover", id: "a", data: Data("cover".utf8))

        // Account isolation.
        let otherAccountFile = try await otherAccount.get(type: "Clip", id: "a")
        XCTAssertNil(otherAccountFile)
        XCTAssertEqual(server.requests.allSatisfy { $0.scope == "ada-token" }, true)

        let usage = await store.usage()
        XCTAssertEqual(usage, StorageUsage(files: 3, bytes: 20, waiting: 2, waitingBytes: 10))

        // URL percent-encodes namespaces and slashes identically to frontend/files.js.
        let url = await store.serverURL(type: "Mix::Stem", id: "a/b")
        XCTAssertEqual(url?.absoluteString, "http://rails.test/instant_record/files/Mix%3A%3AStem/a%2Fb?scope=ada-token")

        // Prune & clear.
        let pruned = await store.prune(type: "Clip", keepingIds: ["b"])
        XCTAssertEqual(pruned, 1)
        let prunedClip = try await store.get(type: "Clip", id: "a")
        let keptCover = try await store.get(type: "Cover", id: "a")
        XCTAssertNil(prunedClip)
        XCTAssertNotNil(keptCover)

        // Simulate a torn attach and tidy it.
        let tornDir = store.root.appendingPathComponent("type-Clip/torn", isDirectory: true)
        try FileManager.default.createDirectory(at: tornDir, withIntermediateDirectories: true)
        let tornJSON = """
        {"type":"Clip","id":"torn","name":"","contentType":"","size":10,"piece":4,"received":0,"upload":"u1","complete":false,"uploaded":false,"pinned":false,"addedAt":1,"usedAt":1}
        """
        try Data(tornJSON.utf8).write(to: tornDir.appendingPathComponent("meta.json"))
        let tidied = await store.tidy()
        XCTAssertEqual(tidied, 1)

        let clearedClip = await store.clear(type: "Clip")
        XCTAssertEqual(clearedClip, 1)
        let clearedAll = await store.clear()
        XCTAssertEqual(clearedAll, 1)
        let finalList = await store.list()
        XCTAssertTrue(finalList.isEmpty)
    }

    func testTransportPrepareAppliesAuthorizationHeadersToFileRequests() {
        let transport = Transport(prepare: { $0.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization") })
        var request = URLRequest(url: URL(string: "http://rails.test/instant_record/files/Clip/one")!)
        transport.prepareRequest(&request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
    }
}
