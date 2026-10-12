import Foundation

/// One explicitly paired device, foreground LAN only. No internet service, cloud
/// account, anonymous content exchange, or user-name-based trust path exists.
public actor LANSyncService {
    private let repository: SharedRepository
    private let pairStore: any LANPairStore
    private let network: LANNetworkDriver
    private var networkGeneration = UUID()
    private var networking = false
    private var nearby: [LANPeer] = []
    private var offer: LANPairingOffer?
    private var offerSecret: Data?
    private var offerLocalID: UUID?
    private var request: LANPairingRequest?
    private var approval: CheckedContinuation<Bool, Error>?
    private var activeID: UUID?
    private var activeChannel: (any LANByteChannel)?
    private var pairingInProgress = false
    private var pairTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var operationTimer: Task<Void, Never>?
    private var message = "尚未开启局域网发现；资料保留在本机。"
    private var lastReport: SyncReport?

    public init(repository: SharedRepository) {
        self.repository = repository; pairStore = LANKeychainStore(); network = LANNetworkDriver()
    }
    internal init(repository: SharedRepository, pairStore: any LANPairStore, network: LANNetworkDriver = LANNetworkDriver()) {
        self.repository = repository; self.pairStore = pairStore; self.network = network
    }

    public func status() throws -> LANSyncStatus {
        let state = try repository.read()
        let record: LANPairRecord?
        do { record = try pairStore.load() }
        catch {
            return LANSyncStatus(enabled: false, isBusy: activeID != nil || pairingInProgress, nearbyPeers: nearby,
                                 pairedPeer: LANPairedPeer(id: "unavailable-pair", name: "无法读取的配对记录"),
                                 pairingOffer: nil, pairingRequest: nil, sync: state.sync.status,
                                 message: "配对密钥暂不可读，已阻止传输。请解锁设备后重试；也可明确忘记旧配对。", lastReport: lastReport)
        }
        let isBound = record.map { Self.bindingMatches($0, state) } ?? false
        let pendingPairing = pairingInProgress || offer != nil || request != nil
        let hasResidualBinding = record != nil || state.sync.peerBindingID != nil
        let shownMessage = !pendingPairing && hasResidualBinding && !isBound ? LANFailure.installationMismatch.localizedDescription : message
        let persistedPeer = record.map { LANPairedPeer(id: $0.peerDeviceID.uuidString.lowercased(), name: $0.peerName) }
            ?? state.sync.peerBindingID.map { LANPairedPeer(id: $0, name: "待清理的配对许可") }
        // Keychain is staged before local authorization. Keep the cancellable
        // pairing UI visible during that interval; it is not an established pair.
        let shownPeer = pendingPairing ? nil : persistedPeer
        return LANSyncStatus(enabled: pendingPairing ? networking : (hasResidualBinding ? (state.sync.enabled && isBound) : networking), isBusy: activeID != nil || pairingInProgress,
                             nearbyPeers: nearby,
                             pairedPeer: shownPeer,
                             pairingOffer: offer, pairingRequest: request, sync: state.sync.status,
                             message: shownMessage, lastReport: lastReport)
    }

    /// Explicit UI enable, or foreground resume of an already-enabled local pair.
    /// Discovering a service name is never permission to exchange its content.
    public func start() async throws {
        // Foreground/permission callbacks may repeat while an operation is
        // finishing. Never replace its driver or generation underneath it.
        if activeID != nil || pairingInProgress { return }
        _ = try repository.read() // Corrupt local data fails before network access.
        let record = try pairStore.load()
        if let record {
            let current = try repository.read()
            guard Self.bindingMatches(record, current) else { throw LANFailure.installationMismatch }
            try repository.updateSync { $0.sync.enabled = true }
            if !networking { try configureNetwork(pair: record) }
            message = "局域网监听已开启。发现设备只表示可见；同步完成须收到落盘确认。"
        } else {
            guard try repository.read().sync.peerBindingID == nil else { throw LANFailure.installationMismatch }
            if !networking { configureBrowser() }
            message = "已开启本地发现。请在自己的两台设备间创建或输入配对码。"
        }
    }
    public func stop() throws {
        suspend()
        try repository.updateSync { $0.sync.enabled = false; $0.sync.epoch = UUID() }
        message = "已停用局域网同步，本机资料与配对保留。"
    }
    /// App backgrounding closes sockets but does not grant/revoke durable permission.
    public func suspend() {
        cancelRuntime()
        message = "局域网连接已暂停。在途内容可能已在对端保存，下次会按版本核对；本机待传状态保留。"
    }
    public func cancelPairing() {
        guard offer != nil || request != nil || pairingInProgress else { return }
        cancelRuntime()
        message = "配对已取消；未在临时配对连接中交换用户内容。"
    }
    public func forgetPeer() throws {
        cancelRuntime()
        // First revoke local permission. If Keychain deletion fails, residual key
        // still cannot authorize the now-unbound store; report the failure.
        try repository.updateSync { state in
            state.sync.enabled = false; state.sync.peerBindingID = nil; state.sync.epoch = UUID()
            state.sync.lastSuccessfulSync = nil
            for key in Array(state.sync.entries.keys) { state.sync.entries[key]?.dirty = true }
        }
        try pairStore.delete()
        message = "已忘记配对。本机内容保留，旧密钥不能再连接。"; lastReport = nil
    }
    public func resumeAfterImport() throws {
        let state = try repository.read()
        let record = try validatedPair(state)
        try repository.updateSync(expectedGeneration: state.generation) { state in
            guard Self.bindingMatches(record, state) else { throw LANFailure.installationMismatch }
            state.sync.importRequiresReview = false; state.sync.enabled = true; state.sync.lastFailure = nil
        }
        message = "已确认只合并。备份中缺少的对端项目不会被自动删除，请点击同步。"
    }
    public func resolveConflict(itemKey: String, versionID: UUID, expectedHeadIDs: Set<UUID>) throws {
        try repository.updateSync { state in
            try state.sync.resolve(key: itemKey, versionID: versionID, expectedHeadIDs: expectedHeadIDs)
            let ledger = state.sync; ledger.materialize(into: &state)
        }
        NotificationCenter.default.post(name: .localChecklistSyncDidCommit, object: nil)
    }

    /// Only explicit UI action creates a secret. It expires in two minutes and
    /// is never persisted, advertised, logged, included in backups or sent as data.
    public func beginPairing() async throws {
        guard activeID == nil, !pairingInProgress else { throw SyncError.busy }
        let state = try repository.read()
        guard try pairStore.load() == nil, state.sync.peerBindingID == nil else { throw LANFailure.pairingRequired }
        cancelRuntime()
        let secret = try LANPairCrypto.randomSecret(); let id = LANPairCrypto.pairingID(for: secret)
        let localID = UUID(); let expires = Date().addingTimeInterval(120)
        offer = LANPairingOffer(id: id, code: LANPairCrypto.encodePairingCode(secret), expiresAt: expires)
        offerSecret = secret; offerLocalID = localID
        configureBrowser()
        let token = networkGeneration
        try network.listen(serviceID: localID.uuidString.lowercased(), secret: secret, identity: Self.identity(id),
                           onConnection: { [weak self] channel in Task { await self?.accept(channel, generation: token) } },
                           onFailure: { [weak self] text in Task { await self?.networkFailed(text, generation: token) } })
        message = "请在另一台自己的设备输入此 32 位配对密钥。双方核对数字并确认前，不传任何内容。"
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 120_000_000_000) } catch { return }
            await self?.expireOffer(id)
        }
    }

    /// Starts a background pairing conversation and returns promptly so the UI
    /// remains able to approve/decline the resulting request.
    public func pair(peerID: String, code: String) async throws {
        guard activeID == nil, !pairingInProgress else { throw SyncError.busy }
        let state = try repository.read()
        guard try pairStore.load() == nil, state.sync.peerBindingID == nil else { throw LANFailure.pairingRequired }
        let secret = try LANPairCrypto.decodePairingCode(code)
        guard UUID(uuidString: peerID) != nil else { throw LANFailure.peerUnavailable }
        if !networking { configureBrowser() }
        guard nearby.contains(where: { $0.id == peerID.lowercased() }) else { throw LANFailure.peerUnavailable }
        let operation = UUID(); let token = networkGeneration
        activeID = operation; pairingInProgress = true
        message = "正在进行加密配对握手；尚未传输内容。"
        pairTask = Task { [weak self] in
            guard let self else { return }
            await self.joinPair(peerID: peerID.lowercased(), secret: secret, operation: operation, generation: token,
                                sourceGeneration: state.generation, sourceEpoch: state.sync.epoch)
        }
        setOperationDeadline(operation, seconds: 120)
    }
    public func confirmPairing(id: UUID, approved: Bool) async throws {
        guard let current = request, current.id == id else { throw LANFailure.stalePairing }
        if !approved && current.localConfirmed { cancelPairing(); return }
        guard let approval else { throw LANFailure.stalePairing }
        self.approval = nil
        request = LANPairingRequest(id: id, peerName: current.peerName, verificationCode: current.verificationCode,
                                    localConfirmed: approved, remoteConfirmed: current.remoteConfirmed)
        approval.resume(returning: approved)
        if !approved { message = "已拒绝配对，未传输用户内容。" }
        else { message = "本机已确认，等待另一台也确认。" }
    }

    public func sync(peerID: String? = nil) async throws -> SyncReport {
        guard activeID == nil, !pairingInProgress else { throw SyncError.busy }
        let snapshot = try repository.read(); let pair = try validatedPair(snapshot)
        guard snapshot.sync.enabled else { throw SyncError.disabled }
        guard !snapshot.sync.importRequiresReview else { throw SyncError.importReviewRequired }
        let destination = pair.peerDeviceID.uuidString.lowercased()
        guard peerID == nil || peerID?.lowercased() == destination else { throw LANFailure.peerUnavailable }
        if !networking { try configureNetwork(pair: pair) }
        guard nearby.contains(where: { $0.id == destination }) else { throw LANFailure.peerUnavailable }
        let operation = UUID(); let token = networkGeneration
        activeID = operation; setOperationDeadline(operation, seconds: 180)
        defer { finishOperation(operation) }
        let progress = LANRunProgress()
        let scope = Self.scope(snapshot, pair: pair)
        do {
            let channel = try await network.connect(to: destination, secret: pair.secret, identity: Self.identity(pair.pairID))
            try checkRuntime(operation, generation: token); activeChannel = channel
            let conversation = LANConversation(channel: channel, sessionID: UUID())
            let nonce = try LANPairCrypto.randomSecret(byteCount: 32)
            try await sendHello(conversation, pairID: pair.pairID, localID: pair.localDeviceID, nonce: nonce, mode: "sync")
            let hello = try await conversation.receive([.hello])
            try validateHello(hello, pairID: pair.pairID, peerID: pair.peerDeviceID, mode: "sync")
            let bridge = LANExchangeRepository(repository: repository, scope: scope)
            let report = try await LANExchange.initiate(conversation: conversation, bridge: bridge, progress: progress,
                checkRuntime: { [weak self] in guard let self else { throw SyncError.interrupted }; try await self.checkRuntime(operation, generation: token) })
            try checkRuntime(operation, generation: token)
            lastReport = report; message = report.summary
            await conversation.close(); try checkRuntime(operation, generation: token); finishOperation(operation)
            return report
        } catch {
            await closeActive(operation)
            guard activeID == operation, networkGeneration == token else { throw SyncError.interrupted }
            try saveFailure(error, progress: progress, scope: scope)
            finishOperation(operation)
            throw SyncError.failed(message)
        }
    }

    private func accept(_ channel: any LANByteChannel, generation token: UUID) async {
        guard token == networkGeneration, activeID == nil else { await channel.close(); return }
        let operation = UUID(); activeID = operation; activeChannel = channel
        let conversation = LANConversation(channel: channel)
        let progress = LANRunProgress()
        var exchangeScope: LANExchangeScope?
        do {
            let state = try repository.read()
            let existing = try pairStore.load()
            if let existing {
                let scope = Self.scope(state, pair: existing); exchangeScope = scope
                guard Self.bindingMatches(existing, state), state.sync.enabled else { throw LANFailure.installationMismatch }
                guard !state.sync.importRequiresReview else { throw SyncError.importReviewRequired }
                setOperationDeadline(operation, seconds: 180)
                let hello = try await conversation.receive([.hello])
                try validateHello(hello, pairID: existing.pairID, peerID: existing.peerDeviceID, mode: "sync")
                try checkRuntime(operation, generation: token)
                try await sendHello(conversation, pairID: existing.pairID, localID: existing.localDeviceID,
                                    nonce: LANPairCrypto.randomSecret(byteCount: 32), mode: "sync")
                let bridge = LANExchangeRepository(repository: repository, scope: scope)
                let report = try await LANExchange.respond(conversation: conversation, bridge: bridge, progress: progress,
                    checkRuntime: { [weak self] in guard let self else { throw SyncError.interrupted }; try await self.checkRuntime(operation, generation: token) })
                try checkRuntime(operation, generation: token)
                lastReport = report; message = report.summary
            } else {
                guard let offer, let secret = offerSecret, let localID = offerLocalID,
                      Date() < offer.expiresAt else { throw LANFailure.pairingExpired }
                pairingInProgress = true; setOperationDeadline(operation, seconds: 120)
                let hello = try await conversation.receive([.hello])
                try validateHello(hello, pairID: offer.id, peerID: nil, mode: "pair")
                let nonce = try LANPairCrypto.randomSecret(byteCount: 32)
                try await sendHello(conversation, pairID: offer.id, localID: localID, nonce: nonce, mode: "pair")
                try await completePair(conversation, hello: hello, localID: localID, nonce: nonce, secret: secret,
                                       operation: operation, generation: token, sourceGeneration: state.generation, sourceEpoch: state.sync.epoch)
            }
            await conversation.close(); try checkRuntime(operation, generation: token); finishOperation(operation)
            if let paired = try? pairStore.load(), Self.bindingMatches(paired, try repository.read()), !networking {
                try configureNetwork(pair: paired)
            }
        } catch {
            await conversation.close()
            // A suspended/cancelled task can finish after a new foreground run.
            // It must not overwrite that run's UI state or persisted failure.
            guard activeID == operation, networkGeneration == token else { return }
            if let scope = exchangeScope {
                do { try saveFailure(error, progress: progress, scope: scope) }
                catch { message = "同步中断，且本机状态未能确认保存。请先检查本地资料再重试。" }
            }
            else {
                if activeID == operation { cancelPairing() }
                message = "配对未完成：\(Self.safeMessage(error))。未在临时连接传输内容。"
            }
            finishOperation(operation)
        }
    }

    private func joinPair(peerID: String, secret: Data, operation: UUID, generation token: UUID,
                          sourceGeneration: UUID, sourceEpoch: UUID) async {
        do {
            try checkRuntime(operation, generation: token)
            let pairID = LANPairCrypto.pairingID(for: secret)
            let channel = try await network.connect(to: peerID, secret: secret, identity: Self.identity(pairID))
            try checkRuntime(operation, generation: token); activeChannel = channel
            let conversation = LANConversation(channel: channel, sessionID: UUID())
            let localID = UUID(); let nonce = try LANPairCrypto.randomSecret(byteCount: 32)
            try await sendHello(conversation, pairID: pairID, localID: localID, nonce: nonce, mode: "pair")
            let hello = try await conversation.receive([.hello])
            try validateHello(hello, pairID: pairID, peerID: UUID(uuidString: peerID), mode: "pair")
            try await completePair(conversation, hello: hello, localID: localID, nonce: nonce, secret: secret,
                                   operation: operation, generation: token, sourceGeneration: sourceGeneration, sourceEpoch: sourceEpoch)
            await conversation.close(); try checkRuntime(operation, generation: token); finishOperation(operation)
            let state = try repository.read(); let pair = try validatedPair(state)
            try configureNetwork(pair: pair)
        } catch {
            await closeActive(operation)
            if activeID == operation, networkGeneration == token { message = "配对未完成：\(Self.safeMessage(error))。未在临时连接传输内容。" }
            finishOperation(operation)
        }
    }

    private func completePair(_ conversation: LANConversation, hello: LANFrame, localID: UUID, nonce: Data, secret: Data,
                              operation: UUID, generation token: UUID, sourceGeneration: UUID, sourceEpoch: UUID) async throws {
        try checkRuntime(operation, generation: token)
        guard let peerID = hello.deviceID, peerID != localID, let peerNonce = hello.nonce,
              let sessionID = conversation.sessionID else { throw LANFailure.protocolViolation("missing pairing identity") }
        let pairID = LANPairCrypto.pairingID(for: secret)
        let transcript = try LANPairCrypto.transcript(pairID: pairID, firstDeviceID: localID, firstNonce: nonce,
                                                     secondDeviceID: peerID, secondNonce: peerNonce)
        let code = LANPairCrypto.verificationCode(secret: secret, transcript: transcript)
        let peerName = hello.deviceName ?? "另一台本地设备"
        request = LANPairingRequest(id: sessionID, peerName: peerName, verificationCode: code,
                                    localConfirmed: false, remoteConfirmed: false)
        message = "请在两台自己的设备核对同一组数字，并各自确认。尚未交换内容。"
        let accepted = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in approval = continuation }
        }, onCancel: { [weak self] in Task { await self?.cancelPairing() } })
        try checkRuntime(operation, generation: token)
        try await conversation.send(.pairingApproval) { $0.approved = accepted }
        guard accepted else { throw LANFailure.pairingDeclined }
        let remote = try await conversation.receive([.pairingApproval])
        guard remote.approved == true else { throw LANFailure.pairingDeclined }
        try checkRuntime(operation, generation: token)
        request = LANPairingRequest(id: sessionID, peerName: peerName, verificationCode: code, localConfirmed: true, remoteConfirmed: true)
        message = "两端已确认，正在保存配对；尚未传输用户内容。"
        let current = try repository.read()
        guard current.generation == sourceGeneration, current.sync.epoch == sourceEpoch,
              current.sync.peerBindingID == nil, try pairStore.load() == nil else { throw LANFailure.stalePairing }
        let record = LANPairRecord(pairID: pairID, localDeviceID: localID, peerDeviceID: peerID, peerName: peerName,
                                   secret: LANPairCrypto.persistentSecret(secret: secret, transcript: transcript), installationID: current.sync.installationID)
        try pairStore.save(record)
        var committedWarning: String?
        do {
            // Both keys must be durable before either side authorizes business data.
            try await conversation.send(.pairingReady) { $0.pairID = pairID }
            let ready = try await conversation.receive([.pairingReady])
            guard ready.pairID == pairID else { throw LANFailure.stalePairing }
            try checkRuntime(operation, generation: token)
            try repository.updateSync(expectedGeneration: sourceGeneration) { state in
                guard state.sync.epoch == sourceEpoch, state.sync.installationID == record.installationID,
                      state.sync.peerBindingID == nil else { throw LANFailure.stalePairing }
                var ledger = state.sync; try ledger.seed(from: state)
                ledger.peerBindingID = pairID.uuidString; ledger.enabled = true; ledger.epoch = UUID()
                for key in Array(ledger.entries.keys) { ledger.entries[key]?.dirty = true }
                ledger.lastSuccessfulSync = nil; ledger.lastFailure = nil; state.sync = ledger
            }
        } catch {
            // rename may have committed before a metadata/fsync warning. Read it
            // back before removing a key that the store might already depend on.
            // An unreadable store is ambiguous: retain the key but do not enable
            // a listener or infer permission from Keychain alone.
            if let persisted = try? repository.read() {
                if Self.bindingMatches(record, persisted) {
                    committedWarning = "配对授权已写入，但保护属性或持久化确认曾失败。请先核实本机存储，再进行同步。"
                } else {
                    if let saved = try? pairStore.load(), saved.pairID == pairID { try? pairStore.delete() }
                    throw error
                }
            } else { throw error }
        }
        offer = nil; offerSecret = nil; offerLocalID = nil; request = nil
        expiryTask?.cancel(); expiryTask = nil
        message = committedWarning ?? "本机已保存双方确认的配对。请在任意一端点击同步；临时配对连接没有传输内容。"
        NotificationCenter.default.post(name: .localChecklistSyncDidCommit, object: nil)
        // Replace the temporary-key listener only after the conversation closes.
        networking = false
    }

    private func configureBrowser() {
        network.stop(); networkGeneration = UUID(); networking = true; nearby = []
        let token = networkGeneration
        network.browse(onChange: { [weak self] peers in Task { await self?.updatePeers(peers, generation: token) } },
                       onFailure: { [weak self] text in Task { await self?.networkFailed(text, generation: token) } })
    }
    private func configureNetwork(pair: LANPairRecord) throws {
        configureBrowser()
        let token = networkGeneration
        try network.listen(serviceID: pair.localDeviceID.uuidString.lowercased(), secret: pair.secret, identity: Self.identity(pair.pairID),
                           onConnection: { [weak self] channel in Task { await self?.accept(channel, generation: token) } },
                           onFailure: { [weak self] text in Task { await self?.networkFailed(text, generation: token) } })
    }
    private func updatePeers(_ values: [LANDestination], generation: UUID) {
        guard generation == networkGeneration else { return }
        nearby = values.map { LANPeer(id: $0.id, name: $0.name) }
    }
    private func networkFailed(_ text: String, generation: UUID) {
        guard generation == networkGeneration, activeID == nil else { return }
        networking = false
        message = "局域网尚不可用：\(text)"
    }
    private func validatedPair(_ snapshot: AppSnapshot) throws -> LANPairRecord {
        guard let pair = try pairStore.load() else { throw LANFailure.notPaired }
        guard Self.bindingMatches(pair, snapshot) else { throw LANFailure.installationMismatch }
        return pair
    }
    private static func bindingMatches(_ pair: LANPairRecord, _ snapshot: AppSnapshot) -> Bool {
        pair.installationID == snapshot.sync.installationID && snapshot.sync.peerBindingID == pair.pairID.uuidString
    }
    private static func scope(_ state: AppSnapshot, pair: LANPairRecord) -> LANExchangeScope {
        LANExchangeScope(generation: state.generation, epoch: state.sync.epoch, installationID: state.sync.installationID, pair: pair)
    }
    private static func identity(_ pairID: UUID) -> Data { Data(("LocalChecklist.LAN.v1|" + pairID.uuidString.lowercased()).utf8) }
    private static var deviceName: String {
        #if targetEnvironment(macCatalyst)
        return "Mac"
        #else
        return "iPhone / iPad"
        #endif
    }
    private func sendHello(_ conversation: LANConversation, pairID: UUID, localID: UUID, nonce: Data, mode: String) async throws {
        try await conversation.send(.hello) {
            $0.pairID = pairID; $0.deviceID = localID; $0.deviceName = Self.deviceName; $0.nonce = nonce; $0.mode = mode
        }
    }
    private func validateHello(_ hello: LANFrame, pairID: UUID, peerID: UUID?, mode: String) throws {
        guard hello.pairID == pairID, hello.mode == mode, hello.nonce?.count == 32,
              let identity = hello.deviceID, peerID == nil || peerID == identity,
              let name = hello.deviceName, !name.isEmpty, name.count <= 64,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LANFailure.protocolViolation("authenticated hello mismatch")
        }
    }
    private func checkRuntime(_ operation: UUID, generation: UUID) throws {
        try Task.checkCancellation()
        guard activeID == operation, networkGeneration == generation else { throw SyncError.interrupted }
    }
    private func setOperationDeadline(_ operation: UUID, seconds: UInt64) {
        operationTimer?.cancel()
        operationTimer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
            await self?.expireOperation(operation)
        }
    }
    private func expireOperation(_ operation: UUID) async {
        guard activeID == operation else { return }
        let token = networkGeneration
        let isPairing = pairingInProgress
        approval?.resume(throwing: LANFailure.timeout); approval = nil
        if let activeChannel { await activeChannel.close() }
        guard activeID == operation, networkGeneration == token else { return }
        if isPairing { cancelPairing() } else { finishOperation(operation) }
        message = LANFailure.timeout.localizedDescription
    }
    private func expireOffer(_ id: UUID) {
        guard offer?.id == id else { return }
        cancelPairing(); message = LANFailure.pairingExpired.localizedDescription
    }
    private func cancelRuntime() {
        networkGeneration = UUID(); network.stop(); networking = false; nearby = []
        pairTask?.cancel(); pairTask = nil; expiryTask?.cancel(); expiryTask = nil; operationTimer?.cancel(); operationTimer = nil
        approval?.resume(throwing: LANFailure.pairingDeclined); approval = nil
        activeID = nil; activeChannel = nil; pairingInProgress = false
        offer = nil; offerSecret = nil; offerLocalID = nil; request = nil
    }
    private func finishOperation(_ operation: UUID) {
        guard activeID == operation else { return }
        activeID = nil; activeChannel = nil; pairingInProgress = false
        operationTimer?.cancel(); operationTimer = nil; pairTask = nil
        approval?.resume(throwing: LANFailure.pairingDeclined); approval = nil; request = nil
    }
    private func closeActive(_ operation: UUID) async {
        guard activeID == operation, let activeChannel else { return }
        await activeChannel.close()
    }
    private func saveFailure(_ error: Error, progress: LANRunProgress, scope: LANExchangeScope) throws {
        let current = try repository.read()
        let text = "对方已确认 \(progress.uploadedConfirmed) 项，本机已提交接收 \(progress.downloadedCommitted) 项；仍待传 \(current.sync.pendingCount) 项。交换未完整结束：\(Self.safeMessage(error))。在途请求可能已经落盘，下次会按版本核对。"
        message = text
        if current.generation == scope.generation, current.sync.epoch == scope.epoch {
            try repository.updateSync { state in
                guard state.generation == scope.generation, state.sync.epoch == scope.epoch else { return }
                state.sync.lastFailure = String(text.prefix(4000))
            }
        }
    }
    private static func safeMessage(_ error: Error) -> String {
        // Protocol/transport errors contain no payload or secret. Never append
        // DecodingError context (which can quote untrusted/private data).
        if error is DecodingError { return "对端消息格式无效" }
        return error.localizedDescription
    }
}
