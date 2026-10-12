import Foundation

extension AppSnapshot {
    /// Validates every record and relationship without repairing or dropping data.
    public func validate() throws { try SnapshotValidator.validate(self) }
}

internal enum SnapshotValidator {
    static let maximumBytes = 20 * 1_024 * 1_024
    // Reserve room for portable backup metadata, even at the storage limit.
    static let maximumStoredBytes = maximumBytes - 1_024

    static func validate(_ snapshot: AppSnapshot, validateSync: Bool = true) throws {
        if validateSync { try snapshot.sync.validate() }
        guard snapshot.revision >= 0 else { throw invalid("revision must be nonnegative") }
        guard snapshot.tasks.count <= 50_000, snapshot.notes.count <= 20_000,
              snapshot.anniversaries.count <= 10_000, snapshot.lists.count <= 5_000
        else { throw invalid("too many records") }
        var allIDs = Set<UUID>()
        for id in snapshot.tasks.map(\.id) + snapshot.notes.map(\.id)
            + snapshot.anniversaries.map(\.id) + snapshot.lists.map(\.id) {
            guard allIDs.insert(id).inserted else { throw invalid("duplicate record ID \(id)") }
        }
        if validateSync { try snapshot.sync.validateProjection(of: snapshot) }
        let listIDs = Set(snapshot.lists.map(\.id))
        for list in snapshot.lists {
            try text(list.title, field: "list title", maximum: 200, required: true)
            let bytes = Array(list.colorHex.utf8)
            guard bytes.count == 7, bytes.first == 35,
                  bytes.dropFirst().allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
            else { throw invalid("list color must be #RRGGBB") }
        }
        for task in snapshot.tasks {
            try text(task.title, field: "task title", maximum: 500, required: true)
            try text(task.detail, field: "task detail", maximum: 100_000)
            try tags(task.tags)
            if let id = task.listID, !listIDs.contains(id) { throw invalid("task refers to a missing list") }
            if let start = task.startDay, let end = task.endDay, end < start { throw invalid("task end day precedes its start day") }
            if let minutes = task.timeMinutes, !(0...1439).contains(minutes) { throw invalid("timeMinutes must be in 0...1439") }
            if task.timeMinutes != nil, task.dueDay == nil { throw invalid("a task time requires a scheduled day") }
            if let schedule = task.schedule {
                guard TimeZone(identifier: schedule.timeZoneIdentifier) != nil else { throw invalid("invalid schedule time zone") }
                if let end = schedule.endTimeMinutes, !(0...1439).contains(end) { throw invalid("end time must be in 0...1439") }
                if !schedule.isAllDay {
                    guard task.timeMinutes != nil, task.dueDay != nil else { throw invalid("timed schedule requires a day and start time") }
                    if let startDay = task.startDay, let endDay = task.endDay {
                        guard let end = schedule.endTimeMinutes else { throw invalid("timed range requires end time") }
                        if startDay == endDay, end < task.timeMinutes! { throw invalid("timed range ends before it starts") }
                    }
                }
                if let reminder = schedule.reminder {
                    guard task.dueDay != nil, (0...525_600).contains(reminder.offsetMinutes), (0...1439).contains(reminder.allDayMinutes) else {
                        throw invalid("invalid reminder offset or all-day time")
                    }
                }
                if let recurrence = schedule.recurrence {
                    guard task.dueDay != nil, (1...99).contains(recurrence.interval) else { throw invalid("invalid recurrence interval or missing date") }
                    if let weekdays = recurrence.weekdays {
                        guard recurrence.frequency == .weekly, !weekdays.isEmpty, weekdays.count <= 7,
                              Set(weekdays).count == weekdays.count, weekdays.allSatisfy({ (1...7).contains($0) }) else {
                            throw invalid("invalid recurrence weekdays")
                        }
                    }
                }
            }
            try timestamps(created: task.createdAt, updated: task.updatedAt)
            guard task.isCompleted == (task.completedAt != nil) else { throw invalid("task completion flag and timestamp disagree") }
            if let completed = task.completedAt {
                try date(completed, field: "completedAt")
                guard completed >= task.createdAt, completed <= task.updatedAt else { throw invalid("completion timestamp is outside the record's lifetime") }
            }
        }
        for note in snapshot.notes {
            try text(note.title, field: "note title", maximum: 500, required: true)
            try text(note.body, field: "note body", maximum: 500_000)
            try tags(note.tags)
            try timestamps(created: note.createdAt, updated: note.updatedAt)
        }
        for anniversary in snapshot.anniversaries {
            try text(anniversary.title, field: "anniversary title", maximum: 500, required: true)
            try text(anniversary.emoji, field: "anniversary emoji", maximum: 32, required: true)
        }
        guard (1...7).contains(snapshot.settings.firstWeekday) else { throw invalid("firstWeekday must be in 1...7") }
        guard snapshot.settings.searchHistory.count <= 30 else { throw invalid("search history may contain at most 30 entries") }
        for query in snapshot.settings.searchHistory { try text(query, field: "search history", maximum: 500, required: true) }
        if let id = snapshot.settings.defaultListID, !listIDs.contains(id) { throw invalid("default list does not exist") }
        if let month = snapshot.settings.widgetCalendarMonth, !month.rawValue.hasSuffix("-01") {
            throw invalid("widgetCalendarMonth must be the first day of a month")
        }
    }

    static func date(_ date: Date, field: String) throws {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds >= -62_135_596_800, seconds < 253_402_300_800
        else { throw invalid("\(field) must be a finite date in years 1...9999") }
    }

    private static func timestamps(created: Date, updated: Date) throws {
        try date(created, field: "createdAt"); try date(updated, field: "updatedAt")
        guard updated >= created else { throw invalid("updatedAt precedes createdAt") }
    }

