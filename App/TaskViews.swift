import SwiftUI

struct TaskRow: View {
    @EnvironmentObject private var model: AppModel
    let task: TodoItem
    let onOpen: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Button { model.setCompleted(task, to: !task.isCompleted) } label: {
                Image(systemName: task.isCompleted ? "checkmark.square.fill" : "square")
                    .font(.system(size: 24, weight: .light)).foregroundStyle(task.isCompleted ? Color.secondary.opacity(0.45) : Color.secondary)
                    .frame(width: 28, height: 36)
            }.buttonStyle(.plain).accessibilityLabel(task.isCompleted ? "标为未完成" : "完成待办")
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(task.title).font(.body).foregroundStyle(task.isCompleted ? Color.secondary : Color.primary).strikethrough(task.isCompleted).lineLimit(2)
                        if !task.tags.isEmpty || task.listID != nil {
                            Text(([model.listName(task.listID)] + task.tags.map { "#" + $0 }).joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(task.dueLabel).font(.caption).foregroundStyle(task.isCompleted ? Color.secondary : ((task.dueDay ?? .today) < .today ? .red : .checklistBlue))
                        if !task.detail.isEmpty { Image(systemName: "text.alignleft").font(.caption2).foregroundStyle(.tertiary) }
                    }
                }.padding(.vertical, 7).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }
}

struct TodayScreen: View {
    @EnvironmentObject private var model: AppModel
    let onTask: (TodoItem) -> Void
    @State private var filter: UUID?
    @State private var collapsed = Set<String>()
    @State private var confirmPostpone = false
    private var tasks: [TodoItem] { model.snapshot.tasks.filter { filter == nil || $0.listID == filter }.sorted(by: taskOrder) }
    private var overdue: [TodoItem] { tasks.filter { !$0.isCompleted && ($0.dueDay.map { $0 < .today } ?? false) } }
    private var today: [TodoItem] { tasks.filter { !$0.isCompleted && $0.occurs(on: .today) } }
    private var unscheduled: [TodoItem] { tasks.filter { !$0.isCompleted && $0.startDay == nil && $0.endDay == nil } }
    private var future: [TodoItem] { tasks.filter { !$0.isCompleted && (($0.startDay ?? $0.endDay).map { $0 > .today } ?? false) } }
    private var done: [TodoItem] { tasks.filter(\.isCompleted).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) } }
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Menu {
                        Button("全部清单") { filter = nil }
                        ForEach(model.snapshot.lists) { list in Button(list.title) { filter = list.id } }
                    } label: { Label(filter == nil ? "全部清单" : model.listName(filter), systemImage: "line.3.horizontal.decrease") }
                    Spacer()
                    Text("\(today.count) 项今天").font(.caption).foregroundStyle(.secondary)
                }.font(.subheadline).padding(.horizontal, 6)
                if tasks.isEmpty { EmptyCard(symbol: "checkmark.circle", title: "从一件小事开始", subtitle: "点右下角加号，记下今天想完成的事") }
                if !overdue.isEmpty { group("已过期", items: overdue, postponed: true) }
                group("今天", items: today)
                if !unscheduled.isEmpty { group("无日期", items: unscheduled) }
                if !future.isEmpty { group("以后", items: future) }
                if !done.isEmpty { group("已完成", items: done) }
            }.padding(.horizontal, 16).padding(.bottom, 95)
        }.confirmationDialog("把全部已过期待办顺延到今天？", isPresented: $confirmPostpone, titleVisibility: .visible) {
            Button("顺延 \(overdue.count) 项") { model.postponeOverdue(ids: Set(overdue.map(\.id))) }
        } message: { Text("跨日任务保留原持续天数，结束日期调整为今天。") }
    }
    @ViewBuilder private func group(_ title: String, items: [TodoItem], postponed: Bool = false) -> some View {
        Card {
            VStack(spacing: 17) {
                HStack {
                    Button {
                        if collapsed.contains(title) { collapsed.remove(title) } else { collapsed.insert(title) }
                    } label: {
                        HStack {
                            Text(title).font(.title3.bold()).foregroundStyle(title == "已完成" ? Color.secondary : Color.primary)
                            Spacer()
                            Text("\(items.count)").font(.subheadline).foregroundStyle(.secondary)
                            Image(systemName: collapsed.contains(title) ? "chevron.right" : "chevron.down").font(.caption).foregroundStyle(.tertiary)
                        }
                    }.buttonStyle(.plain)
                    if postponed { Button("顺延") { confirmPostpone = true }.font(.subheadline.weight(.medium)) }
                }
                if !collapsed.contains(title) {
                    if items.isEmpty { Text("今天没有待办，轻松一点").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10) }
                    ForEach(items) { task in TaskRow(task: task) { onTask(task) } }
                }
            }
        }
    }
}

