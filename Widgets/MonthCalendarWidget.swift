import AppIntents
import SwiftUI
import WidgetKit

struct MonthCalendarWidget: Widget {
    let kind = "LocalChecklistMonthCalendar"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ChecklistTimelineProvider()) { entry in
            MonthCalendarWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("月历清单")
        .description("在桌面切换月份，点月份回到本月。点日期查看当天，点加号新增。")
        .supportedFamilies([.systemLarge])
    }
}

struct MonthCalendarWidgetView: View {
    let entry: ChecklistWidgetEntry

    var body: some View {
        if let message = entry.errorMessage {
            ChecklistWidgetErrorView(message: message)
        } else {
            calendarContent
        }
    }

    private var calendarContent: some View {
        let calendar = ChecklistWidgetDates.calendar(firstWeekday: entry.firstWeekday)
        let displayedDate = entry.calendarMonth?.date(in: calendar) ?? entry.date
        let month = WidgetMonth(date: displayedDate, calendar: calendar)
        return GeometryReader { geometry in
            VStack(spacing: 4) {
                header(month: month, calendar: calendar)
                    .frame(height: 25)
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { index in
                        Text(["日", "一", "二", "三", "四", "五", "六"][(entry.firstWeekday - 1 + index) % 7])
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 13)
                VStack(spacing: 0) {
                    ForEach(month.weeks.indices, id: \.self) { index in
                        CalendarWidgetWeek(
                            days: month.weeks[index], tasks: entry.tasks,
                            monthStart: month.start, today: DayStamp(date: entry.date, calendar: calendar),
                            calendar: calendar, showLunar: entry.showLunar,
                            rowHeight: max(25, (geometry.size.height - 46) / CGFloat(month.weeks.count))
                        )
                    }
                }
                .clipped()
            }
        }
        .widgetURL(ChecklistWidgetLink.calendar(DayStamp(date: displayedDate, calendar: calendar)))
        .invalidatableContent()
    }

    private func header(month: WidgetMonth, calendar: Calendar) -> some View {
        let monthNames = ["一月", "二月", "三月", "四月", "五月", "六月",
                          "七月", "八月", "九月", "十月", "十一月", "十二月"]
        let currentMonth = calendar.component(.month, from: month.start)
        let previous = adjacentMonth(from: month.start, offset: -1, calendar: calendar)
        let next = adjacentMonth(from: month.start, offset: 1, calendar: calendar)
        return HStack(spacing: 9) {
            Text(String(calendar.component(.year, from: month.start)))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            monthArrow(destination: previous, symbol: "chevron.left", label: "显示上个月")
            monthControl(target: "", fallback: ChecklistWidgetLink.calendar(DayStamp(date: entry.date, calendar: calendar))) {
                Text(monthNames[min(11, max(0, currentMonth - 1))])
                    .font(.system(size: 18, weight: .semibold))
            }
            .accessibilityLabel("\(monthNames[min(11, max(0, currentMonth - 1))])，点按回到本月")
            monthArrow(destination: next, symbol: "chevron.right", label: "显示下个月")
            Spacer(minLength: 0)
            Link(destination: ChecklistWidgetLink.add(DayStamp(date: entry.date, calendar: calendar))) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 23, weight: .regular))
            }
            .accessibilityLabel("新增待办")
        }
        .foregroundStyle(ChecklistWidgetPalette.accent)
        .buttonStyle(.plain)
    }

    private func adjacentMonth(from date: Date, offset: Int, calendar: Calendar) -> DayStamp? {
        guard let candidate = calendar.date(byAdding: .month, value: offset, to: date),
              calendar.component(.era, from: candidate) == 1,
              (1...9999).contains(calendar.component(.year, from: candidate)) else { return nil }
        return DayStamp(date: candidate, calendar: calendar)
    }

    @ViewBuilder
    private func monthArrow(destination: DayStamp?, symbol: String, label: String) -> some View {
        if let destination {
            monthControl(target: destination.rawValue, fallback: ChecklistWidgetLink.calendar(destination)) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                    .frame(width: 23, height: 25)
            }
            .accessibilityLabel(label)
        } else {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 23, height: 25)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func monthControl<Label: View>(target: String, fallback: URL,
                                          @ViewBuilder label: () -> Label) -> some View {
        if let generation = entry.generation {
            Button(intent: ShowCalendarMonthIntent(targetMonth: target, generationID: generation.uuidString)) {
                label()
            }
        } else {
            // Placeholders have no store generation and cannot safely mutate it.
            Link(destination: fallback) { label() }
        }
    }
}

private struct WidgetMonth {
    let start: Date
    let weeks: [[Date?]]

    init(date: Date, calendar: Calendar) {
        let start = calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        self.start = start
        let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let dayCount = calendar.range(of: .day, in: .month, for: start)?.count ?? 31
        // February sometimes fits four rows; keep five complete weeks for a
        // consistent home-screen composition. Other months can require six.
        let weekCount = max(5, (leading + dayCount + 6) / 7)
        let gridStart = calendar.date(byAdding: .day, value: -leading, to: start) ?? start
        self.weeks = (0..<weekCount).map { week in
            (0..<7).map { column -> Date? in
                guard let candidate = calendar.date(byAdding: .day, value: week * 7 + column, to: gridStart),
                      calendar.component(.era, from: candidate) == 1,
                      (1...9999).contains(calendar.component(.year, from: candidate)) else { return nil }
                return candidate
            }
        }
    }
}

private struct CalendarWidgetWeek: View {
    let days: [Date?]
    let tasks: [TodoItem]
    let monthStart: Date
    let today: DayStamp
    let calendar: Calendar
    let showLunar: Bool
    let rowHeight: CGFloat

