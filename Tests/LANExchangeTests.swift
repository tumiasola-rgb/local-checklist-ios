import Foundation
import XCTest
@testable import LocalChecklist

private struct LANTestHookChannel: LANByteChannel {
    let base: LANTestChannel
    var beforeSend: (@Sendable (Data) async throws -> Void)?
    var afterReceive: (@Sendable (Data) async throws -> Void)?
    func send(_ data: Data) async throws {
        try await beforeSend?(data)
        try await base.send(data)
    }
    func receive() async throws -> Data {
        let data = try await base.receive()
        try await afterReceive?(data)
        return data
    }
    func close() async { await base.close() }
}

private struct LANExchangeFixture: Sendable {
    let root: URL
    let left: SharedRepository
    let right: SharedRepository
    let leftBridge: LANExchangeRepository
    let rightBridge: LANExchangeRepository

    init(legacyRightTask: TodoItem? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LANExchangeTests-\(UUID().uuidString)")
        left = try SharedRepository(directory: root.appendingPathComponent("iPhone"))
        right = try SharedRepository(directory: root.appendingPathComponent("Mac"))
        _ = try left.read()
        var rightSnapshot = try right.read()
        if let task = legacyRightTask {
            rightSnapshot.tasks = [task]
            var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: SyncCoding.encoder().encode(rightSnapshot)) as? [String: Any])
            payload.removeValue(forKey: "sync")
            let legacy: [String: Any] = ["format": "LocalChecklistStore", "version": 1, "payload": payload]
            try JSONSerialization.data(withJSONObject: legacy).write(to: right.directory.appendingPathComponent(SharedRepository.dataFileName))
        }

        let pairID = UUID(), leftID = UUID(), rightID = UUID()
        let leftState = try left.updateSync { $0.sync.enabled = true; $0.sync.peerBindingID = pairID.uuidString }
        let rightState = try right.updateSync { $0.sync.enabled = true; $0.sync.peerBindingID = pairID.uuidString }
        // PUBLIC FIXED TEST-ONLY BYTES. Never use as a production pairing key.
        // Records remain in memory; no Security/Keychain API is called by fixtures.
        let testOnlySecret = Data((0..<32).map { UInt8($0) })
        let leftPair = LANPairRecord(pairID: pairID, localDeviceID: leftID, peerDeviceID: rightID,
            peerName: "Test Mac", secret: testOnlySecret, installationID: leftState.sync.installationID)
        let rightPair = LANPairRecord(pairID: pairID, localDeviceID: rightID, peerDeviceID: leftID,
            peerName: "Test iPhone", secret: testOnlySecret, installationID: rightState.sync.installationID)
        try leftPair.validate(); try rightPair.validate()
        leftBridge = LANExchangeRepository(repository: left, scope: LANExchangeScope(generation: leftState.generation,
            epoch: leftState.sync.epoch, installationID: leftState.sync.installationID, pair: leftPair))
        rightBridge = LANExchangeRepository(repository: right, scope: LANExchangeScope(generation: rightState.generation,
            epoch: rightState.sync.epoch, installationID: rightState.sync.installationID, pair: rightPair))
    }

    func removeFiles() { try? FileManager.default.removeItem(at: root) }

    func seedCommonTask() throws -> TodoItem {
        let task = TodoItem(title: "Shared original", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try left.saveTask(task, isNew: true)
        let prepared = try leftBridge.prepare(transactionID: UUID())
        _ = try rightBridge.merge(prepared.packet)
        try leftBridge.acknowledge(prepared.packet)
        return try XCTUnwrap(left.read().tasks.first)
    }
}

private func closeLANOnFailure<Value: Sendable>(
    _ conversation: LANConversation, operation: () async throws -> Value
) async throws -> Value {
    do { return try await operation() }
    catch { await conversation.close(); throw error }
}