    private static func text(_ value: String, field: String, maximum: Int, required: Bool = false) throws {
        guard value.count <= maximum else { throw invalid("\(field) is too long") }
        guard !required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid("\(field) must not be empty") }
        guard !value.unicodeScalars.contains(where: { $0.value == 0 }) else { throw invalid("\(field) contains a null character") }
    }

    private static func tags(_ values: [String]) throws {
        guard values.count <= 50 else { throw invalid("an item may contain at most 50 tags") }
        var unique = Set<String>()
        for value in values {
            try text(value, field: "tag", maximum: 80, required: true)
            let key = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard unique.insert(key).inserted else { throw invalid("duplicate tag") }
        }
    }

    /// Reject misspelled/unknown fields instead of silently discarding their data.
    /// Optional keys may be absent or null; JSONDecoder checks their value types.
    static func validateShape(_ data: Data, backup: Bool) throws {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw invalid("malformed JSON") }
        let root = try record(object, required: backup ? ["format", "version", "exportedAt", "payload"] : ["format", "version", "payload"])
        let version = root["version"] as? Int
        let snapshot = try record(root["payload"], required: ["tasks", "notes", "anniversaries", "lists", "settings", "revision", "generation"],
                                  optional: version == 2 ? ["sync"] : [])
        if version == 2 {
            guard snapshot["sync"] is [String: Any] else { throw invalid("v2 sync journal is missing or invalid") }
            try validateSyncLedgerShape(snapshot["sync"])
        }
        for task in try array(snapshot["tasks"]) {
            let taskObject = try record(task, required: ["id", "title", "detail", "tags", "isCompleted", "createdAt", "updatedAt"],
                                        optional: ["listID", "startDay", "endDay", "timeMinutes", "completedAt", "schedule"])
            try validateScheduleShape(taskObject["schedule"])
        }
        for note in try array(snapshot["notes"]) {
            _ = try record(note, required: ["id", "title", "body", "tags", "isPinned", "createdAt", "updatedAt"])
        }
        for anniversary in try array(snapshot["anniversaries"]) {
            _ = try record(anniversary, required: ["id", "title", "day", "emoji", "repeatYearly"])
        }
        for list in try array(snapshot["lists"]) { _ = try record(list, required: ["id", "title", "colorHex"]) }
        _ = try record(snapshot["settings"], required: ["firstWeekday", "showLunar", "searchHistory"], optional: ["defaultListID", "widgetCalendarMonth"])
    }

    static func validateSyncWireShape(_ data: Data) throws {
        let root = try record(try JSONSerialization.jsonObject(with: data), required: ["schema", "key", "heads"])
        try validateHeadsShape(root["heads"])
    }
    private static func validateSyncLedgerShape(_ value: Any?) throws {
        let ledger = try record(value, required: ["schema", "installationID", "replicaID", "counter", "epoch", "enabled", "importRequiresReview", "entries"],
                                optional: ["peerBindingID", "lastSuccessfulSync", "lastFailure"])
        guard let entries = ledger["entries"] as? [String: Any] else { throw invalid("invalid sync entry map") }
        for value in entries.values {
            let entry = try record(value, required: ["heads", "dirty"], optional: ["preferredVersionID"])
            try validateHeadsShape(entry["heads"])
        }
    }
    private static func validateHeadsShape(_ value: Any?) throws {
        for value in try array(value) {
            let head = try record(value, required: ["id", "clock"], optional: ["payload"])
            guard let clock = head["clock"] as? [String: Any], clock.count <= 64 else { throw invalid("invalid causal clock") }
            if let value = head["payload"], !(value is NSNull) {
                guard let payload = value as? [String: Any], payload.count == 1,
                      let kind = payload.keys.first, ["task", "note", "anniversary", "list"].contains(kind) else { throw invalid("invalid sync payload") }
                let associated = try record(payload[kind], required: ["_0"])
                let fields: Set<String>; let optional: Set<String>
                switch kind {
                case "task": fields = ["id", "title", "detail", "tags", "isCompleted", "createdAt", "updatedAt"]; optional = ["listID", "startDay", "endDay", "timeMinutes", "completedAt", "schedule"]
                case "note": fields = ["id", "title", "body", "tags", "isPinned", "createdAt", "updatedAt"]; optional = []
                case "anniversary": fields = ["id", "title", "day", "emoji", "repeatYearly"]; optional = []
                default: fields = ["id", "title", "colorHex"]; optional = []
                }
                let object = try record(associated["_0"], required: fields, optional: optional)
                if kind == "task" { try validateScheduleShape(object["schedule"]) }
            }
        }
    }

    private static func validateScheduleShape(_ value: Any?) throws {
        guard let value, !(value is NSNull) else { return }
        let schedule = try record(value, required: ["isAllDay", "timeZoneIdentifier"], optional: ["endTimeMinutes", "reminder", "recurrence"])
        if let value = schedule["reminder"], !(value is NSNull) {
            _ = try record(value, required: ["offsetMinutes", "allDayMinutes"])
        }
        if let value = schedule["recurrence"], !(value is NSNull) {
            _ = try record(value, required: ["frequency", "interval"], optional: ["weekdays", "untilDay"])
        }
    }

    private static func record(_ value: Any?, required: Set<String>, optional: Set<String> = []) throws -> [String: Any] {
        guard let dictionary = value as? [String: Any] else { throw invalid("expected a JSON object") }
        let keys = Set(dictionary.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else {
            throw invalid("missing or unrecognized fields")
        }
        return dictionary
    }

    private static func array(_ value: Any?) throws -> [Any] {
        guard let values = value as? [Any] else { throw invalid("expected a JSON array") }
        return values
    }

    private static func invalid(_ reason: String) -> RepositoryError { .invalidData(reason) }
}
