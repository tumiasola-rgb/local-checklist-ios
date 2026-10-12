import Foundation
import Network
import Security

/// One encrypted, authenticated, length-delimited byte stream. Exactly one read and
/// one write may be outstanding at a time. A failed/cancelled transport operation closes the
/// stream; application code must establish a new session before retrying.
protocol LANByteChannel: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

struct LANDestination: Identifiable, Sendable {
    let id: String
    let name: String
}

/// Pure, testable framing primitives. Do not allocate a payload before decoding and
/// checking its length. The wire length does not include these four header bytes.
enum LANFrameCodec {
    static let maximumPayloadBytes = 65_536
    static let headerBytes = 4

    static func encodeLength(_ count: Int) throws -> Data {
        guard (1...maximumPayloadBytes).contains(count) else {
            throw LANNetworkFailure.invalidFrame
        }
        let length = UInt32(count)
        return Data([
            UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff), UInt8(length & 0xff)
        ])
    }

    static func decodeLength(_ header: Data) throws -> Int {
        guard header.count == headerBytes else { throw LANNetworkFailure.invalidFrame }
        // Byte-wise decoding is independent of Data alignment and startIndex.
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= UInt32(maximumPayloadBytes) else {
            throw LANNetworkFailure.invalidFrame
        }
        return Int(length)
    }
}

private enum LANNetworkFailure: Error, LocalizedError {
    case invalidSecret, invalidIdentity, invalidServiceID, invalidFrame
    case notDiscovered, tooManyConnections, closed, timedOut, notReady
    case concurrentRead, concurrentWrite, concurrentConnect
    case transport, tlsRejected, disallowedPath

    var errorDescription: String? {
        switch self {
        case .invalidSecret: return "配对密钥格式无效，请重新配对。"
        case .invalidIdentity: return "配对标识格式无效。"
        case .invalidServiceID: return "本机局域网标识格式无效。"
        case .invalidFrame: return "收到的局域网数据帧格式或长度无效。"
        case .notDiscovered: return "这台设备已不在当前局域网发现列表中，请重新搜索。"
        case .tooManyConnections: return "局域网连接过多，请稍后重试。"
        case .closed: return "局域网连接已关闭。"
        case .timedOut: return "局域网连接或传输超时，请确认两端 App 都在前台。"
        case .notReady: return "安全连接尚未建立。"
        case .concurrentRead, .concurrentWrite, .concurrentConnect:
            return "同一局域网连接已有操作正在进行。"
        case .transport: return "局域网安全连接失败，请检查网络、权限和配对密钥。"
        case .tlsRejected: return "对端未建立所要求的 TLS 配对密钥安全连接。"
        case .disallowedPath: return "仅支持当前局域网的 Wi-Fi 或以太网连接。"
        }
    }
}

private enum LANTLS {
    // The older NWConnection API supports TLS-PSK with TLS 1.2, not TLS 1.3.
    // This PSK-only suite provides authenticated encryption, not forward secrecy.
    // https://developer.apple.com/videos/play/wwdc2019/713/
    // https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework
    static var cipherSuite: tls_ciphersuite_t {
        // A compile-time standardized Security.framework cipher-suite constant.
        tls_ciphersuite_t(rawValue: TLS_PSK_WITH_AES_128_GCM_SHA256)!
    }

    static func parameters(secret: Data, identity: Data) throws -> NWParameters {
        // The caller generates 128 random bits for temporary pairing or 256 random
        // bits for the Keychain-backed pair. A short numeric passcode is forbidden.
        guard secret.count == 16 || secret.count == 32 else {
            throw LANNetworkFailure.invalidSecret
        }
        // This identity is sent openly in the TLS handshake: it must be an opaque
        // public protocol/pair identifier, NEVER the secret or personal information.
        guard !identity.isEmpty, identity.count <= 128 else {
            throw LANNetworkFailure.invalidIdentity
        }
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let keyBytes = secret.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityBytes = identity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            options, keyBytes as dispatch_data_t, identityBytes as dispatch_data_t
        )
        sec_protocol_options_append_tls_ciphersuite(options, cipherSuite)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        // Require a fresh authenticated handshake after replacement/revocation.
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_set_tls_renegotiation_enabled(options, false)
        sec_protocol_options_set_tls_false_start_enabled(options, false)
        // No local certificate, trust bypass, plaintext retry, or STARTTLS exists.
        // Also inspect the negotiated suite before exposing application I/O below.
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 30
        let parameters = NWParameters(tls: tls, tcp: tcp)
        restrictToLAN(parameters)
        return parameters
    }

    static func restrictToLAN(_ parameters: NWParameters) {
        parameters.includePeerToPeer = false
        parameters.prohibitedInterfaceTypes = [.cellular, .loopback, .other]
        parameters.preferNoProxies = true
        parameters.allowFastOpen = false
        parameters.multipathServiceType = .disabled
    }

    static func isLAN(_ path: NWPath) -> Bool {
        path.status == .satisfied
            && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            && !path.usesInterfaceType(.cellular)
            && !path.usesInterfaceType(.other)
            && !path.usesInterfaceType(.loopback)
    }
}

