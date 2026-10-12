import Foundation

/// A Gregorian civil day, independent of a time of day or a device time zone.
/// Calendar arguments supply a time zone; non-Gregorian display calendars do not
/// change the persisted YYYY-MM-DD representation.
public struct DayStamp: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.components(rawValue) != nil else { return nil }
        self.rawValue = rawValue
    }

    /// `date` must fall in Gregorian years 1...9999 in the supplied time zone.
    public init(date: Date, calendar: Calendar = .current) {
        let parts = Self.gregorian(calendar).dateComponents([.era, .year, .month, .day], from: date)
        let year = parts.year ?? 0
        precondition(parts.era == 1 && (1...9999).contains(year), "DayStamp supports Gregorian years 1...9999 CE")
        rawValue = String(format: "%04d-%02d-%02d", year, parts.month ?? 1, parts.day ?? 1)
    }

    public static var today: DayStamp { DayStamp(date: Date()) }

    /// Returns the first representable instant of this civil day. A time zone
    /// that skipped this entire day (for example, Samoa in 2011) returns nil.
    public func date(in calendar: Calendar = .current) -> Date? {
        guard let parts = Self.components(rawValue) else { return nil }
        let gregorian = Self.gregorian(calendar)
        var components = DateComponents()
        components.year = parts.year
        components.month = parts.month
        components.day = parts.day
        components.hour = 12
        guard let noon = gregorian.date(from: components),
              DayStamp(date: noon, calendar: gregorian) == self else { return nil }
        return gregorian.startOfDay(for: noon)
    }

    public static func < (lhs: DayStamp, rhs: DayStamp) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Gregorian day: \(raw)")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func gregorian(_ calendar: Calendar) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = calendar.timeZone
        result.locale = Locale(identifier: "en_US_POSIX")
        return result
    }

    /// Proleptic Gregorian ordinal. Avoids time-zone skips and the historical
    /// calendar cutover that can affect Foundation date construction.
    fileprivate var civilOrdinal: Int {
        guard let parts = Self.components(rawValue) else { preconditionFailure("Invalid DayStamp") }
        let adjustedYear = parts.year - (parts.month <= 2 ? 1 : 0)
        let era = adjustedYear / 400
        let yearOfEra = adjustedYear - era * 400
        let shiftedMonth = parts.month + (parts.month > 2 ? -3 : 9)
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + parts.day - 1
        return era * 146_097 + yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    }

    private static func components(_ raw: String) -> (year: Int, month: Int, day: Int)? {
        let bytes = Array(raw.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7 || (48...57).contains($0.element) })
        else { return nil }
        let parts = raw.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
              let day = Int(parts[2]), (1...9999).contains(year), (1...12).contains(month)
        else { return nil }
        let leap = year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...lengths[month - 1]).contains(day) else { return nil }
        return (year, month, day)
    }
}

/// Civil-day arithmetic deliberately avoids dividing elapsed seconds by 86,400.
/// A fixed Gregorian time zone makes the result stable across DST and zone changes.
public func dayDifference(from: DayStamp, to: DayStamp, calendar: Calendar = .current) -> Int {
    to.civilOrdinal - from.civilOrdinal
}

public struct TodoItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var detail: String
    public var listID: UUID?
    public var tags: [String]
    public var startDay: DayStamp?
    public var endDay: DayStamp?
    /// Minutes after local midnight, in 0...1439. No notification is scheduled.
    public var timeMinutes: Int?
    /// Optional v2 scheduling details; absent legacy data retains its previous date/time semantics.
    public var schedule: TaskScheduleOptions?
    public var isCompleted: Bool
    public var completedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, detail: String = "", listID: UUID? = nil,
                tags: [String] = [], startDay: DayStamp? = nil, endDay: DayStamp? = nil,
                timeMinutes: Int? = nil, isCompleted: Bool = false, completedAt: Date? = nil,
                createdAt: Date = Date(), updatedAt: Date? = nil, schedule: TaskScheduleOptions? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.listID = listID
        self.tags = tags; self.startDay = startDay; self.endDay = endDay; self.timeMinutes = timeMinutes; self.schedule = schedule
        self.isCompleted = isCompleted
        self.completedAt = isCompleted ? (completedAt ?? createdAt) : nil
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }

    public var dueDay: DayStamp? { endDay ?? startDay }
    public var scheduledDueDay: DayStamp? { dueDay }

    /// A bounded range is inclusive. A single boundary is a one-day task.
    /// Undated tasks do not appear on every calendar day.
    public func occurs(on day: DayStamp) -> Bool {
        switch (startDay, endDay) {
        case let (start?, end?): return start <= day && day <= end
        case let (start?, nil): return start == day
        case let (nil, end?): return end == day
        case (nil, nil): return false
        }
    }
}

public struct NoteItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var body: String
    public var tags: [String]
    public var isPinned: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, body: String = "", tags: [String] = [],
                isPinned: Bool = false, createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id; self.title = title; self.body = body; self.tags = tags; self.isPinned = isPinned
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }
}

public struct Anniversary: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var day: DayStamp
    public var emoji: String
    public var repeatYearly: Bool

    public init(id: UUID = UUID(), title: String, day: DayStamp, emoji: String = "🎉", repeatYearly: Bool = true) {
        self.id = id; self.title = title; self.day = day; self.emoji = emoji; self.repeatYearly = repeatYearly
    }
}

public struct Checklist: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var colorHex: String

    public init(id: UUID = UUID(), title: String, colorHex: String = "#2F6FEB") {
        self.id = id; self.title = title; self.colorHex = colorHex
    }
}

