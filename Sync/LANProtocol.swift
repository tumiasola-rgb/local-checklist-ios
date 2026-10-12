import Foundation
import CryptoKit

internal enum LANFrameKind: String, Codable, Hashable, Sendable {
    case hello, pairingApproval, pairingReady, packetStart, packetChunk, packetEnd, receipt, finished, failure
}
internal struct LANFrame: Codable, Sendable {
    var schema = 1
    var sessionID: UUID
    var sequence: UInt64
    var kind: LANFrameKind
    var deviceID: UUID?
    var pairID: UUID?
    var deviceName: String?
    var nonce: Data?
    var mode: String?
    var approved: Bool?
    var transferID: UUID?
    var transactionID: UUID?
    var totalBytes: Int?
    var digest: String?
    var acknowledgedDigest: String?
    var index: Int?
    var chunk: Data?
    var message: String?

    func validateShape(_ bytes: Data) throws {
        guard schema == 1, bytes.count <= 65_536,
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw LANFailure.protocolViolation("invalid frame schema") }
        let base: Set<String> = ["schema", "sessionID", "sequence", "kind"]
        let fields: Set<String>; let optional: Set<String>
        switch kind {
        case .hello: fields = ["deviceID", "pairID", "deviceName", "nonce", "mode"]; optional = []
        case .pairingApproval: fields = ["approved"]; optional = []
        case .pairingReady: fields = ["pairID"]; optional = []
        case .packetStart: fields = ["transferID", "transactionID", "totalBytes", "digest"]; optional = ["acknowledgedDigest"]
        case .packetChunk: fields = ["transferID", "index", "chunk"]; optional = []
        case .packetEnd: fields = ["transferID", "digest"]; optional = []
        case .receipt, .finished: fields = ["transactionID", "digest"]; optional = []
        case .failure: fields = ["message"]; optional = []
        }
        let keys = Set(object.keys)
        guard base.union(fields).isSubset(of: keys), keys.isSubset(of: base.union(fields).union(optional)),
              (deviceName?.count ?? 0) <= 64, (nonce?.count ?? 0) <= 32, (message?.count ?? 0) <= 1000 else {
            throw LANFailure.protocolViolation("unexpected/missing frame fields")
        }
    }
}

