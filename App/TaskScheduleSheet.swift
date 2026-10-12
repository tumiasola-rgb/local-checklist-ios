import SwiftUI
import UserNotifications

/// A value-only editing transaction. No repository or notification writes occur
/// until the outer TaskEditor saves the confirmed task.
struct TaskScheduleDraft: Equatable {
    private let original: TodoItem
    var hasDate: Bool
    var isRange: Bool
    var startDay: DayStamp
    var endDay: DayStamp
    var startMinutes: Int
    var endMinutes: Int
    var isAllDay: Bool
    var timeZoneIdentifier: String
    var reminder: TaskReminder?
    var recurrence: TaskRecurrence?

    init(task: TodoItem, today: DayStamp = .today) {
        original = task; hasDate = task.dueDay != nil
        isRange = task.startDay != nil && task.endDay != nil
        startDay = task.startDay ?? task.endDay ?? today; endDay = task.endDay ?? startDay
        startMinutes = task.timeMinutes ?? 540
        endMinutes = task.schedule?.endTimeMinutes ?? task.timeMinutes ?? 600
        isAllDay = task.scheduleIsAllDay
        timeZoneIdentifier = task.schedule?.timeZoneIdentifier ?? TimeZone.current.identifier
        reminder = task.schedule?.reminder; recurrence = task.schedule?.recurrence
    }

    var calendar: Calendar { TaskScheduleMath.calendar(timeZoneIdentifier: timeZoneIdentifier) ?? Calendar(identifier: .gregorian) }
    var validationMessage: String? {
        guard hasDate else { return nil }
        if isRange && endDay < startDay { return "结束日期不能早于开始日期" }
        if isRange && !isAllDay && endDay == startDay && endMinutes < startMinutes { return "结束时间不能早于开始时间" }
        if let until = recurrence?.untilDay, until < startDay { return "重复截止日期不能早于开始日期" }
        if let rule = recurrence, rule.frequency == .weekly, rule.weekdays?.isEmpty == true { return "请至少选择一个星期，或使用开始日对应的星期" }
        guard TaskScheduleMath.calendar(timeZoneIdentifier: timeZoneIdentifier) != nil else { return "无法识别此任务的时区" }
        guard startDay.date(in: calendar) != nil, !isRange || endDay.date(in: calendar) != nil else { return "此时区不存在所选日期，请改选其他日期" }
        return nil
    }

    mutating func clear() { hasDate = false; reminder = nil; recurrence = nil }
    mutating func selectStart(_ day: DayStamp) {
        hasDate = true; startDay = day
        if endDay < day { endDay = day }
    }
    func confirmedTask() -> TodoItem? {
        guard validationMessage == nil else { return nil }
        var task = original
        guard hasDate else {
            task.startDay = nil; task.endDay = nil; task.timeMinutes = nil; task.schedule = nil
            return task
        }
        task.startDay = startDay; task.endDay = isRange ? endDay : nil
        task.timeMinutes = startMinutes
        task.schedule = TaskScheduleOptions(isAllDay: isAllDay, endTimeMinutes: endMinutes,
            timeZoneIdentifier: timeZoneIdentifier, reminder: reminder, recurrence: recurrence)
        return task
    }
}

