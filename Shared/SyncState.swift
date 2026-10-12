import Foundation

public struct SyncEntry: Codable, Equatable, Sendable {
    public var heads: [SyncVersion]
    public var dirty: Bool
    public var preferredVersionID: UUID?

    public init(heads: [SyncVersion], dirty: Bool = true, preferredVersionID: UUID? = nil) {
        self.heads = heads; self.dirty = dirty
        self.preferredVersionID = preferredVersionID
    }
    public var hasConflict: Bool {
        guard let first = heads.first else { return false }
        return heads.contains { !$0.hasSameContent(as: first) }
    }
    /// This is a projection for the normal list UI, not a conflict winner. Every
    /// concurrent value stays in `heads` until an explicit resolution dominates it.
    public var displayedVersion: SyncVersion? {
        let live = heads.filter { !$0.isDeleted }
        if let preferredVersionID, let preferred = live.first(where: { $0.id == preferredVersionID }) { return preferred }
        return live.sorted { $0.id.uuidString < $1.id.uuidString }.first ?? heads.first
    }
}

/// Committed in the SAME snapshot/rename/flock transaction as local content.
/// App and widgets capture edits while offline; only the app talks to a paired LAN peer.
public struct SyncLedger: Codable, Equatable, Sendable {
    public var schema = 1
    /// Local-only installation binding. Portable exports replace it; imports retain this installation.
    public var installationID = UUID()
    public var replicaID = UUID()
    public var counter: UInt64 = 0
    /// A local import changes epoch and rejects all in-flight acknowledgements.
    public var epoch = UUID()
    public var enabled = false
    public var peerBindingID: String?
    public var importRequiresReview = false
    public var entries: [String: SyncEntry] = [:]
    public var lastSuccessfulSync: Date?
    public var lastFailure: String?

    public init() {}
    public var pendingCount: Int { entries.values.filter(\.dirty).count }
    public var conflicts: [SyncConflict] {
        entries.filter { $0.value.hasConflict }.map { key, entry in
            SyncConflict(key: key, title: entry.displayedVersion?.payload?.title ?? key,
                         versions: entry.heads.sorted { $0.id.uuidString < $1.id.uuidString })
        }.sorted { $0.key < $1.key }
    }
    public var status: SyncStatus {
        SyncStatus(enabled: enabled, pausedAfterImport: importRequiresReview, pendingChanges: pendingCount,
                   conflicts: conflicts, lastSuccessfulSync: lastSuccessfulSync, lastFailure: lastFailure)
    }

    public func validate() throws {
        guard schema == 1, entries.count <= 100_000 else { throw RepositoryError.invalidData("unsupported or oversized sync ledger") }
        if let peerBindingID { guard !peerBindingID.isEmpty, peerBindingID.count <= 512 else { throw RepositoryError.invalidData("invalid peer binding") } }
        guard !enabled || peerBindingID != nil else { throw RepositoryError.invalidData("enabled sync has no peer binding") }
        guard (lastFailure?.count ?? 0) <= 4_000 else { throw RepositoryError.invalidData("oversized sync metadata") }
        if let lastSuccessfulSync { try SnapshotValidator.date(lastSuccessfulSync, field: "lastSuccessfulSync") }
        for (key, entry) in entries {
            try SyncEnvelope(key: key, heads: entry.heads).validate()
            guard entry.heads.allSatisfy({ $0.clock[replicaID.uuidString, default: 0] <= counter }) else {
                throw RepositoryError.invalidData("local causal counter was rolled back")
            }
        }
    }

    internal func validateProjection(of snapshot: AppSnapshot) throws {
        let actual = Self.payloads(snapshot)
        let listIDs = Set(snapshot.lists.map(\.id))
        for (key, entry) in entries {
            var expected = entry.displayedVersion?.payload
            if case .task(var task)? = expected, let listID = task.listID, !listIDs.contains(listID) {
                task.listID = nil; expected = .task(task)
            }
            guard actual[key] == expected else { throw RepositoryError.invalidData("content differs from its durable sync version") }
        }
    }

    /// First synchronization also seeds pre-v2 local items. Empty devices seed nothing.
    public mutating func seed(from snapshot: AppSnapshot) throws {
        for (key, payload) in Self.payloads(snapshot) where entries[key] == nil {
            let version = try makeVersion(payload: payload, context: [:])
            entries[key] = SyncEntry(heads: [version], preferredVersionID: version.id)
        }
    }

