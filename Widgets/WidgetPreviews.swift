#if DEBUG
import SwiftUI
import WidgetKit

/// In-memory design fixtures only. These tasks are never written to the store.
private enum WidgetPreviewData {
    static func entry(month: Int) -> ChecklistWidgetEntry {
        let calendar = ChecklistWidgetDates.calendar()
        let date = calendar.date(from: DateComponents(year: 2026, month: month, day: 6, hour: 9))!
        func day(_ offset: Int) -> DayStamp {
            DayStamp(date: calendar.date(byAdding: .day, value: offset, to: date)!, calendar: calendar)
        }
        return ChecklistWidgetEntry(date: date, tasks: [
            TodoItem(title: "整理资料", startDay: day(-3)),
            TodoItem(title: "完成本周计划", startDay: day(-2), endDay: day(4)),
            TodoItem(title: "专注阅读", startDay: day(0), timeMinutes: 18 * 60),
            TodoItem(title: "轻松散步", startDay: day(0)),
            TodoItem(title: "准备周末行程", startDay: day(0)),
            TodoItem(title: "归档笔记", startDay: day(0)),
            TodoItem(title: "整理房间", startDay: day(7)),
            TodoItem(title: "创作时间", startDay: day(8), endDay: day(12)),
            TodoItem(title: "回顾与计划", startDay: day(16), endDay: day(18))
        ], generation: UUID(), firstWeekday: 2, showLunar: true, errorMessage: nil)
    }
}

struct ChecklistWidgetPreviews: PreviewProvider {
    static var previews: some View {
        Group {
            MonthCalendarWidgetView(entry: WidgetPreviewData.entry(month: 10))
                .containerBackground(.background, for: .widget)
                .previewContext(WidgetPreviewContext(family: .systemLarge))
                .previewDisplayName("月历 · 五周")
            MonthCalendarWidgetView(entry: WidgetPreviewData.entry(month: 8))
                .containerBackground(.background, for: .widget)
                .previewContext(WidgetPreviewContext(family: .systemLarge))
                .previewDisplayName("月历 · 六周")
            TodayTasksWidgetView(entry: WidgetPreviewData.entry(month: 10))
                .containerBackground(.background, for: .widget)
                .previewContext(WidgetPreviewContext(family: .systemMedium))
                .previewDisplayName("今日 · 逾期与溢出")
            TodayTasksWidgetView(entry: .placeholder())
                .containerBackground(.background, for: .widget)
                .previewContext(WidgetPreviewContext(family: .systemMedium))
                .previewDisplayName("今日 · 空状态")
        }
    }
}
#endif