struct TaskScheduleSheet: View {
    let showLunar: Bool
    let firstWeekday: Int
    let onConfirm: (TodoItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft: TaskScheduleDraft
    @State private var endpoint: ScheduleEndpoint?
    @State private var editingRepeat = false
    @State private var didClear = false
    @State private var authorization = UNAuthorizationStatus.notDetermined

    init(task: TodoItem, showLunar: Bool, firstWeekday: Int = 1, onConfirm: @escaping (TodoItem) -> Void) {
        self.showLunar = showLunar; self.firstWeekday = firstWeekday; self.onConfirm = onConfirm
        _draft = State(initialValue: TaskScheduleDraft(task: task))
    }
    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 18).padding(.vertical, 16)
            ScrollView {
                VStack(spacing: 18) {
                    if !draft.hasDate {
                        Text("尚未设置日期，点选一天开始安排").font(.footnote).foregroundStyle(.secondary)
                    }
                    if draft.isRange && draft.hasDate {
                        rangeCards
                        scheduleCard { Toggle("全天", isOn: $draft.isAllDay).font(.title3).tint(.checklistBlue).padding(18) }
                    } else {
                        ScheduleMonthGrid(selectedDay: draft.startDay, calendar: draft.calendar, showLunar: showLunar,
                            firstWeekday: firstWeekday, highlighted: draft.hasDate) { draft.selectStart($0) }
                        scheduleCard {
                            VStack(spacing: 0) {
                                Toggle(isOn: Binding(get: { !draft.isAllDay }, set: { draft.hasDate = true; draft.isAllDay = !$0 })) {
                                    Label(draft.isAllDay ? "时间 · 无" : "时间", systemImage: "clock")
                                }.tint(.checklistBlue).padding(18)
                                if !draft.isAllDay {
                                    Divider().padding(.horizontal, 18)
                                    DatePicker("开始时间", selection: minutesBinding($draft.startMinutes, day: draft.startDay, calendar: draft.calendar), displayedComponents: .hourAndMinute)
                                        .padding(.horizontal, 18).padding(.vertical, 10)
                                }
                            }
                        }
                    }
                    scheduleCard {
                        VStack(spacing: 0) {
                            Menu {
                                Button("无") { draft.reminder = nil }
                                ForEach(reminderOffsets, id: \.self) { offset in
                                    Button(reminderOffsetLabel(offset, allDay: draft.isAllDay)) {
                                        draft.hasDate = true
                                        draft.reminder = TaskReminder(offsetMinutes: offset, allDayMinutes: draft.reminder?.allDayMinutes ?? 540)
                                    }
                                }
                            } label: { row("提醒时间", symbol: "alarm", value: draft.reminder.map { reminderOffsetLabel($0.offsetMinutes, allDay: draft.isAllDay) } ?? "无") }
                            if draft.isAllDay, draft.reminder != nil {
                                DatePicker("全天任务提醒时刻", selection: Binding(get: {
                                    TaskScheduleMath.date(day: draft.startDay, minutes: draft.reminder?.allDayMinutes ?? 540, calendar: draft.calendar) ?? Date()
                                }, set: { value in
                                    let parts = draft.calendar.dateComponents([.hour, .minute], from: value)
                                    draft.reminder?.allDayMinutes = (parts.hour ?? 9) * 60 + (parts.minute ?? 0)
                                }), displayedComponents: .hourAndMinute).padding(.horizontal, 18).padding(.bottom, 12)
                            }
                            Divider().padding(.horizontal, 18)
                            Button { editingRepeat = true } label: {
                                row("重复", symbol: "repeat", value: recurrenceLabel(draft.recurrence))
                            }
                        }
                    }
                    if let validation = draft.validationMessage {
                        Label(validation, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if draft.reminder != nil { reminderNotice }
                    if draft.recurrence != nil {
                        Text("完成当前项后，按计划日期生成下一次并保留历史；不提前堆积任务。短月与闰日会跳到下个有效日期。").font(.footnote).foregroundStyle(.secondary)
                    }
                    if draft.hasDate {
                        Text("时间按 \(draft.timeZoneIdentifier) 保存").font(.caption).foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) { draft.clear(); didClear = true } label: {
                        Text(!draft.hasDate && didClear ? "已清除，点右上角确认" : "清除").frame(maxWidth: .infinity).padding(.vertical, 20)
                    }.padding(.top, 14)
                }.padding(.horizontal, 18).padding(.bottom, 24)
            }
        }
        .background(Color.checklistCanvas).tint(.checklistBlue)
        .environment(\.timeZone, draft.calendar.timeZone)
        .presentationDetents([.large]).presentationDragIndicator(.hidden)
        .sheet(item: $endpoint) { endpoint in
            ScheduleEndpointSheet(draft: draft, endpoint: endpoint, showLunar: showLunar, firstWeekday: firstWeekday) { draft = $0 }
        }
        .sheet(isPresented: $editingRepeat) {
            ScheduleRepeatSheet(rule: draft.recurrence, startDay: draft.startDay, calendar: draft.calendar) {
                draft.recurrence = $0
                if $0 != nil { draft.hasDate = true }
            }
        }
        .task { await readAuthorization() }
        .onChange(of: scenePhase) { _, value in if value == .active { Task { await readAuthorization() } } }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Button { dismiss() } label: { Image(systemName: "xmark").font(.title2).frame(width: 46, height: 46).background(.background, in: Circle()) }
                .buttonStyle(.plain).accessibilityLabel("取消日期编辑")
            Spacer(minLength: 0)
            Picker("安排方式", selection: $draft.isRange) { Text("日期").tag(false); Text("时间段").tag(true) }
                .pickerStyle(.segmented).frame(maxWidth: 250)
                .onChange(of: draft.isRange) { _, _ in draft.hasDate = true }
            Spacer(minLength: 0)
            Button {
                guard let task = draft.confirmedTask() else { return }
                onConfirm(task); dismiss()
            } label: { Image(systemName: "checkmark").font(.title2).foregroundStyle(.white).frame(width: 46, height: 46).background(Color.checklistBlue, in: Circle()) }
                .buttonStyle(.plain).disabled(draft.validationMessage != nil).opacity(draft.validationMessage == nil ? 1 : 0.45)
                .accessibilityLabel("确认日期编辑")
        }
    }
    private var rangeCards: some View {
        scheduleCard {
            HStack(spacing: 0) {
                rangeEndpoint(.start, title: "开始", day: draft.startDay, minutes: draft.startMinutes)
                Image(systemName: "chevron.right").font(.title3).foregroundStyle(.quaternary)
                rangeEndpoint(.end, title: "结束", day: draft.endDay, minutes: draft.endMinutes)
            }.padding(.vertical, 8)
        }
    }
    private func rangeEndpoint(_ point: ScheduleEndpoint, title: String, day: DayStamp, minutes: Int) -> some View {
        Button { endpoint = point } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.subheadline).foregroundStyle(.primary)
                Text(scheduleDayLabel(day, calendar: draft.calendar)).font(.headline).foregroundStyle(Color.checklistBlue)
                if !draft.isAllDay { Text(minutesLabel(minutes)).font(.body).foregroundStyle(Color.checklistBlue) }
                else if point == .end {
                    Text("持续 \(max(0, dayDifference(from: draft.startDay, to: draft.endDay)) + 1) 天").font(.caption).foregroundStyle(.secondary)
                } else { Text(day.rawValue).font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }.buttonStyle(.plain)
    }
    private func row(_ title: String, symbol: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary).frame(width: 25)
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 10)
            Text(value).foregroundStyle(.secondary).font(.subheadline).multilineTextAlignment(.trailing)
            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
        }.padding(18).contentShape(Rectangle())
    }
    private var reminderNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(authorizationMessage(authorization)).foregroundStyle(authorization == .denied ? Color.red : Color.secondary)
            Text("本机安排未来最近 60 条提醒，超出部分在打开 App 时补排。手机和 Mac 分别授权，可能各自提醒；不会跨设备去重。")
            Text("系统专注模式、通知摘要等可能影响送达；其他设备的修改要等本机同步后才能更新提醒。")
        }.font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func readAuthorization() async { authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
}