    public static func recordLocalChanges(from before: AppSnapshot, to after: inout AppSnapshot) throws {
        var ledger = before.sync
        try ledger.seed(from: before)
        let previous = payloads(before)
        let proposed = payloads(after)
        for key in Set(previous.keys).union(proposed.keys).sorted() where previous[key] != proposed[key] {
            var payload = proposed[key]
            // A downloaded task may temporarily refer to a list on a later page.
            // Preserve that canonical relation if the user didn't change its projection.
            if case .task(var task)? = payload, case .task(let old)? = previous[key],
               task.listID == old.listID, task.listID == nil,
               case .task(let canonical)? = ledger.entries[key]?.displayedVersion?.payload,
               let listID = canonical.listID, !before.lists.contains(where: { $0.id == listID }) {
                task.listID = listID; payload = .task(task)
            }
            let entry = ledger.entries[key]
            guard entry?.hasConflict != true else { throw SyncError.unresolvedConflict }
            let observed = entry?.heads ?? []
            let version = try ledger.makeVersion(payload: payload, context: Self.joinedClock(observed))
            let merged = try SyncEnvelope.merged(entry?.heads ?? [], [version])
            try SyncEnvelope(key: key, heads: merged).validate()
            ledger.entries[key] = SyncEntry(heads: merged, dirty: true,
                                           preferredVersionID: version.id)
        }
        after.sync = ledger
    }

    /// Incoming versions and receipts use causal comparison. A concurrent local edit made
    /// during network I/O stays dirty unless the actual peer response contains it.
    @discardableResult
    public mutating func mergeRemote(_ envelope: SyncEnvelope) throws -> Bool {
        try envelope.validate()
        let previous = entries[envelope.key]
        let heads = try SyncEnvelope.merged(previous?.heads ?? [], envelope.heads)
        try SyncEnvelope(key: envelope.key, heads: heads).validate()
        let peerIDs = Set(envelope.heads.map(\.id))
        entries[envelope.key] = SyncEntry(heads: heads, dirty: Set(heads.map(\.id)) != peerIDs,
                                        preferredVersionID: previous?.preferredVersionID)
        return previous?.heads != heads
    }

    /// Called only after an authenticated peer confirms this exact packet was
    /// validated and atomically committed. New local heads stay pending.
    public mutating func acknowledge(_ sent: [SyncEnvelope]) {
        for item in sent {
            guard var current = entries[item.key] else { continue }
            current.dirty = Set(current.heads.map(\.id)) != Set(item.heads.map(\.id))
            entries[item.key] = current
        }
    }

    /// Explicit review is the ONLY operation that observes every conflicting head.
    public mutating func resolve(key: String, versionID: UUID, expectedHeadIDs: Set<UUID>) throws {
        guard let entry = entries[key], entry.hasConflict, Set(entry.heads.map(\.id)) == expectedHeadIDs, let chosen = entry.heads.first(where: { $0.id == versionID }) else {
            throw SyncError.missingConflict
        }
        let resolved = try makeVersion(payload: chosen.payload, context: Self.joinedClock(entry.heads))
        entries[key] = SyncEntry(heads: [resolved], dirty: true,
                                preferredVersionID: resolved.id)
    }

    /// Export all reviewable versions, but no peer binding, device identity,
    /// enabled state, or success claims. Never export deletion-only history.
    public func portableCopy() -> SyncLedger {
        var result = SyncLedger()
        for (key, entry) in entries where entry.heads.contains(where: { !$0.isDeleted }) {
            var heads: [SyncVersion] = []; var preferred: UUID?
            // Portable content must not contain a reusable device identity or
            // counter history. Preserve every payload with independent fresh roots.
            for old in entry.heads {
                let replacement = SyncVersion(clock: [UUID().uuidString: 1], payload: old.payload)
                heads.append(replacement)
                if old.id == entry.displayedVersion?.id { preferred = replacement.id }
            }
            result.entries[key] = SyncEntry(heads: heads, dirty: true, preferredVersionID: preferred)
        }
        return result
    }

