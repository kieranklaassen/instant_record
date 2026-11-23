import Foundation

/// Errors thrown by `FileStore` when attaching, reading, downloading, or syncing
/// a `sync_file` record's bytes.
public enum FileStoreError: Error, Equatable, LocalizedError {
    case emptyFile
    case alreadyAttached(type: String, id: String)
    case invalidChunkSize(Int)
    case fileMissing(type: String, id: String)
    case noRoom(needed: Int64)
    case httpError(status: Int, message: String?)
    case unexpectedPieceSize(expected: Int, actual: Int)
    case uploadStalled
    case invalidURL

    public var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "A file needs bytes"
        case let .alreadyAttached(type, id):
            return "\(type) \(id) already has a file. A new file is a new record."
        case let .invalidChunkSize(size):
            return "chunkSize must be a positive integer, got \(size)"
        case let .fileMissing(type, id):
            return "\(type) \(id) has no file on the server"
        case let .noRoom(needed):
            return "No room to keep \(needed) bytes"
        case let .httpError(status, message):
            return message ?? "The server answered \(status)"
        case let .unexpectedPieceSize(expected, actual):
            return "A piece arrived the wrong size (expected \(expected), got \(actual))"
        case .uploadStalled:
            return "The upload is not moving"
        case .invalidURL:
            return "Could not build the file endpoint URL"
        }
    }
}

/// Summary of what is known locally about a record's file.
public struct FileMetadata: Equatable, Sendable {
    public let type: String
    public let id: String
    public let name: String
    public let contentType: String
    public let size: Int64
    public let local: Bool
    public let uploaded: Bool
    public let pinned: Bool
    public let failed: String?
    public let addedAt: Date
    public let usedAt: Date
}

/// Metadata returned when a file is attached locally, matching Active Storage's
/// blob attribute names for the form/mutation that creates the record.
public struct AttachedFile: Equatable, Sendable {
    public let filename: String
    public let contentType: String
    public let byteSize: Int64
    public let localURL: URL
}

/// Local storage accounting for `FileStore`.
public struct StorageUsage: Equatable, Sendable {
    public let files: Int
    public let bytes: Int64
    public let waiting: Int
    public let waitingBytes: Int64
}

/// Outcome of one upload sync pass.
public struct FileSyncResult: Equatable, Sendable {
    public let sent: Int
    public let waiting: Int
}

/// Byte progress during a chunked upload or download.
public struct TransferProgress: Equatable, Sendable {
    public let transferred: Int64
    public let size: Int64
}

/// Lifecycle events emitted by `FileStore`.
public enum FileEvent: Equatable, Sendable {
    case added(type: String, id: String)
    case progress(type: String, id: String, transferred: Int64, size: Int64)
    case uploaded(type: String, id: String)
    case failed(type: String, id: String, reason: String)
    case fetched(type: String, id: String)
    case evicted(type: String, id: String)
    case removed(type: String, id: String)
}

/// Minimal async HTTP interface used by `FileStore`, allowing tests to stub the
/// server without opening real sockets.
public protocol FileHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Default `FileHTTPClient` backed by `URLSession` and an InstantRecord
/// `Transport` so authentication headers and request preparation apply to file
/// transfers too.
public final class TransportFileHTTPClient: FileHTTPClient, @unchecked Sendable {
    private let session: URLSession
    private let transport: Transport