    var body: some View {
        let stamps = days.map { date in date.map { DayStamp(date: $0, calendar: calendar) } }
        let layout = WidgetWeekLayout(days: stamps, tasks: tasks)
        let laneHeight = min(12, max(8, (rowHeight - 17) / 3))
        return GeometryReader { geometry in
            let columnWidth = geometry.size.width / 7
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(days.indices, id: \.self) { index in
                        Rectangle().fill(Color.secondary.opacity(0.12))
                            .frame(width: 0.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                VStack(spacing: 1) {
                    HStack(spacing: 0) {
                        ForEach(days.indices, id: \.self) { index in
                            if let date = days[index], let stamp = stamps[index] {
                                dayHeader(date: date, stamp: stamp, width: columnWidth)
                            } else {
                                Color.clear.frame(width: columnWidth, height: 15)
                            }
                        }
                    }
                    .frame(height: 15)
                    ZStack(alignment: .topLeading) {
                        Color.clear
                        ForEach(layout.visible) { segment in
                            Link(destination: ChecklistWidgetLink.task(segment.task.id)) {
                                Text(segment.task.title.isEmpty ? "未命名待办" : segment.task.title)
                                    .font(.system(size: min(10, laneHeight - 1), weight: .medium))
                                    .foregroundStyle(ChecklistWidgetPalette.ink)
                                    .lineLimit(1)
                                    .padding(.horizontal, 3)
                                    .frame(width: max(1, CGFloat(segment.end - segment.start + 1) * columnWidth - 2),
                                           height: laneHeight - 1, alignment: .leading)
                                    .background(segment.lane == 0 ? ChecklistWidgetPalette.lavender : ChecklistWidgetPalette.purple,
                                                in: RoundedRectangle(cornerRadius: 3))
                                    .privacySensitive()
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("查看待办：\(segment.task.title)")
                            .offset(x: CGFloat(segment.start) * columnWidth + 1,
                                    y: CGFloat(segment.lane) * laneHeight)
                        }
                    }
                    .frame(height: laneHeight * 2, alignment: .topLeading)
                    HStack(spacing: 0) {
                        ForEach(stamps.indices, id: \.self) { index in
                            if let stamp = stamps[index], layout.overflow[index] > 0 {
                                Link(destination: ChecklistWidgetLink.calendar(stamp)) {
                                    Text("+\(layout.overflow[index])")
                                        .font(.system(size: min(9, laneHeight - 1), weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity)
                                        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 3))
                                        .padding(.horizontal, 1)
                                }
                                .accessibilityLabel("查看当天另外 \(layout.overflow[index]) 项待办")
                            } else {
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .frame(height: max(8, laneHeight - 1))
                }
                Rectangle().fill(Color.secondary.opacity(0.16)).frame(height: 0.5)
            }
        }
        .frame(height: rowHeight)
        .clipped()
    }

    private func dayHeader(date: Date, stamp: DayStamp, width: CGFloat) -> some View {
        let isToday = stamp == today
        let isCurrentMonth = calendar.isDate(date, equalTo: monthStart, toGranularity: .month)
        return Link(destination: ChecklistWidgetLink.calendar(stamp)) {
            HStack(spacing: 1) {
                Text(String(calendar.component(.day, from: date)))
                    .font(.system(size: 11, weight: isToday ? .bold : .medium))
                    .foregroundStyle(isToday ? Color.white : Color.primary.opacity(isCurrentMonth ? 0.90 : 0.30))
                    .frame(width: 16, height: 15)
                    .background(isToday ? ChecklistWidgetPalette.accent : Color.clear, in: Circle())
                if showLunar && width >= 37 {
                    Text(ChecklistWidgetDates.lunarLabel(for: date))
                        .font(.system(size: 7))
                        .foregroundStyle(.secondary.opacity(isCurrentMonth ? 0.8 : 0.4))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 1)
            .frame(width: width, height: 15, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(stamp.rawValue)\(isToday ? "，今天" : "")")
    }
}

/// Greedy interval packing keeps multi-day tasks as continuous bars within each
/// week. Hidden tasks are counted on every affected day, never silently dropped.
private struct WidgetWeekLayout {
    struct Segment: Identifiable {
        var id: UUID { task.id }
        let task: TodoItem
        let start: Int
        let end: Int
        var lane: Int = 0
    }

    let visible: [Segment]
    let overflow: [Int]

    init(days: [DayStamp?], tasks: [TodoItem]) {
        var segments: [Segment] = tasks.filter { !$0.isCompleted }.compactMap { task in
            let occupied = days.indices.filter { index in
                guard let day = days[index] else { return false }
                return task.occurs(on: day)
            }
            guard let first = occupied.first, let last = occupied.last else { return nil }
            return Segment(task: task, start: first, end: last)
        }
        segments.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end > $1.end }
            if $0.task.timeMinutes != $1.task.timeMinutes {
                return ($0.task.timeMinutes ?? Int.max) < ($1.task.timeMinutes ?? Int.max)
            }
            if $0.task.createdAt != $1.task.createdAt { return $0.task.createdAt < $1.task.createdAt }
            return $0.task.id.uuidString < $1.task.id.uuidString
        }
        var laneEnds = [-1, -1]
        var rendered: [Segment] = []
        var hidden = Array(repeating: 0, count: days.count)
        for var segment in segments {
            if let lane = laneEnds.firstIndex(where: { $0 < segment.start }) {
                segment.lane = lane
                laneEnds[lane] = segment.end
                rendered.append(segment)
            } else {
                for index in segment.start...segment.end { hidden[index] += 1 }
            }
        }
        visible = rendered
        overflow = hidden
    }
}