private func runLANExchange(
    _ fixture: LANExchangeFixture,
    leftBeforeSend: (@Sendable (Data) async throws -> Void)? = nil,
    rightBeforeSend: (@Sendable (Data) async throws -> Void)? = nil
) async throws -> (SyncReport, SyncReport) {
    try await withLANTestChannels { left, right in
        // LANExchange's production caller has already authenticated TLS and both
        // hello identities. Pure exchange tests explicitly assume that boundary.
        let session = UUID()
        let first = LANConversation(channel: LANTestHookChannel(base: left, beforeSend: leftBeforeSend), sessionID: session)
        let second = LANConversation(channel: LANTestHookChannel(base: right, beforeSend: rightBeforeSend), sessionID: session)
        async let firstReport = closeLANOnFailure(first) {
            try await LANExchange.initiate(conversation: first, bridge: fixture.leftBridge,
                progress: LANRunProgress(), checkRuntime: { try Task.checkCancellation() })
        }
        async let secondReport = closeLANOnFailure(second) {
            try await LANExchange.respond(conversation: second, bridge: fixture.rightBridge,
                progress: LANRunProgress(), checkRuntime: { try Task.checkCancellation() })
        }
        return try await (firstReport, secondReport)
    }
}

final class LANExchangeTests: XCTestCase {
    func testEmptyPeerCannotEraseUnseededMigratedVersionOneContent() async throws {
        let original = TodoItem(title: "Present before journal migration", detail: "Keep this local content",
                                createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let fixture = try LANExchangeFixture(legacyRightTask: original)
        defer { fixture.removeFiles() }
        XCTAssertTrue(try fixture.right.read().sync.entries.isEmpty)
        XCTAssertEqual(try fixture.right.read().tasks, [original])
        let reports = try await runLANExchange(fixture)
        XCTAssertEqual(try fixture.left.read().tasks, [original])
        XCTAssertEqual(try fixture.right.read().tasks, [original])
        XCTAssertEqual(reports.0.pendingChanges, 0)
        XCTAssertEqual(reports.1.pendingChanges, 0)
        XCTAssertNotNil(reports.0.lastSuccessfulSync)
        XCTAssertNotNil(reports.1.lastSuccessfulSync)
    }

    func testDistinctOfflineAdditionsConvergeWithoutReplacingEitherStore() async throws {
        let fixture = try LANExchangeFixture(); defer { fixture.removeFiles() }
        let first = TodoItem(title: "Offline iPhone task"), second = TodoItem(title: "Offline Mac task")
        try fixture.left.saveTask(first, isNew: true)
        try fixture.right.saveTask(second, isNew: true)
        let reports = try await runLANExchange(fixture)
        let left = try fixture.left.read(), right = try fixture.right.read()
        XCTAssertEqual(Set(left.tasks.map(\.id)), [first.id, second.id])
        XCTAssertEqual(Set(right.tasks.map(\.id)), [first.id, second.id])
        XCTAssertEqual(left.sync.entries.mapValues(\.heads), right.sync.entries.mapValues(\.heads))
        XCTAssertEqual(reports.0.uploaded, 1); XCTAssertEqual(reports.1.uploaded, 1)
        XCTAssertEqual(left.sync.pendingCount, 0); XCTAssertEqual(right.sync.pendingCount, 0)
    }

    func testConcurrentSameItemEditsPreserveBothReviewableHeads() async throws {
        let fixture = try LANExchangeFixture(); defer { fixture.removeFiles() }
        let original = try fixture.seedCommonTask(), key = SyncPayload.task(original).key
        var phone = original; phone.title = "iPhone edit"
        var mac = original; mac.title = "Mac edit"
        try fixture.left.saveTask(phone, isNew: false); try fixture.right.saveTask(mac, isNew: false)
        let reports = try await runLANExchange(fixture)
        let left = try fixture.left.read(), right = try fixture.right.read()
        let heads = try XCTUnwrap(left.sync.entries[key]?.heads)
        XCTAssertEqual(heads.count, 2)
        XCTAssertEqual(Set(heads.compactMap { $0.payload?.title }), [phone.title, mac.title])
        XCTAssertEqual(heads, right.sync.entries[key]?.heads)
        XCTAssertEqual(reports.0.conflicts, 1); XCTAssertEqual(reports.1.conflicts, 1)
        XCTAssertNil(reports.0.lastSuccessfulSync); XCTAssertNil(reports.1.lastSuccessfulSync)
    }

    func testTwoOfflineRecurringCompletionsCreateOneSuccessorWithoutAuditConflict() async throws {
        let fixture = try LANExchangeFixture(); defer { fixture.removeFiles() }
        let original = try fixture.seedCommonTask()
        try fixture.left.update {
            $0.tasks[0].startDay = DayStamp(rawValue: "2026-10-06")
            $0.tasks[0].schedule = TaskScheduleOptions(isAllDay: true, timeZoneIdentifier: "UTC", recurrence: TaskRecurrence(frequency: .daily))
        }
        _ = try await runLANExchange(fixture)
        try fixture.left.setTaskCompleted(id: original.id, isCompleted: true)
        try fixture.right.setTaskCompleted(id: original.id, isCompleted: true)
        _ = try await runLANExchange(fixture)
        let left = try fixture.left.read(), right = try fixture.right.read()
        XCTAssertEqual(left.tasks.count, 2); XCTAssertEqual(right.tasks.count, 2)
        XCTAssertEqual(Set(left.tasks.map(\.id)), Set(right.tasks.map(\.id)))
        XCTAssertTrue(left.sync.conflicts.isEmpty); XCTAssertTrue(right.sync.conflicts.isEmpty)
        XCTAssertEqual(left.tasks.filter { !$0.isCompleted }.count, 1)
    }

    func testConcurrentScheduleDifferenceUsesSameSuccessorIDAndPreservesConflict() async throws {
        let fixture = try LANExchangeFixture(); defer { fixture.removeFiles() }
        let original = try fixture.seedCommonTask()
        try fixture.left.update {
            $0.tasks[0].startDay = DayStamp(rawValue: "2026-10-06"); $0.tasks[0].timeMinutes = 540
            $0.tasks[0].schedule = TaskScheduleOptions(isAllDay: false, timeZoneIdentifier: "UTC", recurrence: TaskRecurrence(frequency: .daily))
        }
        _ = try await runLANExchange(fixture)
        try fixture.right.update { $0.tasks[0].timeMinutes = 600 }
        try fixture.left.setTaskCompleted(id: original.id, isCompleted: true)
        try fixture.right.setTaskCompleted(id: original.id, isCompleted: true)
        let leftNext = try XCTUnwrap(fixture.left.read().tasks.first(where: { $0.id != original.id }))
        let rightNext = try XCTUnwrap(fixture.right.read().tasks.first(where: { $0.id != original.id }))
        XCTAssertEqual(leftNext.id, rightNext.id)
        _ = try await runLANExchange(fixture)
        let left = try fixture.left.read()
        XCTAssertEqual(left.tasks.count, 2)
        XCTAssertEqual(left.sync.entries[SyncPayload.task(leftNext).key]?.hasConflict, true)
    }

    func testConcurrentDoubleDeleteRetainsCausalityWithoutConflictOrResurrection() async throws {
        let fixture = try LANExchangeFixture(); defer { fixture.removeFiles() }
        let original = try fixture.seedCommonTask(), key = SyncPayload.task(original).key
        try fixture.left.deleteTask(id: original.id); try fixture.right.deleteTask(id: original.id)
        let reports = try await runLANExchange(fixture)
        let left = try fixture.left.read(), right = try fixture.right.read()
        let heads = try XCTUnwrap(left.sync.entries[key]?.heads)
        XCTAssertEqual(heads.count, 2); XCTAssertTrue(heads.allSatisfy(\.isDeleted))
        XCTAssertEqual(heads, right.sync.entries[key]?.heads)
        XCTAssertTrue(left.tasks.isEmpty); XCTAssertTrue(right.tasks.isEmpty)
        XCTAssertEqual(reports.0.conflicts, 0); XCTAssertEqual(reports.1.conflicts, 0)
        _ = try await runLANExchange(fixture)
        XCTAssertTrue(try fixture.left.read().tasks.isEmpty)
        XCTAssertEqual(try fixture.right.read().sync.entries[key]?.heads, heads)
    }

    func testConcurrentDeleteAndEditRetainsTombstoneAndLiveContent() async throws {
        let fixture = try LANExchangeFixture(); defer { fixture.removeFiles() }
        let original = try fixture.seedCommonTask(), key = SyncPayload.task(original).key
        var edited = original; edited.detail = "Important Mac offline detail"
        try fixture.left.deleteTask(id: original.id); try fixture.right.saveTask(edited, isNew: false)
        _ = try await runLANExchange(fixture)
        for repository in [fixture.left, fixture.right] {
            let snapshot = try repository.read(), entry = try XCTUnwrap(snapshot.sync.entries[key])
            XCTAssertTrue(entry.hasConflict); XCTAssertEqual(entry.heads.count, 2)
            XCTAssertEqual(entry.heads.filter(\.isDeleted).count, 1)
            XCTAssertEqual(snapshot.tasks.first?.detail, edited.detail)
        }
    }

    func testEditWhileResponseIsInFlightRemainsDirtyUntilNextExchange() async throws {
        let fixture = try LANExchangeFixture(); defer { fixture.removeFiles() }
        let original = try fixture.seedCommonTask(), key = SyncPayload.task(original).key
        var sent = original; sent.title = "Version in request"
        try fixture.left.saveTask(sent, isNew: false)
        var edited = sent; edited.title = "New iPhone edit during response"
        let laterEdit = edited
        let reports = try await runLANExchange(fixture, rightBeforeSend: { data in
            if try SyncCoding.decoder().decode(LANFrame.self, from: data).kind == .packetStart {
                try fixture.left.saveTask(laterEdit, isNew: false)
            }
        })
        XCTAssertEqual(try fixture.left.read().tasks.first?.title, laterEdit.title)
        XCTAssertEqual(try fixture.left.read().sync.entries[key]?.dirty, true)
        XCTAssertEqual(try fixture.right.read().tasks.first?.title, sent.title)
        XCTAssertEqual(reports.0.pendingChanges, 1); XCTAssertNil(reports.0.lastSuccessfulSync)
        _ = try await runLANExchange(fixture)
        XCTAssertEqual(try fixture.right.read().tasks.first?.title, laterEdit.title)
        XCTAssertEqual(try fixture.left.read().sync.pendingCount, 0)
    }

    func testEditDuringReceiptCannotBeClearedByOlderPacketAcknowledgement() async throws {
        let fixture = try LANExchangeFixture(); defer { fixture.removeFiles() }
        let original = try fixture.seedCommonTask(), key = SyncPayload.task(original).key
        var sent = original; sent.title = "Version in response"
        try fixture.right.saveTask(sent, isNew: false)
        var edited = sent; edited.title = "New Mac edit while ACK is in flight"
        let laterEdit = edited
        let reports = try await runLANExchange(fixture, leftBeforeSend: { data in
            if try SyncCoding.decoder().decode(LANFrame.self, from: data).kind == .receipt {
                try fixture.right.saveTask(laterEdit, isNew: false)
            }
        })
        XCTAssertEqual(try fixture.right.read().sync.entries[key]?.dirty, true)
        XCTAssertEqual(try fixture.right.read().tasks.first?.title, laterEdit.title)
        XCTAssertEqual(try fixture.left.read().tasks.first?.title, sent.title)
        XCTAssertEqual(reports.1.pendingChanges, 1); XCTAssertNil(reports.1.lastSuccessfulSync)
        _ = try await runLANExchange(fixture)
        XCTAssertEqual(try fixture.left.read().tasks.first?.title, laterEdit.title)
        XCTAssertEqual(try fixture.right.read().sync.pendingCount, 0)
    }

    func testReplacementImportInvalidatesPreparedAcknowledgementAndMergeScope() throws {
        let fixture = try LANExchangeFixture(); defer { fixture.removeFiles() }
        _ = try fixture.seedCommonTask()
        let prepared = try fixture.leftBridge.prepare(transactionID: UUID())
        let remote = try fixture.rightBridge.prepare(transactionID: UUID())
        let before = try fixture.left.read()
        let preview = try fixture.left.previewImport(fixture.left.exportData())
        let imported = try fixture.left.replace(with: preview, expectedGeneration: before.generation)
        XCTAssertNotEqual(imported.generation, before.generation)
        XCTAssertNotEqual(imported.sync.epoch, before.sync.epoch)
        XCTAssertTrue(imported.sync.importRequiresReview)
        XCTAssertEqual(imported.sync.installationID, before.sync.installationID)
        XCTAssertThrowsError(try fixture.leftBridge.acknowledge(prepared.packet)) {
            XCTAssertEqual($0 as? SyncError, .interrupted)
        }
        XCTAssertThrowsError(try fixture.leftBridge.merge(remote.packet))
        XCTAssertEqual(try fixture.left.read(), imported)
        XCTAssertGreaterThan(imported.sync.pendingCount, 0)
    }

    func testDropBeforePeerReceiptDoesNotClaimUploadOrClearPending() async throws {
        let fixture = try LANExchangeFixture(); defer { fixture.removeFiles() }
        try fixture.left.saveTask(TodoItem(title: "Never confirmed"), isNew: true)
        let progress = LANRunProgress()
        try await withLANTestChannels { left, right in
            let session = UUID()
            let client = LANConversation(channel: left, sessionID: session)
            let peer = LANConversation(channel: right, sessionID: session)
            async let outcome: Void = assertLANThrows {
                _ = try await LANExchange.initiate(conversation: client, bridge: fixture.leftBridge,
                    progress: progress, checkRuntime: { try Task.checkCancellation() })
            }
            _ = try await peer.receivePacket(from: fixture.leftBridge.scope.pair.localDeviceID)
            // Receiving bytes alone is not an atomic repository commit or receipt.
            await peer.close()
            await outcome
        }
        XCTAssertEqual(progress.uploadedConfirmed, 0)
        XCTAssertEqual(try fixture.left.read().sync.pendingCount, 1)
        XCTAssertNil(try fixture.left.read().sync.lastSuccessfulSync)
    }

    func testBadReceiptDoesNotAcknowledgeRespondersLocalPendingVersion() async throws {
        let fixture = try LANExchangeFixture(); defer { fixture.removeFiles() }
        try fixture.right.saveTask(TodoItem(title: "Responder must retain pending"), isNew: true)
        let progress = LANRunProgress()
        try await withLANTestChannels { left, right in
            let session = UUID(), transaction = UUID()
            let peer = LANConversation(channel: left, sessionID: session)
            let server = LANConversation(channel: right, sessionID: session)
            async let outcome: Void = assertLANThrows {
                _ = try await closeLANOnFailure(server) {
                    try await LANExchange.respond(conversation: server, bridge: fixture.rightBridge,
                        progress: progress, checkRuntime: { try Task.checkCancellation() })
                }
            }
            let packet = LANPacket(transactionID: transaction,
                senderDeviceID: fixture.leftBridge.scope.pair.localDeviceID, records: [])
            let requestDigest = try await peer.sendPacket(packet)
            _ = try await peer.receivePacket(transactionID: transaction,
                from: fixture.rightBridge.scope.pair.localDeviceID, acknowledging: requestDigest)
            try await peer.send(.receipt) { $0.transactionID = transaction; $0.digest = String(repeating: "0", count: 64) }
            await outcome
        }
        XCTAssertEqual(progress.uploadedConfirmed, 0)
        XCTAssertEqual(try fixture.right.read().sync.pendingCount, 1)
        XCTAssertNil(try fixture.right.read().sync.lastSuccessfulSync)
    }

    func testInterruptedPartialReceiveNeverMergesTheValidPrefix() async throws {
        let fixture = try LANExchangeFixture(); defer { fixture.removeFiles() }
        try fixture.right.saveTask(TodoItem(title: "Original receiver content"), isNew: true)
        let before = try fixture.right.read()
        let packet = lanTestPacket(sender: fixture.leftBridge.scope.pair.localDeviceID)
        let bytes = try packet.encoded(), digest = LANPacket.digest(bytes)
        let chunkObserved = expectation(description: "Receiver consumed a complete data chunk")
        try await withLANTestChannels { left, right in
            let session = UUID(), transfer = UUID()
            let peer = LANConversation(channel: left, sessionID: session)
            let monitored = LANTestHookChannel(base: right, afterReceive: { data in
                if try SyncCoding.decoder().decode(LANFrame.self, from: data).kind == .packetChunk {
                    chunkObserved.fulfill()
                }
            })
            let server = LANConversation(channel: monitored, sessionID: session)
            async let outcome: Void = assertLANThrows {
                _ = try await LANExchange.respond(conversation: server, bridge: fixture.rightBridge,
                    progress: LANRunProgress(), checkRuntime: { try Task.checkCancellation() })
            }
            try await peer.send(.packetStart) {
                $0.transferID = transfer; $0.transactionID = packet.transactionID
                $0.totalBytes = bytes.count; $0.digest = digest
            }
            try await peer.send(.packetChunk) { $0.transferID = transfer; $0.index = 0; $0.chunk = bytes }
            let wait = await XCTWaiter.fulfillment(of: [chunkObserved], timeout: 2)
            XCTAssertEqual(wait, .completed)
            XCTAssertEqual(try fixture.right.read(), before)
            // Drop before packetEnd: even a valid JSON prefix must not be applied.
            await peer.close()
            await outcome
        }
        XCTAssertEqual(try fixture.right.read(), before)
    }

    func testInvalidLaterRecordRejectsWholePacketWithoutPartialRepositoryWrite() throws {
        let fixture = try LANExchangeFixture(); defer { fixture.removeFiles() }
        try fixture.right.saveTask(TodoItem(title: "Existing receiver task"), isNew: true)
        let before = try fixture.right.read()
        let valid = lanTestPacket(sender: fixture.leftBridge.scope.pair.localDeviceID)
        let invalid = SyncEnvelope(key: "note.\(UUID().uuidString.lowercased())", heads: [])
        let packet = LANPacket(transactionID: valid.transactionID, senderDeviceID: valid.senderDeviceID,
                               records: valid.records + [invalid])
        XCTAssertThrowsError(try fixture.rightBridge.merge(packet))
        XCTAssertEqual(try fixture.right.read(), before)
        XCTAssertTrue(try fixture.right.read().notes.isEmpty)
    }

    func testPortableExportRerootsIdentitiesAndCannotGrantPeerPermissions() throws {
        let fixture = try LANExchangeFixture(); defer { fixture.removeFiles() }
        let original = try fixture.seedCommonTask(), key = SyncPayload.task(original).key
        let local = try fixture.left.read()
        let exported = try fixture.left.exportData()
        let portable = try fixture.left.previewImport(exported).snapshot
        XCTAssertFalse(portable.sync.enabled); XCTAssertNil(portable.sync.peerBindingID)
        XCTAssertNil(portable.sync.lastSuccessfulSync)
        XCTAssertNotEqual(portable.sync.installationID, local.sync.installationID)
        XCTAssertNotEqual(portable.sync.replicaID, local.sync.replicaID)
        let oldHeads = try XCTUnwrap(local.sync.entries[key]?.heads)
        let newHeads = try XCTUnwrap(portable.sync.entries[key]?.heads)
        XCTAssertEqual(newHeads.map(\.payload), oldHeads.map(\.payload))
        XCTAssertTrue(Set(newHeads.map(\.id)).isDisjoint(with: Set(oldHeads.map(\.id))))
        let oldReplicas = Set(oldHeads.flatMap { $0.clock.keys })
        XCTAssertTrue(Set(newHeads.flatMap { $0.clock.keys }).isDisjoint(with: oldReplicas))
        let text = try XCTUnwrap(String(data: exported, encoding: .utf8))
        XCTAssertFalse(text.contains(fixture.leftBridge.scope.pair.secret.base64EncodedString()))
        XCTAssertFalse(text.contains(fixture.leftBridge.scope.pair.pairID.uuidString))
        XCTAssertFalse(text.contains(fixture.leftBridge.scope.pair.localDeviceID.uuidString))
    }

    func testConflictResolutionRejectsStaleReviewThenPropagatesExactReviewedChoice() async throws {
        let fixture = try LANExchangeFixture(); defer { fixture.removeFiles() }
        let original = try fixture.seedCommonTask(), key = SyncPayload.task(original).key
        var first = original; first.title = "Choose iPhone content"
        var second = original; second.title = "Other Mac content"
        try fixture.left.saveTask(first, isNew: false); try fixture.right.saveTask(second, isNew: false)
        _ = try await runLANExchange(fixture)
        let before = try fixture.left.read()
        let heads = try XCTUnwrap(before.sync.entries[key]?.heads)
        let chosen = try XCTUnwrap(heads.first(where: { $0.payload?.title == first.title }))
        XCTAssertThrowsError(try fixture.left.updateSync { state in
            try state.sync.resolve(key: key, versionID: chosen.id, expectedHeadIDs: [chosen.id])
            let ledger = state.sync; ledger.materialize(into: &state)
        })
        XCTAssertEqual(try fixture.left.read(), before)
        try fixture.left.updateSync { state in
            try state.sync.resolve(key: key, versionID: chosen.id, expectedHeadIDs: Set(heads.map(\.id)))
            let ledger = state.sync; ledger.materialize(into: &state)
        }
        _ = try await runLANExchange(fixture)
        for repository in [fixture.left, fixture.right] {
            let state = try repository.read()
            XCTAssertEqual(state.tasks.first?.title, first.title)
            XCTAssertEqual(state.sync.entries[key]?.heads.count, 1)
            XCTAssertEqual(state.sync.pendingCount, 0); XCTAssertTrue(state.sync.conflicts.isEmpty)
        }
    }
}
