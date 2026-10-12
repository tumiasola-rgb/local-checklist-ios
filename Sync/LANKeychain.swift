import Foundation
import Security
import CryptoKit

/// A device-local credential, never a snapshot, wire-message, or backup model.
/// Codable is used only for the protected Keychain value. Do not log this value.
struct LANPairRecord: Codable, Equatable, Sendable {
    var pairID: UUID
    var localDeviceID: UUID
    var peerDeviceID: UUID
    var peerName: String
    var secret: Data
    /// Must match the independently persisted, local installation identity.
    /// Keychain items may survive uninstall; loading one does not authorize sync.
    var installationID: UUID

    func validate() throws {
        guard secret.count == 32 else {
            throw LANPairFailure.invalid(1, "The saved LAN pairing key must contain exactly 32 bytes.")
        }
        guard localDeviceID != peerDeviceID else {
            throw LANPairFailure.invalid(2, "A LAN pairing must identify two different devices.")
        }
        guard (1...64).contains(peerName.count),
              !peerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !peerName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LANPairFailure.invalid(3, "The paired device name must contain 1–64 characters and no control characters.")
        }
    }
}

protocol LANPairStore: Sendable {
    /// Only a missing item returns nil. Locked, unreadable, or invalid items throw.
    func load() throws -> LANPairRecord?
    /// The caller must obtain both devices' approval before saving a new pair.
    func save(_ value: LANPairRecord) throws
    func delete() throws
}

/// App-private, non-synchronizable, device-bound Keychain storage.
///
/// The service must also check installationID, localDeviceID, its local binding,
/// and the user's enabled setting before using a record. This class deliberately
/// does not recreate any of those permissions from residual Keychain contents.
final class LANKeychainStore: LANPairStore, @unchecked Sendable {
    private let service: String
    // Serializes all instances in this process, including an in-flight delete.
    // Each Security update is atomic; no delete-and-reinsert window is used.
    private static let processLock = NSLock()

    init(service: String = (Bundle.main.bundleIdentifier ?? "LocalChecklist") + ".LANPair") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "active-pair",
         kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
        // No access-group override: never widen the app's Keychain access.
    }

    func load() throws -> LANPairRecord? {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        return try loadWhileLocked()
    }

    private func loadWhileLocked() throws -> LANPairRecord? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw LANPairFailure.security(status, operation: "read") }
        guard let attributes = result as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data,
              data.count <= 16_384 else {
            throw LANPairFailure.invalid(4, "The stored LAN pairing is unreadable. It has not been replaced.")
        }
        // Do not accept an old item created with weaker or migratable protection.
        guard let accessibility = attributes[kSecAttrAccessible as String] as? String,
              accessibility == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String),
              (attributes[kSecAttrSynchronizable as String] as? Bool) != true else {
            throw LANPairFailure.invalid(5, "The stored LAN pairing does not have the required device-only protection.")
        }
        let record: LANPairRecord
        do {
            record = try JSONDecoder().decode(LANPairRecord.self, from: data)
        } catch {
            // Do not attach a decoding error that could quote credential bytes.
            throw LANPairFailure.invalid(6, "The stored LAN pairing is invalid. It has not been replaced.")
        }
        try record.validate()
        return record
    }

    func save(_ value: LANPairRecord) throws {
        try value.validate()
        let data = try JSONEncoder().encode(value)
        guard data.count <= 16_384 else {
            throw LANPairFailure.invalid(12, "The LAN pairing record is too large to save.")
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw LANPairFailure.security(status, operation: "update") }
        var insertion = query
        for (key, value) in attributes { insertion[key] = value }
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem {
            // Another writer inserted between the update and add. Only accept
            // an identical result; never overwrite a different newly approved
            // pair or delete an item in order to make an insertion succeed.
            if try loadWhileLocked() == value { return }
            throw LANPairFailure.invalid(7, "The LAN pairing changed while it was being saved. The other pairing was not overwritten.")
        }
        throw LANPairFailure.security(addStatus, operation: "save")
    }

    func delete() throws {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LANPairFailure.security(status, operation: "delete")
        }
    }
}

/// Pairing identifiers, human verification, and key derivation only.
/// Network.framework's TLS-PSK supplies transport encryption and authentication;
/// none of these helpers is a substitute for TLS or for approval on both devices.
enum LANPairCrypto {
    // Public, versioned domain separators. Changing them changes the protocol.
    private static let pairIDContext = Data("LocalChecklist.LAN.PairID.v1\0".utf8)
    private static let transcriptContext = Data("LocalChecklist.LAN.Transcript.v1\0".utf8)
    private static let verificationContext = Data("LocalChecklist.LAN.Verification.v1\0".utf8)
    private static let persistentContext = Data("LocalChecklist.LAN.PersistentKey.v1\0".utf8)

