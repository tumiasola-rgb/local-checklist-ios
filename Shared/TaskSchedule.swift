import Foundation
import CryptoKit

/// Optional on old tasks. Civil dates remain in startDay/endDay. A time zone is
/// fixed when a schedule is edited; changing devices never changes its wall time.
public struct TaskScheduleOptions: Codable, Equatable, Sendable {
    public var isAllDay: Bool
    /// Retained while all-day is enabled, just like TodoItem.timeMinutes.
    public var endTimeMinutes: Int?
    public var timeZoneIdentifier: String
    public var reminder: TaskReminder?
    public var recurrence: TaskRecurrence?

    public init(isAllDay: Bool, endTimeMinutes: Int? = nil,
                timeZoneIdentifier: String = TimeZone.current.identifier,
                reminder: TaskReminder? = nil, recurrence: TaskRecurrence? = nil) {
        self.isAllDay = isAllDay; self.endTimeMinutes = endTimeMinutes
        self.timeZoneIdentifier = timeZoneIdentifier
        self.reminder = reminder; self.recurrence = recurrence
    }
}

public struct TaskReminder: Codable, Equatable, Hashable, Sendable {
    /// Whole 1,440-minute portions are CIVIL days; remaining minutes are elapsed
    /// calendar minutes. One day before 09:00 remains 09:00 across a DST boundary.
    public var offsetMinutes: Int
    public var allDayMinutes: Int
    public init(offsetMinutes: Int = 0, allDayMinutes: Int = 540) {
        self.offsetMinutes = offsetMinutes; self.allDayMinutes = allDayMinutes
    }
}

public struct TaskRecurrence: Codable, Equatable, Hashable, Sendable {
    public enum Frequency: String, Codable, CaseIterable, Sendable { case daily, weekly, monthly, yearly }
    public var frequency: Frequency
    public var interval: Int
    /// Foundation weekdays, Sunday=1. Only used for weekly schedules. A week
    /// starts on Monday for interval counting, independently of display settings.
    public var weekdays: [Int]?
    /// Inclusive last permitted START day. A range may end after this boundary.
    public var untilDay: DayStamp?
    public init(frequency: Frequency, interval: Int = 1, weekdays: [Int]? = nil, untilDay: DayStamp? = nil) {
        self.frequency = frequency; self.interval = interval; self.weekdays = weekdays; self.untilDay = untilDay
    }
}

public extension TodoItem {
    var scheduleIsAllDay: Bool { schedule?.isAllDay ?? (timeMinutes == nil) }
}

