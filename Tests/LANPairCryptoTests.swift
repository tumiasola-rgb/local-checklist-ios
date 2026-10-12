import Foundation
import XCTest
@testable import LocalChecklist

/// Public deterministic TEST-ONLY fixtures. Never use these bytes as a live key.
/// These tests do not connect to a peer or read/write the real Keychain.
final class LANPairCryptoTests: XCTestCase {
    private let testOnlySecret = Data((0..<16).map { UInt8($0) })
    private let firstDevice = UUID(uuidString: "01020304-0506-4708-890A-0B0C0D0E0F10")!
    private let secondDevice = UUID(uuidString: "FFEEDDCC-BBAA-4988-B766-554433221100")!
    private let firstNonce = Data((0..<32).map { UInt8($0) })
    private let secondNonce = Data((32..<64).map { UInt8($0) })

    private func fixtureTranscript() throws -> Data {
        try LANPairCrypto.transcript(pairID: LANPairCrypto.pairingID(for: testOnlySecret),
            firstDeviceID: firstDevice, firstNonce: firstNonce,
            secondDeviceID: secondDevice, secondNonce: secondNonce)
    }

    private func fixtureRecord() throws -> LANPairRecord {
        LANPairRecord(pairID: LANPairCrypto.pairingID(for: testOnlySecret),
            localDeviceID: firstDevice, peerDeviceID: secondDevice, peerName: "Test Mac",
            secret: LANPairCrypto.persistentSecret(secret: testOnlySecret, transcript: try fixtureTranscript()),
            installationID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!)
    }

    func testPairingCodeGroupsExactly32HexDigitsAndRoundTrips() throws {
        let code = LANPairCrypto.encodePairingCode(testOnlySecret)
        XCTAssertEqual(code, "0001-0203-0405-0607-0809-0A0B-0C0D-0E0F")
        XCTAssertEqual(code.split(separator: "-").map(\.count), Array(repeating: 4, count: 8))
        XCTAssertEqual(try LANPairCrypto.decodePairingCode(code), testOnlySecret)
        XCTAssertEqual(try LANPairCrypto.decodePairingCode(code.lowercased()), testOnlySecret)
        XCTAssertEqual(try LANPairCrypto.decodePairingCode(code.replacingOccurrences(of: "-", with: " ")), testOnlySecret)
        XCTAssertEqual(try LANPairCrypto.decodePairingCode(" " + code + " "), testOnlySecret)
        XCTAssertEqual(try LANPairCrypto.decodePairingCode(code.replacingOccurrences(of: "-", with: "")), testOnlySecret)
    }

    func testPairingCodeRejectsMalformedInputWithoutLeakingInputInErrors() {
        let invalid = ["", String(repeating: "0", count: 31), String(repeating: "0", count: 33),
            String(repeating: "G", count: 32), String(repeating: "０", count: 32),
            String(repeating: "0", count: 32) + "\n", String(repeating: "0", count: 32) + "\t",
            "0x" + String(repeating: "0", count: 32), String(repeating: " ", count: 257)]
        for input in invalid {
            XCTAssertThrowsError(try LANPairCrypto.decodePairingCode(input)) { error in
                let error = error as NSError
                XCTAssertEqual(error.domain, "LocalChecklist.LANPair")
                XCTAssertEqual(error.code, 9)
                XCTAssertNil(error.userInfo[NSUnderlyingErrorKey])
            }
        }
    }

    func testRandomLengthValidationDoesNotCallSecurityForInvalidLengths() {
        for length in [-1, 0, 4097, Int.max] {
            XCTAssertThrowsError(try LANPairCrypto.randomSecret(byteCount: length))
        }
    }

    func testRandomSecretUsesRequestedByteCount() throws {
        XCTAssertEqual(try LANPairCrypto.randomSecret().count, 16)
        XCTAssertEqual(try LANPairCrypto.randomSecret(byteCount: 32).count, 32)
    }

    func testPublicIdentifierHasStableNetworkByteOrderAndUUIDv8Variant() {
        let id = LANPairCrypto.pairingID(for: testOnlySecret)
        XCTAssertEqual(id.uuidString.lowercased(), "701d87d9-8926-8314-b1d3-7c9a00c2b35b")
        XCTAssertEqual(id.uuid.6 >> 4, 8)
        XCTAssertEqual(id.uuid.8 & 0xc0, 0x80)
        XCTAssertNotEqual(id, LANPairCrypto.pairingID(for: Data(repeating: 1, count: 16)))
    }

