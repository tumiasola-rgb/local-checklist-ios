import Foundation

/// A causally versioned item. Settings remain device-local; explicit backups include them.
public enum SyncPayload: Codable, Equatable, Sendable {
    case task(TodoItem)
    case note(NoteItem)
    case anniversary(Anniversary)
    case list(Checklist)

    public var key: String {
        switch self {
        case .task(let value): return "task.\(value.id.uuidString.lowercased())"
        case .note(let value): return "note.\(value.id.uuidString.lowercased())"
        case .anniversary(let value): return "anniversary.\(value.id.uuidString.lowercased())"
        case .list(let value): return "list.\(value.id.uuidString.lowercased())"
        }
    }
    public var title: String {
        switch self {
        case .task(let value): return value.title
        case .note(let value): return value.title
        case .anniversary(let value): return value.title
        case .list(let value): return value.title
        }
    }
    public var summary: String {
        if case .task(let value) = self { return "\(value.isCompleted ? "已完成" : "未完成") · \(value.title)" }
        return title
    }
    /// Full, lossless review text. Dates here describe content, never conflict priority.
    public var detail: String {
        let encoder = SyncCoding.encoder(pretty: true)
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return summary }
        return text
    }
    /// Ignore audit timestamps when deciding whether two concurrent versions
    /// need user review. Causal heads are still retained; no clock information or
    /// different business fields are discarded by this equivalence check.
    internal func isSemanticallyEquivalent(to other: SyncPayload) -> Bool {
        switch (self, other) {
        case (.task(var lhs), .task(let rhs)):
            lhs.createdAt = rhs.createdAt; lhs.updatedAt = rhs.updatedAt; lhs.completedAt = rhs.completedAt
            return lhs == rhs
        case (.note(var lhs), .note(let rhs)):
            lhs.createdAt = rhs.createdAt; lhs.updatedAt = rhs.updatedAt
            return lhs == rhs
        default: return self == other
        }
    }
    internal func validate() throws {
        var sample = AppSnapshot()
        switch self {
        case .task(let value):
            sample.tasks = [value]
            if let id = value.listID { sample.lists = [Checklist(id: id, title: "Relationship validation")] }
        case .note(let value): sample.notes = [value]
        case .anniversary(let value): sample.anniversaries = [value]
        case .list(let value): sample.lists = [value]
        }
        try sample.validate()
    }
}

public struct SyncVersion: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// Vector clock, not wall-clock time. Counters are allocated atomically with local content.
    public let clock: [String: UInt64]
    public let payload: SyncPayload?
    public var isDeleted: Bool { payload == nil }
    public var summary: String { payload?.summary ?? "删除此项" }
    public var detail: String { payload?.detail ?? "此版本是删除标记。选择它会保留删除，并在下次同步传播；其他版本当前仍保留供查看。" }

    public init(id: UUID = UUID(), clock: [String: UInt64], payload: SyncPayload?) {
        self.id = id; self.clock = clock; self.payload = payload
    }
    internal func hasSameContent(as other: SyncVersion) -> Bool {
        switch (payload, other.payload) {
        case (.none, .none): return true
        case (.some(let lhs), .some(let rhs)): return lhs.isSemanticallyEquivalent(to: rhs)
        default: return false
        }
    }
    internal func dominates(_ other: SyncVersion) -> Bool {
        guard clock != other.clock else { return false }
        return other.clock.allSatisfy { clock[$0.key, default: 0] >= $0.value }
    }
}

public struct SyncConflict: Identifiable, Equatable, Sendable {
    public var id: String { key }
    public let key: String
    public let title: String
    public let versions: [SyncVersion]
}

public struct SyncStatus: Equatable, Sendable {
    public let enabled: Bool
    public let pausedAfterImport: Bool
    public let pendingChanges: Int
    public let conflicts: [SyncConflict]
    public let lastSuccessfulSync: Date?
    public let lastFailure: String?
}

public struct SyncReport: Equatable, Sendable {
    public let uploaded: Int
    public let downloaded: Int
    public let conflicts: Int
    public let pendingChanges: Int
    public let lastSuccessfulSync: Date?
    public var summary: String {
        "对方已确认落盘 \(uploaded) 项变更；本机已接收 \(downloaded) 项；仍待传 \(pendingChanges) 项，待审冲突 \(conflicts) 项。确认只针对本次交换的版本。"
    }
}