    public init(transport: Transport = Transport(), timeout: TimeInterval = 120) {
        self.transport = transport
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var prepared = request
        transport.prepareRequest(&prepared)
        let (data, response) = try await session.data(for: prepared)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// Disk-backed chunked file store for `sync_file` models on iOS and macOS.
///
/// Mirrors `frontend/files.js` and speaks directly to `InstantRecord::FilesController`:
/// - `attach` writes a record's bytes locally first (offline-safe) and queues
///   them for background chunked upload via `PUT <endpoint>/files/:type/:id`.
/// - `sync` uploads waiting files in proxy-safe chunks (512 KiB by default,
///   negotiated down if the server advertises a smaller `chunk_size`), resuming
///   interrupted transfers via `GET .../upload`.
/// - `open` / `download` reads locally when cached, or fetches via `Range`
///   requests and keeps partial progress across interruptions.
/// - Past `budget`, already-uploaded and unpinned files are evicted least
///   recently used first; unuploaded and pinned files are never dropped.
public actor FileStore {
    /// Default chunk size (512 KiB), safely below common 1-2 MB reverse-proxy
    /// request body limits.
    public static let defaultChunkSize = 512 * 1024
    public static let defaultTouchInterval: TimeInterval = 60

    private static let rootFolderName = "instant-record-files"
    private static let metaFileName = "meta.json"
    private static let contentFileName = "content"
    private static let partialFileName = "partial"

    public nonisolated let root: URL
    public nonisolated let endpoint: String
    public nonisolated let scope: String?
    public nonisolated let chunkSize: Int
    public nonisolated let budget: Int64?

    private let client: FileHTTPClient
    private let autoSync: Bool
    private let touchInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let fileManager = FileManager.default

    private var listeners: [UUID: @Sendable (FileEvent) -> Void] = [:]
    private var downloads: [String: Task<URL, Error>] = [:]
    private var syncTask: Task<FileSyncResult, Never>?
    private var syncAgain = false
    private var lockedKeys: Set<String> = []
    private var lockWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    private struct StoredMeta: Codable {
        var type: String
        var id: String
        var name: String
        var contentType: String
        var size: Int64
        var piece: Int
        var received: Int64
        var upload: String?
        var complete: Bool
        var uploaded: Bool
        var pinned: Bool
        var failed: String?
        var addedAt: TimeInterval
        var usedAt: TimeInterval

        func shown() -> FileMetadata {
            FileMetadata(
                type: type,
                id: id,
                name: name,
                contentType: contentType,
                size: size,
                local: complete,
                uploaded: uploaded,
                pinned: pinned,
                failed: failed,
                addedAt: Date(timeIntervalSince1970: addedAt),
                usedAt: Date(timeIntervalSince1970: usedAt)
            )
        }
    }

    private struct UploadStanding: Decodable {
        let complete: Bool
        let offset: Int64
        let chunkSize: Int?

        enum CodingKeys: String, CodingKey {
            case complete, offset
            case chunkSize = "chunk_size"
        }
    }

    private struct ErrorPayload: Decodable {
        let error: String?
        let chunkSize: Int?

        enum CodingKeys: String, CodingKey {
            case error
            case chunkSize = "chunk_size"
        }
    }

    public init(
        directory: URL,
        endpoint: String,
        scope: String? = nil,
        name: String? = nil,
        chunkSize: Int = FileStore.defaultChunkSize,
        budget: Int64? = nil,
        autoSync: Bool = false,
        transport: Transport = Transport(),
        client: FileHTTPClient? = nil,
        touchInterval: TimeInterval = FileStore.defaultTouchInterval,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard chunkSize > 0 else { throw FileStoreError.invalidChunkSize(chunkSize) }
        var base = directory.appendingPathComponent(Self.rootFolderName, isDirectory: true)
        if let name, !name.isEmpty {
            base = base.appendingPathComponent("name-\(Self.safe(name))", isDirectory: true)
        }
        self.root = base
        self.endpoint = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        self.scope = scope?.isEmpty == true ? nil : scope
        self.chunkSize = chunkSize
        self.budget = budget
        self.autoSync = autoSync
        self.client = client ?? TransportFileHTTPClient(transport: transport)
        self.touchInterval = touchInterval
        self.now = now
    }

    // MARK: - Writing

    /// Store `data` locally as the file for `(type, id)` and mark it waiting for upload.
    @discardableResult
    public func attach(
        type: String,
        id: String,
        data: Data,
        filename: String = "",
        contentType: String = "application/octet-stream",
        pinned: Bool = false
    ) async throws -> AttachedFile {
        guard !data.isEmpty else { throw FileStoreError.emptyFile }
        let size = Int64(data.count)
        return try await attachStream(
            type: type,
            id: id,
            size: size,
            filename: filename,
            contentType: contentType,
            pinned: pinned
        ) { partialURL in
            try data.write(to: partialURL, options: .atomic)
        }
    }

    /// Stream an existing local file URL into the store in chunk-sized reads so
    /// large files are never buffered whole in memory.
    @discardableResult
    public func attach(
        type: String,
        id: String,
        fileURL sourceURL: URL,
        filename: String? = nil,
        contentType: String = "application/octet-stream",
        pinned: Bool = false
    ) async throws -> AttachedFile {
        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw FileStoreError.emptyFile }
        let resolvedName = filename ?? sourceURL.lastPathComponent
        let step = chunkSize
        return try await attachStream(
            type: type,
            id: id,
            size: size,
            filename: resolvedName,
            contentType: contentType,
            pinned: pinned
        ) { partialURL in
            fileManager.createFile(atPath: partialURL.path, contents: nil)
            let reader = try FileHandle(forReadingFrom: sourceURL)
            let writer = try FileHandle(forWritingTo: partialURL)
            defer {
                try? reader.close()
                try? writer.close()
            }
            while true {
                let chunk = try reader.read(upToCount: step) ?? Data()
                if chunk.isEmpty { break }
                try writer.write(contentsOf: chunk)
            }
            try writer.synchronize()
        }
    }

    private func attachStream(
        type: String,
        id: String,
        size: Int64,
        filename: String,
        contentType: String,
        pinned: Bool,
        writePartial: (URL) throws -> Void
    ) async throws -> AttachedFile {
        let key = Self.recordKey(type, id)
        let timestamp = now().timeIntervalSince1970
        var meta = StoredMeta(
            type: type,
            id: id,
            name: filename,
            contentType: contentType,
            size: size,
            piece: chunkSize,
            received: 0,
            upload: Self.uploadToken(),
            complete: false,
            uploaded: false,
            pinned: pinned,
            failed: nil,
            addedAt: timestamp,
            usedAt: timestamp
        )

        let localURL = try await withRecordLock(key) { () async throws -> URL in
            if readMeta(type: type, id: id) != nil {
                throw FileStoreError.alreadyAttached(type: type, id: id)
            }
            try ensureRoom(for: meta, bytesToWrite: size)
            do {
                dropRecord(type: type, id: id)
                let folder = try recordFolder(type: type, id: id, create: true)
                try writeMeta(meta, in: folder)
                let partialURL = folder.appendingPathComponent(Self.partialFileName)
                let contentURL = folder.appendingPathComponent(Self.contentFileName)
                try writePartial(partialURL)
                if fileManager.fileExists(atPath: contentURL.path) {
                    try fileManager.removeItem(at: contentURL)
                }
                try fileManager.moveItem(at: partialURL, to: contentURL)
                meta.received = size
                meta.complete = true
                try writeMeta(meta, in: folder)
                return contentURL
            } catch {
                dropRecord(type: type, id: id)
                throw error
            }
        }

        emit(.added(type: type, id: id))
        if autoSync {
            Task { _ = await self.sync() }
        }
        return AttachedFile(
            filename: meta.name,
            contentType: meta.contentType,
            byteSize: meta.size,
            localURL: localURL
        )
    }

    // MARK: - Reading

    /// Returns the local file URL if the complete file is cached on disk, else nil.
    /// Never touches the network.
    public func fileURL(forType type: String, id: String, touch: Bool = true) -> URL? {
        guard var meta = readMeta(type: type, id: id), meta.complete else { return nil }
        let folder = recordFolderURL(type: type, id: id)
        let contentURL = folder.appendingPathComponent(Self.contentFileName)
        guard fileManager.fileExists(atPath: contentURL.path) else { return nil }
        if touch {
            let timestamp = now().timeIntervalSince1970
            if timestamp - meta.usedAt > touchInterval {
                meta.usedAt = timestamp
                try? writeMeta(meta, in: folder)
            }
        }
        return contentURL
    }

    /// Returns the file's bytes if cached locally, else nil. Never touches the network.
    public func get(type: String, id: String, touch: Bool = true) throws -> Data? {
        guard let url = fileURL(forType: type, id: id, touch: touch) else { return nil }
        return try Data(contentsOf: url)
    }

    /// Returns the file's bytes from local cache, or fetches it from the server in
    /// chunks and caches it. If the store's budget cannot accommodate caching the
    /// file even after evicting droppable files, it still returns the bytes read
    /// from the server without keeping them on disk.
    public func open(
        type: String,
        id: String,
        onProgress: (@Sendable (TransferProgress) -> Void)? = nil
    ) async throws -> Data {
        if let local = try get(type: type, id: id) {
            return local
        }
        do {
            let url = try await download(type: type, id: id, onProgress: onProgress)
            return try Data(contentsOf: url)
        } catch FileStoreError.noRoom {
            return try await fetchWholeUncached(type: type, id: id)
        }
    }

    /// Returns the local cached URL for `(type, id)`, downloading it in resumable
    /// chunks from the server if not already cached. Concurrent callers for the
    /// same record share a single download.
    public func download(
        type: String,
        id: String,
        onProgress: (@Sendable (TransferProgress) -> Void)? = nil
    ) async throws -> URL {
        if let local = fileURL(forType: type, id: id) {
            return local
        }
        let key = Self.recordKey(type, id)
        if let existing = downloads[key] {
            return try await existing.value
        }
        let task = Task<URL, Error> {
            try await self.performDownload(type: type, id: id, onProgress: onProgress)
        }
        downloads[key] = task
        defer { downloads.removeValue(forKey: key) }
        return try await task.value
    }

    // MARK: - Introspection

    public func stat(type: String, id: String) -> FileMetadata? {
        readMeta(type: type, id: id)?.shown()
    }

    public func list() -> [FileMetadata] {
        allMetas().map { $0.shown() }
    }

    public func usage() -> StorageUsage {
        let metas = allMetas()
        let held = metas.filter(\.complete)
        let waiting = held.filter { !$0.uploaded }
        return StorageUsage(
            files: held.count,
            bytes: metas.reduce(0) { $0 + $1.size },
            waiting: waiting.count,
            waitingBytes: waiting.reduce(0) { $0 + $1.size }
        )
    }

    // MARK: - Keeping & Evicting

    @discardableResult
    public func pin(type: String, id: String) async throws -> Bool {
        try await mark(type: type, id: id) { $0.pinned = true }
    }

    @discardableResult
    public func unpin(type: String, id: String) async throws -> Bool {
        try await mark(type: type, id: id) { $0.pinned = false }
    }

    public func remove(type: String, id: String) async {
        let key = Self.recordKey(type, id)
        await withRecordLock(key) {
            dropRecord(type: type, id: id)
        }
        emit(.removed(type: type, id: id))
    }

    @discardableResult
    public func prune(type: String, keepingIds: Set<String>) async -> Int {
        let gone = allMetas().filter { $0.type == type && !keepingIds.contains($0.id) }
        for meta in gone {
            await remove(type: meta.type, id: meta.id)
        }
        return gone.count
    }

    @discardableResult
    public func clear(type: String? = nil) async -> Int {
        let gone = allMetas().filter { type == nil || $0.type == type }
        for meta in gone {
            await remove(type: meta.type, id: meta.id)
        }
        return gone.count
    }

    /// Evict already-uploaded, unpinned files (incomplete downloads first, then
    /// least recently used) until at least `bytes` are freed. Returns bytes freed.
    @discardableResult
    public func free(bytes: Int64) -> Int64 {
        evict(bytes: bytes, keeping: nil)
    }

    /// Remove torn partials left behind by an interrupted `attach`.
    @discardableResult
    public func tidy() -> Int {
        let dead = allMetas(includeTorn: true).filter { !$0.complete && !$0.uploaded }
        var removed = 0
        for meta in dead {
            let key = Self.recordKey(meta.type, meta.id)
            guard tryLockRecord(key) else { continue }
            defer { unlockRecord(key) }
            if let current = readMeta(type: meta.type, id: meta.id, includeTorn: true),
               !current.complete && !current.uploaded {
                dropRecord(type: meta.type, id: meta.id)
                removed += 1
            }
        }
        return removed
    }

    // MARK: - Uploading

    /// Upload all complete, non-failed files the server does not hold yet, oldest
    /// first. Concurrent calls coalesce into one pass and loop again if called
    /// mid-pass.
    public func sync() async -> FileSyncResult {
        if let existing = syncTask {
            syncAgain = true
            return await existing.value
        }
        let task = Task<FileSyncResult, Never> {
            var totalSent = 0
            var lastWaiting = 0
            repeat {
                self.syncAgain = false
                let pass = await self.drain()
                totalSent += pass.sent
                lastWaiting = pass.waiting
            } while self.syncAgain
            return FileSyncResult(sent: totalSent, waiting: lastWaiting)
        }
        syncTask = task
        let result = await task.value
        syncTask = nil
        return result
    }

    // MARK: - Events & URLs

    @discardableResult
    public func subscribe(_ listener: @escaping @Sendable (FileEvent) -> Void) -> UUID {
        let token = UUID()
        listeners[token] = listener
        return token
    }

    public func unsubscribe(_ token: UUID) {
        listeners.removeValue(forKey: token)
    }

    public func serverURL(type: String, id: String, query: [(String, String)] = [], suffix: String = "") -> URL? {
        let base = "\(endpoint)/files/\(Self.urlSegment(type))/\(Self.urlSegment(id))\(suffix)"
        guard var components = URLComponents(string: base) else { return nil }
        var items: [URLQueryItem] = []
        if let scope, !scope.isEmpty {
            items.append(URLQueryItem(name: "scope", value: scope))
        }
        for (name, value) in query {
            items.append(URLQueryItem(name: name, value: value))
        }
        if !items.isEmpty {
            components.queryItems = items
        }
        return components.url
    }

    // MARK: - Internal Transfer Logic

    private func performDownload(
        type: String,
        id: String,
        onProgress: (@Sendable (TransferProgress) -> Void)?
    ) async throws -> URL {
        let key = Self.recordKey(type, id)
        let localURL = try await withRecordLock(key) { () async throws -> URL in
            if let existing = fileURL(forType: type, id: id) {
                return existing
            }

            var meta: StoredMeta
            if let existing = readMeta(type: type, id: id), existing.uploaded && !existing.complete {
                meta = existing
            } else {
                guard let headURL = serverURL(type: type, id: id) else { throw FileStoreError.invalidURL }
                var headRequest = URLRequest(url: headURL)
                headRequest.httpMethod = "HEAD"
                let (_, headResponse) = try await client.send(headRequest)
                if headResponse.statusCode == 404 {
                    throw FileStoreError.fileMissing(type: type, id: id)
                }
                guard (200..<300).contains(headResponse.statusCode) else {
                    throw FileStoreError.httpError(status: headResponse.statusCode, message: nil)
                }
                let size = headResponse.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) ?? 0
                guard size > 0 else {
                    throw FileStoreError.httpError(status: headResponse.statusCode, message: "The server gave no size for \(type) \(id)")
                }
                let contentType = headResponse.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
                let advertised = headResponse.value(forHTTPHeaderField: "X-Instant-Record-Chunk-Size").flatMap(Int.init)
                let piece = advertised.flatMap { $0 > 0 ? min(chunkSize, $0) : nil } ?? chunkSize
                let timestamp = now().timeIntervalSince1970
                dropRecord(type: type, id: id)
                meta = StoredMeta(
                    type: type,
                    id: id,
                    name: "",
                    contentType: contentType,
                    size: size,
                    piece: piece,
                    received: 0,
                    upload: nil,
                    complete: false,
                    uploaded: true,
                    pinned: false,
                    failed: nil,
                    addedAt: timestamp,
                    usedAt: timestamp
                )
            }

            let folder = try recordFolder(type: type, id: id, create: true)
            let partialURL = folder.appendingPathComponent(Self.partialFileName)
            let contentURL = folder.appendingPathComponent(Self.contentFileName)

            let diskSize = fileSize(at: partialURL)
            let committed = min(meta.received, diskSize)
            meta.received = committed

            do {
                try ensureRoom(for: meta, bytesToWrite: meta.size - meta.received)
            } catch {
                dropRecord(type: type, id: id)
                throw error
            }

            try writeMeta(meta, in: folder)
            if !fileManager.fileExists(atPath: partialURL.path) {
                fileManager.createFile(atPath: partialURL.path, contents: nil)
            }
            if diskSize > committed {
                let handle = try FileHandle(forUpdating: partialURL)
                try handle.truncate(atOffset: UInt64(committed))
                try handle.close()
            }

            while meta.received < meta.size {
                let from = meta.received
                let to = min(from + Int64(meta.piece), meta.size) - 1
                let expected = Int(to - from + 1)

                guard let getURL = serverURL(type: type, id: id) else { throw FileStoreError.invalidURL }
                var request = URLRequest(url: getURL)
                request.httpMethod = "GET"
                request.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
                let (body, response) = try await client.send(request)
                if response.statusCode == 404 {
                    dropRecord(type: type, id: id)
                    throw FileStoreError.fileMissing(type: type, id: id)
                }
                guard (200..<300).contains(response.statusCode) else {
                    throw FileStoreError.httpError(status: response.statusCode, message: nil)
                }
                var pieceData = body
                if response.statusCode == 200 && Int64(body.count) == meta.size {
                    pieceData = body.subdata(in: Int(from)..<Int(to + 1))
                }
                guard pieceData.count == expected else {
                    throw FileStoreError.unexpectedPieceSize(expected: expected, actual: pieceData.count)
                }

                let handle = try FileHandle(forUpdating: partialURL)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(from))
                try handle.write(contentsOf: pieceData)
                try handle.synchronize()

                meta.received = to + 1
                try writeMeta(meta, in: folder)

                let progress = TransferProgress(transferred: meta.received, size: meta.size)
                onProgress?(progress)
                emit(.progress(type: type, id: id, transferred: meta.received, size: meta.size))
            }

            if fileManager.fileExists(atPath: contentURL.path) {
                try fileManager.removeItem(at: contentURL)
            }
            try fileManager.moveItem(at: partialURL, to: contentURL)
            meta.complete = true
            meta.usedAt = now().timeIntervalSince1970
            try writeMeta(meta, in: folder)
            return contentURL
        }

