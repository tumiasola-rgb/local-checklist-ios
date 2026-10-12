import AppIntents
import Foundation
import WidgetKit

/// A command, deliberately not a toggle: repeated or delayed taps cannot undo
/// completion. Writes use the repository's locked read-modify-write transaction.
struct CompleteTodoIntent: AppIntent {
    static var title: LocalizedStringResource = "完成待办"
    static var description = IntentDescription("将本机清单中的一项待办标记为已完成。")
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "待办 ID") var taskID: String
    @Parameter(title: "数据版本") var generationID: String

    init() {}

    init(taskID: UUID, generationID: UUID) {
        self.taskID = taskID.uuidString
        self.generationID = generationID.uuidString
    }

    func perform() async throws -> some IntentResult {
        // Refresh stale rows on both success and failure (for example after a
        // restore). A reload is only a request and never substitutes for a write.
        defer { WidgetCenter.shared.reloadAllTimelines() }
        guard let id = UUID(uuidString: taskID),
              let generation = UUID(uuidString: generationID) else {
            throw CompletionError.invalidReference
        }
        let repository = try SharedRepository()
        // A backup restore gives the store a new generation. A stale widget must
        // not complete an unrelated/restored record with an old captured ID.
        let updated: AppSnapshot
        var committedWarning: RepositoryError?
        do { updated = try repository.setTaskCompleted(id: id, isCompleted: true, expectedGeneration: generation) }
        catch RepositoryError.committedMetadataFailure(let reason) {
            // The task/next occurrence was saved. Still reconcile notifications
            // before reporting the protection-metadata warning to the system.
            committedWarning = .committedMetadataFailure(reason)
            updated = try repository.read()
        }
        let scheduler = await LocalNotificationScheduler()
        _ = await scheduler.rebuild(tasks: updated.tasks, readLatestTasks: { try repository.read().tasks })
        if let committedWarning { throw committedWarning }
        return .result()
    }

    enum CompletionError: Error, LocalizedError {
        case invalidReference

        var errorDescription: String? {
            "小组件中的待办信息已失效，请打开 App 后重试。"
        }
    }
}
