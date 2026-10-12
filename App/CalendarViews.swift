import SwiftUI

struct CalendarMonth {
    let date: Date
    let firstWeekday: Int
    var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = .current; value.firstWeekday = firstWeekday; return value }
    var first: Date { calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date }
    var days: [Date] {
        let offset = (calendar.component(.weekday, from: first) - firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        let total = ((offset + count + 6) / 7) * 7
        return (0..<total).compactMap { calendar.date(byAdding: .day, value: $0 - offset, to: first) }
    }
    var weeks: [[Date?]] {
        stride(from: 0, to: days.count, by: 7).map { offset in
            days[offset..<min(offset + 7, days.count)].map { value in
                let parts = calendar.dateComponents([.era, .year], from: value)
                return parts.era == 1 && (1...9999).contains(parts.year ?? 0) ? value : nil
            }
        }
    }
    var weekdayNames: [String] { let names = ["日", "一", "二", "三", "四", "五", "六"]; return (0..<7).map { names[($0 + firstWeekday - 1) % 7] } }
}

struct CalendarScreen: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selectedDate: Date
    let onDay: (DayStamp) -> Void
    let onTask: (TodoItem) -> Void
    var month: CalendarMonth { CalendarMonth(date: selectedDate, firstWeekday: model.snapshot.settings.firstWeekday) }
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                CircleIconButton(symbol: "chevron.left", label: "上个月") { shift(-1) }
                Spacer()
                Button { selectedDate = Date() } label: {
                    Text(selectedDate.formatted(.dateTime.year().month(.wide).locale(Locale(identifier: "zh_CN")))).font(.title3.weight(.semibold))
                }.buttonStyle(.plain).accessibilityHint("点按回到本月")
                Spacer()
                CircleIconButton(symbol: "chevron.right", label: "下个月") { shift(1) }
            }.padding(.horizontal, 18)
            HStack(spacing: 0) { ForEach(month.weekdayNames, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) } }.padding(.horizontal, 8)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(month.weeks.enumerated()), id: \.offset) { _, dates in
                        CalendarWeek(dates: dates, month: selectedDate, selectedDate: selectedDate, showLunar: model.snapshot.settings.showLunar, tasks: model.snapshot.tasks, onDay: onDay, onTask: onTask)
                    }
                }.padding(.horizontal, 7).padding(.bottom, 90)
            }
        }
    }
    private func shift(_ count: Int) {
        guard let target = month.calendar.date(byAdding: .month, value: count, to: month.first) else { return }
        let parts = month.calendar.dateComponents([.era, .year], from: target)
        guard parts.era == 1, (1...9999).contains(parts.year ?? 0) else { return }
        selectedDate = target
    }
}

private struct CalendarBar: Identifiable {
    let task: TodoItem
    let start: Int
    let length: Int
    let lane: Int
    var id: UUID { task.id }
}

