import XCTest
@testable import LocalChecklist

final class SharedRepositoryTests: XCTestCase {
    private var directory: URL!
    private var repository: SharedRepository!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalChecklistTests-\(UUID().uuidString)", isDirectory: true)
        repository = try SharedRepository(directory: directory)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
        repository = nil
        directory = nil
    }

    #if STANDALONE_APP
    func testStandaloneStoreUsesApplicationSupportWithoutAppGroupConfiguration() throws {
        let testBundle = Bundle(for: SharedRepositoryTests.self)
        XCTAssertNil(testBundle.object(forInfoDictionaryKey: "AppGroupIdentifier"))
        let store = try SharedRepository(bundle: testBundle)
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: false)
        XCTAssertEqual(store.directory, support.appendingPathComponent("LocalChecklist", isDirectory: true).standardizedFileURL)
    }
    #endif

    func testInitialStoreIsEmptyAndGenerationIsStableAcrossInstances() throws {
        let first = try repository.read()
        XCTAssertTrue(first.tasks.isEmpty)
        XCTAssertTrue(first.notes.isEmpty)
        XCTAssertTrue(first.anniversaries.isEmpty)
        XCTAssertTrue(first.lists.isEmpty)
        XCTAssertNil(first.settings.widgetCalendarMonth)
        XCTAssertEqual(first.revision, 0)
        let second = try SharedRepository(directory: directory).read()
        XCTAssertEqual(first, second)
        XCTAssertNil(try repository.readRecoveryPreview())
    }

    func testBackupRoundTripPreservesIDsStatusesDatesAndSettings() throws {
        let original = try installFixture()
        let data = try repository.exportData()
        let preview = try repository.previewImport(data)
        assertContentEqual(preview.snapshot, original)
        XCTAssertFalse(preview.snapshot.sync.enabled)
        XCTAssertNil(preview.snapshot.sync.peerBindingID)
        XCTAssertEqual(preview.counts.tasks, 1)
        XCTAssertEqual(preview.counts.notes, 1)
        XCTAssertEqual(preview.counts.anniversaries, 1)
        XCTAssertEqual(preview.counts.lists, 1)
        let replacement = try repository.replace(with: preview, expectedGeneration: original.generation)
        XCTAssertNotEqual(replacement.generation, original.generation)
        XCTAssertEqual(replacement.revision, original.revision + 1)
        XCTAssertEqual(replacement.tasks, original.tasks)
        XCTAssertEqual(replacement.notes, original.notes)
        XCTAssertEqual(replacement.anniversaries, original.anniversaries)
        XCTAssertEqual(replacement.lists, original.lists)
        XCTAssertEqual(replacement.settings, original.settings)
        XCTAssertEqual(replacement.settings.widgetCalendarMonth?.rawValue, "2026-11-01")
        assertContentEqual(try XCTUnwrap(repository.readRecoveryPreview()).snapshot, original)
    }

    func testVersionOneFilesWithoutWidgetMonthRemainReadable() throws {
        let original = try installFixture()
        var backup = try JSONSerialization.jsonObject(with: repository.exportData()) as! [String: Any]
        var payload = backup["payload"] as! [String: Any]
        var settings = payload["settings"] as! [String: Any]
        settings.removeValue(forKey: "widgetCalendarMonth")
        payload["settings"] = settings
        payload.removeValue(forKey: "sync")
        backup["version"] = 1
        backup["payload"] = payload
        let preview = try repository.previewImport(JSONSerialization.data(withJSONObject: backup))
        XCTAssertNil(preview.snapshot.settings.widgetCalendarMonth)
        XCTAssertEqual(preview.snapshot.settings.searchHistory, original.settings.searchHistory)

        var store = try JSONSerialization.jsonObject(with: storedBytes()) as! [String: Any]
        store["payload"] = payload
        store["version"] = 1
        try JSONSerialization.data(withJSONObject: store).write(to: directory.appendingPathComponent(SharedRepository.dataFileName))
        let loaded = try repository.read()
        XCTAssertNil(loaded.settings.widgetCalendarMonth)
        XCTAssertEqual(loaded.generation, original.generation)
        XCTAssertEqual(loaded.tasks, original.tasks)
    }

    func testWidgetMonthRejectsNonFirstDaysAndMalformedDates() throws {
        let invalidValues: [Any] = ["2026-11-02", "2026-13-01", "not a date", 20261101]
        for invalid in invalidValues {
            try assertRejectedPayload { payload in
                var settings = payload["settings"] as! [String: Any]
                settings["widgetCalendarMonth"] = invalid
                payload["settings"] = settings
            }
        }
        let original = try installFixture()
        let before = try storedBytes()
        XCTAssertThrowsError(try repository.update { $0.settings.widgetCalendarMonth = DayStamp(rawValue: "2026-11-02") })
        XCTAssertEqual(try storedBytes(), before)
        let followingCurrent = try repository.update { $0.settings.widgetCalendarMonth = nil }
        XCTAssertNil(followingCurrent.settings.widgetCalendarMonth)
        XCTAssertEqual(followingCurrent.settings.searchHistory, original.settings.searchHistory)
    }

    func testRecoveryRestoresPreImportStateAndPreservesPreRestoreState() throws {
        let first = try installFixture()
        let oldPreview = try repository.previewImport(repository.exportData())
        let changed = try repository.update { $0.tasks[0].title = "A newer title" }
        let imported = try repository.replace(with: oldPreview, expectedGeneration: first.generation)
        XCTAssertEqual(imported.tasks[0].title, first.tasks[0].title)
        let recovery = try XCTUnwrap(repository.readRecoveryPreview())
        XCTAssertEqual(recovery.snapshot.tasks[0].title, changed.tasks[0].title)
        let restored = try repository.replace(with: recovery, expectedGeneration: imported.generation)
        XCTAssertEqual(restored.tasks, changed.tasks)
        XCTAssertEqual(try repository.readRecoveryPreview()?.snapshot.tasks, imported.tasks)
    }

    func testRecoveryWriteFailureLeavesPrimaryStoreUntouched() throws {
        let original = try installFixture()
        let preview = try repository.previewImport(repository.exportData())
        let before = try storedBytes()
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("pre-import.json"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try repository.replace(with: preview, expectedGeneration: original.generation))
        XCTAssertEqual(try storedBytes(), before)
        XCTAssertEqual(try repository.read(), original)
    }

    func testPreviewDoesNotWriteOrReplaceAnything() throws {
        _ = try installFixture()
        let before = try storedBytes()
        _ = try repository.previewImport(repository.exportData())
        XCTAssertEqual(try storedBytes(), before)
        XCTAssertNil(try repository.readRecoveryPreview())
    }

    func testMalformedAndOversizedImportsPreserveExistingData() throws {
        _ = try installFixture()
        let before = try storedBytes()
        for data in [Data(), Data("not JSON".utf8), Data("{\"format\":true}".utf8), Data(repeating: 32, count: 20 * 1_024 * 1_024 + 1)] {
            XCTAssertThrowsError(try repository.previewImport(data))
            XCTAssertEqual(try storedBytes(), before)
        }
    }

    func testFutureVersionIsRejectedBeforePayloadDecode() throws {
        let data = Data("{\"format\":\"LocalChecklistBackup\",\"version\":999,\"payload\":false}".utf8)
        XCTAssertThrowsError(try repository.previewImport(data)) { error in
            XCTAssertEqual(error as? RepositoryError, .unsupportedVersion(999))
        }
    }

    func testRejectsMissingUnknownAndWrongTypedFields() throws {
        try assertRejected { $0.removeValue(forKey: "exportedAt") }
        try assertRejected { $0["unrecognized"] = "must not silently disappear" }
        try assertRejectedPayload { $0["tasks"] = "not an array" }
        try assertRejectedPayload { $0["revision"] = -1 }
        try assertRejectedTask { $0["isCompleted"] = "true" }
        try assertRejectedTask { $0["id"] = "invalid uuid" }
        try assertRejectedTask { $0["unexpectedField"] = true }
        try assertRejectedTask { $0.removeValue(forKey: "title") }
        try assertRejectedTask { $0["createdAt"] = "yesterday" }
    }

    func testRejectsDuplicateIDsAndDanglingForeignKeys() throws {
        try assertRejectedPayload { payload in
            var tasks = payload["tasks"] as! [[String: Any]]
            tasks.append(tasks[0]); payload["tasks"] = tasks
        }
        try assertRejectedPayload { payload in
            let taskID = (payload["tasks"] as! [[String: Any]])[0]["id"]!
            var notes = payload["notes"] as! [[String: Any]]
            notes[0]["id"] = taskID; payload["notes"] = notes
        }
        try assertRejectedTask { $0["listID"] = UUID().uuidString }
        try assertRejectedPayload { payload in
            var settings = payload["settings"] as! [String: Any]
            settings["defaultListID"] = UUID().uuidString; payload["settings"] = settings
        }
    }

    func testRejectsInvalidDatesTimesStatusAndTags() throws {
        try assertRejectedTask { $0["startDay"] = "2025-02-29" }
        try assertRejectedTask { $0["startDay"] = "2026-03-12"; $0["endDay"] = "2026-03-11" }
        try assertRejectedTask { $0["timeMinutes"] = 1440 }
        try assertRejectedTask { $0["timeMinutes"] = -1 }
        try assertRejectedTask { $0.removeValue(forKey: "startDay"); $0.removeValue(forKey: "endDay") }
        try assertRejectedTask { $0["isCompleted"] = false }
        try assertRejectedTask { $0.removeValue(forKey: "completedAt") }
        try assertRejectedTask { $0["tags"] = ["same", "Same"] }
        try assertRejectedTask { $0["title"] = "  \n" }
        try assertRejectedTask { $0["updatedAt"] = 0 }
        try assertRejectedPayload { payload in
            var settings = payload["settings"] as! [String: Any]
            settings["firstWeekday"] = 8; payload["settings"] = settings
        }
    }

    func testCorruptPersistedStoreIsNotSilentlyResetOrOverwritten() throws {
        _ = try installFixture()
        let corrupted = Data("{broken store".utf8)
        try corrupted.write(to: directory.appendingPathComponent(SharedRepository.dataFileName))
        XCTAssertThrowsError(try repository.read())
        XCTAssertThrowsError(try repository.saveTask(TodoItem(title: "Must not replace old bytes")))
        XCTAssertEqual(try storedBytes(), corrupted)
    }

    func testFuturePersistedStoreAndMalformedPayloadArePreserved() throws {
        _ = try installFixture()
        var object = try JSONSerialization.jsonObject(with: storedBytes()) as! [String: Any]
        object["version"] = 42
        let future = try JSONSerialization.data(withJSONObject: object)
        try future.write(to: directory.appendingPathComponent(SharedRepository.dataFileName))
        XCTAssertThrowsError(try repository.read())
        XCTAssertEqual(try storedBytes(), future)
        object["version"] = 1
        var payload = object["payload"] as! [String: Any]
        payload["tasks"] = false; object["payload"] = payload
        let malformed = try JSONSerialization.data(withJSONObject: object)
        try malformed.write(to: directory.appendingPathComponent(SharedRepository.dataFileName))
        XCTAssertThrowsError(try repository.read())
        XCTAssertEqual(try storedBytes(), malformed)
    }

    func testThrowingOrInvalidTransactionLeavesExactOldBytes() throws {
        _ = try installFixture()
        let before = try storedBytes()
        enum TestFailure: Error { case intentional }
        XCTAssertThrowsError(try repository.update { state in
            state.tasks.removeAll()
            throw TestFailure.intentional
        })
        XCTAssertEqual(try storedBytes(), before)
        XCTAssertThrowsError(try repository.update { $0.tasks[0].title = "" })
        XCTAssertEqual(try storedBytes(), before)
        XCTAssertThrowsError(try repository.update { $0.generation = UUID() })
        XCTAssertEqual(try storedBytes(), before)
        XCTAssertThrowsError(try repository.update { $0.revision += 1 })
        XCTAssertEqual(try storedBytes(), before)
    }

    func testImportedGenerationBlocksStaleEditorsAndWidgetIntents() throws {
        let original = try installFixture()
        let preview = try repository.previewImport(repository.exportData())
        let imported = try repository.replace(with: preview, expectedGeneration: original.generation)
        XCTAssertThrowsError(try repository.setTaskCompleted(id: original.tasks[0].id, isCompleted: false, expectedGeneration: original.generation)) { error in
            XCTAssertEqual(error as? RepositoryError, .staleGeneration)
        }
        XCTAssertThrowsError(try repository.saveTask(original.tasks[0], expectedGeneration: original.generation))
        XCTAssertThrowsError(try repository.replace(with: preview, expectedGeneration: original.generation))
        XCTAssertEqual(try repository.read(), imported)
    }

    func testExplicitCompletionIsIdempotentAndEditableSavePreservesLatestStatus() throws {
        let draft = TodoItem(title: "Initial")
        let saved = try repository.saveTask(draft, isNew: true)
        let completed = try repository.setTaskCompleted(id: draft.id, isCompleted: true, expectedGeneration: saved.generation)
        let duplicate = try repository.setTaskCompleted(id: draft.id, isCompleted: true, expectedGeneration: saved.generation)
        XCTAssertEqual(duplicate, completed)
        var staleEditor = draft
        staleEditor.title = "Edited while widget completed it"
        let edited = try repository.saveTask(staleEditor, isNew: false, expectedGeneration: saved.generation)
        XCTAssertTrue(edited.tasks[0].isCompleted)
        XCTAssertEqual(edited.tasks[0].completedAt, completed.tasks[0].completedAt)
        XCTAssertEqual(edited.tasks[0].title, staleEditor.title)
        let reopened = try repository.setTaskCompleted(id: draft.id, isCompleted: false)
        XCTAssertFalse(reopened.tasks[0].isCompleted)
        XCTAssertNil(reopened.tasks[0].completedAt)
    }

    func testReturnedSnapshotMatchesPersistedTimestampRepresentation() throws {
        let precise = Date(timeIntervalSinceReferenceDate: 812_345_678.1234567)
        let task = TodoItem(title: "Fractional date", createdAt: precise)
        let saved = try repository.saveTask(task)
        XCTAssertEqual(saved, try repository.read())
        let completed = try repository.setTaskCompleted(id: task.id, isCompleted: true)
        XCTAssertEqual(completed, try repository.read())
        assertContentEqual(try repository.previewImport(repository.exportData()).snapshot, completed)
    }

    func testNoteContentEditPreservesPinAndDeletedEditorCannotResurrectRecord() throws {
        let note = NoteItem(title: "A note")
        _ = try repository.saveNote(note, isNew: true)
        _ = try repository.setNotePinned(id: note.id, isPinned: true)
        var edited = note; edited.body = "More content"
        let result = try repository.saveNote(edited, isNew: false)
        XCTAssertTrue(result.notes[0].isPinned)
        _ = try repository.deleteNote(id: note.id)
        XCTAssertThrowsError(try repository.saveNote(edited, isNew: false))
        XCTAssertTrue(try repository.read().notes.isEmpty)
        let task = TodoItem(title: "Task")
        _ = try repository.saveTask(task, isNew: true)
        _ = try repository.deleteTask(id: task.id)
        XCTAssertThrowsError(try repository.saveTask(task, isNew: false))
    }

    func testIndependentRepositoryInstancesDoNotLoseConcurrentEdits() throws {
        let first = try repository.read()
        let directory = try XCTUnwrap(self.directory)
        let errors = LockedErrors()
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            do {
                let independent = try SharedRepository(directory: directory)
                try independent.saveTask(TodoItem(title: "Task \(index)"), isNew: true, expectedGeneration: first.generation)
            } catch { errors.append(error) }
        }
        XCTAssertTrue(errors.values.isEmpty, errors.values.map(\.localizedDescription).joined(separator: "\n"))
        let result = try repository.read()
        XCTAssertEqual(result.tasks.count, 64)
        XCTAssertEqual(Set(result.tasks.map(\.title)).count, 64)
        XCTAssertEqual(result.revision, 64)
        XCTAssertEqual(result.generation, first.generation)
    }

    func testDeleteListUnlinksTasksAndDefaultWithoutDeletingTasks() throws {
        let original = try installFixture()
        let result = try repository.deleteList(id: original.lists[0].id)
        XCTAssertTrue(result.lists.isEmpty)
        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertNil(result.tasks[0].listID)
        XCTAssertNil(result.settings.defaultListID)
    }

    func testSearchHistoryIsBoundedDeduplicatedAndExported() throws {
        for index in 0..<35 { _ = try repository.recordSearch("query \(index)") }
        _ = try repository.recordSearch("  QUERY 34  ")
        let result = try repository.read()
        XCTAssertEqual(result.settings.searchHistory.count, 30)
        XCTAssertEqual(result.settings.searchHistory.first, "QUERY 34")
        XCTAssertEqual(result.settings.searchHistory.filter { $0.lowercased() == "query 34" }.count, 1)
        XCTAssertEqual(try repository.previewImport(repository.exportData()).snapshot.settings.searchHistory, result.settings.searchHistory)
    }

    func testBackupExclusionIsReappliedAfterReplacement() throws {
        #if canImport(Darwin)
        let first = try installFixture()
        let preview = try repository.previewImport(repository.exportData())
        _ = try repository.replace(with: preview, expectedGeneration: first.generation)
        for url in [directory!, directory.appendingPathComponent(SharedRepository.dataFileName), directory.appendingPathComponent("pre-import.json"), directory.appendingPathComponent("transaction.lock")] {
            XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        }
        #endif
    }

    @discardableResult
    private func installFixture() throws -> AppSnapshot {
        // Explicit test-only sample; no production startup path seeds user data.
        try repository.update { state in
            let created = Date(timeIntervalSince1970: 1_700_000_000)
            let updated = created.addingTimeInterval(10)
            let list = Checklist(title: "Test list", colorHex: "#123ABC")
            state.lists = [list]
            state.tasks = [TodoItem(title: "Test task", detail: "Private local detail", listID: list.id, tags: ["test"],
                                   startDay: DayStamp(rawValue: "2026-03-08"), endDay: DayStamp(rawValue: "2026-03-10"),
                                   timeMinutes: 540, isCompleted: true, completedAt: updated, createdAt: created, updatedAt: updated)]
            state.notes = [NoteItem(title: "Test note", body: "Local note body", tags: ["note"], isPinned: true, createdAt: created, updatedAt: updated)]
            state.anniversaries = [Anniversary(title: "Leap day", day: DayStamp(rawValue: "2024-02-29")!, emoji: "🌱", repeatYearly: true)]
            state.settings = Settings(firstWeekday: 1, showLunar: false, searchHistory: ["local", "test"], defaultListID: list.id,
                                      widgetCalendarMonth: DayStamp(rawValue: "2026-11-01"))
        }
    }

    private func assertContentEqual(_ lhs: AppSnapshot, _ rhs: AppSnapshot, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.tasks, rhs.tasks, file: file, line: line)
        XCTAssertEqual(lhs.notes, rhs.notes, file: file, line: line)
        XCTAssertEqual(lhs.anniversaries, rhs.anniversaries, file: file, line: line)
        XCTAssertEqual(lhs.lists, rhs.lists, file: file, line: line)
        XCTAssertEqual(lhs.settings, rhs.settings, file: file, line: line)
    }

    private func storedBytes() throws -> Data { try Data(contentsOf: directory.appendingPathComponent(SharedRepository.dataFileName)) }

    private func assertRejected(_ change: (inout [String: Any]) -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
        _ = try installFixture()
        let before = try storedBytes()
        var object = try JSONSerialization.jsonObject(with: repository.exportData()) as! [String: Any]
        change(&object)
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try repository.previewImport(data), file: file, line: line)
        XCTAssertEqual(try storedBytes(), before, file: file, line: line)
    }

    private func assertRejectedPayload(_ change: (inout [String: Any]) -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
        try assertRejected({ object in
            var payload = object["payload"] as! [String: Any]
            change(&payload); object["payload"] = payload
        }, file: file, line: line)
    }

    private func assertRejectedTask(_ change: (inout [String: Any]) -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
        try assertRejectedPayload({ payload in
            var tasks = payload["tasks"] as! [[String: Any]]
            change(&tasks[0]); payload["tasks"] = tasks
        }, file: file, line: line)
    }
}

private final class LockedErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Error] = []
    func append(_ error: Error) { lock.lock(); defer { lock.unlock() }; storage.append(error) }
    var values: [Error] { lock.lock(); defer { lock.unlock() }; return storage }
}
