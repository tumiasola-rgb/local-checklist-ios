import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Synchronous, small local-file transactions shared by the app and widget.
/// Each operation opens the SAME persistent lock file and obtains an exclusive
/// flock before reading current state. Never delete/replace the lock file.
/// This class owns no in-memory cache. A Swift actor alone would not protect a
/// second process. Do not call repository methods recursively inside `update`.
public final class SharedRepository: @unchecked Sendable {
    public static let currentVersion = 2
    public static let dataFileName = "snapshot.json"
    public let directory: URL
    private let snapshotURL: URL
    private let lockURL: URL
    private let recoveryURL: URL

    /// The standalone product explicitly uses its own Application Support directory.
    /// The original app/widget product requires matching App Group configuration;
    /// a missing shared container never silently redirects to another store.
    public convenience init(bundle: Bundle = .main) throws {
        #if STANDALONE_APP
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true)
        try self.init(directory: support.appendingPathComponent("LocalChecklist", isDirectory: true))
        #else
        guard let identifier = bundle.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              identifier.hasPrefix("group."), !identifier.contains("$(") else {
            throw RepositoryError.missingAppGroupIdentifier
        }
        #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS) || os(visionOS)
        guard let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            throw RepositoryError.unavailableAppGroup(identifier)
        }
        try self.init(directory: groupURL.appendingPathComponent("LocalChecklist", isDirectory: true))
        #else
        throw RepositoryError.unavailableAppGroup(identifier)
        #endif
        #endif
    }

    /// Injection point for isolated tests. Use an Application Support/App Group
    /// directory in production, never Caches or tmp.
    public init(directory: URL) throws {
        guard directory.isFileURL else { throw RepositoryError.io("Expected a local file URL") }
        self.directory = directory.standardizedFileURL
        snapshotURL = self.directory.appendingPathComponent(Self.dataFileName)
        lockURL = self.directory.appendingPathComponent("transaction.lock")
        recoveryURL = self.directory.appendingPathComponent("pre-import.json")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try applyStorageAttributes(at: self.directory)
    }

    /// The first read creates a persisted, empty store; corrupt existing data
    /// always throws and is never silently replaced by an empty store.
    public func read() throws -> AppSnapshot {
        try withExclusiveLock { try readLocked() }
    }

    /// Changes the latest on-disk snapshot under the process-shared lock. The
    /// closure should modify only intended fields, not replace stale snapshots.
    @discardableResult
    public func update(expectedGeneration: UUID? = nil, _ change: (inout AppSnapshot) throws -> Void) throws -> AppSnapshot {
        try transaction(expectedGeneration: expectedGeneration, captureLocalChanges: true, change)
    }

    /// Internal sync commits use the same durable transaction, without creating fake local edits.
    @discardableResult
    public func updateSync(expectedGeneration: UUID? = nil, _ change: (inout AppSnapshot) throws -> Void) throws -> AppSnapshot {
        try transaction(expectedGeneration: expectedGeneration, captureLocalChanges: false, change)
    }

    private func transaction(expectedGeneration: UUID?, captureLocalChanges: Bool, _ change: (inout AppSnapshot) throws -> Void) throws -> AppSnapshot {
        try withExclusiveLock {
            let current = try readLocked()
            try checkGeneration(expectedGeneration, current: current)
            guard current.revision < Int.max else { throw RepositoryError.revisionOverflow }
            var next = current
            try change(&next)
            guard next.generation == current.generation, next.revision == current.revision else {
                throw RepositoryError.invalidData("transaction closures must not modify generation or revision")
            }
            if captureLocalChanges {
                try SnapshotValidator.validate(next, validateSync: false) // Reject duplicate IDs before building dictionaries.
                try SyncLedger.recordLocalChanges(from: current, to: &next)
            }
            try next.validate()
            if next == current { return current }
            next.revision = current.revision + 1
            return try writeLocked(next)
        }
    }

    /// Dates in the portable JSON envelope are milliseconds since the Unix epoch.
    public func exportData() throws -> Data {
        let snapshot = try read()
        let envelope = BackupEnvelope(format: "LocalChecklistBackup", version: Self.currentVersion,
                                      exportedAt: Date(), payload: snapshot.portableBackupSnapshot())
        let data = try Self.encoder().encode(envelope)
        guard data.count <= SnapshotValidator.maximumBytes else { throw RepositoryError.sizeLimitExceeded }
        return data
    }

    /// Pure validation: does not modify the store. A future or malformed file
    /// cannot become a preview, so the UI can show counts before confirmation.
    public func previewImport(_ data: Data) throws -> ImportPreview {
        try Self.validateHeader(data, expectedFormat: "LocalChecklistBackup")
        try SnapshotValidator.validateShape(data, backup: true)
        let envelope: BackupEnvelope
        do { envelope = try Self.decoder().decode(BackupEnvelope.self, from: data) }
        catch { throw RepositoryError.invalidData("invalid backup field types or dates") }
        try envelope.payload.validate()
        try SnapshotValidator.date(envelope.exportedAt, field: "exportedAt")
        let normalizedStore = try Self.encoder().encode(StoreEnvelope(format: "LocalChecklistStore", version: Self.currentVersion, payload: envelope.payload))
        guard normalizedStore.count <= SnapshotValidator.maximumStoredBytes else { throw RepositoryError.sizeLimitExceeded }
        return ImportPreview(snapshot: envelope.payload, exportedAt: envelope.exportedAt)
    }

    /// The most recent pre-import state, or nil before the first replacement.
    /// Restoring this preview uses the same explicit-confirmation replace flow.
    public func readRecoveryPreview() throws -> ImportPreview? {
        try withExclusiveLock {
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: recoveryURL.path) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw RepositoryError.io("The recovery copy is not a regular file") }
            if let size = attributes[.size] as? NSNumber, size.int64Value > Int64(SnapshotValidator.maximumBytes) {
                throw RepositoryError.sizeLimitExceeded
            }
            return try previewImport(Data(contentsOf: recoveryURL))
        }
    }

    /// Call only after the user confirms replacement of their current database.
    /// A new generation invalidates all previously opened editors and intents.
    @discardableResult
    public func replace(with preview: ImportPreview, expectedGeneration: UUID) throws -> AppSnapshot {
        try withExclusiveLock {
            let current = try readLocked()
            try checkGeneration(expectedGeneration, current: current)
            guard current.revision < Int.max else { throw RepositoryError.revisionOverflow }
            var next = preview.snapshot
            try next.validate()
            next.sync = try current.sync.pausedForImport(snapshot: next)
            let importedLedger = next.sync; importedLedger.materialize(into: &next)
            next.generation = UUID()
            next.revision = current.revision + 1
            let recovery = BackupEnvelope(format: "LocalChecklistBackup", version: Self.currentVersion,
                                          exportedAt: Date(), payload: current.portableBackupSnapshot())
            // Any failure here leaves the primary store untouched. Keep one
            // recovery copy; restoring also preserves the pre-restore state.
            do { try writeDataLocked(Self.encoder().encode(recovery), to: recoveryURL) }
            catch { throw RepositoryError.recoveryPreparationFailed(error.localizedDescription) }
            return try writeLocked(next)
        }
    }

    private func readLocked() throws -> AppSnapshot {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: snapshotURL.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return try writeLocked(.empty)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw RepositoryError.io("The store is not a regular file") }
        if let size = attributes[.size] as? NSNumber, size.int64Value > Int64(SnapshotValidator.maximumBytes) {
            throw RepositoryError.sizeLimitExceeded
        }
        let data = try Data(contentsOf: snapshotURL)
        try Self.validateHeader(data, expectedFormat: "LocalChecklistStore")
        try SnapshotValidator.validateShape(data, backup: false)
        let envelope: StoreEnvelope
        do { envelope = try Self.decoder().decode(StoreEnvelope.self, from: data) }
        catch { throw RepositoryError.invalidData("invalid persisted field types or dates") }
        try envelope.payload.validate()
        if envelope.version == 1 {
            // Explicit, non-destructive v1 -> v2 migration. Invalid/unknown versions never reset the store.
            return try writeLocked(envelope.payload)
        }
        return envelope.payload
    }

    private func writeLocked(_ snapshot: AppSnapshot) throws -> AppSnapshot {
        try snapshot.validate()
        let data = try Self.encoder().encode(StoreEnvelope(format: "LocalChecklistStore", version: Self.currentVersion, payload: snapshot))
        guard data.count <= SnapshotValidator.maximumStoredBytes else { throw RepositoryError.sizeLimitExceeded }
        // Return exactly the JSON-round-tripped representation. Epoch conversion
        // can round a Date's sub-microsecond bits; callers must see the same value
        // a second process reads, including for idempotent completion checks.
        let persisted = try Self.decoder().decode(StoreEnvelope.self, from: data).payload
        try persisted.validate()
        try writeDataLocked(data, to: snapshotURL)
        return persisted
    }

    private func writeDataLocked(_ data: Data, to destination: URL) throws {
        guard data.count <= SnapshotValidator.maximumBytes else { throw RepositoryError.sizeLimitExceeded }
        #if canImport(Darwin)
        // Staging and destination are siblings, so rename() is atomic on this filesystem.
        // Validation, complete write, protection metadata and fsync all precede rename.
        let temporary = directory.appendingPathComponent(".snapshot-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw posixError("create staging file") }
        var descriptorOpen = true
        var committed = false
        defer {
            if descriptorOpen { _ = Darwin.close(descriptor) }
            if !committed { try? FileManager.default.removeItem(at: temporary) }
        }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { throw RepositoryError.io("Empty encoded store") }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw posixError("write staging file") }
                offset += written
            }
        }
        try applyStorageAttributes(at: temporary)
        guard Darwin.fsync(descriptor) == 0 else { throw posixError("sync staging file") }
        let closeResult = Darwin.close(descriptor)
        descriptorOpen = false
        guard closeResult == 0 else { throw posixError("close staging file") }
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw posixError("replace store") }
        committed = true
        do {
            // Atomic replacement may reset URL metadata. Reapply and read it back.
            try applyStorageAttributes(at: destination)
            try applyStorageAttributes(at: directory)
            let directoryDescriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY)
            guard directoryDescriptor >= 0 else { throw posixError("open storage directory") }
            defer { _ = Darwin.close(directoryDescriptor) }
            guard Darwin.fsync(directoryDescriptor) == 0 else { throw posixError("sync storage directory") }
        } catch {
            // The rename already committed. Never falsely report a rollback.
            throw RepositoryError.committedMetadataFailure(error.localizedDescription)
        }
        #else
        throw RepositoryError.io("This repository requires Apple platform flock/file-protection APIs")
        #endif
    }

    private func withExclusiveLock<Result>(_ body: () throws -> Result) throws -> Result {
        #if canImport(Darwin)
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw posixError("open transaction lock") }
        defer { _ = Darwin.close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw posixError("acquire transaction lock")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        try applyStorageAttributes(at: lockURL)
        return try body()
        #else
        throw RepositoryError.io("This repository requires Apple platform flock APIs")
        #endif
    }

    private func checkGeneration(_ expected: UUID?, current: AppSnapshot) throws {
        if let expected, expected != current.generation { throw RepositoryError.staleGeneration }
    }

    private func applyStorageAttributes(at url: URL) throws {
        #if (os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)) && !targetEnvironment(macCatalyst)
        // Widgets can read after the first unlock following boot. Before that,
        // protected-data errors are surfaced and must not be treated as empty data.
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        #if canImport(Darwin)
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
        mutableURL.removeAllCachedResourceValues()
        guard try mutableURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else {
            throw RepositoryError.io("Could not verify the backup-exclusion attribute")
        }
        #endif
    }

    #if canImport(Darwin)
    private func posixError(_ action: String) -> RepositoryError {
        let code = errno
        return .io("\(action): \(String(cString: strerror(code))) (\(code))")
    }
    #endif

    private static func validateHeader(_ data: Data, expectedFormat: String) throws {
        guard !data.isEmpty else { throw RepositoryError.invalidFormat }
        guard data.count <= SnapshotValidator.maximumBytes else { throw RepositoryError.sizeLimitExceeded }
        let header: EnvelopeHeader
        do { header = try decoder().decode(EnvelopeHeader.self, from: data) }
        catch { throw RepositoryError.invalidFormat }
        guard header.format == expectedFormat else { throw RepositoryError.invalidFormat }
        guard header.version == 1 || header.version == currentVersion else { throw RepositoryError.unsupportedVersion(header.version) }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

private struct EnvelopeHeader: Decodable {
    let format: String
    let version: Int
}

private struct StoreEnvelope: Codable {
    let format: String
    let version: Int
    let payload: AppSnapshot
}

private struct BackupEnvelope: Codable {
    let format: String
    let version: Int
    let exportedAt: Date
    let payload: AppSnapshot
}