        emit(.fetched(type: type, id: id))
        return localURL
    }

    private func fetchWholeUncached(type: String, id: String) async throws -> Data {
        guard let url = serverURL(type: type, id: id) else { throw FileStoreError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await client.send(request)
        if response.statusCode == 404 {
            throw FileStoreError.fileMissing(type: type, id: id)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw FileStoreError.httpError(status: response.statusCode, message: nil)
        }
        return data
    }

    private func drain() async -> FileSyncResult {
        let waiting = allMetas()
            .filter { $0.complete && !$0.uploaded && $0.failed == nil }
            .sorted { $0.addedAt < $1.addedAt }
        var sent = 0
        var left = 0
        for meta in waiting {
            do {
                if try await sendFile(meta) {
                    sent += 1
                } else {
                    left += 1
                }
            } catch {
                // Offline or transient server failure: stop this pass and leave
                // this file plus the remainder waiting.
                left = waiting.count - sent
                break
            }
        }
        return FileSyncResult(sent: sent, waiting: left)
    }

    private func sendFile(_ meta: StoredMeta) async throws -> Bool {
        guard let contentURL = fileURL(forType: meta.type, id: meta.id, touch: false),
              let uploadToken = meta.upload else {
            return false
        }
        guard let standingURL = serverURL(
            type: meta.type,
            id: meta.id,
            query: [("upload", uploadToken)],
            suffix: "/upload"
        ) else {
            throw FileStoreError.invalidURL
        }
        var standingRequest = URLRequest(url: standingURL)
        standingRequest.httpMethod = "GET"
        let (standingData, standingResponse) = try await client.send(standingRequest)
        if standingResponse.statusCode == 404 {
            return false
        }
        guard (200..<300).contains(standingResponse.statusCode) else {
            throw FileStoreError.httpError(status: standingResponse.statusCode, message: nil)
        }
        let initial = try JSONDecoder().decode(UploadStanding.self, from: standingData)
        var complete = initial.complete
        var offset = initial.offset
        var step = initial.chunkSize.flatMap { $0 > 0 ? min(chunkSize, $0) : nil } ?? chunkSize

        var turns = 0
        while !complete {
            let maxTurns = Int(ceil(Double(meta.size) / Double(step))) + 8
            guard turns <= maxTurns else { throw FileStoreError.uploadStalled }
            turns += 1

            let length = Int(min(Int64(step), meta.size - offset))
            let pieceData = try readSlice(from: contentURL, offset: offset, length: length)
            guard let putURL = serverURL(
                type: meta.type,
                id: meta.id,
                query: [("upload", uploadToken), ("offset", String(offset)), ("size", String(meta.size))]
            ) else {
                throw FileStoreError.invalidURL
            }
            var putRequest = URLRequest(url: putURL)
            putRequest.httpMethod = "PUT"
            putRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            putRequest.httpBody = pieceData

            let (replyData, replyResponse) = try await client.send(putRequest)
            switch replyResponse.statusCode {
            case 404:
                return false
            case 409:
                let conflict = try JSONDecoder().decode(UploadStanding.self, from: replyData)
                offset = conflict.offset
                if let serverChunk = conflict.chunkSize, serverChunk > 0 {
                    step = min(step, serverChunk)
                }
                continue
            case 413:
                let payload = try? JSONDecoder().decode(ErrorPayload.self, from: replyData)
                if let serverChunk = payload?.chunkSize, serverChunk > 0, serverChunk < step {
                    step = serverChunk
                    continue
                }
                let reason = payload?.error ?? "refused (413)"
                _ = try await mark(type: meta.type, id: meta.id) { $0.failed = reason }
                emit(.failed(type: meta.type, id: meta.id, reason: reason))
                return false
            case 400, 415, 422:
                let payload = try? JSONDecoder().decode(ErrorPayload.self, from: replyData)
                let reason = payload?.error ?? "refused (\(replyResponse.statusCode))"
                _ = try await mark(type: meta.type, id: meta.id) { $0.failed = reason }
                emit(.failed(type: meta.type, id: meta.id, reason: reason))
                return false
            case 200..<300:
                let accepted = try JSONDecoder().decode(UploadStanding.self, from: replyData)
                complete = accepted.complete
                offset = accepted.offset
                if let serverChunk = accepted.chunkSize, serverChunk > 0 {
                    step = min(step, serverChunk)
                }
                emit(.progress(type: meta.type, id: meta.id, transferred: offset, size: meta.size))
            default:
                throw FileStoreError.httpError(status: replyResponse.statusCode, message: nil)
            }
        }

        _ = try await mark(type: meta.type, id: meta.id) { $0.uploaded = true }
        emit(.uploaded(type: meta.type, id: meta.id))
        return true
    }

    // MARK: - Room & LRU Eviction

    private func ensureRoom(for keep: StoredMeta, bytesToWrite: Int64) throws {
        guard bytesToWrite > 0, let budget else { return }
        let others = allMetas(includeTorn: true)
            .filter { !($0.type == keep.type && $0.id == keep.id) }
            .reduce(Int64(0)) { $0 + $1.size }
        let over = others + keep.size - budget
        guard over > 0 else { return }
        let freed = evict(bytes: over, keeping: keep)
        if freed < over {
            throw FileStoreError.noRoom(needed: bytesToWrite)
        }
    }

    private func evict(bytes: Int64, keeping keep: StoredMeta?) -> Int64 {
        guard bytes > 0 else { return 0 }
        let droppable = allMetas()
            .filter { meta in
                meta.uploaded
                    && !meta.pinned
                    && !(keep != nil && meta.type == keep!.type && meta.id == keep!.id)
            }
            .sorted { lhs, rhs in
                if lhs.complete != rhs.complete {
                    return !lhs.complete && rhs.complete
                }
                return lhs.usedAt < rhs.usedAt
            }

        var freed: Int64 = 0
        for meta in droppable {
            if freed >= bytes { break }
            let key = Self.recordKey(meta.type, meta.id)
            if downloads[key] != nil { continue }
            guard tryLockRecord(key) else { continue }
            dropRecord(type: meta.type, id: meta.id)
            unlockRecord(key)
            freed += meta.size
            emit(.evicted(type: meta.type, id: meta.id))
        }
        return freed
    }

    // MARK: - Disk Helpers

    private func mark(type: String, id: String, mutate: (inout StoredMeta) -> Void) async throws -> Bool {
        let key = Self.recordKey(type, id)
        return try await withRecordLock(key) {
            guard var meta = readMeta(type: type, id: id) else { return false }
            mutate(&meta)
            try writeMeta(meta, in: recordFolderURL(type: type, id: id))
            return true
        }
    }

    private func recordFolderURL(type: String, id: String) -> URL {
        root
            .appendingPathComponent("type-\(Self.safe(type))", isDirectory: true)
            .appendingPathComponent(Self.safe(id), isDirectory: true)
    }

    private func recordFolder(type: String, id: String, create: Bool) throws -> URL {
        let folder = recordFolderURL(type: type, id: id)
        if create {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    private func writeMeta(_ meta: StoredMeta, in folder: URL) throws {
        let data = try JSONEncoder().encode(meta)
        try data.write(to: folder.appendingPathComponent(Self.metaFileName), options: .atomic)
    }

    private func readMeta(type: String, id: String, includeTorn: Bool = false) -> StoredMeta? {
        readMeta(in: recordFolderURL(type: type, id: id), includeTorn: includeTorn)
    }

    private func readMeta(in folder: URL, includeTorn: Bool) -> StoredMeta? {
        let metaURL = folder.appendingPathComponent(Self.metaFileName)
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(StoredMeta.self, from: data) else {
            return nil
        }
        return (includeTorn || meta.complete || meta.uploaded) ? meta : nil
    }

    private func allMetas(includeTorn: Bool = false) -> [StoredMeta] {
        guard let typeFolders = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var found: [StoredMeta] = []
        for typeFolder in typeFolders where typeFolder.lastPathComponent.hasPrefix("type-") {
            guard let recordFolders = try? fileManager.contentsOfDirectory(
                at: typeFolder,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for folder in recordFolders {
                if let meta = readMeta(in: folder, includeTorn: includeTorn) {
                    found.append(meta)
                }
            }
        }
        return found
    }

    private func dropRecord(type: String, id: String) {
        let folder = recordFolderURL(type: type, id: id)
        try? fileManager.removeItem(at: folder)
    }

    private func fileSize(at url: URL) -> Int64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber else {
            return 0
        }
        return number.int64Value
    }

    private func readSlice(from url: URL, offset: Int64, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: length) ?? Data()
    }

    // MARK: - Per-Record Serialization

    private func withRecordLock<T>(_ key: String, _ work: () async throws -> T) async rethrows -> T {
        if lockedKeys.contains(key) {
            await withCheckedContinuation { continuation in
                lockWaiters[key, default: []].append(continuation)
            }
        } else {
            lockedKeys.insert(key)
        }
        defer { unlockRecord(key) }
        return try await work()
    }

    private func tryLockRecord(_ key: String) -> Bool {
        if lockedKeys.contains(key) { return false }
        lockedKeys.insert(key)
        return true
    }

    private func unlockRecord(_ key: String) {
        if var waiters = lockWaiters[key], !waiters.isEmpty {
            let next = waiters.removeFirst()
            if waiters.isEmpty {
                lockWaiters.removeValue(forKey: key)
            } else {
                lockWaiters[key] = waiters
            }
            next.resume()
        } else {
            lockedKeys.remove(key)
        }
    }

    private func emit(_ event: FileEvent) {
        for listener in listeners.values {
            listener(event)
        }
    }

    // MARK: - Encoding

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")

    private static func recordKey(_ type: String, _ id: String) -> String {
        "\(type)/\(id)"
    }

    private static func urlSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static func safe(_ value: String) -> String {
        let encoded = urlSegment(value)
        return encoded.hasPrefix(".") ? "%2E" + encoded.dropFirst() : encoded
    }

    private static func uploadToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