public enum TaskScheduleMath {
    public static func calendar(timeZoneIdentifier: String) -> Calendar? {
        guard let zone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    public static func calendar(for task: TodoItem) -> Calendar? {
        calendar(timeZoneIdentifier: task.schedule?.timeZoneIdentifier ?? TimeZone.current.identifier)
    }

    /// DST gap: next existing wall time that day. Fold: first occurrence.
    /// A time zone that skipped the entire civil day returns nil.
    public static func date(day: DayStamp, minutes: Int, calendar: Calendar) -> Date? {
        guard (0...1439).contains(minutes), let start = day.date(in: calendar),
              let date = calendar.nextDate(after: start.addingTimeInterval(-1),
                  matching: DateComponents(hour: minutes / 60, minute: minutes % 60, second: 0),
                  matchingPolicy: .nextTime, repeatedTimePolicy: .first),
              DayStamp(date: date, calendar: calendar) == day else { return nil }
        return date
    }

    public static func startDate(for task: TodoItem) -> Date? {
        guard let day = task.startDay ?? task.endDay, let calendar = calendar(for: task) else { return nil }
        return date(day: day, minutes: task.scheduleIsAllDay ? 0 : (task.timeMinutes ?? 0), calendar: calendar)
    }

    public static func endDate(for task: TodoItem) -> Date? {
        guard let day = task.endDay ?? task.startDay, let calendar = calendar(for: task) else { return nil }
        return date(day: day, minutes: task.scheduleIsAllDay ? 0 : (task.schedule?.endTimeMinutes ?? task.timeMinutes ?? 0), calendar: calendar)
    }

    public static func reminderDate(for task: TodoItem) -> Date? {
        guard !task.isCompleted, let reminder = task.schedule?.reminder,
              (0...525_600).contains(reminder.offsetMinutes), (0...1439).contains(reminder.allDayMinutes),
              let day = task.startDay ?? task.endDay, let calendar = calendar(for: task),
              let anchor = date(day: day, minutes: task.scheduleIsAllDay ? reminder.allDayMinutes : (task.timeMinutes ?? 0), calendar: calendar),
              let dayAdjusted = calendar.date(byAdding: .day, value: -(reminder.offsetMinutes / 1440), to: anchor)
        else { return nil }
        return calendar.date(byAdding: .minute, value: -(reminder.offsetMinutes % 1440), to: dayAdjusted)
    }

    /// Pure Gregorian civil-day advance. Monthly/yearly schedules skip dates
    /// absent from a candidate period instead of drifting to its last day.
    public static func nextDay(after day: DayStamp, rule: TaskRecurrence) -> DayStamp? {
        guard let result = nextUnboundedDay(after: day, rule: rule), rule.untilDay.map({ result <= $0 }) ?? true else { return nil }
        return result
    }

    private static func nextUnboundedDay(after day: DayStamp, rule: TaskRecurrence) -> DayStamp? {
        guard (1...99).contains(rule.interval) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = day.date(in: calendar) else { return nil }
        if rule.frequency == .weekly, let weekdays = rule.weekdays, !weekdays.isEmpty {
            guard weekdays.allSatisfy({ (1...7).contains($0) }), Set(weekdays).count == weekdays.count else { return nil }
            let weekday = calendar.component(.weekday, from: date)
            let position = (weekday + 5) % 7 // Monday=0, Sunday=6.
            let positions = weekdays.map { ($0 + 5) % 7 }.sorted()
            let distance = positions.first(where: { $0 > position }).map { $0 - position }
                ?? (rule.interval * 7 - position + positions[0])
            return shifted(day, by: distance)
        }
        if rule.frequency == .daily || rule.frequency == .weekly {
            let days = rule.interval * (rule.frequency == .weekly ? 7 : 1)
            guard let next = calendar.date(byAdding: .day, value: days, to: date),
                  (1...9999).contains(calendar.component(.year, from: next)), calendar.component(.era, from: next) == 1 else { return nil }
            return DayStamp(date: next, calendar: calendar)
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { return nil }
        // At most a Gregorian 400-year cycle is needed, and the persisted year
        // bounds provide a hard stop. No Date() or completion time participates.
        for step in 1...4800 {
            let amount = rule.interval * step
            let nextYear: Int; let nextMonth: Int
            if rule.frequency == .monthly {
                let absolute = year * 12 + (month - 1) + amount
                nextYear = absolute / 12; nextMonth = absolute % 12 + 1
            } else { nextYear = year + amount; nextMonth = month }
            guard (1...9999).contains(nextYear) else { return nil }
            let raw = String(format: "%04d-%02d-%02d", nextYear, nextMonth, dayOfMonth)
            if let next = DayStamp(rawValue: raw) { return next }
        }
        return nil
    }

    public static func shifted(_ day: DayStamp, by days: Int) -> DayStamp? {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = day.date(in: calendar), let next = calendar.date(byAdding: .day, value: days, to: date),
              calendar.component(.era, from: next) == 1, (1...9999).contains(calendar.component(.year, from: next)) else { return nil }
        return DayStamp(date: next, calendar: calendar)
    }
}

/// Called only by a repository completion transaction. Existing/tombstoned IDs
/// are checked by that transaction so replay cannot duplicate or resurrect tasks.
public func nextOccurrence(after task: TodoItem) -> TodoItem? {
    guard let rule = task.schedule?.recurrence, let anchor = task.startDay ?? task.endDay,
          let nextAnchor = TaskScheduleMath.nextDay(after: anchor, rule: rule) else { return nil }
    let shift = dayDifference(from: anchor, to: nextAnchor)
    var next = task
    if let start = task.startDay {
        guard let value = TaskScheduleMath.shifted(start, by: shift) else { return nil }; next.startDay = value
    }
    if let end = task.endDay {
        guard let value = TaskScheduleMath.shifted(end, by: shift) else { return nil }; next.endDay = value
    }
    // One parent can have only ONE successor identity, even when two devices
    // edited its schedule differently. Divergent content becomes a reviewable
    // same-ID conflict rather than two unrelated future tasks.
    let seed = "LocalChecklist.next.v1|" + task.id.uuidString.lowercased()
    var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
    // UUID variant and custom name-derived version bits. This is deliberately
    // SHA-256 based, not a claim to implement RFC UUIDv5's SHA-1 algorithm.
    bytes[6] = (bytes[6] & 0x0f) | 0x80; bytes[8] = (bytes[8] & 0x3f) | 0x80
    next.id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                         bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    next.isCompleted = false; next.completedAt = nil
    // Stable across two offline devices completing the same occurrence.
    next.createdAt = task.createdAt; next.updatedAt = task.createdAt
    return next
}
