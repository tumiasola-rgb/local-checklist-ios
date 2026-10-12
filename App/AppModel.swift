import Foundation
import SwiftUI
import WidgetKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot = AppSnapshot.empty
    @Published var problem: String?
    @Published var isModalOpen = false
    @Published private(set) var isReady = false
    @Published private(set) var isSyncing = false
    @Published private(set) var syncMessage = "局域网连接未开启"
    private var lanService: LANSyncService?
    private var lanIsForeground = false
    private var lanLifecycle = UUID()
    @Published private(set) var lanStatus: LANSyncStatus?
    private var repository: SharedRepository?
    private let reminderScheduler = LocalNotificationScheduler()
    @Published private(set) var notificationMessage = ""

    init() {
        do {
            let repository = try SharedRepository()
            self.repository = repository
            snapshot = try repository.read()
            isReady = true
            Task { await reloadSyncStatus(); await rebuildLocalNotifications() }
        } catch { problem = error.localizedDescription }
    }

    func refresh() {
        do {
            guard let repository else { return }
            snapshot = try repository.read()
            isReady = true
            Task { await reloadSyncStatus(); await rebuildLocalNotifications() }
        } catch { problem = error.localizedDescription }
    }

    func receivedSyncedData() {
        refresh()
        WidgetCenter.shared.reloadAllTimelines()
    }

    @discardableResult
    func commit(generation: UUID? = nil, _ change: (inout AppSnapshot) throws -> Void) -> Bool {
        do {
            guard let repository else { throw AppFailure.storageUnavailable }
            snapshot = try repository.update(expectedGeneration: generation, change)
            WidgetCenter.shared.reloadAllTimelines()
            Task { await reloadSyncStatus(); await rebuildLocalNotifications() }
            return true
        } catch { return handleMutationError(error) }
    }

    @discardableResult
    func save(_ task: TodoItem, generation: UUID, isNew: Bool, expectedOriginal: TodoItem? = nil) -> Bool {
        do {
            guard let repository else { throw AppFailure.storageUnavailable }
            snapshot = try repository.saveTask(task, isNew: isNew, expectedGeneration: generation, expectedOriginal: expectedOriginal)
            WidgetCenter.shared.reloadAllTimelines()
            Task { await reloadSyncStatus(); await rebuildLocalNotifications() }
            return true
        } catch { return handleMutationError(error) }
    }

    @discardableResult
    func save(_ note: NoteItem, generation: UUID, isNew: Bool, expectedOriginal: NoteItem? = nil) -> Bool {
        do {
            guard let repository else { throw AppFailure.storageUnavailable }
            snapshot = try repository.saveNote(note, isNew: isNew, expectedGeneration: generation, expectedOriginal: expectedOriginal)
            WidgetCenter.shared.reloadAllTimelines()
            Task { await reloadSyncStatus(); await rebuildLocalNotifications() }
            return true
        } catch { return handleMutationError(error) }
    }

    @discardableResult
    func save(_ item: Anniversary, generation: UUID, isNew: Bool, expectedOriginal: Anniversary? = nil) -> Bool {
        do {
            guard let repository else { throw AppFailure.storageUnavailable }
            snapshot = try repository.saveAnniversary(item, isNew: isNew, expectedGeneration: generation, expectedOriginal: expectedOriginal)
            WidgetCenter.shared.reloadAllTimelines(); Task { await reloadSyncStatus(); await rebuildLocalNotifications() }; return true
        } catch { return handleMutationError(error) }
    }
    @discardableResult
    func save(_ list: Checklist, generation: UUID, isNew: Bool, expectedOriginal: Checklist? = nil) -> Bool {
        do {
            guard let repository else { throw AppFailure.storageUnavailable }
            snapshot = try repository.saveList(list, isNew: isNew, expectedGeneration: generation, expectedOriginal: expectedOriginal)
            WidgetCenter.shared.reloadAllTimelines(); Task { await reloadSyncStatus(); await rebuildLocalNotifications() }; return true
        } catch { return handleMutationError(error) }
    }
    @discardableResult
    func deleteList(_ id: UUID, generation: UUID, expectedOriginal: Checklist? = nil) -> Bool {
        do {
            guard let repository else { throw AppFailure.storageUnavailable }
            snapshot = try repository.deleteList(id: id, expectedGeneration: generation, expectedOriginal: expectedOriginal)
            WidgetCenter.shared.reloadAllTimelines(); Task { await reloadSyncStatus(); await rebuildLocalNotifications() }; return true
        } catch { return handleMutationError(error) }
    }

    private func handleMutationError(_ error: Error) -> Bool {
        if case RepositoryError.committedMetadataFailure = error {
            refresh()
            problem = error.localizedDescription
            WidgetCenter.shared.reloadAllTimelines()
            Task { await reloadSyncStatus(); await rebuildLocalNotifications() }
            return true
        }
        problem = error.localizedDescription
        return false
    }

    @discardableResult
    func setCompleted(_ task: TodoItem, to completed: Bool) -> Bool {
        do {
            guard let repository else { throw AppFailure.storageUnavailable }
            snapshot = try repository.setTaskCompleted(id: task.id, isCompleted: completed, expectedGeneration: snapshot.generation)
            WidgetCenter.shared.reloadAllTimelines()
            Task { await reloadSyncStatus(); await rebuildLocalNotifications() }
            return true
        } catch { return handleMutationError(error) }
    }

    func postponeOverdue(ids: Set<UUID>) {
        let today = DayStamp.today
        commit(generation: snapshot.generation) { value in
            for i in value.tasks.indices where !value.tasks[i].isCompleted && ids.contains(value.tasks[i].id) {
                guard let due = value.tasks[i].endDay ?? value.tasks[i].startDay, due < today else { continue }
                if let start = value.tasks[i].startDay, value.tasks[i].endDay != nil {
                    let length = max(0, dayDifference(from: start, to: due))
                    value.tasks[i].startDay = DayStamp(date: Calendar.current.date(byAdding: .day, value: -length, to: Date()) ?? Date())
                    value.tasks[i].endDay = today
                } else { value.tasks[i].startDay = today; value.tasks[i].endDay = nil }
                value.tasks[i].updatedAt = max(Date(), value.tasks[i].updatedAt)
            }
        }
    }

    @discardableResult func deleteTask(_ id: UUID, generation: UUID? = nil, expectedOriginal: TodoItem? = nil) -> Bool {
        do {
            guard let repository else { throw AppFailure.storageUnavailable }
            snapshot = try repository.deleteTask(id: id, expectedGeneration: generation ?? snapshot.generation, expectedOriginal: expectedOriginal)
            WidgetCenter.shared.reloadAllTimelines(); Task { await reloadSyncStatus(); await rebuildLocalNotifications() }; return true
        } catch { return handleMutationError(error) }
    }
    @discardableResult func deleteNote(_ id: UUID, generation: UUID? = nil, expectedOriginal: NoteItem? = nil) -> Bool {
        do {
            guard let repository else { throw AppFailure.storageUnavailable }
            snapshot = try repository.deleteNote(id: id, expectedGeneration: generation ?? snapshot.generation, expectedOriginal: expectedOriginal)
            WidgetCenter.shared.reloadAllTimelines(); Task { await reloadSyncStatus(); await rebuildLocalNotifications() }; return true
        } catch { return handleMutationError(error) }
    }
    @discardableResult func deleteAnniversary(_ id: UUID, generation: UUID? = nil, expectedOriginal: Anniversary? = nil) -> Bool {
        do {
            guard let repository else { throw AppFailure.storageUnavailable }
            snapshot = try repository.deleteAnniversary(id: id, expectedGeneration: generation ?? snapshot.generation, expectedOriginal: expectedOriginal)
            WidgetCenter.shared.reloadAllTimelines(); Task { await reloadSyncStatus(); await rebuildLocalNotifications() }; return true
        } catch { return handleMutationError(error) }
    }
    func pinNote(_ id: UUID) {
        commit(generation: snapshot.generation) { value in
            guard let i = value.notes.firstIndex(where: { $0.id == id }) else { return }
            value.notes[i].isPinned.toggle(); value.notes[i].updatedAt = max(Date(), value.notes[i].updatedAt)
        }
    }
    func listName(_ id: UUID?) -> String { snapshot.lists.first { $0.id == id }?.title ?? "收集箱" }
    func exportData() throws -> Data { guard let repository else { throw AppFailure.storageUnavailable }; return try repository.exportData() }
    func previewImport(_ data: Data) throws -> ImportPreview { guard let repository else { throw AppFailure.storageUnavailable }; return try repository.previewImport(data) }
    func recoveryPreview() throws -> ImportPreview? { guard let repository else { throw AppFailure.storageUnavailable }; return try repository.readRecoveryPreview() }
    func restore(_ preview: ImportPreview) throws {
        guard let repository else { throw AppFailure.storageUnavailable }
        do { snapshot = try repository.replace(with: preview, expectedGeneration: snapshot.generation) }
        catch {
            if case RepositoryError.committedMetadataFailure = error { refresh(); problem = error.localizedDescription }
            else { throw error }
        }
        WidgetCenter.shared.reloadAllTimelines()
        Task { await reloadSyncStatus(); await rebuildLocalNotifications() }
    }
    func rebuildLocalNotifications() async {
        guard let repository else { return }
        let status = await reminderScheduler.rebuild(tasks: snapshot.tasks, readLatestTasks: { try repository.read().tasks })
        notificationMessage = status.summary
    }
    /// Called only after the user explicitly saves a task with an enabled reminder.
    func authorizeReminderFromUserAction() async {
        _ = await reminderScheduler.requestAuthorizationForReminder()
        await rebuildLocalNotifications()
    }

    func localSyncService() throws -> LANSyncService {
        if let lanService { return lanService }
        guard let repository else { throw AppFailure.storageUnavailable }
        let service = LANSyncService(repository: repository)
        lanService = service
        return service
    }
    func reloadSyncStatus() async {
        do {
            let status = try await localSyncService().status()
            lanStatus = status
            if !isSyncing { syncMessage = status.message }
        } catch { if lanStatus != nil { syncMessage = error.localizedDescription } }
    }
    /// Foreground only. A fresh install does not discover or listen automatically.
    func activateLANIfEnabled() async {
        lanIsForeground = true
        let token = UUID(); lanLifecycle = token
        await reloadSyncStatus()
        guard lanIsForeground, lanLifecycle == token, lanStatus?.enabled == true else { return }
        do {
            let service = try localSyncService()
            try await service.start()
            if !lanIsForeground { await service.suspend() }
            await reloadSyncStatus()
        } catch { syncMessage = error.localizedDescription }
    }
    func suspendLAN() async {
        lanIsForeground = false; lanLifecycle = UUID()
        guard let lanService else { return }
        await lanService.suspend()
        await reloadSyncStatus()
    }
    func syncNow() async {
        guard !isSyncing, lanStatus?.isBusy != true else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let report = try await localSyncService().sync()
            receivedSyncedData()
            await reloadSyncStatus()
            syncMessage = report.summary
        } catch {
            refresh()
            await reloadSyncStatus()
            syncMessage = error.localizedDescription
            problem = error.localizedDescription
        }
    }

    func rememberSearch(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        commit(generation: snapshot.generation) { value in
            value.settings.searchHistory.removeAll { $0 == text }
            value.settings.searchHistory.insert(text, at: 0)
            value.settings.searchHistory = Array(value.settings.searchHistory.prefix(30))
        }
    }
}

enum AppFailure: LocalizedError {
    case storageUnavailable
    case invalidImport
    var errorDescription: String? {
        switch self {
        case .storageUnavailable: return "无法打开本地资料。请查看上方错误详情，已有数据不会被重置。"
        case .invalidImport: return "备份文件过大或无法读取。请使用本 App 导出的 JSON 备份。"
        }
    }
}

extension TodoItem {
    var timeLabel: String? { guard !scheduleIsAllDay else { return nil }; return timeMinutes.map { String(format: "%02d:%02d", $0 / 60, $0 % 60) } }
    var dueLabel: String {
        guard let day = dueDay else { return "无日期" }
        let days = dayDifference(from: .today, to: day)
        if days == 0 { return timeLabel ?? "今天" }
        if days < 0 { return "\(-days) 天" }
        if days == 1 { return "明天" }
        return day.rawValue
    }
}
