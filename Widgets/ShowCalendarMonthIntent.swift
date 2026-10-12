import AppIntents
import Foundation
import WidgetKit

/// Stores an explicit destination rather than incrementing the stored month.
/// Repeated taps on an old rendered button therefore remain idempotent.
struct ShowCalendarMonthIntent: AppIntent {
    static var title: LocalizedStringResource = "切换月历月份"
    static var description = IntentDescription("在桌面月历中显示指定月份，或回到当前月。")
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "目标月份") var targetMonth: String
    @Parameter(title: "数据版本") var generationID: String

    init() {}

    init(targetMonth: String, generationID: String) {
        self.targetMonth = targetMonth
        self.generationID = generationID
    }

    func perform() async throws -> some IntentResult {
        defer { WidgetCenter.shared.reloadTimelines(ofKind: "LocalChecklistMonthCalendar") }
        guard let generation = UUID(uuidString: generationID) else {
            throw MonthNavigationError.invalidReference
        }
        let destination: DayStamp?
        if targetMonth.isEmpty {
            destination = nil
        } else {
            let calendar = ChecklistWidgetDates.calendar()
            guard let stamp = DayStamp(rawValue: targetMonth),
                  let date = stamp.date(in: calendar),
                  calendar.component(.day, from: date) == 1 else {
                throw MonthNavigationError.invalidMonth
            }
            destination = stamp
        }
        let repository = try SharedRepository()
        _ = try repository.update(expectedGeneration: generation) { snapshot in
            snapshot.settings.widgetCalendarMonth = destination
        }
        return .result()
    }

    enum MonthNavigationError: Error, LocalizedError {
        case invalidReference
        case invalidMonth

        var errorDescription: String? {
            switch self {
            case .invalidReference: return "小组件数据版本已失效，请打开 App 后重试。"
            case .invalidMonth: return "无法显示此月份，请打开 App 后重试。"
            }
        }
    }
}
