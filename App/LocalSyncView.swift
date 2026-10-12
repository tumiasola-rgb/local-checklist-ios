import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Uses AppModel's sole service. This screen never creates a second listener.
@MainActor
struct LANSyncScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let service: LANSyncService
    let onDataChanged: () -> Void
    @State private var status: LANSyncStatus?
    @State private var statusProblem: String?
    @State private var actionProblem: String?
    @State private var isVisible = false
    @State private var isPerforming = false
    @State private var isPairingAction = false
    @State private var isExchanging = false
    @State private var isCancellingExchange = false
    @State private var exchangeNotice: String?
    @State private var activeActionID: UUID?
    @State private var latestStatusRequestID: UUID?
    @State private var actionTask: Task<Void, Never>?
    @State private var isCleaningPairing = false
    @State private var showCodeInput = false
    @State private var codeDraft = ""
    @State private var selectedPeerID: String?
    @State private var ownedPasteboardChange: Int?
    @State private var copyNotice: String?
    @State private var confirmStop = false
    @State private var confirmForget = false
    @State private var confirmResume = false

    private var isBusy: Bool { isPerforming || isCleaningPairing || isCancellingExchange || (status?.isBusy ?? false) }
    private var pairingInProgress: Bool { status?.pairingOffer != nil || status?.pairingRequest != nil || isPairingAction }
    private var normalizedDraft: String {
        codeDraft.filter { !$0.isWhitespace && $0 != "-" }.uppercased()
    }
    private var draftIsValid: Bool {
        let bytes = normalizedDraft.utf8
        return bytes.count == 32 && bytes.allSatisfy { (48...57).contains($0) || (65...70).contains($0) }
    }
    private var selectedPeerIsPresent: Bool {
        guard let selectedPeerID else { return false }
        return status?.nearbyPeers.contains { $0.id == selectedPeerID } == true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("手机与 Mac") {
                    Label("同一 Wi-Fi / 局域网，直接连接", systemImage: "wifi")
                    Text("两台设备都需打开 App 并允许本地网络访问。配对后可从任一端手动双向同步待办、笔记、清单、标签、纪念日、相关修改与删除。资料各自保存在本机，不使用云端中转。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let status {
                    connectionSection(status)
                    if status.enabled && status.pairedPeer == nil {
                        pairingSection(status)
                    }
                    statusSection(status)
                    if status.sync.pausedAfterImport { importSection }
                    if !status.sync.conflicts.isEmpty {
                        Section("保留的冲突版本") {
                            ForEach(status.sync.conflicts) { conflict in
                                NavigationLink {
                                    LANConflictScreen(service: service, conflict: conflict, serviceIsBusy: isBusy, onDataChanged: onDataChanged)
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(conflict.title).lineLimit(2)
                                        Text("\(conflict.versions.count) 个版本，选择前不会悄悄覆盖")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                } else if statusProblem == nil {
                    Section { ProgressView("正在读取本机同步状态…") }
                }
                if let problem = actionProblem ?? statusProblem {
                    Section("暂未完成") {
                        Text(problem).font(.footnote).foregroundStyle(.red)
                        if statusProblem != nil {
                            Button("重新读取状态") { Task { await reloadStatus() } }.disabled(isBusy)
                        }
                    }
                }
                Section("连接与隐私") {
                    Text("仅支持一组配对设备。首次配对使用随机 32 位十六进制配对码建立加密连接，再由两端核对数字并分别确认。配对密钥只保存在本设备钥匙串，不随整包备份导出。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("发现设备不代表已交换资料。另一端关闭 App、休眠、离线，或路由器隔离设备时，修改仍保留在本机；下次两端可连接时，再点双向同步。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("局域网同步")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { clearPairingOnExit(); dismiss() }
                }
            }
            .confirmationDialog("暂停此设备的局域网连接？", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("暂停连接") { perform { try await service.stop() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("停止发现与交换资料，已有配对、本机资料和待同步修改保留。需要时可重新开启。")
            }
            .confirmationDialog("解除此设备的配对？", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("解除配对", role: .destructive) {
                    clearSecretDraft()
                    perform { try await service.forgetPeer() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("移除此设备保存的配对密钥并停止与原设备交换资料，不删除待办、笔记等用户记录。重新配对前，也请在另一台设备解除旧配对。")
            }
            .confirmationDialog("允许恢复后的资料参与合并？", isPresented: $confirmResume, titleVisibility: .visible) {
                Button("确认并允许合并") { perform(changesData: true) { try await service.resumeAfterImport() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("下次双向同步会合并两端内容，备份中缺少的项目不会作为删除传播；不同版本会保留供你审阅。确认后仍需点击双向同步。")
            }
        }
        .onAppear { isVisible = true }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await reloadStatus()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                guard !Task.isCancelled else { return }
                await reloadStatus()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // System permission prompts temporarily make a scene inactive.
            // Hide secrets while inactive, but cancel only when backgrounded.
            if phase == .background { clearPairingOnExit() }
        }
        .onDisappear {
            isVisible = false
            clearPairingOnExit()
        }
    }

    @ViewBuilder
    private func connectionSection(_ status: LANSyncStatus) -> some View {
        Section("连接") {
            if let peer = status.pairedPeer {
                LabeledContent("已配对设备", value: peer.name)
                if status.enabled {
                    let isNearby = status.nearbyPeers.contains { $0.id == peer.id }
                    Label(isNearby ? "已在附近发现配对设备" : "暂未在附近发现配对设备", systemImage: isNearby ? "wifi" : "wifi.slash")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("立即双向同步", systemImage: "arrow.triangle.2.circlepath") {
                        perform(exchange: true, changesData: true) { _ = try await service.sync() }
                    }
                    .disabled(isBusy || status.sync.pausedAfterImport)
                }
                Button("解除配对", role: .destructive) { confirmForget = true }.disabled(isBusy)
            }
            if status.enabled {
                Button("暂停此设备的连接") { confirmStop = true }.disabled(isBusy || pairingInProgress)
            } else {
                Button("开启局域网连接", systemImage: "antenna.radiowaves.left.and.right") {
                    perform { try await service.start() }
                }
                .disabled(isBusy)
                Text("首次开启时，请在系统提示中允许本地网络访问。只有配对并在两端确认后，才会交换用户记录。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func pairingSection(_ status: LANSyncStatus) -> some View {
        if scenePhase == .active, let request = status.pairingRequest {
            Section("请在两端核对并确认") {
                LabeledContent("另一台设备", value: request.peerName)
                Text("先确认两台屏幕显示的核对数字相同，再分别点确认。不一致或并非你正在操作的设备，请取消。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(request.verificationCode)
                    .font(.system(.largeTitle, design: .monospaced)).bold()
                    .privacySensitive()
                    .accessibilityLabel("本次连接核对数字")
                    .accessibilityValue(request.verificationCode)
                Text("这些数字仅用于核对本次已加密的连接，不是首次配对码。双方确认前不会交换待办、笔记等用户记录。")
                    .font(.footnote).foregroundStyle(.secondary)
                if request.localConfirmed {
                    Label("本机已确认，等待另一台确认", systemImage: "hourglass")
                } else {
                    Button("数字一致，确认配对", systemImage: "checkmark.shield") {
                        clearSecretDraft()
                        perform(pairing: true, changesData: true) {
                            try await service.confirmPairing(id: request.id, approved: true)
                        }
                    }
                    .disabled(isPerforming || isCleaningPairing || isCancellingExchange)
                }
                Button("取消配对", role: .destructive) {
                    clearSecretDraft()
                    perform(pairing: true) { try await service.confirmPairing(id: request.id, approved: false) }
                }
                .disabled(isPerforming || isCleaningPairing || isCancellingExchange)
            }
        } else if scenePhase == .active, let offer = status.pairingOffer {
            Section("在另一台设备输入配对码") {
                Text("在另一台设备打开局域网同步，选“输入另一台的配对码”，选择本设备后输入下方完整配对码。只在你自己的两台设备之间使用，请勿发到聊天或公开截图。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(groupedCode(offer.code))
                    .font(.system(.title3, design: .monospaced)).bold()
                    .fixedSize(horizontal: false, vertical: true)
                    .privacySensitive()
                    .accessibilityLabel("首次配对码")
                    .accessibilityValue(offer.code)
                LabeledContent("失效时间", value: offer.expiresAt.formatted(date: .omitted, time: .standard))
                Button("复制到本机，最多保留 1 分钟", systemImage: "doc.on.doc") { copyCode(offer) }
                    .disabled(offer.expiresAt <= Date() || isCleaningPairing)
                if let copyNotice { Text(copyNotice).font(.caption).foregroundStyle(.secondary) }
                Button("取消配对", role: .destructive) { clearPairingOnExit() }
                    .disabled(isCleaningPairing)
                Text("配对码只在当前配对页显示；复制内容不会进入通用剪贴板，离开页面或取消时会清除本页仍持有的剪贴板内容。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } else if scenePhase == .active {
            Section("首次配对") {
                Button("在这台生成配对码", systemImage: "qrcode") {
                    clearSecretDraft()
                    showCodeInput = false
                    perform(pairing: true) { try await service.beginPairing() }
                }
                .disabled(isBusy)
                Button(showCodeInput ? "收起配对码输入" : "输入另一台的配对码", systemImage: "keyboard") {
                    clearSecretDraft()
                    showCodeInput.toggle()
                }
                .disabled(isBusy)
                if showCodeInput {
                    if status.nearbyPeers.isEmpty {
                        Text("尚未发现等待配对的设备。请先在另一台生成配对码，并保持两台 App 打开。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Picker("另一台设备", selection: $selectedPeerID) {
                            Text("请选择").tag(Optional<String>.none)
                            ForEach(status.nearbyPeers) { peer in Text(peer.name).tag(Optional(peer.id)) }
                        }
                    }
                    SecureField("32 位配对码，可带分组横线", text: $codeDraft)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .privacySensitive()
                        .onSubmit { joinPairing() }
                        .onChange(of: codeDraft) { _, value in
                            if value.count > 80 { codeDraft = String(value.prefix(80)) }
                        }
                        .disabled(isBusy)
                    Button("连接并核对", systemImage: "link") { joinPairing() }
                        .disabled(isBusy || !draftIsValid || !selectedPeerIsPresent)
                    Text("请输入另一台刚生成的完整 32 位十六进制配对码。不会用六位数字或设备名称代替加密密钥。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func statusSection(_ status: LANSyncStatus) -> some View {
        Section("同步状态") {
            if isCancellingExchange { ProgressView("正在取消本次交换…") }
            else if isBusy { ProgressView("正在处理…") }
            Text(status.message).font(.subheadline)
            if status.pairedPeer != nil, !pairingInProgress, isExchanging || status.isBusy || isCancellingExchange {
                // Cancellation must remain usable while the ordinary action
                // gate is occupied by either an outgoing or incoming exchange.
                Button("取消本次交换", systemImage: "stop.circle") { cancelExchange() }
                    .disabled(isCancellingExchange || isCleaningPairing)
                Text("取消会停止本次连接。已保存的部分会保留，未确认变更仍待同步；不会解除配对或删除资料。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let exchangeNotice { Text(exchangeNotice).font(.footnote).foregroundStyle(.secondary) }
            if status.pairedPeer == nil, status.isBusy, status.pairingOffer == nil, status.pairingRequest == nil {
                Button("取消正在建立的配对连接", role: .destructive) { clearPairingOnExit() }
                    .disabled(isCleaningPairing)
            }
            LabeledContent("本机待对方确认的变更", value: "\(status.sync.pendingChanges)")
            LabeledContent("需要处理的冲突", value: "\(status.sync.conflicts.count)")
            if let date = status.sync.lastSuccessfulSync {
                LabeledContent("上次对方持久化确认", value: date.formatted(date: .abbreviated, time: .shortened))
            } else {
                Text("尚无对方持久化接收的确认记录").font(.footnote).foregroundStyle(.secondary)
            }
            Text("只有收到对方写入本机存储后的确认，才会更新已确认状态。已配对、发现设备或开始发送，都不代表另一端已收到；之后新增的修改仍需再次同步。")
                .font(.footnote).foregroundStyle(.secondary)
            if let failure = status.sync.lastFailure, failure != status.message {
                Text(failure).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private var importSection: some View {
        Section("导入后已暂停传播") {
            Text("刚恢复的备份可能比另一台旧。恢复后不会自动把备份里缺少的项目当作删除；核对后才允许合并，冲突版本会保留。")
                .font(.footnote).foregroundStyle(.secondary)
            Button("核对后允许合并") { confirmResume = true }.disabled(isBusy)
        }
    }

    private func joinPairing() {
        guard !isBusy, draftIsValid, selectedPeerIsPresent, let peerID = selectedPeerID else { return }
        let code = normalizedDraft
        clearSecretDraft()
        perform(pairing: true) { try await service.pair(peerID: peerID, code: code) }
    }

    private func perform(pairing: Bool = false, exchange: Bool = false, changesData: Bool = false, _ operation: @escaping @MainActor () async throws -> Void) {
        guard !isPerforming && !isCleaningPairing && !isCancellingExchange, isVisible, scenePhase == .active else { return }
        let actionID = UUID()
        activeActionID = actionID
        isPerforming = true
        isPairingAction = pairing
        isExchanging = exchange
        actionProblem = nil
        exchangeNotice = nil
        actionTask = Task {
            defer {
                // An explicitly cancelled action no longer owns UI state.
                // Its delayed completion must not clear a newer task's gate.
                if activeActionID == actionID {
                    activeActionID = nil
                    isPerforming = false
                    isPairingAction = false
                    isExchanging = false
                    actionTask = nil
                    if changesData { onDataChanged() }
                }
            }
            do { try await operation() }
            catch {
                if activeActionID == actionID && !Task.isCancelled && isVisible && scenePhase == .active {
                    actionProblem = error.localizedDescription
                }
            }
            if activeActionID == actionID && !Task.isCancelled { await reloadStatus() }
        }
    }

    /// A separate cancellation lane: do not route through perform(), which is
    /// intentionally occupied while an outgoing exchange waits on the peer.
    private func cancelExchange() {
        guard !isCancellingExchange && !isCleaningPairing && !pairingInProgress,
              status?.pairedPeer != nil, isExchanging || status?.isBusy == true else { return }
        isCancellingExchange = true
        actionProblem = nil
        exchangeNotice = nil
        let previousAction = actionTask
        activeActionID = nil
        latestStatusRequestID = nil
        previousAction?.cancel()
        Task {
            // suspend closes network activity, but retains the pairing,
            // durable content and permission to reconnect on a later attempt.
            await service.suspend()
            // Do not offer Retry while this screen's old exchange can still
            // finish its persistence/error handling and unwind its defer.
            await previousAction?.value
            onDataChanged()
            await reloadStatus()
            actionTask = nil
            isPerforming = false
            isPairingAction = false
            isExchanging = false
            exchangeNotice = "已停止本次连接。已保存的部分会保留，未确认变更仍待同步；在途内容可能已到对端，下次会按版本核对。"
            isCancellingExchange = false
        }
    }

    private func reloadStatus() async {
        guard isVisible && scenePhase == .active else { return }
        let requestID = UUID()
        latestStatusRequestID = requestID
        do {
            let value = try await service.status()
            guard latestStatusRequestID == requestID, isVisible && scenePhase == .active, !Task.isCancelled else { return }
            let prior = status
            if prior?.pairingOffer?.id != value.pairingOffer?.id || prior?.pairingRequest?.id != value.pairingRequest?.id {
                clearSecretDraft()
            }
            if let selectedPeerID, !value.nearbyPeers.contains(where: { $0.id == selectedPeerID }) { self.selectedPeerID = nil }
            if value.pairedPeer != nil { clearSecretDraft(); showCodeInput = false }
            status = value
            statusProblem = nil
            if let prior, prior.sync.lastSuccessfulSync != value.sync.lastSuccessfulSync || prior.sync.conflicts != value.sync.conflicts {
                if prior.sync.lastSuccessfulSync != value.sync.lastSuccessfulSync { actionProblem = nil }
                onDataChanged()
            }
        } catch {
            guard latestStatusRequestID == requestID, isVisible && scenePhase == .active, !Task.isCancelled else { return }
            status = nil
            clearSecretDraft()
            statusProblem = error.localizedDescription
        }
    }

    private func copyCode(_ offer: LANPairingOffer) {
        guard scenePhase == .active, isVisible, offer.expiresAt > Date(), status?.pairingOffer?.id == offer.id else { return }
        let expiry = min(offer.expiresAt, Date().addingTimeInterval(60))
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: groupedCode(offer.code)]], options: [.localOnly: true, .expirationDate: expiry])
        ownedPasteboardChange = UIPasteboard.general.changeCount
        copyNotice = "已复制到本机，过期后自动清除"
    }

    private func clearSecretDraft() {
        codeDraft = ""
        copyNotice = nil
        if let ownedPasteboardChange, UIPasteboard.general.changeCount == ownedPasteboardChange {
            UIPasteboard.general.items = []
        }
        ownedPasteboardChange = nil
    }

    /// Cancel first, then cancel again after any in-flight pairing action has
    /// unwound. This prevents a late begin/join result reviving a dismissed code.
    private func clearPairingOnExit() {
        clearSecretDraft()
        showCodeInput = false
        selectedPeerID = nil
        confirmStop = false
        confirmForget = false
        confirmResume = false
        let pairingAction = isPairingAction ? actionTask : nil
        pairingAction?.cancel()
        latestStatusRequestID = nil
        status = nil
        guard !isCleaningPairing else { return }
        isCleaningPairing = true
        Task {
            await service.cancelPairing()
            await pairingAction?.value
            await service.cancelPairing()
            isCleaningPairing = false
            await reloadStatus()
        }
    }

    private func groupedCode(_ code: String) -> String {
        let characters = Array(code.filter { !$0.isWhitespace && $0 != "-" }.uppercased())
        return stride(from: 0, to: characters.count, by: 4).map { start in
            String(characters[start..<min(start + 4, characters.count)])
        }.joined(separator: "-")
    }
}

/// A choice includes the complete version set that was visible when the user
/// selected it. Never rebuild that set from a later status poll at confirmation.
private struct LANConflictChoice {
    let version: SyncVersion
    let expectedHeadIDs: Set<UUID>
}

@MainActor
private struct LANConflictScreen: View {
    @Environment(\.dismiss) private var dismiss
    let service: LANSyncService
    let conflict: SyncConflict
    let serviceIsBusy: Bool
    let onDataChanged: () -> Void
    @State private var selected: LANConflictChoice?
    @State private var isResolving = false
    @State private var problem: String?

    var body: some View {
        List {
            Section {
                Text(conflict.title).font(.headline)
                Text("请逐个检查完整版本，再选择要保留的版本。删除也是一个明确版本；选择删除后，会在下次成功同步时传给配对设备。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let problem {
                Section("暂未采用所选版本") {
                    Text(problem).foregroundStyle(.red)
                    Text("如果版本集合已经变化，请返回同步页，重新打开冲突并核对全部版本。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            ForEach(conflict.versions) { version in
                Section(version.isDeleted ? "删除版本" : "内容版本") {
                    Text(version.summary).textSelection(.enabled)
                    Text(version.detail).font(.body).textSelection(.enabled)
                    Button(version.isDeleted ? "采用这个删除版本" : "保留这个版本", role: version.isDeleted ? .destructive : nil) {
                        selected = LANConflictChoice(version: version, expectedHeadIDs: Set(conflict.versions.map(\.id)))
                    }
                    .disabled(isResolving || serviceIsBusy)
                }
            }
            if isResolving { ProgressView("正在保存选择…") }
        }
        .navigationTitle("处理冲突")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isResolving)
        .confirmationDialog("确认采用所选版本？", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
            if let choice = selected {
                Button(choice.version.isDeleted ? "确认删除" : "确认保留", role: choice.version.isDeleted ? .destructive : nil) {
                    resolve(choice)
                }
            }
            Button("取消", role: .cancel) { selected = nil }
        } message: {
            Text("选择先写入本机，需再次双向同步后才会传给配对设备。对方离线时，不能确认它已经收到。")
        }
    }

    private func resolve(_ choice: LANConflictChoice) {
        guard !isResolving && !serviceIsBusy else { return }
        isResolving = true
        problem = nil
        selected = nil
        Task {
            defer { isResolving = false }
            do {
                try await service.resolveConflict(itemKey: conflict.key, versionID: choice.version.id, expectedHeadIDs: choice.expectedHeadIDs)
                onDataChanged()
                dismiss()
            } catch { problem = error.localizedDescription }
        }
    }
}
