import Foundation
import SwiftUI

/// A quarantined offline write that the server rejected or last-write-wins
/// overwrote. Kept in the local SQLite ledger until the user retries it, forks
/// it as a new record, or dismisses it.
public struct SyncNotice: Identifiable, Equatable, Decodable {
    public struct FieldDiff: Identifiable, Equatable {
        public var id: String { field }
        public let field: String
        public let localValue: String?
        public let serverValue: String?

        public init(field: String, localValue: String?, serverValue: String?) {
            self.field = field
            self.localValue = localValue
            self.serverValue = serverValue
        }
    }

    public let id: String
    public let mutationId: String
    public let kind: String
    public let recordType: String
    public let recordId: String
    public let operation: String
    public let reason: String
    public let attemptedChanges: [String: String]
    public let serverAttributes: [String: String]
    public let serverVersion: Int
    public let createdAt: String?

    public var isConflict: Bool { kind == "conflict" }
    public var isRejected: Bool { kind == "rejected" }

    private static let bookkeepingColumns: Set<String> = [
        "id", "server_version", "sync_state", "created_at", "updated_at",
    ]

    public init(
        id: String,
        mutationId: String = "",
        kind: String,
        recordType: String,
        recordId: String,
        operation: String,
        reason: String,
        attemptedChanges: [String: String] = [:],
        serverAttributes: [String: String] = [:],
        serverVersion: Int = 0,
        createdAt: String? = nil
    ) {
        self.id = id
        self.mutationId = mutationId
        self.kind = kind
        self.recordType = recordType
        self.recordId = recordId
        self.operation = operation
        self.reason = reason
        self.attemptedChanges = attemptedChanges
        self.serverAttributes = serverAttributes
        self.serverVersion = serverVersion
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case mutationId = "mutation_id"
        case kind
        case recordType = "record_type"
        case recordId = "record_id"
        case operation
        case reason
        case attemptedChanges = "attempted_changes"
        case serverAttributes = "server_attributes"
        case serverVersion = "server_version"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        mutationId = try container.decodeIfPresent(String.self, forKey: .mutationId) ?? ""
        kind = try container.decode(String.self, forKey: .kind)
        recordType = try container.decode(String.self, forKey: .recordType)
        recordId = try container.decode(String.self, forKey: .recordId)
        operation = try container.decode(String.self, forKey: .operation)
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
        attemptedChanges = Self.decodeStringMap(from: container, forKey: .attemptedChanges)
        serverAttributes = Self.decodeStringMap(from: container, forKey: .serverAttributes)
        serverVersion = try container.decodeIfPresent(Int.self, forKey: .serverVersion) ?? 0
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
    }

    /// Field-level differences between attempted local values and the winning
    /// server attributes, omitting gem bookkeeping columns.
    public var fieldDiffs: [FieldDiff] {
        let keys = (operation == "destroy" ? Array(serverAttributes.keys) : Array(attemptedChanges.keys))
            .filter { !Self.bookkeepingColumns.contains($0) }
            .sorted()

        return keys.compactMap { field in
            let local = operation == "destroy" ? nil : attemptedChanges[field]
            let server = serverAttributes[field]
            if !serverAttributes.isEmpty, local == server { return nil }
            return FieldDiff(field: field, localValue: local, serverValue: server)
        }
    }

    private static func decodeStringMap(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> [String: String] {
        guard let raw = try? container.decodeIfPresent([String: JSONValue].self, forKey: key) else { return [:] }
        var out: [String: String] = [:]
        for (name, value) in raw {
            if let text = value.displayString { out[name] = text }
        }
        return out
    }
}

private enum JSONValue: Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let bool = try? single.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? single.decode(Int.self) {
            self = .int(int)
        } else if let double = try? single.decode(Double.self) {
            self = .double(double)
        } else if let string = try? single.decode(String.self) {
            self = .string(string)
        } else {
            self = .null
        }
    }

    var displayString: String? {
        switch self {
        case .string(let value): value
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .bool(let value): value ? "true" : "false"
        case .null: nil
        }
    }
}

/// Parses `ir_notice()` output: `"records_changed"`, optional `"Type:id"` lines,
/// and optional `"sync_notice:<json>"` lines.
enum NoticeSignal {
    struct Parsed: Equatable {
        let recordsChanged: Bool
        let syncNotices: [SyncNotice]
    }

    private static let prefix = "sync_notice:"

    static func parse(_ raw: String) -> Parsed {
        guard raw.hasPrefix("records_changed") else {
            return Parsed(recordsChanged: false, syncNotices: [])
        }
        let decoder = JSONDecoder()
        var found: [SyncNotice] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true).dropFirst() {
            guard line.hasPrefix(prefix) else { continue }
            let json = String(line.dropFirst(prefix.count))
            if let notice = try? decoder.decode(SyncNotice.self, from: Data(json.utf8)) {
                found.append(notice)
            }
        }
        return Parsed(recordsChanged: true, syncNotices: found)
    }
}

struct SyncNoticesResponse: Decodable {
    let ok: Bool
    let error: String?
    let recordId: String?
    let notices: [SyncNotice]?

    enum CodingKeys: String, CodingKey {
        case ok, error, notices
        case recordId = "record_id"
    }
}

/// Modal sheet letting the user inspect quarantined offline writes and choose
/// to retry them, fork them as new records, or dismiss them.
struct SyncNoticesSheet: View {
    @ObservedObject var host: AppHost
    let theme: Theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if host.notices.isEmpty {
                    Text("No sync conflicts or rejections.")
                        .font(.body)
                        .fontDesign(theme.ui)
                        .foregroundStyle(theme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(host.notices) { notice in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Text(notice.isConflict ? "Conflict" : "Rejected")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background((notice.isConflict ? Color.orange : Color.red).opacity(0.18), in: Capsule())
                                    .foregroundStyle(notice.isConflict ? Color.orange : Color.red)
                                Text("\(notice.recordType) (\(notice.operation))")
                                    .font(.headline)
                                    .fontDesign(theme.ui)
                                    .foregroundStyle(theme.ink)
                            }

                            if !notice.reason.isEmpty {
                                Text(notice.reason)
                                    .font(.subheadline)
                                    .fontDesign(theme.ui)
                                    .foregroundStyle(theme.muted)
                            }

                            if !notice.fieldDiffs.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(notice.fieldDiffs) { diff in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(diff.field)
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(theme.muted)
                                            Text("Yours: \(diff.localValue ?? "(removed)")")
                                                .font(.caption)
                                                .foregroundStyle(theme.ink)
                                            if let server = diff.serverValue {
                                                Text("Server: \(server)")
                                                    .font(.caption)
                                                    .foregroundStyle(theme.muted)
                                            }
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }

                            HStack(spacing: 12) {
                                Button("Retry") { host.retryNotice(notice.id) }
                                    .buttonStyle(.borderedProminent)
                                    .accessibilityIdentifier("notice-retry-\(notice.id)")
                                Button("Fork as New") { host.forkNotice(notice.id) }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("notice-fork-\(notice.id)")
                                Button("Dismiss", role: .destructive) { host.dismissNotice(notice.id) }
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("notice-dismiss-\(notice.id)")
                            }
                            .font(.footnote)
                            .fontDesign(theme.ui)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Sync Notices")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(theme.tint)
        .environment(\.theme, theme)
    }
}
