import XCTest
@testable import LocalChecklist

final class LANServiceBindingTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDownWithError() throws { for root in roots { try FileManager.default.removeItem(at: root) }; roots = [] }
    private func repository() throws -> SharedRepository {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LANBindingTests-\(UUID().uuidString)")
        roots.append(url); return try SharedRepository(directory: url)
    }
    private func record(installation: UUID) -> LANPairRecord {
        // Public test-only fixture. Production keys come exclusively from SecRandomCopyBytes/HKDF.
        LANPairRecord(pairID: UUID(), localDeviceID: UUID(), peerDeviceID: UUID(), peerName: "Test peer",
                      secret: Data(repeating: 0x51, count: 32), installationID: installation)
    }
    private func bind(_ repository: SharedRepository, record: LANPairRecord) throws {
        try repository.updateSync { $0.sync.peerBindingID = record.pairID.uuidString; $0.sync.enabled = true }
    }
    func testResidualKeychainCannotEnableNewInstallation() async throws {
        let repository = try repository(); let state = try repository.read()
        let old = record(installation: UUID()); let store = MemoryPairStore(old)
        let service = LANSyncService(repository: repository, pairStore: store)
        let before = try await service.status()
        XCTAssertFalse(before.enabled); XCTAssertNotNil(before.pairedPeer)
        do { try await service.start(); XCTFail("Old installation must never auto-bind") } catch {
            XCTAssertEqual(error as? LANFailure, .installationMismatch)
        }
        XCTAssertNil(try repository.read().sync.peerBindingID)
        XCTAssertEqual(try repository.read().sync.installationID, state.sync.installationID)
    }
    func testMatchingKeyWithoutLocalBindingIsStillUnauthorized() async throws {
        let repository = try repository(); let state = try repository.read()
        let stored = record(installation: state.sync.installationID)
        let service = LANSyncService(repository: repository, pairStore: MemoryPairStore(stored))
        do { try await service.start(); XCTFail("Keychain alone is not permission") } catch {}
        XCTAssertFalse(try repository.read().sync.enabled)
    }
    func testForgetRevokesPermissionRemovesKeyAndRetainsContent() async throws {
        let repository = try repository(); try repository.saveNote(NoteItem(title: "Keep me", body: "Local content"), isNew: true)
        let stored = record(installation: try repository.read().sync.installationID)
        try bind(repository, record: stored)
        let store = MemoryPairStore(stored); let service = LANSyncService(repository: repository, pairStore: store)
        try await service.forgetPeer()
        let result = try repository.read()
        XCTAssertFalse(result.sync.enabled); XCTAssertNil(result.sync.peerBindingID); XCTAssertNil(try store.load())
        XCTAssertEqual(result.notes.first?.body, "Local content")
    }
    func testFailedKeyDeletionDoesNotLeaveTransmissionAuthorized() async throws {
        let repository = try repository(); let stored = record(installation: try repository.read().sync.installationID)
        try bind(repository, record: stored)
        let store = MemoryPairStore(stored); store.failDelete = true
        let service = LANSyncService(repository: repository, pairStore: store)
        do { try await service.forgetPeer(); XCTFail("Deletion failure must be reported") } catch {}
        XCTAssertFalse(try repository.read().sync.enabled); XCTAssertNil(try repository.read().sync.peerBindingID)
        XCTAssertNotNil(try store.load())
        let status = try await service.status(); XCTAssertFalse(status.enabled)
    }
    func testBackupNeverReusesPairPermissionOrInstallationIdentity() throws {
        let repository = try repository(); try repository.saveTask(TodoItem(title: "Backup"), isNew: true)
        let stored = record(installation: try repository.read().sync.installationID); try bind(repository, record: stored)
        let original = try repository.read(); let preview = try repository.previewImport(repository.exportData())
        XCTAssertFalse(preview.snapshot.sync.enabled); XCTAssertNil(preview.snapshot.sync.peerBindingID)
        XCTAssertNotEqual(preview.snapshot.sync.installationID, original.sync.installationID)
        XCTAssertFalse(String(decoding: try repository.exportData(), as: UTF8.self).contains(stored.secret.base64EncodedString()))
        let restored = try repository.replace(with: preview, expectedGeneration: original.generation)
        XCTAssertEqual(restored.sync.installationID, original.sync.installationID)
        XCTAssertEqual(restored.sync.peerBindingID, original.sync.peerBindingID)
        XCTAssertTrue(restored.sync.importRequiresReview)
    }
    func testCorruptStorePreventsStartBeforeCredentialRead() async throws {
        let repository = try repository()
        try Data("broken".utf8).write(to: repository.directory.appendingPathComponent(SharedRepository.dataFileName))
        let store = MemoryPairStore(nil); let service = LANSyncService(repository: repository, pairStore: store)
        do { try await service.start(); XCTFail("Corrupt store must stop before network") } catch {}
        XCTAssertEqual(store.readCount, 0)
    }
    func testSuspendPreservesEnabledButStopRevokesIt() async throws {
        let repository = try repository(); let stored = record(installation: try repository.read().sync.installationID)
        try bind(repository, record: stored)
        let service = LANSyncService(repository: repository, pairStore: MemoryPairStore(stored))
        await service.suspend(); XCTAssertTrue(try repository.read().sync.enabled)
        try await service.stop(); XCTAssertFalse(try repository.read().sync.enabled)
    }
    func testUnreadableKeychainStatusFailsClosedAndOffersForgetPath() async throws {
        let repository = try repository(); let store = MemoryPairStore(nil); store.failRead = true
        let service = LANSyncService(repository: repository, pairStore: store)
        let status = try await service.status()
        XCTAssertFalse(status.enabled); XCTAssertNotNil(status.pairedPeer)
        XCTAssertNil(status.pairingOffer); XCTAssertNil(status.pairingRequest)
    }
}

private final class MemoryPairStore: LANPairStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: LANPairRecord?
    private var reads = 0
    // Configured before the service begins accessing the test store.
    var failDelete = false
    var failRead = false
    init(_ record: LANPairRecord?) { stored = record }
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func load() throws -> LANPairRecord? {
        lock.lock(); defer { lock.unlock() }; reads += 1
        if failRead { throw NSError(domain: "PublicTestFixture", code: 1) }
        return stored
    }
    func save(_ value: LANPairRecord) throws { lock.lock(); defer { lock.unlock() }; stored = value }
    func delete() throws {
        lock.lock(); defer { lock.unlock() }
        if failDelete { throw NSError(domain: "PublicTestFixture", code: 2) }
        stored = nil
    }
}