/// All mutable state and every Network callback are confined to `queue`. The
/// unchecked conformance describes this confinement, not unchecked TLS trust.
private final class LANNetworkChannel: LANByteChannel, @unchecked Sendable {
    private struct Pending<Value> {
        let id: UUID
        let continuation: CheckedContinuation<Value, Error>
        let timeout: DispatchSourceTimer
        let expiresAt = DispatchTime.now() + .seconds(30)

        var hasExpired: Bool {
            DispatchTime.now().uptimeNanoseconds >= expiresAt.uptimeNanoseconds
        }
    }

    private struct ReadState {
        let pending: Pending<Data>
        var header = Data()
        var payload = Data()
        var expectedLength: Int?
    }

    let id = UUID()
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "LocalChecklist.LAN.channel")
    private let onClose: @Sendable (UUID) -> Void
    private var terminalError: Error?
    private var started = false
    private var ready = false
    private var connecting: Pending<Void>?
    private var writing: Pending<Void>?
    private var reading: ReadState?

    init(connection: NWConnection, onClose: @escaping @Sendable (UUID) -> Void) {
        self.connection = connection
        self.onClose = onClose
    }

    deinit { connection.forceCancel() }

    func start() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    if let error = self.terminalError {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard !self.started else {
                        continuation.resume(throwing: LANNetworkFailure.concurrentConnect)
                        return
                    }
                    self.started = true
                    let id = UUID()
                    let timer = self.deadline(for: id)
                    self.connecting = Pending(id: id, continuation: continuation, timeout: timer)
                    self.connection.stateUpdateHandler = { [weak self] state in
                        self?.stateChanged(state)
                    }
                    self.connection.pathUpdateHandler = { [weak self] path in
                        guard let self, self.ready, !LANTLS.isLAN(path) else { return }
                        self.finish(LANNetworkFailure.disallowedPath)
                    }
                    self.connection.start(queue: self.queue)
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func send(_ data: Data) async throws {
        // Validate before copying the caller's payload or constructing a frame.
        let header = try LANFrameCodec.encodeLength(data.count)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    if let error = self.terminalError {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard self.ready else {
                        continuation.resume(throwing: LANNetworkFailure.notReady)
                        return
                    }
                    guard self.writing == nil else {
                        continuation.resume(throwing: LANNetworkFailure.concurrentWrite)
                        return
                    }
                    let id = UUID()
                    let timer = self.deadline(for: id)
                    self.writing = Pending(id: id, continuation: continuation, timeout: timer)
                    var frame = header
                    frame.append(data)
                    self.connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                        guard let self, let pending = self.writing, pending.id == id else { return }
                        guard !pending.hasExpired else {
                            self.finish(LANNetworkFailure.timedOut)
                            return
                        }
                        if error != nil {
                            self.finish(LANNetworkFailure.transport)
                            return
                        }
                        self.writing = nil
                        pending.timeout.cancel()
                        // Backpressure: completion means Network processed this frame,
                        // NOT that the peer durably saved its application payload.
                        pending.continuation.resume()
                    })
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func receive() async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                queue.async {
                    if let error = self.terminalError {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard self.ready else {
                        continuation.resume(throwing: LANNetworkFailure.notReady)
                        return
                    }
                    guard self.reading == nil else {
                        continuation.resume(throwing: LANNetworkFailure.concurrentRead)
                        return
                    }
                    let id = UUID()
                    let timer = self.deadline(for: id)
                    self.reading = ReadState(pending: Pending(
                        id: id, continuation: continuation, timeout: timer
                    ))
                    self.readNextPart(id: id)
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.finish(LANNetworkFailure.closed)
                continuation.resume()
            }
        }
    }

    /// Synchronous entry point used by driver.stop and task cancellation. It never
    /// blocks the caller on a Network callback; finish resumes all waiters itself.
    func cancel() {
        queue.async { self.finish(CancellationError()) }
    }

    private func deadline(for id: UUID) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.connecting?.id == id || self.writing?.id == id
                    || self.reading?.pending.id == id else { return }
            self.finish(LANNetworkFailure.timedOut)
        }
        // One absolute 30-second deadline per whole frame/handshake. Partial reads
        // do not reset it, so a slow sender cannot keep a receive alive forever.
        timer.schedule(deadline: .now() + .seconds(30))
        timer.resume()
        return timer
    }

    private func stateChanged(_ state: NWConnection.State) {
        guard terminalError == nil else { return }
        switch state {
        case .ready:
            if connecting?.hasExpired == true {
                finish(LANNetworkFailure.timedOut)
                return
            }
            guard let metadata = connection.metadata(definition: NWProtocolTLS.definition)
                    as? NWProtocolTLS.Metadata else {
                finish(LANNetworkFailure.tlsRejected)
                return
            }
            let tls = metadata.securityProtocolMetadata
            guard sec_protocol_metadata_get_negotiated_tls_protocol_version(tls) == .TLSv12,
                  sec_protocol_metadata_get_negotiated_tls_ciphersuite(tls) == LANTLS.cipherSuite else {
                finish(LANNetworkFailure.tlsRejected)
                return
            }
            guard let path = connection.currentPath, LANTLS.isLAN(path) else {
                finish(LANNetworkFailure.disallowedPath)
                return
            }
            ready = true
            if let pending = connecting {
                connecting = nil
                pending.timeout.cancel()
                pending.continuation.resume()
            }
        case .failed:
            finish(LANNetworkFailure.transport)
        case .cancelled:
            finish(LANNetworkFailure.closed)
        case .waiting:
            // A waiting handshake retains its original deadline. An established
            // session cannot silently migrate/replay an unfinished transaction.
            if ready { finish(LANNetworkFailure.transport) }
        case .setup, .preparing:
            break
        @unknown default:
            finish(LANNetworkFailure.transport)
        }
    }

    private func readNextPart(id: UUID) {
        guard let read = reading, read.pending.id == id else { return }
        let remaining: Int
        if let expected = read.expectedLength {
            remaining = expected - read.payload.count
        } else {
            remaining = LANFrameCodec.headerBytes - read.header.count
        }
        // At most 16 KiB is requested in a callback, never bytes from a future frame.
        let requested = min(remaining, 16_384)
        guard requested > 0 else {
            finish(LANNetworkFailure.invalidFrame)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: requested) { [weak self] data, _, complete, error in
            guard let self, var read = self.reading, read.pending.id == id else { return }
            guard !read.pending.hasExpired else {
                self.finish(LANNetworkFailure.timedOut)
                return
            }
            if error != nil {
                self.finish(LANNetworkFailure.transport)
                return
            }
            guard let data, !data.isEmpty, data.count <= requested else {
                self.finish(complete ? LANNetworkFailure.closed : LANNetworkFailure.invalidFrame)
                return
            }
            if read.expectedLength == nil {
                read.header.append(data)
                if read.header.count == LANFrameCodec.headerBytes {
                    do {
                        let length = try LANFrameCodec.decodeLength(read.header)
                        read.expectedLength = length
                        // This allocation occurs only after the untrusted UInt32
                        // length was checked against 1...65,536.
                        read.payload.reserveCapacity(length)
                    } catch {
                        self.finish(error)
                        return
                    }
                }
            } else {
                read.payload.append(data)
            }
            if let expected = read.expectedLength, read.payload.count == expected {
                self.reading = nil
                read.pending.timeout.cancel()
                read.pending.continuation.resume(returning: read.payload)
                if complete { self.finish(LANNetworkFailure.closed) }
                return
            }
            self.reading = read
            if complete {
                self.finish(LANNetworkFailure.invalidFrame)
                return
            }
            self.readNextPart(id: id)
        }
    }

    private func finish(_ error: Error) {
        guard terminalError == nil else { return }
        terminalError = error
        ready = false
        connection.stateUpdateHandler = nil
        connection.pathUpdateHandler = nil
        connection.forceCancel()

        // Take every continuation before resuming any of them. Late Network
        // callbacks and timeout work items observe empty slots and do nothing.
        let connect = connecting
        let write = writing
        let read = reading
        connecting = nil
        writing = nil
        reading = nil
        connect?.timeout.cancel()
        write?.timeout.cancel()
        read?.pending.timeout.cancel()
        connect?.continuation.resume(throwing: error)
        write?.continuation.resume(throwing: error)
        read?.pending.continuation.resume(throwing: error)
        onClose(id)
    }
}