    /// Replacement import is a new independent causal branch. Missing records do
    /// not become tombstones; old pending deletions are not uploaded implicitly.
    public func pausedForImport(snapshot: AppSnapshot) throws -> SyncLedger {
        var result = SyncLedger()
        result.enabled = enabled; result.peerBindingID = peerBindingID
        result.installationID = installationID
        result.importRequiresReview = true
        result.lastFailure = "导入完成，同步已暂停，等待确认与已配对设备合并。"
        // A later exchange merges explicit versions only. Missing items are never deletes.
        let materialized = Self.payloads(snapshot)
        for (key, payload) in materialized.sorted(by: { $0.key < $1.key }) {
            let source = snapshot.sync.entries[key]
            let versions: [SyncPayload?] = source?.heads.map(\.payload) ?? [payload]
            var heads: [SyncVersion] = []
            var preferred: UUID?
            // Separate replica roots preserve imported alternatives as concurrent.
            for value in versions {
                let version = SyncVersion(clock: [UUID().uuidString: 1], payload: value)
                heads.append(version)
                if value == source?.displayedVersion?.payload || (source == nil && value == payload) { preferred = version.id }
            }
            result.entries[key] = SyncEntry(heads: heads, preferredVersionID: preferred)
        }
        return result
    }

    /// Rebuild only synchronized collections. Keep device-local settings, and
    /// project temporarily missing list references safely without deleting them
    /// from their canonical version in the ledger.
    public func materialize(into snapshot: inout AppSnapshot) {
        let oldTaskIDs = snapshot.tasks.map(\.id); let oldNoteIDs = snapshot.notes.map(\.id)
        let oldAnniversaryIDs = snapshot.anniversaries.map(\.id); let oldListIDs = snapshot.lists.map(\.id)
        var tasks: [TodoItem] = []; var notes: [NoteItem] = []
        var anniversaries: [Anniversary] = []; var lists: [Checklist] = []
        for entry in entries.values {
            guard let payload = entry.displayedVersion?.payload else { continue }
            switch payload {
            case .task(let value): tasks.append(value)
            case .note(let value): notes.append(value)
            case .anniversary(let value): anniversaries.append(value)
            case .list(let value): lists.append(value)
            }
        }
        let listIDs = Set(lists.map(\.id))
        for index in tasks.indices where tasks[index].listID.map({ !listIDs.contains($0) }) == true { tasks[index].listID = nil }
        snapshot.tasks = Self.stableOrder(tasks, prior: oldTaskIDs)
        snapshot.notes = Self.stableOrder(notes, prior: oldNoteIDs)
        snapshot.anniversaries = Self.stableOrder(anniversaries, prior: oldAnniversaryIDs)
        snapshot.lists = Self.stableOrder(lists, prior: oldListIDs)
        if let id = snapshot.settings.defaultListID, !listIDs.contains(id) { snapshot.settings.defaultListID = nil }
    }

    internal static func payloads(_ snapshot: AppSnapshot) -> [String: SyncPayload] {
        let all = snapshot.tasks.map(SyncPayload.task) + snapshot.notes.map(SyncPayload.note)
            + snapshot.anniversaries.map(SyncPayload.anniversary) + snapshot.lists.map(SyncPayload.list)
        return Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })
    }
    private mutating func makeVersion(payload: SyncPayload?, context: [String: UInt64]) throws -> SyncVersion {
        guard counter < UInt64.max else { throw SyncError.clockLimit }
        var clock = context; counter += 1; clock[replicaID.uuidString] = counter
        guard clock.count <= 64 else { throw SyncError.clockLimit }
        return SyncVersion(clock: clock, payload: payload)
    }
    private static func joinedClock(_ versions: [SyncVersion]) -> [String: UInt64] {
        var result: [String: UInt64] = [:]
        for version in versions { for (key, value) in version.clock { result[key] = max(result[key, default: 0], value) } }
        return result
    }
    private static func stableOrder<T: Identifiable>(_ values: [T], prior: [UUID]) -> [T] where T.ID == UUID {
        let indices = Dictionary(uniqueKeysWithValues: prior.enumerated().map { ($0.element, $0.offset) })
        return values.sorted {
            let left = indices[$0.id, default: Int.max]; let right = indices[$1.id, default: Int.max]
            return left == right ? $0.id.uuidString < $1.id.uuidString : left < right
        }
    }
}