    func testTranscriptIsCanonicalFromBothPeers() throws {
        let transcript = try fixtureTranscript()
        let reversed = try LANPairCrypto.transcript(pairID: LANPairCrypto.pairingID(for: testOnlySecret),
            firstDeviceID: secondDevice, firstNonce: secondNonce,
            secondDeviceID: firstDevice, secondNonce: firstNonce)
        XCTAssertEqual(transcript, reversed)
        XCTAssertEqual(transcript.count, 145)
        // Both peers derive the exact same verification display and durable key.
        XCTAssertEqual(LANPairCrypto.verificationCode(secret: testOnlySecret, transcript: transcript),
                       LANPairCrypto.verificationCode(secret: testOnlySecret, transcript: reversed))
        XCTAssertEqual(LANPairCrypto.persistentSecret(secret: testOnlySecret, transcript: transcript),
                       LANPairCrypto.persistentSecret(secret: testOnlySecret, transcript: reversed))
    }

    func testTranscriptBindsPairIdentitiesAndTheirOwnNonces() throws {
        let pairID = LANPairCrypto.pairingID(for: testOnlySecret)
        let baseline = try fixtureTranscript()
        let changed = [
            try LANPairCrypto.transcript(pairID: secondDevice,
                firstDeviceID: firstDevice, firstNonce: firstNonce, secondDeviceID: secondDevice, secondNonce: secondNonce),
            try LANPairCrypto.transcript(pairID: pairID,
                firstDeviceID: pairID, firstNonce: firstNonce, secondDeviceID: secondDevice, secondNonce: secondNonce),
            try LANPairCrypto.transcript(pairID: pairID,
                firstDeviceID: firstDevice, firstNonce: secondNonce, secondDeviceID: secondDevice, secondNonce: firstNonce)
        ]
        for transcript in changed {
            XCTAssertNotEqual(baseline, transcript)
            XCTAssertNotEqual(LANPairCrypto.persistentSecret(secret: testOnlySecret, transcript: baseline),
                              LANPairCrypto.persistentSecret(secret: testOnlySecret, transcript: transcript))
        }
    }

    func testTranscriptRejectsSameDeviceAndWrongNonceLengths() {
        let pairID = LANPairCrypto.pairingID(for: testOnlySecret)
        XCTAssertThrowsError(try LANPairCrypto.transcript(pairID: pairID,
            firstDeviceID: firstDevice, firstNonce: firstNonce, secondDeviceID: firstDevice, secondNonce: secondNonce))
        for count in [0, 16, 31, 33, 64] {
            XCTAssertThrowsError(try LANPairCrypto.transcript(pairID: pairID,
                firstDeviceID: firstDevice, firstNonce: Data(repeating: 0, count: count),
                secondDeviceID: secondDevice, secondNonce: secondNonce))
            XCTAssertThrowsError(try LANPairCrypto.transcript(pairID: pairID,
                firstDeviceID: firstDevice, firstNonce: firstNonce,
                secondDeviceID: secondDevice, secondNonce: Data(repeating: 0, count: count)))
        }
    }

    func testHMACAndHKDFMatchIndependentTestOnlyVectors() throws {
        let transcript = try fixtureTranscript()
        XCTAssertEqual(LANPairCrypto.verificationCode(secret: testOnlySecret, transcript: transcript), "735610")
        let result = LANPairCrypto.persistentSecret(secret: testOnlySecret, transcript: transcript)
        XCTAssertEqual(result.count, 32)
        XCTAssertEqual(result.map { String(format: "%02x", $0) }.joined(),
                       "e32776a565bb506a8d8ca948a039851009ea49f61723268e4e019e05a4642250")
    }

    func testVerificationCodeRetainsLeadingZero() {
        // Isolated public HMAC fixture, not a real pairing transcript.
        XCTAssertEqual(LANPairCrypto.verificationCode(secret: testOnlySecret, transcript: Data([9])), "052309")
    }

    func testRecordValidationAndInMemoryCodablePreserveInstallationBinding() throws {
        let record = try fixtureRecord()
        XCTAssertNoThrow(try record.validate())
        let roundTrip = try JSONDecoder().decode(LANPairRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(roundTrip, record)
        var differentInstallation = record
        differentInstallation.installationID = UUID()
        XCTAssertNotEqual(differentInstallation, record)
    }

    func testRecordRejectsInvalidSecretsIdentitiesAndNames() throws {
        var record = try fixtureRecord()
        for count in [0, 16, 31, 33, 64] {
            record.secret = Data(repeating: 0, count: count)
            XCTAssertThrowsError(try record.validate())
        }
        record = try fixtureRecord(); record.peerDeviceID = record.localDeviceID
        XCTAssertThrowsError(try record.validate())
        for name in ["", "   ", "\t", "Test\nMac", String(repeating: "a", count: 65)] {
            record = try fixtureRecord(); record.peerName = name
            XCTAssertThrowsError(try record.validate())
        }
        record = try fixtureRecord(); record.peerName = String(repeating: "a", count: 64)
        XCTAssertNoThrow(try record.validate())
    }
}
