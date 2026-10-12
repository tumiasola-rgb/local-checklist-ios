import AppIntents
import SwiftUI
import WidgetKit

struct TodayTasksWidget: Widget {
    let kind = "LocalChecklistTodayTasks"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ChecklistTimelineProvider()) { entry in
            TodayTasksWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("今天待办")
        .description("显示逾期及今天未完成的待办。点方框完成，点加号新增。")
        .supportedFamilies([.systemMedium])
    }
}

struct TodayTasksWidgetView: View {
    let entry: ChecklistWidgetEntry

    var body: some View {
        if let message = entry.errorMessage {
            ChecklistWidgetErrorView(message: message)
        } else {
            taskContent
        }
    }

    private var taskContent: some View {
        let calendar = ChecklistWidgetDates.calendar()
        let today = DayStamp(date: entry.date, calendar: calendar)
        let tasks = relevantTasks(today: today)
        return GeometryReader { geometry in
            // Widget sizes differ by device. Use fewer rows rather than drawing
            // an off-screen list or pretending a widget supports scrolling.
            let capacity = max(1, min(5, Int((geometry.size.height - 47) / 26)))
            let shown = Array(tasks.prefix(capacity))
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Link(destination: ChecklistWidgetLink.today) {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text("今天").font(.system(size: 22, weight: .semibold))
                            Text("\(tasks.count)")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(ChecklistWidgetPalette.accent.opacity(0.60))
                        }
                    }
                    Spacer()
                    Link(destination: ChecklistWidgetLink.add(today)) {
                        Image(systemName: "plus")
                            .font(.system(size: 23, weight: .medium))
                            .frame(width: 28, height: 26)
                    }
                    .accessibilityLabel("新增今天的待办")
                }
                .foregroundStyle(ChecklistWidgetPalette.accent)
                .frame(height: 28)

                if tasks.isEmpty {
                    Link(destination: ChecklistWidgetLink.add(today)) {
                        HStack(spacing: 9) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 25, weight: .light))
                                .foregroundStyle(ChecklistWidgetPalette.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("今天从容一点").font(.system(size: 14, weight: .medium))
                                Text("没有逾期或今日待办，点此添加")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                } else {
                    ForEach(shown) { task in
                        taskRow(task, today: today, calendar: calendar)
                            .frame(height: 23)
                    }
                    Spacer(minLength: 0)
                    if tasks.count > shown.count {
                        Link(destination: ChecklistWidgetLink.today) {
                            Text("还有 \(tasks.count - shown.count) 项，打开查看")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .widgetURL(ChecklistWidgetLink.today)
    }

    private func taskRow(_ task: TodoItem, today: DayStamp, calendar: Calendar) -> some View {
        HStack(spacing: 7) {
            if let generation = entry.generation {
                Button(intent: CompleteTodoIntent(taskID: task.id, generationID: generation)) {
                    Image(systemName: "square")
                        .font(.system(size: 19, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 23)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("完成待办：\(task.title)")
            }
            Link(destination: ChecklistWidgetLink.task(task.id)) {
                HStack(spacing: 5) {
                    Text(task.title.isEmpty ? "未命名待办" : task.title)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .privacySensitive()
                    Text(dueLabel(task, today: today, calendar: calendar))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(isOverdue(task, today: today) ? Color.red : ChecklistWidgetPalette.accent)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .buttonStyle(.plain)
        }
        .invalidatableContent()
    }

    private func relevantTasks(today: DayStamp) -> [TodoItem] {
        entry.tasks.filter { task in
            !task.isCompleted && (isOverdue(task, today: today) || task.occurs(on: today))
        }.sorted { left, right in
            let leftOverdue = isOverdue(left, today: today)
            let rightOverdue = isOverdue(right, today: today)
            if leftOverdue != rightOverdue { return leftOverdue }
            if left.dueDay != right.dueDay {
                return (left.dueDay?.rawValue ?? "9999-12-31") < (right.dueDay?.rawValue ?? "9999-12-31")
            }
            let leftTime = left.scheduleIsAllDay ? -1 : (left.timeMinutes ?? -1)
            let rightTime = right.scheduleIsAllDay ? -1 : (right.timeMinutes ?? -1)
            if leftTime != rightTime { return leftTime < rightTime }
            if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
            return left.id.uuidString < right.id.uuidString
        }
    }

    private func isOverdue(_ task: TodoItem, today: DayStamp) -> Bool {
        guard let due = task.dueDay else { return false }
        return due < today
    }

    private func dueLabel(_ task: TodoItem, today: DayStamp, calendar: Calendar) -> String {
        if let due = task.dueDay, due < today {
            let days = dayDifference(from: due, to: today, calendar: calendar)
            return "逾期 \(max(1, days)) 天"
        }
        if !task.scheduleIsAllDay, let minutes = task.timeMinutes, (0..<1440).contains(minutes) {
            return String(format: "%02d:%02d", minutes / 60, minutes % 60)
        }
        return "今天"
    }
}