private enum ScheduleEndpoint: String, Identifiable { case start, end; var id: String { rawValue } }

private struct ScheduleEndpointSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: TaskScheduleDraft
    @State var endpoint: ScheduleEndpoint
    let showLunar: Bool
    let firstWeekday: Int
    let onConfirm: (TaskScheduleDraft) -> Void
    private var selectedDay: DayStamp { endpoint == .start ? draft.startDay : draft.endDay }
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Picker("选择边界", selection: $endpoint) { Text("开始").tag(ScheduleEndpoint.start); Text("结束").tag(ScheduleEndpoint.end) }
                    .pickerStyle(.segmented).frame(maxWidth: 240).padding(.top, 20)
                ScheduleMonthGrid(selectedDay: selectedDay, calendar: draft.calendar, showLunar: showLunar, firstWeekday: firstWeekday) {
                    if endpoint == .start { draft.startDay = $0 } else { draft.endDay = $0 }
                }
                HStack {
                    Text(scheduleDayLabel(selectedDay, calendar: draft.calendar)).foregroundStyle(.orange)
                    Spacer()
                    if !draft.isAllDay {
                        DatePicker("时间", selection: minutesBinding(endpoint == .start ? $draft.startMinutes : $draft.endMinutes, day: selectedDay, calendar: draft.calendar), displayedComponents: .hourAndMinute).labelsHidden()
                    }
                }
                if let validation = draft.validationMessage { Text(validation).font(.footnote).foregroundStyle(.red) }
                HStack(spacing: 16) {
                    Button { dismiss() } label: { Text("取消").frame(maxWidth: .infinity).padding(17).background(Color.checklistCanvas, in: Capsule()) }.buttonStyle(.plain)
                    Button { onConfirm(draft); dismiss() } label: {
                        Text("完成").foregroundStyle(.white).frame(maxWidth: .infinity).padding(17).background(Color.checklistBlue, in: Capsule())
                    }.disabled(draft.validationMessage != nil).opacity(draft.validationMessage == nil ? 1 : 0.45)
                }
            }.padding(24)
        }.background(Color.checklistCard).tint(.checklistBlue).environment(\.timeZone, draft.calendar.timeZone)
            .presentationDetents([.large]).presentationCornerRadius(32)
    }
}

