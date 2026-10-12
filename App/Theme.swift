import SwiftUI

extension Color {
    static let checklistBlue = Color(red: 0.32, green: 0.42, blue: 0.98)
    static let checklistLavender = Color(red: 0.84, green: 0.87, blue: 1)
    static let checklistCanvas = Color(uiColor: .systemGroupedBackground)
    static let checklistCard = Color(uiColor: .secondarySystemGroupedBackground)
    init(hex: String) {
        let source = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let number = UInt64(source, radix: 16) ?? 0x536DFE
        self.init(red: Double((number >> 16) & 255) / 255, green: Double((number >> 8) & 255) / 255, blue: Double(number & 255) / 255)
    }
}

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View { content.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color.checklistCard, in: RoundedRectangle(cornerRadius: 22)) }
}

struct CircleIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.title3.weight(.medium)).frame(width: 44, height: 44).background(.regularMaterial, in: Circle()) }
            .buttonStyle(.plain).accessibilityLabel(label)
    }
}

struct EmptyCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 46, weight: .light)).foregroundStyle(Color.checklistBlue).padding(.bottom, 6)
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 58).padding(.horizontal, 24)
    }
}

func splitTags(_ text: String) -> [String] {
    var seen = Set<String>()
    return text.components(separatedBy: CharacterSet(charactersIn: ",，#\n")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
}

func lunarLabel(_ date: Date) -> String {
    var chinese = Calendar(identifier: .chinese); chinese.timeZone = .current
    let components = chinese.dateComponents(in: .current, from: date)
    let days = ["初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十", "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十", "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"]
    let months = ["正月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "冬月", "腊月"]
    guard let day = components.day, (1...30).contains(day) else { return "" }
    if day == 1, let month = components.month, (1...12).contains(month) { return (components.isLeapMonth == true ? "闰" : "") + months[month - 1] }
    return days[day - 1]
}

func taskOrder(_ lhs: TodoItem, _ rhs: TodoItem) -> Bool {
    if lhs.dueDay != rhs.dueDay { return (lhs.dueDay?.rawValue ?? "9999-12-31") < (rhs.dueDay?.rawValue ?? "9999-12-31") }
    let leftTime = lhs.scheduleIsAllDay ? -1 : (lhs.timeMinutes ?? -1)
    let rightTime = rhs.scheduleIsAllDay ? -1 : (rhs.timeMinutes ?? -1)
    if leftTime != rightTime { return leftTime < rightTime }
    return lhs.createdAt < rhs.createdAt
}

func taskScheduleSummary(_ task: TodoItem) -> String {
    guard let start = task.startDay ?? task.endDay else { return "未设置日期" }
    var pieces = [start.rawValue + (task.endDay.map { " → " + $0.rawValue } ?? "")]
    if task.scheduleIsAllDay { pieces.append("全天") }
    else {
        let startTime = task.timeMinutes.map { String(format: "%02d:%02d", $0 / 60, $0 % 60) } ?? "00:00"
        let endTime = task.schedule?.endTimeMinutes.map { String(format: "%02d:%02d", $0 / 60, $0 % 60) }
        pieces.append(startTime + (endTime.map { " – " + $0 } ?? ""))
    }
    if let reminder = task.schedule?.reminder {
        let clock = String(format: "%02d:%02d", reminder.allDayMinutes / 60, reminder.allDayMinutes % 60)
        pieces.append((task.scheduleIsAllDay ? "\(clock)" : "开始时间") + (reminder.offsetMinutes == 0 ? "提醒" : "提前\(reminder.offsetMinutes)分钟提醒"))
    }
    if let rule = task.schedule?.recurrence {
        let frequency: String
        switch rule.frequency { case .daily: frequency = "天"; case .weekly: frequency = "周"; case .monthly: frequency = "月"; case .yearly: frequency = "年" }
        pieces.append("每\(rule.interval)\(frequency)重复" + (rule.untilDay.map { "，截至" + $0.rawValue } ?? ""))
    }
    return pieces.joined(separator: " · ")
}
