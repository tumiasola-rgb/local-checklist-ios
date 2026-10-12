import Foundation

internal struct LANExchangeScope: Sendable {
    let generation: UUID
    let epoch: UUID
    let installationID: UUID
    let pair: LANPairRecord
    func check(_ snapshot: AppSnapshot) throws {
        guard snapshot.generation == generation, snapshot.sync.epoch == epoch,
              snapshot.sync.installationID == installationID,
              pair.installationID == installationID,
              snapshot.sync.peerBindingID == pair.pairID.uuidString else { throw SyncError.interrupted }
        guard snapshot.sync.enabled else { throw SyncError.disabled }
        guard !snapshot.sync.importRequiresReview else { throw SyncError.importReviewRequired }
    }
}
internal struct LANPreparedPacket: Sendable {
    let packet: LANPacket
    let pendingCount: Int
}
internal final class LANRunProgress: @unchecked Sendable {
    // Single exchange-task owner. UI reads only after that task has returned/thrown.
    var uploadedConfirmed = 0
    var downloadedCommitted = 0
}

/// No network call runs inside a file lock. Each content/ack write is one complete
/// transaction, and a replacement import invalidates every earlier scope.
internal struct LANExchangeRepository: Sendable {
    let repository: SharedRepository
    let scope: LANExchangeScope
    func prepare(transactionID: UUID) throws -> LANPreparedPacket {
        let snapshot = try repository.updateSync { state in
            try scope.check(state)
            var ledger = state.sync; try ledger.seed(from: state); state.sync = ledger
        }
        let records = snapshot.sync.entries.sorted { $0.key < $1.key }.map { SyncEnvelope(key: $0.key, heads: $0.value.heads) }
        let packet = LANPacket(transactionID: transactionID, senderDeviceID: scope.pair.localDeviceID, records: records)
        _ = try packet.encoded() // Preflight the complete bounded packet before sending a header.
        return LANPreparedPacket(packet: packet, pendingCount: snapshot.sync.pendingCount)
    }
    func merge(_ packet: LANPacket) throws -> Int {
        guard packet.senderDeviceID == scope.pair.peerDeviceID else { throw LANFailure.protocolViolation("wrong authenticated device") }
        _ = try packet.encoded()
        var changed = 0
        try repository.updateSync { snapshot in
            try scope.check(snapshot)
            // A migrated v1 store can have live content with no journal yet.
            // Seed it before projection so first-time receive cannot erase it.
            var seeded = snapshot.sync; try seeded.seed(from: snapshot); snapshot.sync = seeded
            for record in packet.records {
                if try snapshot.sync.mergeRemote(record) { changed += 1 }
            }
            let ledger = snapshot.sync; ledger.materialize(into: &snapshot)
        }
        NotificationCenter.default.post(name: .localChecklistSyncDidCommit, object: nil)
        return changed
    }
    func acknowledge(_ packet: LANPacket) throws {
        guard packet.senderDeviceID == scope.pair.localDeviceID else { throw LANFailure.invalidReceipt }
        try repository.updateSync { state in
            try scope.check(state); state.sync.acknowledge(packet.records)
        }
    }
    func finish(progress: LANRunProgress) throws -> SyncReport {
        let state = try repository.updateSync { state in
            try scope.check(state)
            state.sync.lastFailure = nil
            if state.sync.pendingCount == 0 && state.sync.conflicts.isEmpty { state.sync.lastSuccessfulSync = Date() }
        }
        NotificationCenter.default.post(name: .localChecklistSyncDidCommit, object: nil)
        return SyncReport(uploaded: progress.uploadedConfirmed, downloaded: progress.downloadedCommitted,
                          conflicts: state.sync.conflicts.count, pendingChanges: state.sync.pendingCount,
                          lastSuccessfulSync: state.sync.lastSuccessfulSync)
    }
}

/// Protocol assumes LANConversation is already on a TLS-authenticated connection
/// with the exact persistent pair and both hello identities checked. Temporary
/// pairing channels never call these methods.
internal enum LANExchange {
    static func initiate(conversation: LANConversation, bridge: LANExchangeRepository,
                         progress: LANRunProgress, checkRuntime: @Sendable () async throws -> Void) async throws -> SyncReport {
        try await checkRuntime()
        let transaction = UUID()
        let outgoing = try bridge.prepare(transactionID: transaction)
        let sentDigest = try await conversation.sendPacket(outgoing.packet)
        let incoming = try await conversation.receivePacket(transactionID: transaction,
                                                             from: bridge.scope.pair.peerDeviceID, acknowledging: sentDigest)
        try await checkRuntime()
        // Response includes an authenticated receipt for the exact request digest,
        // emitted only after the peer's atomic merge. Still preserve any local edit
        // made while the packet was in flight.
        progress.downloadedCommitted += try bridge.merge(incoming.packet)
        progress.uploadedConfirmed += outgoing.pendingCount
        try await checkRuntime()
        try await conversation.send(.receipt) { $0.transactionID = transaction; $0.digest = incoming.digest }
        let finished = try await conversation.receive([.finished])
        guard finished.transactionID == transaction, finished.digest == incoming.digest else { throw LANFailure.invalidReceipt }
        try await checkRuntime()
        return try bridge.finish(progress: progress)
    }

    static func respond(conversation: LANConversation, bridge: LANExchangeRepository,
                        progress: LANRunProgress, checkRuntime: @Sendable () async throws -> Void) async throws -> SyncReport {
        let incoming = try await conversation.receivePacket(from: bridge.scope.pair.peerDeviceID)
        try await checkRuntime()
        progress.downloadedCommitted += try bridge.merge(incoming.packet)
        try await checkRuntime()
        let outgoing = try bridge.prepare(transactionID: incoming.packet.transactionID)
        let sentDigest = try await conversation.sendPacket(outgoing.packet, acknowledging: incoming.digest)
        let receipt = try await conversation.receive([.receipt])
        guard receipt.transactionID == incoming.packet.transactionID, receipt.digest == sentDigest else { throw LANFailure.invalidReceipt }
        try await checkRuntime()
        try bridge.acknowledge(outgoing.packet)
        progress.uploadedConfirmed += outgoing.pendingCount
        let report = try bridge.finish(progress: progress)
        try await conversation.send(.finished) { $0.transactionID = incoming.packet.transactionID; $0.digest = sentDigest }
        return report
    }
}