struct TaskEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var task: TodoItem
    let generation: UUID
    @State private var tags = ""
    @State private var didInitialize = false
    @State private var wasNew = true
    @State private var openedGeneration: UUID?
    @State private var originalTask: TodoItem?
    @State private var showSchedule = false
    @State private var saving = false
    @State private var deleting = false
    @State private var share: SharePayload?
    @State private var shareError: String?
    private var existing: Bool { model.snapshot.tasks.contains { $0.id == task.id } }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("想做什么？", text: $task.title, axis: .vertical).font(.title3)
                    TextField("补充说明", text: $task.detail, axis: .vertical).lineLimit(4...12)
                }
                Section("安排") {
                    Button { showSchedule = true } label: {
                        HStack(alignment: .top) {
                            Image(systemName: "calendar")
                            VStack(alignment: .leading, spacing: 6) {
                                Text(taskScheduleSummary(task)).foregroundStyle(.primary)
                                Text("日期 / 时间段 · 全天 · 提醒 · 重复").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if task.schedule?.reminder != nil { Text("提醒规则会同步，但每台设备需要自己授予通知权限。").font(.footnote).foregroundStyle(.secondary) }
                }
                Section("整理") {
                    Picker("清单", selection: $task.listID) {
                        Text("收集箱").tag(nil as UUID?)
                        ForEach(model.snapshot.lists) { Text($0.title).tag(Optional($0.id)) }
                    }
                    TextField("标签，用逗号分隔", text: $tags)
                }
                if existing {
                    Section {
                        Button(task.isCompleted ? "标为未完成" : "标为已完成", systemImage: "checkmark.circle") {
                            let desired = !task.isCompleted
                            guard model.save(preparedTask(), generation: openedGeneration ?? generation, isNew: false, expectedOriginal: originalTask) else { shareError = model.problem; return }
                            originalTask = model.snapshot.tasks.first { $0.id == task.id }
                            guard model.setCompleted(task, to: desired) else { shareError = model.problem; return }
                            if let latest = model.snapshot.tasks.first(where: { $0.id == task.id }) { task = latest; originalTask = latest }
                            let reminderTask = task.isCompleted ? nextOccurrence(after: task).flatMap { next in model.snapshot.tasks.first { $0.id == next.id } } : task
                            if let reminderTask, let fireDate = TaskScheduleMath.reminderDate(for: reminderTask), fireDate > Date() { Task { await model.authorizeReminderFromUserAction() } }
                        }
                        Button("生成图片分享", systemImage: "square.and.arrow.up") { shareTask() }
                        Button("删除待办", role: .destructive) { deleting = true }
                    }
                }
                Section { Text("重复按计划日递推：完成后保留历史，并生成下一次；没有完成时不会每天堆积新任务。提醒是否送达受系统权限、专注模式与调度影响。").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle(existing ? "待办详情" : "新建待办").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") { persist() }.disabled(saving || task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("删除这条待办？", isPresented: $deleting, titleVisibility: .visible) { Button("删除", role: .destructive) { if model.deleteTask(task.id, generation: openedGeneration ?? generation, expectedOriginal: originalTask) { dismiss() } else { shareError = model.problem } } }
            .sheet(isPresented: $showSchedule) {
                TaskScheduleSheet(task: task, showLunar: model.snapshot.settings.showLunar, firstWeekday: model.snapshot.settings.firstWeekday) { value in task = value; showSchedule = false }
            }
            .sheet(item: $share) { ShareSheet(payload: $0) }
            .alert("操作未完成", isPresented: Binding(get: { shareError != nil }, set: { if !$0 { shareError = nil } })) { Button("好", role: .cancel) {} } message: { Text(shareError ?? "") }
        }
        .onAppear {
            guard !didInitialize else { return }; didInitialize = true
            openedGeneration = generation; wasNew = !existing; originalTask = existing ? task : nil
            tags = task.tags.joined(separator: ", ")
        }
        .interactiveDismissDisabled(saving)
    }
    private func persist() {
        guard !saving else { return }; saving = true
        let value = preparedTask()
        Task { @MainActor in
            defer { saving = false }
            guard model.save(value, generation: openedGeneration ?? generation, isNew: wasNew, expectedOriginal: originalTask) else { shareError = model.problem; return }
            if let fireDate = TaskScheduleMath.reminderDate(for: value), fireDate > Date() { await model.authorizeReminderFromUserAction() }
            dismiss()
        }
    }
    private func preparedTask() -> TodoItem {
        var result = task
        if let latest = model.snapshot.tasks.first(where: { $0.id == task.id }) { result.isCompleted = latest.isCompleted; result.completedAt = latest.completedAt }
        result.title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        result.tags = splitTags(tags)
        return result
    }
    private func shareTask() {
        do { share = try ShareImageMaker.task(preparedTask(), list: model.listName(task.listID)) }
        catch { shareError = error.localizedDescription }
    }
}
