import Foundation
import SwiftUI
import WidgetKit

enum ChecklistWidgetPalette {
    static let accent = Color(red: 0.34, green: 0.42, blue: 0.95)
    static let lavender = Color(red: 0.84, green: 0.86, blue: 1)
    static let purple = Color(red: 0.77, green: 0.70, blue: 0.94)
    static let ink = Color(red: 0.20, green: 0.23, blue: 0.40)
}

/// Every route is also handled by the main app. No widget owns an alternate data store.
enum ChecklistWidgetLink {
    static var today: URL { URL(string: "localchecklist://today")! }

    static func calendar(_ day: DayStamp) -> URL {
        make(host: "calendar", name: "day", value: day.rawValue)
    }

    static func add(_ day: DayStamp) -> URL {
        make(host: "add", name: "day", value: day.rawValue)
    }

    static func task(_ id: UUID) -> URL {
        make(host: "task", name: "id", value: id.uuidString)
    }

    private static func make(host: String, name: String, value: String) -> URL {
        var components = URLComponents()
        components.scheme = "localchecklist"
        components.host = host
        components.queryItems = [URLQueryItem(name: name, value: value)]
        // The scheme, host and query names above are compile-time constants.
        return components.url!
    }
}

struct ChecklistWidgetEntry: TimelineEntry {
    let date: Date
    let tasks: [TodoItem]
    let generation: UUID?
    let firstWeekday: Int
    let showLunar: Bool
    let errorMessage: String?
    var calendarMonth: DayStamp? = nil

    static func placeholder(at date: Date = Date()) -> Self {
        Self(date: date, tasks: [], generation: nil, firstWeekday: 2,
             showLunar: true, errorMessage: nil)
    }

    func at(_ newDate: Date) -> Self {
        Self(date: newDate, tasks: tasks, generation: generation,
             firstWeekday: firstWeekday, showLunar: showLunar,
             errorMessage: errorMessage, calendarMonth: calendarMonth)
    }
}

struct ChecklistTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> ChecklistWidgetEntry {
        .placeholder()
    }

    func getSnapshot(in context: Context, completion: @escaping (ChecklistWidgetEntry) -> Void) {
        completion(load(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ChecklistWidgetEntry>) -> Void) {
        let now = Date()
        let entry = load(at: now)
        var entries = [entry]
        // A future entry changes day-based grouping at local midnight even if the
        // system postpones our reload request. Calendar arithmetic respects DST.
        let calendar = Calendar.current
        if let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) {
            entries.append(entry.at(midnight))
        }
        // This is a request, not a 15-minute refresh guarantee. WidgetKit budgets
        // background refreshes. The app and successful intents also request reloads.
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }

    private func load(at date: Date) -> ChecklistWidgetEntry {
        do {
            let snapshot = try SharedRepository().read()
            return ChecklistWidgetEntry(date: date, tasks: snapshot.tasks,
                generation: snapshot.generation,
                firstWeekday: min(7, max(1, snapshot.settings.firstWeekday)),
                showLunar: snapshot.settings.showLunar, errorMessage: nil,
                calendarMonth: snapshot.settings.widgetCalendarMonth)
        } catch {
            // A corrupt/inaccessible store must never be replaced with an empty one.
            return ChecklistWidgetEntry(date: date, tasks: [], generation: nil,
                firstWeekday: 2, showLunar: false,
                errorMessage: "暂时无法读取本机数据")
        }
    }
}

struct ChecklistWidgetErrorView: View {
    let message: String

    var body: some View {
        Link(destination: ChecklistWidgetLink.today) {
            VStack(alignment: .leading, spacing: 10) {
                Label("本机清单", systemImage: "checklist")
                    .font(.headline)
                    .foregroundStyle(ChecklistWidgetPalette.accent)
                Text(message).font(.subheadline).foregroundStyle(.primary)
                Text("点按打开 App 检查数据，再刷新小组件")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

enum ChecklistWidgetDates {
    static func calendar(firstWeekday: Int = 2) -> Calendar {
        // DayStamp stores Gregorian civil days, independent of the device's
        // preferred display calendar. Both calendars use the current time zone.
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .current
        value.locale = Locale(identifier: "zh_CN")
        value.firstWeekday = firstWeekday
        return value
    }

    static func lunarLabel(for date: Date) -> String {
        var lunar = Calendar(identifier: .chinese)
        lunar.timeZone = .current
        let day = lunar.component(.day, from: date)
        let names = ["初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
                     "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
                     "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"]
        return (1...30).contains(day) ? names[day - 1] : ""
    }
}