    static func randomSecret(byteCount: Int = 16) throws -> Data {
        guard (1...4096).contains(byteCount) else {
            throw LANPairFailure.invalid(8, "The random byte request must be between 1 and 4096 bytes.")
        }
        var bytes = Data(count: byteCount)
        let status = bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> OSStatus in
            guard let address = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, byteCount, address)
        }
        guard status == errSecSuccess else { throw LANPairFailure.security(status, operation: "generate random bytes") }
        return bytes
    }

    /// Only freshly generated/decoded 16-byte pairing secrets may be formatted.
    /// This precondition is a programming invariant; decode validates user input.
    static func encodePairingCode(_ secret: Data) -> String {
        precondition(secret.count == 16, "A pairing code requires exactly 16 random bytes.")
        let alphabet = Array("0123456789ABCDEF".utf8)
        var output = [UInt8]()
        output.reserveCapacity(39)
        for (index, byte) in secret.enumerated() {
            if index > 0 && index.isMultiple(of: 2) { output.append(45) }
            output.append(alphabet[Int(byte >> 4)])
            output.append(alphabet[Int(byte & 0x0f)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// ASCII hex, hyphens and spaces only. Rejects truncated codes, Unicode
    /// lookalikes, newlines, and extra characters instead of guessing the secret.
    static func decodePairingCode(_ code: String) throws -> Data {
        guard code.utf8.count <= 256 else { throw malformedCode() }
        var nibbles = [UInt8]()
        nibbles.reserveCapacity(32)
        for character in code.utf8 {
            switch character {
            case 45, 32: continue
            case 48...57: nibbles.append(character - 48)
            case 65...70: nibbles.append(character - 65 + 10)
            case 97...102: nibbles.append(character - 97 + 10)
            default: throw malformedCode()
            }
            guard nibbles.count <= 32 else { throw malformedCode() }
        }
        guard nibbles.count == 32 else { throw malformedCode() }
        return Data(stride(from: 0, to: 32, by: 2).map { nibbles[$0] << 4 | nibbles[$0 + 1] })
    }

    /// A public TLS identity derived from an already validated high-entropy
    /// secret. Never use a short PIN/password as the input to this function.
    static func pairingID(for secret: Data) -> UUID {
        var input = pairIDContext
        input.append(secret)
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80 // Custom UUIDv8, not UUIDv5.
        bytes[8] = (bytes[8] & 0x3f) | 0x80 // RFC variant; independent of host endian.
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Fixed-width encoding: context || pair UUID || sorted (device UUID, nonce).
    /// Each nonce stays attached to its device when either side calls this API.
    static func transcript(pairID: UUID, firstDeviceID: UUID, firstNonce: Data,
                           secondDeviceID: UUID, secondNonce: Data) throws -> Data {
        guard firstDeviceID != secondDeviceID else {
            throw LANPairFailure.invalid(10, "A pairing transcript requires two different device identities.")
        }
        guard firstNonce.count == 32, secondNonce.count == 32 else {
            throw LANPairFailure.invalid(11, "Each pairing transcript nonce must contain exactly 32 bytes.")
        }
        let first = uuidBytes(firstDeviceID)
        let second = uuidBytes(secondDeviceID)
        var result = transcriptContext
        result.append(contentsOf: uuidBytes(pairID))
        if first.lexicographicallyPrecedes(second) {
            result.append(contentsOf: first); result.append(firstNonce)
            result.append(contentsOf: second); result.append(secondNonce)
        } else {
            result.append(contentsOf: second); result.append(secondNonce)
            result.append(contentsOf: first); result.append(firstNonce)
        }
        return result
    }

    /// Human comparison only, never a replacement for the 128-bit pairing code.
    static func verificationCode(secret: Data, transcript: Data) -> String {
        var input = verificationContext
        input.append(transcript)
        let tag = HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: secret))
        let value = tag.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let digits = String(value % 1_000_000)
        return String(repeating: "0", count: 6 - digits.count) + digits
    }

    /// Bind the durable key to this approved device/nonce transcript. Only the
    /// Keychain record persists this result; temporary pairing material expires.
    static func persistentSecret(secret: Data, transcript: Data) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
                                       salt: Data(SHA256.hash(data: transcript)),
                                       info: persistentContext, outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    private static func uuidBytes(_ value: UUID) -> [UInt8] {
        let u = value.uuid
        return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
    }

    private static func malformedCode() -> NSError {
        LANPairFailure.invalid(9, "A pairing code must contain exactly 32 hexadecimal characters, with optional spaces or hyphens.")
    }
}

private enum LANPairFailure {
    static func invalid(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "LocalChecklist.LANPair", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func security(_ status: OSStatus, operation: String) -> NSError {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "Security framework error"
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "LAN pairing could not \(operation): \(reason) (\(status))."
        ])
    }
}
