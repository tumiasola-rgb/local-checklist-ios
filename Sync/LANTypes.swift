import Foundation

public struct LANPeer: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
}
public struct LANPairedPeer: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
}
public struct LANPairingOffer: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// A short-lived 128-bit SECRET, not an ordinary verification number.
    /// Show only on this device. Never log, export, share, or use universal clipboard.
    public let code: String
    public let expiresAt: Date
}
public struct LANPairingRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let peerName: String
    /// Public six-digit session comparison value; not the secret pairing code.
    public let verificationCode: String
    public let localConfirmed: Bool
    public let remoteConfirmed: Bool
}
public struct LANSyncStatus: Sendable {
    public let enabled: Bool
    public let isBusy: Bool
    public let nearbyPeers: [LANPeer]
    public let pairedPeer: LANPairedPeer?
    public let pairingOffer: LANPairingOffer?
    public let pairingRequest: LANPairingRequest?
    public let sync: SyncStatus
    public let message: String
    public let lastReport: SyncReport?
}
internal enum LANFailure: Error, LocalizedError, Equatable {
    case notPaired, stalePairing, pairingExpired, pairingDeclined, pairingRequired, peerUnavailable
    case installationMismatch, protocolViolation(String), sizeLimit, timeout, invalidReceipt, unconfirmedPairing
    public var errorDescription: String? {
        switch self {
        case .notPaired: return "请先在自己的两台设备之间配对。"
        case .stalePairing: return "配对会话已经改变，请使用当前显示的配对码重新连接。"
        case .pairingExpired: return "临时配对码或确认已过期，未交换用户内容。"
        case .pairingDeclined: return "配对已取消，未交换用户内容。"
        case .pairingRequired: return "当前已有配对记录；如要改配，请先明确忘记旧配对。"
        case .peerUnavailable: return "未发现已配对设备。请让两台设备连接同一局域网，并在前台打开应用。"
        case .installationMismatch: return "发现旧安装留下的配对密钥，但本机资料没有匹配的授权。不会自动接收或发送，请先忘记旧配对，再重新确认配对。"
        case .protocolViolation(let reason): return "局域网协议校验失败：\(reason)。未提交未校验的内容。"
        case .sizeLimit: return "同步包超过 20 MiB 或单帧超过安全上限，未提交此次接收。"
        case .timeout: return "连接或确认超时；未确认的内容仍在本机待同步。"
        case .invalidReceipt: return "没有收到与本次版本匹配的持久化确认，不能报告对方已收到。"
        case .unconfirmedPairing: return "双方尚未完成配对确认，不能交换内容。"
        }
    }
}