private struct CalendarWeek: View {
    let dates: [Date?]
    let month: Date
    let selectedDate: Date
    let showLunar: Bool
    let tasks: [TodoItem]
    let onDay: (DayStamp) -> Void
    let onTask: (TodoItem) -> Void
    private let laneCount = 4
    private var bars: [CalendarBar] {
        var occupied = Array(repeating: Set<Int>(), count: laneCount)
        var result: [CalendarBar] = []
        let candidates = tasks.filter { task in dates.compactMap { $0 }.contains { task.occurs(on: DayStamp(date: $0)) } }.sorted { lhs, rhs in
            let left = lhs.startDay.flatMap { start in lhs.endDay.map { dayDifference(from: start, to: $0) } } ?? 0
            let right = rhs.startDay.flatMap { start in rhs.endDay.map { dayDifference(from: start, to: $0) } } ?? 0
            return left == right ? taskOrder(lhs, rhs) : left > right
        }
        for task in candidates {
            let indices = dates.indices.filter { index in dates[index].map { task.occurs(on: DayStamp(date: $0)) } ?? false }
            guard let start = indices.first, let end = indices.last, let lane = occupied.firstIndex(where: { $0.isDisjoint(with: indices) }) else { continue }
            occupied[lane].formUnion(indices)
            result.append(CalendarBar(task: task, start: start, length: end - start + 1, lane: lane))
        }
        return result
    }
    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 0) {
                ForEach(Array(dates.enumerated()), id: \.offset) { _, candidate in
                    if let date = candidate {
                    let today = Calendar.current.isDateInToday(date)
                    let thisMonth = Calendar.current.isDate(date, equalTo: month, toGranularity: .month)
                    Button { onDay(DayStamp(date: date)) } label: {
                        VStack(spacing: 2) {
                            Text("\(Calendar.current.component(.day, from: date))").font(.system(size: 17, weight: .medium))
                            if showLunar { Text(lunarLabel(date)).font(.system(size: 9)).lineLimit(1) }
                        }.frame(width: 38, height: 43)
                            .foregroundStyle(today ? Color.white : (thisMonth ? Color.primary : Color.secondary.opacity(0.5)))
                            .background(today ? Color.checklistBlue : Color.clear, in: Circle())
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.plain).accessibilityLabel("\(DayStamp(date: date).rawValue)，打开当天待办")
                    } else { Color.clear.frame(maxWidth: .infinity).frame(height: 43) }
                }
            }
            GeometryReader { geometry in
                let width = geometry.size.width / 7
                ZStack(alignment: .topLeading) {
                    ForEach(0..<8, id: \.self) { i in Rectangle().fill(Color.secondary.opacity(0.1)).frame(width: 0.5).offset(x: CGFloat(i) * width) }
                    ForEach(bars) { bar in
                        Button { onTask(bar.task) } label: {
                            Text(bar.task.title).font(.system(size: 10, weight: .medium)).lineLimit(1).strikethrough(bar.task.isCompleted).foregroundStyle(bar.task.isCompleted ? Color.secondary : Color(red: 0.18, green: 0.22, blue: 0.42)).padding(.horizontal, 3)
                                .frame(width: max(1, CGFloat(bar.length) * width - 3), height: 18, alignment: .leading)
                                .background(bar.task.isCompleted ? Color.secondary.opacity(0.1) : Color.checklistBlue.opacity(bar.length > 1 ? 0.3 : 0.19), in: RoundedRectangle(cornerRadius: 4))
                        }.buttonStyle(.plain).offset(x: CGFloat(bar.start) * width + 1, y: CGFloat(bar.lane) * 20)
                            .accessibilityLabel(bar.task.title)
                    }
                    ForEach(Array(dates.enumerated()), id: \.offset) { index, candidate in
                        if let date = candidate {
                        let all = tasks.filter { $0.occurs(on: DayStamp(date: date)) }.count
                        let visible = bars.filter { index >= $0.start && index < $0.start + $0.length }.count
                        if all > visible {
                            Button("+\(all - visible)") { onDay(DayStamp(date: date)) }.font(.system(size: 10)).foregroundStyle(.secondary).frame(width: width).offset(x: CGFloat(index) * width, y: 81)
                        }
                        }
                    }
                }
            }.frame(height: 98)
        }.padding(.top, 6).overlay(alignment: .bottom) { Rectangle().fill(Color.secondary.opacity(0.1)).frame(height: 0.5) }
    }
}

struct DayAgenda: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let day: DayStamp
    let onTask: (TodoItem) -> Void
    let onAdd: () -> Void
    private var tasks: [TodoItem] { model.snapshot.tasks.filter { $0.occurs(on: day) }.sorted(by: taskOrder) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if tasks.isEmpty { EmptyCard(symbol: "calendar", title: "这一天还很空", subtitle: "添加一条待办，把计划放进日历") }
                    else { Card { VStack(spacing: 18) { ForEach(tasks) { task in TaskRow(task: task) { onTask(task) } } } } }
                    Button("添加这一天的待办", systemImage: "plus", action: onAdd).buttonStyle(.borderedProminent)
                }.padding(16)
            }.background(Color.checklistCanvas).navigationTitle(day.rawValue).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}
