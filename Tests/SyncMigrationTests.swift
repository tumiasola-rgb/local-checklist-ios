import XCTest
@testable import LocalChecklist

final class SyncMigrationTests: XCTestCase {
    private var root: URL!
    private var repository: SharedRepository!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MigrationTests-\(UUID().uuidString)")
        repository = try SharedRepository(directory: root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private var storeURL: URL { root.appendingPathComponent(SharedRepository.dataFileName) }
    private func oldEnvelope(backup: Bool) throws -> Data {
        let task = TodoItem(title: "Version one", detail: "Keep every field", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let snapshot = try repository.saveTask(task, isNew: true)
        var payload = try JSONSerialization.jsonObject(with: SyncCoding.encoder().encode(snapshot)) as! [String: Any]
        payload.removeValue(forKey: "sync")
        var envelope: [String: Any] = ["format": backup ? "LocalChecklistBackup" : "LocalChecklistStore", "version": 1, "payload": payload]
        if backup { envelope["exportedAt"] = 1_700_000_000_000 }
        return try JSONSerialization.data(withJSONObject: envelope)
    }
    func testVersionOneStoreMigratesExplicitlyWithoutResettingContentOrGeneration() throws {
        let bytes = try oldEnvelope(backup: false)
        let before = try repository.read()
        try bytes.write(to: storeURL)
        let migrated = try repository.read()
        XCTAssertEqual(migrated.tasks, before.tasks); XCTAssertEqual(migrated.generation, before.generation)
        XCTAssertEqual(migrated.revision, before.revision); XCTAssertFalse(migrated.sync.enabled)
        XCTAssertNil(migrated.sync.peerBindingID)
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as! [String: Any]
        XCTAssertEqual(root["version"] as? Int, 2)
        XCTAssertNotNil((root["payload"] as? [String: Any])?["sync"])
    }
    func testVersionOneBackupImportsIntoIndependentPausedEpoch() throws {
        let bytes = try oldEnvelope(backup: true)
        let current = try repository.read(); let preview = try repository.previewImport(bytes)
        let result = try repository.replace(with: preview, expectedGeneration: current.generation)
        XCTAssertEqual(result.tasks, current.tasks); XCTAssertTrue(result.sync.importRequiresReview)
        XCTAssertNotEqual(result.sync.epoch, current.sync.epoch)
        XCTAssertEqual(result.sync.pendingCount, 1)
    }
    func testVersionTwoMissingJournalCannotDecodeAsFreshState() throws {
        _ = try repository.saveNote(NoteItem(title: "Must preserve"), isNew: true)
        let before = try Data(contentsOf: storeURL)
        var object = try JSONSerialization.jsonObject(with: repository.exportData()) as! [String: Any]
        var payload = object["payload"] as! [String: Any]; payload.removeValue(forKey: "sync"); object["payload"] = payload
        XCTAssertThrowsError(try repository.previewImport(JSONSerialization.data(withJSONObject: object)))
        XCTAssertEqual(try Data(contentsOf: storeURL), before)
    }
    func testVersionTwoProjectionMismatchRejectsRatherThanChoosingOldBody() throws {
        _ = try repository.saveNote(NoteItem(title: "Body", body: "Canonical body"), isNew: true)
        let before = try Data(contentsOf: storeURL)
        var object = try JSONSerialization.jsonObject(with: repository.exportData()) as! [String: Any]
        var payload = object["payload"] as! [String: Any]
        var notes = payload["notes"] as! [[String: Any]]; notes[0]["body"] = "Different visible body"
        payload["notes"] = notes; object["payload"] = payload
        XCTAssertThrowsError(try repository.previewImport(JSONSerialization.data(withJSONObject: object)))
        XCTAssertEqual(try Data(contentsOf: storeURL), before)
    }
    func testUnknownSyncMetadataDoesNotSilentlyDisappear() throws {
        _ = try repository.saveTask(TodoItem(title: "Keep"), isNew: true)
        var object = try JSONSerialization.jsonObject(with: repository.exportData()) as! [String: Any]
        var payload = object["payload"] as! [String: Any]; var sync = payload["sync"] as! [String: Any]
        sync["futureUserContent"] = "must not be dropped"; payload["sync"] = sync; object["payload"] = payload
        XCTAssertThrowsError(try repository.previewImport(JSONSerialization.data(withJSONObject: object)))
    }
    func testFutureStoreVersionIsRejectedWithoutDeletingOriginalBytes() throws {
        _ = try repository.read()
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as! [String: Any]
        object["version"] = 3
        let bytes = try JSONSerialization.data(withJSONObject: object); try bytes.write(to: storeURL)
        XCTAssertThrowsError(try repository.read()) { XCTAssertEqual($0 as? RepositoryError, .unsupportedVersion(3)) }
        XCTAssertEqual(try Data(contentsOf: storeURL), bytes)
    }
    func testInvalidSyncTransactionLeavesContentAndPendingExactlyUnchanged() throws {
        let task = TodoItem(title: "Durable")
        try repository.saveTask(task, isNew: true)
        let before = try Data(contentsOf: storeURL)
        XCTAssertThrowsError(try repository.updateSync { state in
            state.tasks[0].title = "Unjournaled mutation"
        })
        XCTAssertEqual(try Data(contentsOf: storeURL), before)
        XCTAssertEqual(try repository.read().sync.pendingCount, 1)
    }
    func testDuplicateLocalIDsThrowBeforeDictionaryConstruction() throws {
        let task = TodoItem(title: "No process trap")
        try repository.saveTask(task, isNew: true)
        let before = try Data(contentsOf: storeURL)
        XCTAssertThrowsError(try repository.update { $0.tasks.append($0.tasks[0]) })
        XCTAssertEqual(try Data(contentsOf: storeURL), before)
    }
    func testRecurringCompletionDoesNotDuplicateOrResurrectNextInstance() throws {
        var task = TodoItem(title: "Daily", startDay: DayStamp(rawValue: "2026-10-06"))
        task.schedule = TaskScheduleOptions(isAllDay: true, timeZoneIdentifier: "UTC", recurrence: TaskRecurrence(frequency: .daily))
        try repository.saveTask(task, isNew: true)
        let first = try repository.setTaskCompleted(id: task.id, isCompleted: true)
        XCTAssertEqual(first.tasks.count, 2)
        let next = try XCTUnwrap(first.tasks.first(where: { $0.id != task.id }))
        XCTAssertEqual(next.startDay?.rawValue, "2026-10-07")
        try repository.setTaskCompleted(id: task.id, isCompleted: false)
        try repository.setTaskCompleted(id: task.id, isCompleted: true)
        XCTAssertEqual(try repository.read().tasks.count, 2)
        try repository.deleteTask(id: next.id)
        try repository.setTaskCompleted(id: task.id, isCompleted: false)
        let repeated = try repository.setTaskCompleted(id: task.id, isCompleted: true)
        XCTAssertEqual(repeated.tasks.count, 1)
        XCTAssertTrue(repeated.sync.entries[SyncPayload.task(next).key]!.heads.allSatisfy(\.isDeleted))
    }
    func testOldDeleteConfirmationCannotRemoveChangedContent() throws {
        let saved = try repository.saveNote(NoteItem(title: "Original"), isNew: true)
        let original = saved.notes[0]
        try repository.update { $0.notes[0].body = "Arrived since delete dialog opened" }
        XCTAssertThrowsError(try repository.deleteNote(id: original.id, expectedOriginal: original)) {
            XCTAssertEqual($0 as? RepositoryError, .staleContent)
        }
        XCTAssertEqual(try repository.read().notes.count, 1)
    }
}