public enum SyncError: Error, LocalizedError, Equatable {
    case disabled, importReviewRequired, busy, interrupted
    case invalidRemoteData(String), conflictLimit, clockLimit, missingConflict, unresolvedConflict
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .disabled: return "局域网同步尚未启用，本地内容仍可使用。"
        case .importReviewRequired: return "导入后已暂停同步。请确认合并后继续；备份缺少的项目不会作为删除发送。"
        case .busy: return "同步或配对正在进行，请稍候。"
        case .interrupted: return "同步被停用、导入或新的本地资料版本中断；已发出的操作将在下次核对。"
        case .invalidRemoteData(let reason): return "对端数据未通过校验，未提交此次接收：\(reason)"
        case .conflictLimit: return "单项冲突或内容达到安全上限。未删除任何版本，请先审阅并解决冲突。"
        case .clockLimit: return "同步因果版本达到安全上限。未覆盖已有内容，请导出备份后处理。"
        case .missingConflict: return "此冲突版本集合已改变，请刷新后重新查看。"
        case .unresolvedConflict: return "此项有未审阅的并发版本，请先在同步冲突中明确选择，再编辑、完成或删除。"
        case .failed(let message): return message
        }
    }
}

public extension Notification.Name {
    static let localChecklistSyncDidCommit = Notification.Name("LocalChecklist.localSyncDidCommit")
}

internal enum SyncCoding {
    static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970; return decoder
    }
}

/// The per-item local-network wire format. Explicit schema and bounded growth fail closed.
public struct SyncEnvelope: Codable, Equatable, Sendable {
    public static let maximumItemBytes = 8 * 1_024 * 1_024
    public let schema: Int
    public let key: String
    public let heads: [SyncVersion]
    public init(key: String, heads: [SyncVersion]) { schema = 1; self.key = key; self.heads = heads }

    public func validate() throws {
        guard schema == 1 else { throw SyncError.invalidRemoteData("unsupported sync schema") }
        let parts = key.split(separator: ".")
        guard parts.count == 2, ["task", "note", "anniversary", "list"].contains(String(parts[0])),
              let uuid = UUID(uuidString: String(parts[1])), uuid.uuidString.lowercased() == parts[1] else {
            throw SyncError.invalidRemoteData("invalid item key")
        }
        guard !heads.isEmpty, heads.count <= 64 else { throw SyncError.conflictLimit }
        var ids = Set<UUID>()
        var clocks = Set<Data>()
        for version in heads {
            guard ids.insert(version.id).inserted, !version.clock.isEmpty, version.clock.count <= 64,
                  version.clock.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value > 0 }) else {
                throw SyncError.invalidRemoteData("invalid causal version")
            }
            guard clocks.insert(try SyncCoding.encoder().encode(version.clock)).inserted else {
                throw SyncError.invalidRemoteData("duplicate causal clock")
            }
            if let payload = version.payload {
                guard payload.key == key else { throw SyncError.invalidRemoteData("payload identity mismatch") }
                try payload.validate()
            }
        }
        guard heads.allSatisfy({ a in !heads.contains(where: { $0.dominates(a) }) }) else {
            throw SyncError.invalidRemoteData("non-maximal causal heads")
        }
        guard try SyncCoding.encoder().encode(self).count <= Self.maximumItemBytes else { throw SyncError.conflictLimit }
    }

    /// Union followed by causal maximality. Concurrent tombstones/edits are never LWW.
    public static func merged(_ lhs: [SyncVersion], _ rhs: [SyncVersion]) throws -> [SyncVersion] {
        var byID: [UUID: SyncVersion] = [:]
        for version in lhs + rhs {
            if let prior = byID[version.id], prior != version { throw SyncError.invalidRemoteData("version ID reused with different content") }
            byID[version.id] = version
        }
        let all = Array(byID.values)
        let result = all.filter { version in !all.contains(where: { $0.dominates(version) }) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        guard result.count <= 64 else { throw SyncError.conflictLimit }
        return result
    }
}
