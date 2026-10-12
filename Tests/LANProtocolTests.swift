import Foundation
import XCTest
@testable import LocalChecklist

// Test-only, in-memory framed transport. It deliberately makes no claim about
// Network.framework, TLS, Bonjour, device permissions, or the real Keychain.
enum LANTestTransportError: Error { case closed, concurrentReceive, timedOut }

private actor LANTestInbox {
    private var queued: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private var failure: LANTestTransportError?

    func push(_ data: Data) throws {
        if let failure { throw failure }
        if let pending = waiter {
            waiter = nil
            pending.resume(returning: data)
        } else {
            queued.append(data)
        }
    }

    func pop() async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let failure { throw failure }
            if !queued.isEmpty { return queued.removeFirst() }
            guard waiter == nil else { throw LANTestTransportError.concurrentReceive }
            return try await withCheckedThrowingContinuation { waiter = $0 }
        } onCancel: {
            Task { await self.close() }
        }
    }

    func close(_ error: LANTestTransportError = .closed) {
        guard failure == nil else { return }
        failure = error
        queued.removeAll()
        let pending = waiter
        waiter = nil
        pending?.resume(throwing: error)
    }
}

struct LANTestChannel: LANByteChannel {
    private let input: LANTestInbox
    private let output: LANTestInbox

    static func pair() -> (LANTestChannel, LANTestChannel) {
        let left = LANTestInbox(), right = LANTestInbox()
        return (Self(input: left, output: right), Self(input: right, output: left))
    }

    func send(_ data: Data) async throws { try await output.push(data) }
    func receive() async throws -> Data { try await input.pop() }
    func close() async { await input.close(); await output.close() }
    func expire() async { await input.close(.timedOut); await output.close(.timedOut) }
}

/// A deadline closes both inboxes before cancellation, including failure paths.
/// Thus malformed-peer tests cannot strand a continuation or hang the test run.
func withLANTestChannels<Value: Sendable>(
    _ operation: @escaping @Sendable (LANTestChannel, LANTestChannel) async throws -> Value
) async throws -> Value {
    let (left, right) = LANTestChannel.pair()
    return try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation(left, right) }
        group.addTask {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            await left.expire()
            throw LANTestTransportError.timedOut
        }
        do {
            let result = try await group.next()!
            await left.close()
            group.cancelAll()
            return result
        } catch {
            await left.close()
            group.cancelAll()
            throw error
        }
    }
}

func assertLANThrows(
    file: StaticString = #filePath, line: UInt = #line,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("Expected the invalid or interrupted exchange to fail", file: file, line: line)
    } catch is CancellationError {
        XCTFail("Cancellation is not evidence of protocol rejection", file: file, line: line)
    } catch LANTestTransportError.timedOut {
        XCTFail("The test timed out rather than rejecting input", file: file, line: line)
    } catch { }
}