/// Only causal user-content versions travel, never device permissions, pairing
/// secrets, local installation binding, settings, or whole-store replacement.
internal struct LANPacket: Codable, Equatable, Sendable {
    static let maximumBytes = 20 * 1_024 * 1_024
    let schema: Int
    let transactionID: UUID
    let senderDeviceID: UUID
    let records: [SyncEnvelope]
    init(transactionID: UUID, senderDeviceID: UUID, records: [SyncEnvelope]) {
        schema = 1; self.transactionID = transactionID; self.senderDeviceID = senderDeviceID; self.records = records
    }
    func encoded() throws -> Data {
        try validate()
        let data = try SyncCoding.encoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw LANFailure.sizeLimit }
        return data
    }
    func validate() throws {
        guard schema == 1, records.count <= 100_000, Set(records.map(\.key)).count == records.count else {
            throw LANFailure.protocolViolation("duplicate items or unsupported packet")
        }
        for record in records { try record.validate() }
    }
    static func decode(_ data: Data) throws -> LANPacket {
        guard data.count <= maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schema", "transactionID", "senderDeviceID", "records"],
              let records = object["records"] as? [[String: Any]], records.count <= 100_000 else { throw LANFailure.sizeLimit }
        for record in records { try SnapshotValidator.validateSyncWireShape(JSONSerialization.data(withJSONObject: record)) }
        let packet = try SyncCoding.decoder().decode(LANPacket.self, from: data)
        try packet.validate(); return packet
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// One owner runs a conversation sequentially. Network framing/TLS lives in
/// LANByteChannel; this layer binds all messages to a fresh session and monotonic
/// direction-specific sequence. It cannot resume a different/old transaction.
internal final class LANConversation: @unchecked Sendable {
    let channel: any LANByteChannel
    private(set) var sessionID: UUID?
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    init(channel: any LANByteChannel, sessionID: UUID? = nil) { self.channel = channel; self.sessionID = sessionID }

    func send(_ kind: LANFrameKind, configure: (inout LANFrame) -> Void = { _ in }) async throws {
        guard let sessionID, sent < UInt64.max else { throw LANFailure.protocolViolation("missing/overflow session") }
        var frame = LANFrame(sessionID: sessionID, sequence: sent, kind: kind)
        configure(&frame)
        let bytes = try SyncCoding.encoder().encode(frame); try frame.validateShape(bytes)
        guard bytes.count <= 65_536 else { throw LANFailure.sizeLimit }
        try await channel.send(bytes); sent += 1
    }
    func receive(_ kinds: Set<LANFrameKind>) async throws -> LANFrame {
        let bytes = try await channel.receive()
        guard bytes.count <= 65_536 else { throw LANFailure.sizeLimit }
        let frame = try SyncCoding.decoder().decode(LANFrame.self, from: bytes)
        try frame.validateShape(bytes)
        guard received < UInt64.max, frame.sequence == received else { throw LANFailure.protocolViolation("replayed/out-of-order frame") }
        if let sessionID {
            guard frame.sessionID == sessionID else { throw LANFailure.protocolViolation("wrong session") }
        } else {
            guard frame.kind == .hello, frame.sequence == 0 else { throw LANFailure.protocolViolation("session must begin with authenticated hello") }
            sessionID = frame.sessionID
        }
        received += 1
        if frame.kind == .failure { throw SyncError.failed(frame.message ?? "对端停止了此次操作。") }
        guard kinds.contains(frame.kind) else { throw LANFailure.protocolViolation("unexpected frame phase") }
        return frame
    }
    @discardableResult
    func sendPacket(_ packet: LANPacket, acknowledging: String? = nil) async throws -> String {
        let bytes = try packet.encoded(); let digest = LANPacket.digest(bytes); let transfer = UUID()
        try await send(.packetStart) {
            $0.transferID = transfer; $0.transactionID = packet.transactionID; $0.totalBytes = bytes.count
            $0.digest = digest; $0.acknowledgedDigest = acknowledging
        }
        var offset = 0; var index = 0
        // 32 KiB raw bytes remain below 64 KiB after JSON/Base64 framing.
        while offset < bytes.count {
            let end = min(offset + 32_768, bytes.count); let chunk = bytes.subdata(in: offset..<end)
            try await send(.packetChunk) { $0.transferID = transfer; $0.index = index; $0.chunk = chunk }
            offset = end; index += 1
        }
        try await send(.packetEnd) { $0.transferID = transfer; $0.digest = digest }
        return digest
    }
    func receivePacket(transactionID: UUID? = nil, from deviceID: UUID, acknowledging expectedAck: String? = nil) async throws -> (packet: LANPacket, digest: String) {
        let start = try await receive([.packetStart])
        guard let transfer = start.transferID, let transaction = start.transactionID,
              transactionID == nil || transactionID == transaction,
              let total = start.totalBytes, total > 0, total <= LANPacket.maximumBytes,
              let expectedDigest = start.digest, expectedDigest.count == 64,
              start.acknowledgedDigest == expectedAck else { throw LANFailure.invalidReceipt }
        var bytes = Data(); bytes.reserveCapacity(total)
        var index = 0
        while bytes.count < total {
            let frame = try await receive([.packetChunk])
            guard frame.transferID == transfer, frame.index == index,
                  let chunk = frame.chunk, chunk.count == min(32_768, total - bytes.count) else { throw LANFailure.protocolViolation("invalid chunk bounds/order") }
            bytes.append(chunk); index += 1
        }
        let end = try await receive([.packetEnd])
        guard end.transferID == transfer, end.digest == expectedDigest, LANPacket.digest(bytes) == expectedDigest else {
            throw LANFailure.protocolViolation("packet digest mismatch")
        }
        // No repository access occurs until the full bounded transfer validates.
        let packet = try LANPacket.decode(bytes)
        guard packet.transactionID == transaction, packet.senderDeviceID == deviceID else { throw LANFailure.protocolViolation("packet identity mismatch") }
        return (packet, expectedDigest)
    }
    func close() async { await channel.close() }
}
