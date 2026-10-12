import Foundation
import Combine
import UserNotifications

struct PlannedTaskNotification: Equatable, Sendable {
    let identifier: String
    let taskID: UUID
    let date: Date
}

struct TaskNotificationPlan: Sendable {
    let notifications: [PlannedTaskNotification]
    let deferredCount: Int
    let invalidCount: Int
}

enum TaskNotificationPlanner {
    static let identifierPrefix = "local-checklist.reminder.v1."
    static let maximumPending = 60
    static func identifier(for taskID: UUID) -> String { identifierPrefix + taskID.uuidString.lowercased() }
    static func owns(_ identifier: String) -> Bool { identifier.hasPrefix(identifierPrefix) }

    /// Current task instances only. Recurrence is advanced in the completion
    /// transaction, never expanded infinitely into the system notification queue.
    static func plan(tasks: [TodoItem], now: Date, otherPendingCount: Int = 0) -> TaskNotificationPlan {
        var candidates: [PlannedTaskNotification] = []
        var deferred = 0; var invalid = 0; var seen = Set<UUID>()
        for task in tasks where !task.isCompleted && task.schedule?.reminder != nil {
            guard seen.insert(task.id).inserted else { continue }
            guard let date = TaskScheduleMath.reminderDate(for: task) else { invalid += 1; continue }
            guard date > now else { continue } // Never deliver an overdue reminder immediately.
            candidates.append(PlannedTaskNotification(identifier: identifier(for: task.id), taskID: task.id, date: date))
        }
        candidates.sort { $0.date == $1.date ? $0.identifier < $1.identifier : $0.date < $1.date }
        let capacity = max(0, maximumPending - max(0, otherPendingCount))
        let selected = Array(candidates.prefix(capacity))
        deferred += max(0, candidates.count - selected.count)
        return TaskNotificationPlan(notifications: selected, deferredCount: deferred, invalidCount: invalid)
    }
}

struct LocalNotificationPermission: Equatable, Sendable {
    enum Authorization: Equatable, Sendable { case notDetermined, denied, authorized, quiet, unknown }
    let authorization: Authorization
    let alertsEnabled: Bool
    let soundsEnabled: Bool
    var canSchedule: Bool { authorization == .authorized || authorization == .quiet }
}

struct LocalNotificationStatus: Equatable, Sendable {
    var permission: LocalNotificationPermission
    var scheduledCount = 0
    var deferredCount = 0
    var invalidCount = 0
    var failureCount = 0
    var isRebuilding = false
    var failure: String?
    var summary: String {
        if let failure { return "提醒更新未完成：\(failure)" }
        switch permission.authorization {
        case .notDetermined: return "本机通知尚未授权，保存有效提醒时会申请权限"
        case .denied: return "本机通知权限已关闭；提醒规则已保存，但这台设备不会通知"
        case .unknown: return "无法确认本机通知权限，请检查系统设置"
        case .authorized, .quiet: break
        }
        if isRebuilding { return "正在更新本机提醒…" }
        var value = "本机已安排 \(scheduledCount) 条提醒"
        if deferredCount > 0 { value += "，\(deferredCount) 条待后续打开 App 补排" }
        if invalidCount > 0 { value += "，\(invalidCount) 条日期无法安排" }
        if failureCount > 0 { value += "，\(failureCount) 条安排失败，请稍后重试" }
        if permission.authorization == .quiet || !permission.alertsEnabled { value += "；横幅未开启" }
        if !permission.soundsEnabled { value += "；声音未开启" }
        return value
    }
}

/// Injectable boundary: tests exercise denied permission, ownership, budgets,
/// replacement, and interleaved rebuilds without touching system notifications.
@MainActor
protocol TaskNotificationCenterClient: AnyObject {
    func permission() async -> LocalNotificationPermission
    func requestAuthorization() async throws -> Bool
    func pendingIdentifiers() async -> [String]
    func deliveredIdentifiers() async -> [String]
    func removePending(_ identifiers: [String])
    func removeDelivered(_ identifiers: [String])
    func add(_ notification: PlannedTaskNotification) async throws
}

@MainActor
final class SystemTaskNotificationCenter: TaskNotificationCenterClient {
    private let center = UNUserNotificationCenter.current()
    func permission() async -> LocalNotificationPermission {
        let settings = await center.notificationSettings()
        let status: LocalNotificationPermission.Authorization
        switch settings.authorizationStatus {
        case .notDetermined: status = .notDetermined
        case .denied: status = .denied
        case .authorized, .ephemeral: status = .authorized
        case .provisional: status = .quiet
        @unknown default: status = .unknown
        }
        return LocalNotificationPermission(authorization: status,
            alertsEnabled: settings.alertSetting == .enabled, soundsEnabled: settings.soundSetting == .enabled)
    }
    func requestAuthorization() async throws -> Bool {
        #if WIDGET_EXTENSION
        return false // Widgets only rebuild under the main app's existing grant.
        #else
        return try await center.requestAuthorization(options: [.alert, .sound])
        #endif
    }
    func pendingIdentifiers() async -> [String] { await center.pendingNotificationRequests().map(\.identifier) }
    func deliveredIdentifiers() async -> [String] { await center.deliveredNotifications().map { $0.request.identifier } }
    func removePending(_ identifiers: [String]) { if !identifiers.isEmpty { center.removePendingNotificationRequests(withIdentifiers: identifiers) } }
    func removeDelivered(_ identifiers: [String]) { if !identifiers.isEmpty { center.removeDeliveredNotifications(withIdentifiers: identifiers) } }
    func add(_ notification: PlannedTaskNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = "待办提醒"
        content.body = "有一项待办到了提醒时间，打开本地清单查看。"
        content.sound = .default
        // A UUID only. Titles, notes, tags and private task text never enter the
        // notification payload or lock-screen preview.
        content.userInfo = ["taskID": notification.taskID.uuidString]
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: notification.date)
        components.calendar = calendar; components.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try await center.add(UNNotificationRequest(identifier: notification.identifier, content: content, trigger: trigger))
    }
}

