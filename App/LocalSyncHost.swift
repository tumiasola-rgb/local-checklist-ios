import SwiftUI

/// Shares the single AppModel-owned service; presenting this screen never
/// creates a second listener or silently begins device discovery.
struct LocalSyncHost: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Group {
            if let service = try? model.localSyncService() {
                LANSyncScreen(service: service) {
                    model.receivedSyncedData()
                    Task { await model.reloadSyncStatus() }
                }
            } else {
                ContentUnavailableView("本机资料暂不可用", systemImage: "externaldrive.badge.exclamationmark", description: Text(model.problem ?? "请先确认本机资料能够正常读取。"))
            }
        }
        .onDisappear { Task { await model.reloadSyncStatus() } }
    }
}