func lanTestPacket(sender: UUID = UUID(), body: String = "Public fixture") -> LANPacket {
    let note = NoteItem(title: "Protocol fixture", body: body,
                        createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    let version = SyncVersion(clock: [UUID().uuidString: 1], payload: .note(note))
    return LANPacket(transactionID: UUID(), senderDeviceID: sender,
                     records: [SyncEnvelope(key: SyncPayload.note(note).key, heads: [version])])
}

final class LANProtocolTests: XCTestCase {
    func testFrameLengthBoundariesAndNonzeroIndexDataSlice() throws {
        for length in [1, 255, 256, 32_768, 65_535, 65_536] {
            let header = try LANFrameCodec.encodeLength(length)
            XCTAssertEqual(header.count, 4)
            XCTAssertEqual(try LANFrameCodec.decodeLength(header), length)
            var padded = Data([99, 98, 97]); padded.append(header); padded.append(96)
            let slice = padded[3..<7]
            XCTAssertEqual(slice.startIndex, 3)
            XCTAssertEqual(try LANFrameCodec.decodeLength(slice), length)
        }
        XCTAssertEqual(try LANFrameCodec.encodeLength(65_536), Data([0, 1, 0, 0]))
    }

    func testFrameLengthRejectsZeroOverflowAndWrongHeaderWidths() {
        for length in [Int.min, -1, 0, 65_537, Int.max] {
            XCTAssertThrowsError(try LANFrameCodec.encodeLength(length))
        }
        for header in [Data(), Data([1]), Data([0, 0, 1]), Data([0, 0, 0, 1, 0]),
                       Data([0, 0, 0, 0]), Data([0, 1, 0, 1]), Data([255, 255, 255, 255])] {
            XCTAssertThrowsError(try LANFrameCodec.decodeLength(header))
        }
    }

    func testPacketWireContainsOnlyContentAndPublicTransactionIdentity() throws {
        let packet = lanTestPacket()
        let data = try packet.encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schema", "transactionID", "senderDeviceID", "records"])
        XCTAssertEqual(object["schema"] as? Int, 1)
        let forbidden: Set<String> = ["secret", "pairID", "peerBindingID", "installationID", "enabled",
                                      "importRequiresReview", "settings", "lastSuccessfulSync", "peerName"]
        func assertNoPermissions(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                XCTAssertTrue(Set(dictionary.keys).isDisjoint(with: forbidden))
                dictionary.values.forEach(assertNoPermissions)
            } else if let array = value as? [Any] { array.forEach(assertNoPermissions) }
        }
        assertNoPermissions(object)
        XCTAssertEqual(try LANPacket.decode(data), packet)
    }

    func testPacketRejectsUnknownSchemasFieldsDuplicateItemsAndOversize() throws {
        let packet = lanTestPacket()
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: packet.encoded()) as? [String: Any])
        var future = original; future["schema"] = 2
        var unknown = original; unknown["peerBindingID"] = "must not be accepted"
        var nested = original
        var records = try XCTUnwrap(nested["records"] as? [[String: Any]])
        records[0]["permissions"] = ["enabled": true]; nested["records"] = records
        for object in [future, unknown, nested] {
            XCTAssertThrowsError(try LANPacket.decode(JSONSerialization.data(withJSONObject: object)))
        }
        XCTAssertThrowsError(try LANPacket(transactionID: UUID(), senderDeviceID: UUID(),
                                         records: packet.records + packet.records).encoded())
        XCTAssertEqual(LANPacket.maximumBytes, 20 * 1_024 * 1_024)
        XCTAssertThrowsError(try LANPacket.decode(Data(repeating: 0, count: LANPacket.maximumBytes + 1)))
    }

    func testMultiChunkPacketRoundTripWithExactRemainderAndReceipt() async throws {
        let packet = lanTestPacket(body: String(repeating: "界", count: 24_000))
        let bytes = try packet.encoded()
        XCTAssertGreaterThan(bytes.count, 65_536)
        let session = UUID()
        try await withLANTestChannels { left, right in
            let sender = LANConversation(channel: left, sessionID: session)
            let receiver = LANConversation(channel: right, sessionID: session)
            let digest = try await sender.sendPacket(packet, acknowledging: String(repeating: "a", count: 64))
            let result = try await receiver.receivePacket(transactionID: packet.transactionID,
                from: packet.senderDeviceID, acknowledging: String(repeating: "a", count: 64))
            XCTAssertEqual(result.packet, packet)
            XCTAssertEqual(result.digest, digest)
            XCTAssertEqual(digest, LANPacket.digest(bytes))
        }
    }

    func testSessionMustBeginWithHelloAndCannotChangeAfterward() async throws {
        let session = UUID(), senderID = UUID(), pairID = UUID()
        try await withLANTestChannels { left, right in
            let sender = LANConversation(channel: left, sessionID: session)
            let receiver = LANConversation(channel: right)
            try await sender.send(.hello) {
                $0.deviceID = senderID; $0.pairID = pairID; $0.deviceName = "Test Mac"
                $0.nonce = Data(repeating: 0xAB, count: 32); $0.mode = "sync"
            }
            _ = try await receiver.receive([.hello])
            XCTAssertEqual(receiver.sessionID, session)
            var wrong = LANFrame(sessionID: UUID(), sequence: 1, kind: .receipt)
            wrong.transactionID = UUID(); wrong.digest = String(repeating: "a", count: 64)
            try await left.send(SyncCoding.encoder().encode(wrong))
            await assertLANThrows { _ = try await receiver.receive([.receipt]) }
        }
        try await withLANTestChannels { left, right in
            let sender = LANConversation(channel: left, sessionID: session)
            try await sender.send(.receipt) { $0.transactionID = UUID(); $0.digest = String(repeating: "a", count: 64) }
            let receiver = LANConversation(channel: right)
            await assertLANThrows { _ = try await receiver.receive([.receipt]) }
            XCTAssertNil(receiver.sessionID)
        }
    }

    func testSequenceReplayAndOutOfOrderFramesAreRejected() async throws {
        for sequence in [UInt64(0), UInt64(2)] {
            let session = UUID()
            try await withLANTestChannels { left, right in
                let receiver = LANConversation(channel: right, sessionID: session)
                var first = LANFrame(sessionID: session, sequence: 0, kind: .receipt)
                first.transactionID = UUID(); first.digest = String(repeating: "a", count: 64)
                try await left.send(SyncCoding.encoder().encode(first))
                _ = try await receiver.receive([.receipt])
                var next = first; next.sequence = sequence
                try await left.send(SyncCoding.encoder().encode(next))
                await assertLANThrows { _ = try await receiver.receive([.receipt]) }
            }
        }
    }

    func testFrameRejectsUnknownFieldsSchemaAndOversizedJSON() async throws {
        let session = UUID()
        var frame = LANFrame(sessionID: session, sequence: 0, kind: .receipt)
        frame.transactionID = UUID(); frame.digest = String(repeating: "a", count: 64)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: SyncCoding.encoder().encode(frame)) as? [String: Any])
        var unknown = object; unknown["futureField"] = true
        var schema = object; schema["schema"] = 2
        var extraKnown = object; extraKnown["approved"] = true
        let candidates = try [unknown, schema, extraKnown].map { try JSONSerialization.data(withJSONObject: $0) }
            + [Data(repeating: 32, count: 65_537)]
        for bytes in candidates {
            try await withLANTestChannels { left, right in
                try await left.send(bytes)
                let receiver = LANConversation(channel: right, sessionID: session)
                await assertLANThrows { _ = try await receiver.receive([.receipt]) }
            }
        }
    }

    func testTamperedPacketDigestIsRejectedBeforeDecode() async throws {
        let packet = lanTestPacket(), session = UUID(), transfer = UUID()
        let bytes = try packet.encoded(), badDigest = String(repeating: "0", count: 64)
        try await withLANTestChannels { left, right in
            let sender = LANConversation(channel: left, sessionID: session)
            try await sender.send(.packetStart) {
                $0.transferID = transfer; $0.transactionID = packet.transactionID
                $0.totalBytes = bytes.count; $0.digest = badDigest
            }
            try await sender.send(.packetChunk) { $0.transferID = transfer; $0.index = 0; $0.chunk = bytes }
            try await sender.send(.packetEnd) { $0.transferID = transfer; $0.digest = badDigest }
            let receiver = LANConversation(channel: right, sessionID: session)
            await assertLANThrows { _ = try await receiver.receivePacket(from: packet.senderDeviceID) }
        }
    }

    func testShortFullChunkAndShortFinalRemainderAreRejected() async throws {
        for total in [100, 32_768, 32_769] {
            let session = UUID(), transaction = UUID(), transfer = UUID(), device = UUID()
            try await withLANTestChannels { left, right in
                let sender = LANConversation(channel: left, sessionID: session)
                try await sender.send(.packetStart) {
                    $0.transferID = transfer; $0.transactionID = transaction
                    $0.totalBytes = total; $0.digest = String(repeating: "a", count: 64)
                }
                if total == 32_769 {
                    try await sender.send(.packetChunk) {
                        $0.transferID = transfer; $0.index = 0; $0.chunk = Data(repeating: 1, count: 32_768)
                    }
                    try await sender.send(.packetChunk) { $0.transferID = transfer; $0.index = 1; $0.chunk = Data() }
                } else {
                    try await sender.send(.packetChunk) {
                        $0.transferID = transfer; $0.index = 0; $0.chunk = Data(repeating: 1, count: total - 1)
                    }
                }
                let receiver = LANConversation(channel: right, sessionID: session)
                await assertLANThrows { _ = try await receiver.receivePacket(from: device) }
            }
        }
    }

    func testPacketStartRejectsOversizeAndMismatchedAcknowledgement() async throws {
        for oversized in [false, true] {
            let session = UUID(), transaction = UUID(), device = UUID()
            try await withLANTestChannels { left, right in
                let sender = LANConversation(channel: left, sessionID: session)
                try await sender.send(.packetStart) {
                    $0.transferID = UUID(); $0.transactionID = transaction
                    $0.totalBytes = oversized ? LANPacket.maximumBytes + 1 : 100
                    $0.digest = String(repeating: "a", count: 64)
                    $0.acknowledgedDigest = oversized ? nil : String(repeating: "b", count: 64)
                }
                let receiver = LANConversation(channel: right, sessionID: session)
                await assertLANThrows { _ = try await receiver.receivePacket(from: device) }
            }
        }
    }
}
