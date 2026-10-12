import XCTest
@testable import LocalChecklist

final class SyncLedgerTests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    private func item(_ title: String = "Original") -> TodoItem {
        TodoItem(id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!, title: title,
                 createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
    private func version(_ replica: UUID, _ count: UInt64, _ payload: SyncPayload?) -> SyncVersion {
        SyncVersion(clock: [replica.uuidString: count], payload: payload)
    }
    private func pair() throws -> (AppSnapshot, AppSnapshot) {
        let task = item(); let head = version(a, 1, .task(task))
        let envelope = SyncEnvelope(key: SyncPayload.task(task).key, heads: [head])
        var left = AppSnapshot(tasks: [task]); left.sync.replicaID = a; left.sync.counter = 1
        var right = AppSnapshot(tasks: [task]); right.sync.replicaID = b
        try left.sync.mergeRemote(envelope)
        try right.sync.mergeRemote(envelope)
        return (left, right)
    }
    private func change(_ state: AppSnapshot, _ edit: (inout AppSnapshot) -> Void) throws -> AppSnapshot {
        var next = state; edit(&next); try SyncLedger.recordLocalChanges(from: state, to: &next)
        try next.validate(); return next
    }

    func testOfflineEditsCoalesceCausallyAndRemainDurablyPending() throws {
        let (base, _) = try pair()
        let edited = try change(base) { $0.tasks[0].title = "First offline edit" }
        let twice = try change(edited) { $0.tasks[0].title = "Second offline edit" }
        let entry = try XCTUnwrap(twice.sync.entries.values.first)
        XCTAssertEqual(entry.heads.count, 1); XCTAssertTrue(entry.dirty)
        XCTAssertEqual(entry.heads.first?.clock[a.uuidString], 3)
        let restored = try SyncCoding.decoder().decode(AppSnapshot.self, from: SyncCoding.encoder().encode(twice))
        XCTAssertEqual(restored, twice)
    }
    func testConcurrentEditsPreserveBothVersionsAndConverge() throws {
        let (aState, bState) = try pair()
        var left = try change(aState) { $0.tasks[0].title = "iPhone edit" }
        var right = try change(bState) { $0.tasks[0].title = "Mac edit" }
        let key = SyncPayload.task(item()).key
        let leftHeads = left.sync.entries[key]!.heads; let rightHeads = right.sync.entries[key]!.heads
        try left.sync.mergeRemote(SyncEnvelope(key: key, heads: rightHeads))
        try right.sync.mergeRemote(SyncEnvelope(key: key, heads: leftHeads))
        XCTAssertEqual(left.sync.entries[key]?.heads, right.sync.entries[key]?.heads)
        XCTAssertEqual(left.sync.conflicts.count, 1); XCTAssertEqual(left.sync.conflicts[0].versions.count, 2)
    }
    func testConcurrentCompletionAndContentEditAreReviewable() throws {
        let (aState, bState) = try pair()
        var left = try change(aState) { $0.tasks[0].title = "Changed title" }
        let right = try change(bState) {
            $0.tasks[0].isCompleted = true; $0.tasks[0].completedAt = $0.tasks[0].createdAt
        }
        let key = SyncPayload.task(item()).key
        try left.sync.mergeRemote(SyncEnvelope(key: key, heads: right.sync.entries[key]!.heads))
        XCTAssertEqual(left.sync.conflicts.count, 1)
        XCTAssertTrue(left.sync.conflicts[0].versions.contains { $0.summary.contains("已完成") })
    }
    func testSameBusinessContentWithDifferentAuditTimesIsNotAConflict() throws {
        var first = item(); first.isCompleted = true; first.completedAt = first.createdAt.addingTimeInterval(10); first.updatedAt = first.completedAt!
        var second = first; second.completedAt = second.createdAt.addingTimeInterval(20); second.updatedAt = second.completedAt!
        let heads = [version(a, 1, .task(first)), version(b, 1, .task(second))]
        XCTAssertFalse(SyncEntry(heads: heads).hasConflict)
        XCTAssertEqual(try SyncEnvelope.merged([heads[0]], [heads[1]]).count, 2, "Keep both causal heads, even when no business conflict needs review")
        second.title = "Actual content change"
        XCTAssertTrue(SyncEntry(heads: [heads[0], version(b, 2, .task(second))]).hasConflict)
    }
    func testConcurrentDoubleDeleteIsNotAContentConflict() throws {
        let (aState, bState) = try pair()
        var left = try change(aState) { $0.tasks = [] }
        let right = try change(bState) { $0.tasks = [] }
        let key = SyncPayload.task(item()).key
        try left.sync.mergeRemote(SyncEnvelope(key: key, heads: right.sync.entries[key]!.heads))
        XCTAssertFalse(left.sync.entries[key]!.hasConflict)
        XCTAssertEqual(left.sync.entries[key]?.heads.count, 2) // Causal knowledge is retained.
        let ledger = left.sync; ledger.materialize(into: &left)
        XCTAssertTrue(left.tasks.isEmpty)
    }
    func testConcurrentDeleteAndEditPreservesLiveAndTombstone() throws {
        let (aState, bState) = try pair()
        var left = try change(aState) { $0.tasks = [] }
        let right = try change(bState) { $0.tasks[0].detail = "Important offline detail" }
        let key = SyncPayload.task(item()).key
        try left.sync.mergeRemote(SyncEnvelope(key: key, heads: right.sync.entries[key]!.heads))
        let ledger = left.sync; ledger.materialize(into: &left)
        XCTAssertEqual(left.tasks.first?.detail, "Important offline detail")
        XCTAssertEqual(left.sync.conflicts.count, 1)
        XCTAssertTrue(left.sync.conflicts[0].versions.contains( where: \.isDeleted))
    }
    func testAcknowledgementDoesNotClearNewerOfflineEdit() throws {
        let (base, _) = try pair(); let key = SyncPayload.task(item()).key
        let sent = try change(base) { $0.tasks[0].title = "Sent" }
        var newer = try change(sent) { $0.tasks[0].title = "Edited during network save" }
        try newer.sync.mergeRemote(SyncEnvelope(key: key, heads: sent.sync.entries[key]!.heads))
        XCTAssertTrue(newer.sync.entries[key]!.dirty)
        XCTAssertEqual(newer.sync.entries[key]?.heads.first?.payload?.title, "Edited during network save")
    }
    func testEquivalentHeadsAreIdempotent() throws {
        let (base, _) = try pair(); let key = SyncPayload.task(item()).key
        var ledger = base.sync
        let envelope = SyncEnvelope(key: key, heads: ledger.entries[key]!.heads)
        XCTAssertFalse(try ledger.mergeRemote(envelope))
        XCTAssertFalse(try ledger.mergeRemote(envelope))
        XCTAssertEqual(ledger.pendingCount, 0)
    }
    func testKnownConflictBlocksOrdinaryEditEvenWithHigherLocalCounter() throws {
        let task = item(); let key = SyncPayload.task(task).key
        let first = SyncVersion(clock: [a.uuidString: 5, b.uuidString: 1], payload: .task(task))
        let second = SyncVersion(clock: [a.uuidString: 6], payload: .task(item("Unseen local branch")))
        var state = AppSnapshot(tasks: [task]); state.sync.replicaID = a; state.sync.counter = 6
        state.sync.entries[key] = SyncEntry(heads: [first, second], preferredVersionID: first.id)
        XCTAssertThrowsError(try change(state) { $0.tasks[0].title = "Would erase other head" }) {
            XCTAssertEqual($0 as? SyncError, .unresolvedConflict)
        }
        XCTAssertEqual(state.sync.entries[key]?.heads.count, 2)
    }
    func testResolutionRequiresExactlyReviewedHeadSet() throws {
        let task = item(); let key = SyncPayload.task(task).key
        let first = version(a, 1, .task(task)); let second = version(b, 1, .task(item("B")))
        let third = version(c, 1, .task(item("C arrived after review")))
        var ledger = SyncLedger(); ledger.entries[key] = SyncEntry(heads: [first, second, third])
        XCTAssertThrowsError(try ledger.resolve(key: key, versionID: first.id, expectedHeadIDs: [first.id, second.id]))
        XCTAssertEqual(ledger.entries[key]?.heads.count, 3)
        try ledger.resolve(key: key, versionID: first.id, expectedHeadIDs: [first.id, second.id, third.id])
        XCTAssertEqual(ledger.entries[key]?.heads.count, 1)
        XCTAssertEqual(ledger.entries[key]?.heads.first?.payload?.title, task.title)
    }
    func testImportCreatesIndependentEpochAndDoesNotInferDeletes() throws {
        let (state, _) = try pair()
        var ledger = state.sync; ledger.enabled = true; ledger.peerBindingID = "pair-A"
        let imported = AppSnapshot(notes: [NoteItem(title: "From old backup")])
        let next = try ledger.pausedForImport(snapshot: imported)
        XCTAssertTrue(next.importRequiresReview); XCTAssertNotEqual(next.epoch, ledger.epoch)
        XCTAssertEqual(next.peerBindingID, "pair-A")
        XCTAssertEqual(next.installationID, ledger.installationID)
        XCTAssertNotEqual(next.replicaID, ledger.replicaID)
        XCTAssertNil(next.entries[SyncPayload.task(item()).key])
        XCTAssertFalse(next.entries.values.flatMap(\.heads).contains(where: \.isDeleted))
    }
    func testBackupRetainsConflictContentWithoutPeerOrDeviceIdentity() throws {
        let task = item(); let key = SyncPayload.task(task).key
        let first = version(a, 1, .task(task)); let deletion = version(b, 1, nil)
        var ledger = SyncLedger(); ledger.enabled = true; ledger.peerBindingID = "private-pair"
        ledger.entries[key] = SyncEntry(heads: [first, deletion])
        let portable = ledger.portableCopy()
        XCTAssertEqual(portable.entries[key]?.heads.map(\.payload), [first, deletion].map(\.payload))
        XCTAssertTrue(portable.entries[key]!.heads.allSatisfy { $0.id != first.id && $0.id != deletion.id })
        XCTAssertTrue(portable.entries[key]!.heads.allSatisfy { $0.clock[a.uuidString] == nil && $0.clock[b.uuidString] == nil })
        XCTAssertFalse(portable.enabled)
        XCTAssertNil(portable.peerBindingID)
        XCTAssertNil(portable.lastSuccessfulSync)
        XCTAssertNotEqual(portable.installationID, ledger.installationID)
        XCTAssertNotEqual(portable.replicaID, ledger.replicaID)
        let imported = try ledger.pausedForImport(snapshot: AppSnapshot(tasks: [task], sync: portable))
        XCTAssertEqual(imported.entries[key]?.heads.count, 2)
        XCTAssertTrue(imported.entries[key]!.heads.allSatisfy { $0.id != first.id && $0.id != deletion.id })
    }
    func testMissingParentListIsProjectedSafelyWithoutErasingReference() throws {
        let list = Checklist(title: "Arrives on later page")
        var task = item(); task.listID = list.id
        let key = SyncPayload.task(task).key
        var snapshot = AppSnapshot()
        try snapshot.sync.mergeRemote(SyncEnvelope(key: key, heads: [version(a, 1, .task(task))]))
        var ledger = snapshot.sync; ledger.materialize(into: &snapshot)
        XCTAssertNil(snapshot.tasks[0].listID); try snapshot.validate()
        try snapshot.sync.mergeRemote(SyncEnvelope(key: SyncPayload.list(list).key, heads: [version(a, 2, .list(list))]))
        ledger = snapshot.sync; ledger.materialize(into: &snapshot)
        XCTAssertEqual(snapshot.tasks[0].listID, list.id); try snapshot.validate()
    }
    func testLargeUnicodeNoteFitsBoundedWireItem() throws {
        let note = NoteItem(title: "Large note", body: String(repeating: "界", count: 400_000))
        let envelope = SyncEnvelope(key: SyncPayload.note(note).key, heads: [version(a, 1, .note(note))])
        try envelope.validate()
        let bytes = try SyncCoding.encoder().encode(envelope)
        XCTAssertGreaterThan(bytes.count, 1_024 * 1_024)
        XCTAssertLessThan(bytes.count, SyncEnvelope.maximumItemBytes)
    }
    func testClockDoesNotUseUpdatedAtToChooseWinner() throws {
        var oldWallClock = item("Causally newer")
        var futureWallClock = item("Causally older")
        oldWallClock.updatedAt = oldWallClock.createdAt
        futureWallClock.updatedAt = futureWallClock.createdAt.addingTimeInterval(100_000)
        let old = version(a, 1, .task(futureWallClock)); let new = version(a, 2, .task(oldWallClock))
        XCTAssertEqual(try SyncEnvelope.merged([old], [new]), [new])
    }
    func testDuplicateClockWithDifferentVersionsFailsClosed() throws {
        let task = item(); let first = version(a, 1, .task(task)); let second = version(a, 1, .task(item("Different")))
        XCTAssertThrowsError(try SyncEnvelope(key: SyncPayload.task(task).key, heads: [first, second]).validate())
    }
}