public struct Settings: Codable, Equatable, Sendable {
    /// Foundation weekday numbering: Sunday=1, Monday=2, ... Saturday=7.
    public var firstWeekday: Int
    public var showLunar: Bool
    public var searchHistory: [String]
    public var defaultListID: UUID?
    /// First day of the month shown by the calendar widget. Nil follows the
    /// current real month. Kept in shared local storage and portable backups.
    public var widgetCalendarMonth: DayStamp?

    public init(firstWeekday: Int = 1, showLunar: Bool = true, searchHistory: [String] = [], defaultListID: UUID? = nil,
                widgetCalendarMonth: DayStamp? = nil) {
        self.firstWeekday = firstWeekday; self.showLunar = showLunar
        self.searchHistory = searchHistory; self.defaultListID = defaultListID
        self.widgetCalendarMonth = widgetCalendarMonth
    }
}

public struct AppSnapshot: Codable, Equatable, Sendable {
    public var tasks: [TodoItem]
    public var notes: [NoteItem]
    public var anniversaries: [Anniversary]
    public var lists: [Checklist]
    public var settings: Settings
    /// Increases on each committed mutation, including a replacement import.
    public var revision: Int
    /// Changes only after a replacement import. Blocks stale app/widget editors.
    public var generation: UUID
    /// Durable device-sync journal, atomically committed with content.
    public var sync: SyncLedger

    public init(tasks: [TodoItem] = [], notes: [NoteItem] = [], anniversaries: [Anniversary] = [],
                lists: [Checklist] = [], settings: Settings = Settings(), revision: Int = 0, generation: UUID = UUID(),
                sync: SyncLedger = SyncLedger()) {
        self.tasks = tasks; self.notes = notes; self.anniversaries = anniversaries; self.lists = lists
        self.settings = settings; self.revision = revision; self.generation = generation; self.sync = sync
    }

    private enum CodingKeys: String, CodingKey { case tasks, notes, anniversaries, lists, settings, revision, generation, sync }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try values.decode([TodoItem].self, forKey: .tasks)
        notes = try values.decode([NoteItem].self, forKey: .notes)
        anniversaries = try values.decode([Anniversary].self, forKey: .anniversaries)
        lists = try values.decode([Checklist].self, forKey: .lists)
        settings = try values.decode(Settings.self, forKey: .settings)
        revision = try values.decode(Int.self, forKey: .revision)
        generation = try values.decode(UUID.self, forKey: .generation)
        // Repository's strict envelope/shape validator permits absence ONLY for v1 migration.
        sync = try values.decodeIfPresent(SyncLedger.self, forKey: .sync) ?? SyncLedger()
    }

    public func portableBackupSnapshot() -> AppSnapshot {
        var result = self
        result.sync = sync.portableCopy()
        return result
    }

    /// A fresh empty database. A repository persists this once to stabilize its generation.
    public static var empty: AppSnapshot { AppSnapshot() }
}

public struct ImportCounts: Equatable, Sendable {
    public let tasks: Int
    public let notes: Int
    public let anniversaries: Int
    public let lists: Int
}

/// Immutable, validated preview. Only a repository can construct one.
public struct ImportPreview: Sendable {
    public let snapshot: AppSnapshot
    public let exportedAt: Date
    public let counts: ImportCounts

    internal init(snapshot: AppSnapshot, exportedAt: Date) {
        self.snapshot = snapshot; self.exportedAt = exportedAt
        counts = ImportCounts(tasks: snapshot.tasks.count, notes: snapshot.notes.count,
                              anniversaries: snapshot.anniversaries.count, lists: snapshot.lists.count)
    }
}

public enum RepositoryError: Error, LocalizedError, Equatable {
    case missingAppGroupIdentifier
    case unavailableAppGroup(String)
    case unsupportedVersion(Int)
    case invalidFormat
    case invalidData(String)
    case sizeLimitExceeded
    case staleGeneration
    case staleContent
    case itemNotFound
    case revisionOverflow
    case io(String)
    case recoveryPreparationFailed(String)
    case committedMetadataFailure(String)

    public var errorDescription: String? {
        switch self {
        case .missingAppGroupIdentifier: return "缺少 AppGroupIdentifier 配置，请检查 App 与小组件的 Info.plist。"
        case .unavailableAppGroup(let group): return "无法打开共享本地容器（\(group)），请检查 App 与小组件的 App Groups 签名配置。"
        case .unsupportedVersion(let version): return "不支持文件版本 \(version)，未替换现有数据。请使用兼容版本的应用。"
        case .invalidFormat: return "文件不是有效的本地清单备份或存储文件，未替换现有数据。"
        case .invalidData(let reason): return "数据校验未通过，未替换现有数据。详情：\(reason)"
        case .sizeLimitExceeded: return "文件超过本地大小限制（约 20 MB），未替换现有数据。"
        case .staleContent: return "这条内容在编辑期间已被另一操作或设备修改。草稿未提交，请保留草稿并刷新查看最新内容后再编辑。"
        case .staleGeneration: return "本地数据已被导入操作替换，请刷新后再编辑或操作小组件。"
        case .itemNotFound: return "这条内容已被删除，请刷新后再操作。"
        case .revisionOverflow: return "本地存储版本计数已达上限，未替换现有数据。"
        case .io(let reason): return "本地存储操作未能完成：\(reason)"
        case .recoveryPreparationFailed(let reason): return "未能准备导入前的本机恢复副本，主数据未替换。详情：\(reason)"
        case .committedMetadataFailure(let reason): return "数据已保存，但保护属性或持久化确认失败。请先刷新核实，不要重复操作。详情：\(reason)"
        }
    }
}