/// Browse/listen are explicit opt-in entry points. init() never opens a socket.
/// All discovery/listener state lives on one serial queue. Callbacks may arrive on
/// that queue; UI callers must hop to their actor. No account or cloud API is used.
final class LANNetworkDriver: @unchecked Sendable {
    private struct Discovered {
        let destination: LANDestination
        let endpoint: NWEndpoint
        let interface: NWInterface
    }

    private static let serviceType = "_lc-checklist._tcp"
    private static let domain = "local."
    private static let maximumConnections = 8
    private static let maximumDiscoveries = 64
    private let queue = DispatchQueue(label: "LocalChecklist.LAN.discovery")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var browser: NWBrowser?
    private var browserGeneration = UUID()
    private var listener: NWListener?
    private var listenerGeneration = UUID()
    private var endpoints: [String: Discovered] = [:]
    private var ownedServiceNames = Set<String>()
    private var channels: [UUID: LANNetworkChannel] = [:]
    private var discoveryChanged: (@Sendable ([LANDestination]) -> Void)?

    init() { queue.setSpecific(key: queueKey, value: 1) }

    deinit {
        browser?.cancel()
        listener?.cancel()
        for channel in channels.values { channel.cancel() }
    }

    func browse(
        onChange: @escaping @Sendable ([LANDestination]) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        onQueue {
            browserGeneration = UUID()
            let generation = browserGeneration
            browser?.cancel()
            endpoints.removeAll()
            discoveryChanged = onChange
            let parameters = NWParameters()
            LANTLS.restrictToLAN(parameters)
            let newBrowser = NWBrowser(
                for: .bonjour(type: Self.serviceType, domain: Self.domain), using: parameters
            )
            browser = newBrowser
            newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self, self.browserGeneration == generation else { return }
                self.updateDiscoveries(results)
            }
            newBrowser.stateUpdateHandler = { [weak self] state in
                guard let self, self.browserGeneration == generation else { return }
                switch state {
                case .failed:
                    self.browser?.cancel()
                    self.browser = nil
                    self.endpoints.removeAll()
                    self.discoveryChanged?([])
                    onFailure("局域网搜索失败，请检查本地网络权限及 Wi-Fi 或以太网连接。")
                case .waiting:
                    onFailure("局域网搜索正在等待网络或本地网络权限。")
                default:
                    break
                }
            }
            onChange([])
            newBrowser.start(queue: queue)
        }
    }

    func listen(
        serviceID: String, secret: Data, identity: Data,
        onConnection: @escaping @Sendable (any LANByteChannel) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        // serviceID must be a random, public UUID. Never advertise a device/user
        // name, pair secret, checklist content, or TXT metadata.
        guard let uuid = UUID(uuidString: serviceID) else { throw LANNetworkFailure.invalidServiceID }
        let serviceName = "LC-" + uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let parameters = try LANTLS.parameters(secret: secret, identity: identity)
        parameters.acceptLocalOnly = true
        let newListener = try NWListener(using: parameters, on: .any)
        newListener.service = NWListener.Service(
            name: serviceName, type: Self.serviceType, domain: Self.domain, txtRecord: nil
        )

        onQueue {
            listenerGeneration = UUID()
            let generation = listenerGeneration
            listener?.cancel()
            listener = newListener
            newListener.newConnectionLimit = max(0, Self.maximumConnections - channels.count)
            ownedServiceNames.insert(serviceName.lowercased())
            if let browser { updateDiscoveries(browser.browseResults) }
            newListener.serviceRegistrationUpdateHandler = { [weak self] change in
                guard let self, self.listenerGeneration == generation else { return }
                if case .add(let endpoint) = change,
                   case .service(let name, _, _, _) = endpoint {
                    // Bonjour may rename a colliding service. Filter that name too.
                    self.ownedServiceNames.insert(name.lowercased())
                    if let browser = self.browser { self.updateDiscoveries(browser.browseResults) }
                }
            }
            newListener.stateUpdateHandler = { [weak self] state in
                guard let self, self.listenerGeneration == generation else { return }
                switch state {
                case .failed:
                    self.listener?.cancel()
                    self.listener = nil
                    self.listenerGeneration = UUID()
                    onFailure("局域网接收服务失败，请检查本地网络权限。")
                case .waiting:
                    onFailure("局域网接收服务正在等待网络或本地网络权限。")
                default:
                    break
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                guard let self, self.listenerGeneration == generation,
                      self.channels.count < Self.maximumConnections else {
                    connection.forceCancel()
                    return
                }
                let channel = self.track(connection)
                Task { [weak self] in
                    do {
                        try await channel.start()
                        guard let self else { await channel.close(); return }
                        self.queue.async { [weak self] in
                            guard let self, self.listenerGeneration == generation,
                                  self.channels[channel.id] != nil else {
                                channel.cancel()
                                return
                            }
                            // Never expose a TCP-only or unverified TLS connection.
                            onConnection(channel)
                        }
                    } catch {
                        await channel.close()
                        guard let self else { return }
                        self.queue.async { [weak self] in
                            guard let self, self.listenerGeneration == generation else { return }
                            onFailure("局域网安全握手失败或超时，请确认两端使用相同的配对密钥。")
                        }
                    }
                }
            }
            newListener.start(queue: queue)
        }
    }

    func connect(to id: String, secret: Data, identity: Data) async throws -> any LANByteChannel {
        try Task.checkCancellation()
        let parameters = try LANTLS.parameters(secret: secret, identity: identity)
        let channel = try onQueue {
            // IDs only index current Bonjour results. They are never interpreted
            // as an address, URL, port, hostname, or user-supplied WAN destination.
            guard let found = endpoints[id] else { throw LANNetworkFailure.notDiscovered }
            guard channels.count < Self.maximumConnections else { throw LANNetworkFailure.tooManyConnections }
            parameters.requiredInterface = found.interface
            return track(NWConnection(to: found.endpoint, using: parameters))
        }
        do {
            try await channel.start()
            try Task.checkCancellation()
            return channel
        } catch {
            await channel.close()
            throw error
        }
    }

    func stop() {
        onQueue {
            browserGeneration = UUID()
            listenerGeneration = UUID()
            browser?.cancel()
            listener?.cancel()
            browser = nil
            listener = nil
            endpoints.removeAll()
            ownedServiceNames.removeAll()
            let held = Array(channels.values)
            channels.removeAll()
            for channel in held { channel.cancel() }
            let changed = discoveryChanged
            discoveryChanged = nil
            changed?([])
        }
    }

    private func track(_ connection: NWConnection) -> LANNetworkChannel {
        let channel = LANNetworkChannel(connection: connection) { [weak self] id in
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.channels.removeValue(forKey: id)
                self.listener?.newConnectionLimit = max(0, Self.maximumConnections - self.channels.count)
            }
        }
        channels[channel.id] = channel
        listener?.newConnectionLimit = max(0, Self.maximumConnections - channels.count)
        return channel
    }

    private func updateDiscoveries(_ results: Set<NWBrowser.Result>) {
        var found: [String: Discovered] = [:]
        for result in results {
            guard case .service(let name, let type, let domain, _) = result.endpoint,
                  type.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == Self.serviceType,
                  domain.lowercased() == Self.domain,
                  !ownedServiceNames.contains(name.lowercased()),
                  let suffix = Self.publicSuffix(name),
                  let interface = result.interfaces
                    .filter({ $0.type == .wifi || $0.type == .wiredEthernet })
                    .sorted(by: { $0.index < $1.index }).first else { continue }
            // The app persists the public device UUID, not the Bonjour display
            // name. Preserve that stable identity across auto-renames/interfaces.
            let raw = Array(suffix)
            let id = String(raw[0..<8]) + "-" + String(raw[8..<12]) + "-"
                + String(raw[12..<16]) + "-" + String(raw[16..<20]) + "-" + String(raw[20..<32])
            // Coalesce multiple interface results for the same Bonjour service.
            if let existing = found[id], existing.interface.index <= interface.index { continue }
            let endpoint = NWEndpoint.service(
                name: name, type: Self.serviceType, domain: Self.domain, interface: interface
            )
            found[id] = Discovered(
                destination: LANDestination(id: id, name: "本地清单 · " + suffix.prefix(8).uppercased()),
                endpoint: endpoint, interface: interface
            )
            if found.count >= Self.maximumDiscoveries { break }
        }
        endpoints = found
        discoveryChanged?(found.values.map(\.destination).sorted { $0.id < $1.id })
    }

    private static func publicSuffix(_ name: String) -> String? {
        let lower = name.lowercased()
        guard lower.hasPrefix("lc-"), lower.utf8.count <= 63 else { return nil }
        let suffix = lower.dropFirst(3).prefix(32)
        guard suffix.utf8.count == 32,
              suffix.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        let remainder = lower.dropFirst(35)
        // Permit only Bonjour's numeric collision suffix, never arbitrary labels.
        if !remainder.isEmpty {
            guard remainder.hasPrefix(" ("), remainder.hasSuffix(")") else { return nil }
            let digits = remainder.dropFirst(2).dropLast()
            guard !digits.isEmpty, digits.count <= 4,
                  digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        }
        return String(suffix)
    }

    private func onQueue<Value>(_ operation: () throws -> Value) rethrows -> Value {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try operation() }
        return try queue.sync(execute: operation)
    }
}