private struct ScheduleRepeatSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Bool
    @State private var frequency: TaskRecurrence.Frequency
    @State private var interval: Int
    @State private var chosenWeekdays: Set<Int>
    @State private var customWeekdays: Bool
    @State private var hasEnd: Bool
    @State private var endDate: Date
    let startDay: DayStamp
    let calendar: Calendar
    let onConfirm: (TaskRecurrence?) -> Void
    init(rule: TaskRecurrence?, startDay: DayStamp, calendar: Calendar, onConfirm: @escaping (TaskRecurrence?) -> Void) {
        self.startDay = startDay; self.calendar = calendar; self.onConfirm = onConfirm
        _enabled = State(initialValue: rule != nil); _frequency = State(initialValue: rule?.frequency ?? .daily)
        _interval = State(initialValue: rule?.interval ?? 1)
        _chosenWeekdays = State(initialValue: Set(rule?.weekdays ?? [calendar.component(.weekday, from: startDay.date(in: calendar) ?? Date())]))
        _customWeekdays = State(initialValue: rule?.weekdays != nil)
        _hasEnd = State(initialValue: rule?.untilDay != nil)
        _endDate = State(initialValue: (rule?.untilDay ?? startDay).date(in: calendar) ?? Date())
    }
    private var valid: Bool { !enabled || ((!hasEnd || DayStamp(date: endDate, calendar: calendar) >= startDay) && (frequency != .weekly || !customWeekdays || !chosenWeekdays.isEmpty)) }
    var body: some View {
        NavigationStack {
            Form {
                Toggle("重复", isOn: $enabled)
                if enabled {
                    Picker("频率", selection: $frequency) {
                        ForEach(TaskRecurrence.Frequency.allCases, id: \.self) { Text(frequencyLabel($0)).tag($0) }
                    }
                    Stepper("每 \(interval) \(frequencyUnit(frequency))", value: $interval, in: 1...99)
                    if frequency == .weekly {
                        Toggle("指定星期", isOn: $customWeekdays)
                        if customWeekdays {
                            ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { weekday in
                                Toggle("星期\(["日", "一", "二", "三", "四", "五", "六"][weekday - 1])", isOn: Binding(get: { chosenWeekdays.contains(weekday) }, set: { value in
                                    if value { chosenWeekdays.insert(weekday) } else { chosenWeekdays.remove(weekday) }
                                }))
                            }
                            Button("选择周一至周五") { chosenWeekdays = Set(2...6) }
                            Text("周一至周五不包含法定节假日与调休判断；间隔周以周一为起点。").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("设置截止日期", isOn: $hasEnd)
                    if hasEnd { DatePicker("最后一次开始日", selection: $endDate, in: (startDay.date(in: calendar) ?? Date())..., displayedComponents: .date) }
                    if !valid { Text("请至少选择一个星期，并检查截止日期").font(.footnote).foregroundStyle(.red) }
                }
                Section {
                    Text("完成后才生成下一次；依据计划日期递推，保留完成历史。短月、闰日跳过无效日期。撤销完成不会删除已生成的下一次。").font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("重复规则").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("完成") {
                        onConfirm(enabled ? TaskRecurrence(frequency: frequency, interval: interval,
                            weekdays: frequency == .weekly && customWeekdays ? chosenWeekdays.sorted() : nil,
                            untilDay: hasEnd ? DayStamp(date: endDate, calendar: calendar) : nil) : nil)
                        dismiss()
                    }.disabled(!valid) }
                }
        }.tint(.checklistBlue).environment(\.timeZone, calendar.timeZone)
    }
}

private struct ScheduleMonthGrid: View {
    let selectedDay: DayStamp
    let calendar: Calendar
    let showLunar: Bool
    let firstWeekday: Int
    var highlighted = true
    let onSelect: (DayStamp) -> Void
    @State private var month: Date
    init(selectedDay: DayStamp, calendar: Calendar, showLunar: Bool, firstWeekday: Int, highlighted: Bool = true, onSelect: @escaping (DayStamp) -> Void) {
        self.selectedDay = selectedDay; self.calendar = calendar; self.showLunar = showLunar
        self.firstWeekday = firstWeekday; self.highlighted = highlighted; self.onSelect = onSelect
        _month = State(initialValue: selectedDay.date(in: calendar) ?? Date())
    }
    private var first: Date { calendar.date(from: calendar.dateComponents([.year, .month], from: month)) ?? month }
    private var offset: Int { (calendar.component(.weekday, from: first) - firstWeekday + 7) % 7 }
    private var count: Int { calendar.range(of: .day, in: .month, for: month)?.count ?? 30 }
    private var monthTitle: String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: month)
    }
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("上个月")
                Spacer()
                Text(monthTitle).font(.title3.weight(.medium))
                Spacer()
                Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.accessibilityLabel("下个月")
            }.foregroundStyle(.primary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 10) {
                ForEach(0..<7, id: \.self) { index in
                    Text(["日", "一", "二", "三", "四", "五", "六"][(index + firstWeekday - 1) % 7]).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(0..<(offset + count), id: \.self) { index in
                    if index < offset { Color.clear.frame(height: 47) }
                    else if let date = calendar.date(byAdding: .day, value: index - offset, to: first) {
                        let day = DayStamp(date: date, calendar: calendar)
                        let selected = highlighted && day == selectedDay
                        Button { onSelect(day) } label: {
                            VStack(spacing: 2) {
                                Text("\(index - offset + 1)").font(.body.weight(.medium))
                                if showLunar { Text(scheduleLunarLabel(day)).font(.system(size: 10)).lineLimit(1) }
                            }.foregroundStyle(selected ? Color.white : Color.primary)
                                .frame(maxWidth: .infinity, minHeight: 47)
                                .background(selected ? Color.checklistBlue : Color.clear, in: Circle())
                        }.buttonStyle(.plain).accessibilityLabel(day.rawValue).accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
        }.onChange(of: selectedDay) { _, value in month = value.date(in: calendar) ?? month }
    }
    private func shift(_ amount: Int) {
        guard let result = calendar.date(byAdding: .month, value: amount, to: first), (1...9999).contains(calendar.component(.year, from: result)) else { return }
        month = result
    }
}

private func scheduleCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content().frame(maxWidth: .infinity).background(Color.checklistCard, in: RoundedRectangle(cornerRadius: 22))
}
private func minutesBinding(_ minutes: Binding<Int>, day: DayStamp, calendar: Calendar) -> Binding<Date> {
    Binding(get: { TaskScheduleMath.date(day: day, minutes: minutes.wrappedValue, calendar: calendar) ?? Date() }, set: { value in
        let parts = calendar.dateComponents([.hour, .minute], from: value)
        minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    })
}
private func minutesLabel(_ value: Int) -> String { String(format: "%02d:%02d", value / 60, value % 60) }
private func scheduleDayLabel(_ day: DayStamp, calendar: Calendar) -> String {
    guard let date = day.date(in: calendar) else { return day.rawValue }
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.timeZone = calendar.timeZone; formatter.dateFormat = "M月d日，EEE"
    return formatter.string(from: date)
}
private func scheduleLunarLabel(_ day: DayStamp) -> String {
    // Render the same civil day in the current display zone for the existing
    // Foundation lunar helper; no unsupported holiday/adjusted-workday claims.
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
    guard let date = TaskScheduleMath.date(day: day, minutes: 720, calendar: calendar) else { return "" }
    return lunarLabel(date)
}
private let reminderOffsets = [0, 5, 10, 15, 30, 60, 1440, 2880, 10080]
private func reminderOffsetLabel(_ offset: Int, allDay: Bool) -> String {
    if offset == 0 { return allDay ? "当天" : "开始时" }
    if offset % 1440 == 0 { return "提前 \(offset / 1440) 天" }
    if offset % 60 == 0 { return "提前 \(offset / 60) 小时" }
    return "提前 \(offset) 分钟"
}
private func frequencyLabel(_ frequency: TaskRecurrence.Frequency) -> String {
    switch frequency { case .daily: return "每天"; case .weekly: return "每周"; case .monthly: return "每月"; case .yearly: return "每年" }
}
private func frequencyUnit(_ frequency: TaskRecurrence.Frequency) -> String {
    switch frequency { case .daily: return "天"; case .weekly: return "周"; case .monthly: return "个月"; case .yearly: return "年" }
}
func recurrenceLabel(_ rule: TaskRecurrence?) -> String {
    guard let rule else { return "无" }
    var label = rule.interval == 1 ? frequencyLabel(rule.frequency) : "每 \(rule.interval) \(frequencyUnit(rule.frequency))"
    if let weekdays = rule.weekdays, !weekdays.isEmpty {
        label += "（" + weekdays.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }.map { ["日", "一", "二", "三", "四", "五", "六"][$0 - 1] }.joined(separator: "、") + "）"
    }
    if let until = rule.untilDay { label += "，至 \(until.rawValue)" }
    return label
}
private func authorizationMessage(_ value: UNAuthorizationStatus) -> String {
    switch value {
    case .denied: return "本机通知权限已关闭，这台设备不会提醒。请到系统设置允许本 App 通知。"
    case .notDetermined: return "保存有效提醒时才会申请本机通知权限；取消编辑不会申请。"
    case .provisional: return "本机仅获静默通知授权，请到系统设置检查横幅与声音。"
    case .authorized, .ephemeral: return "提醒规则会保存；通知是否送达取决于本机系统设置。"
    @unknown default: return "请到系统设置确认本机通知权限。"
    }
}