@MainActor
final class LocalNotificationScheduler: ObservableObject {
    @Published private(set) var status = LocalNotificationStatus(permission:
        LocalNotificationPermission(authorization: .notDetermined, alertsEnabled: false, soundsEnabled: false))
    private let client: any TaskNotificationCenterClient
    private let now: () -> Date
    private var queuedTasks: [TodoItem] = []
    private var readLatestTasks: (() throws -> [TodoItem])?
    private var revision: UInt64 = 0
    private var running = false
    private var waiters: [CheckedContinuation<LocalNotificationStatus, Never>] = []

    init(client: (any TaskNotificationCenterClient)? = nil, now: @escaping () -> Date = Date.init) {
        self.client = client ?? SystemTaskNotificationCenter(); self.now = now
    }

    /// Call only after an explicitly configured, valid reminder has been saved.
    /// No startup, sync, import, widget or background path invokes this method.
    @discardableResult
    func requestAuthorizationForReminder() async -> Bool {
        var permission = await client.permission()
        if permission.authorization == .notDetermined {
            do { _ = try await client.requestAuthorization() }
            catch { status.failure = error.localizedDescription; return false }
            permission = await client.permission()
        }
        status.permission = permission
        return permission.canSchedule
    }

    /// A single worker drains the newest snapshot, even when an older call was
    /// suspended in a notification-center await. Every caller waits for the final
    /// drain. The read closure detects app/widget commits while awaits run.
    @discardableResult
    func rebuild(tasks: [TodoItem], readLatestTasks: (() throws -> [TodoItem])? = nil) async -> LocalNotificationStatus {
        queuedTasks = tasks; self.readLatestTasks = readLatestTasks; revision &+= 1
        if running {
            return await withCheckedContinuation { waiters.append($0) }
        }
        running = true; status.isRebuilding = true
        while true {
            do { try reloadLatest() }
            catch { await failClosed(error); break }
            let token = revision
            let current = queuedTasks
            let permission = await client.permission()
            if superseded(token) { continue }
            let pending = await client.pendingIdentifiers()
            if superseded(token) { continue }
            let delivered = await client.deliveredIdentifiers()
            if superseded(token) { continue }
            let ownedPending = pending.filter(TaskNotificationPlanner.owns)
            let liveIDs = Set(current.filter { !$0.isCompleted && $0.schedule?.reminder != nil }.map { TaskNotificationPlanner.identifier(for: $0.id) })
            client.removeDelivered(delivered.filter { TaskNotificationPlanner.owns($0) && !liveIDs.contains($0) })
            guard permission.canSchedule else {
                client.removePending(ownedPending)
                status = LocalNotificationStatus(permission: permission)
                break
            }
            let plan = TaskNotificationPlanner.plan(tasks: current, now: now(), otherPendingCount: pending.count - ownedPending.count)
            let wanted = Set(plan.notifications.map(\.identifier))
            client.removePending(ownedPending.filter { !wanted.contains($0) })
            var added = 0; var failures = 0
            for notification in plan.notifications {
                if superseded(token) { break }
                // Same identifier replaces its existing request instead of adding
                // duplicates. Past reminders are never resurrected by a rebuild.
                if notification.date <= now() { client.removePending([notification.identifier]); continue }
                do { try await client.add(notification); added += 1 }
                catch { failures += 1; client.removePending([notification.identifier]) }
                if superseded(token) { break }
            }
            if superseded(token) { continue }
            // Read-back checks what the OS accepted, not a delivery guarantee.
            let accepted = await client.pendingIdentifiers()
            if superseded(token) { continue }
            let actual = Set(accepted).intersection(wanted).count
            status = LocalNotificationStatus(permission: permission, scheduledCount: actual,
                deferredCount: plan.deferredCount, invalidCount: plan.invalidCount,
                failureCount: max(failures, added - actual))
            break
        }
        running = false; status.isRebuilding = false
        let result = status; let suspended = waiters; waiters.removeAll()
        for waiter in suspended { waiter.resume(returning: result) }
        return result
    }

    private func reloadLatest() throws {
        if let latest = try readLatestTasks?(), latest != queuedTasks { queuedTasks = latest; revision &+= 1 }
    }
    private func superseded(_ token: UInt64) -> Bool {
        do { try reloadLatest() }
        catch {
            // Do not continue adding stale reminders if authoritative storage
            // becomes unavailable. The next loop performs fail-closed removal.
            revision &+= 1
            return true
        }
        return token != revision
    }
    private func failClosed(_ error: Error) async {
        let pending = await client.pendingIdentifiers()
        client.removePending(pending.filter(TaskNotificationPlanner.owns))
        status.scheduledCount = 0; status.failure = error.localizedDescription
    }
}
