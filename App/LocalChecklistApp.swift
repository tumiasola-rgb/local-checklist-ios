import SwiftUI
import UIKit

@main
struct LocalChecklistApp: App {
    @StateObject private var model = AppModel()
    @UIApplicationDelegateAdaptor(NotificationAppDelegate.self) private var notificationDelegate
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).tint(.checklistBlue)
                .onChange(of: scenePhase) { _, phase in if phase == .active { model.refresh(); Task { await model.activateLANIfEnabled() } } else if phase == .background { Task { await model.suspendLAN() } } }
        }
        #if targetEnvironment(macCatalyst)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建待办") { NotificationCenter.default.post(name: .checklistNewTask, object: nil) }.keyboardShortcut("n", modifiers: .command).disabled(model.isModalOpen)
                Button("新建笔记") { NotificationCenter.default.post(name: .checklistNewNote, object: nil) }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.isModalOpen)
            }
            CommandGroup(after: .newItem) {
                Button("立即同步") { NotificationCenter.default.post(name: .checklistSync, object: nil) }.keyboardShortcut("r", modifiers: .command).disabled(model.isModalOpen)
            }
        }
        #endif
    }
}

enum AppTab: Int, CaseIterable {
    case calendar, today, search, notebook, anniversaries
    var title: String { ["日历", "今日待办", "搜索", "记事本", "纪念日"][rawValue] }
    var icon: String { ["calendar", "checkmark.square.fill", "magnifyingglass", "note.text", "hourglass"][rawValue] }
}

enum AppSheet: Identifiable {
    case task(TodoItem), note(NoteItem), anniversary(Anniversary), day(DayStamp), settings, capture, sync
    var id: String {
        switch self {
        case .task(let item): return "task-\(item.id)"
        case .note(let item): return "note-\(item.id)"
        case .anniversary(let item): return "anniversary-\(item.id)"
        case .day(let day): return "day-\(day.rawValue)"
        case .settings: return "settings"
        case .capture: return "capture"
        case .sync: return "sync"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: AppTab = .today
    @State private var sheet: AppSheet?
    @State private var calendarDay = Date()
    @AppStorage("didOpenLocalChecklist") private var didOpen = false
    @State private var welcome = false
    @State private var pendingURL: URL?
    private let dayTicker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            #if targetEnvironment(macCatalyst)
            VStack(alignment: .leading, spacing: 16) {
                Label("本地清单", systemImage: "checkmark.square.fill").font(.title3.bold()).foregroundStyle(Color.checklistBlue).padding(.bottom, 20)
                ForEach(AppTab.allCases, id: \.rawValue) { item in
                    Button { tab = item } label: {
                        Label(item.title, systemImage: item.icon).font(.body).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(tab == item ? Color.checklistBlue.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(tab == item ? Color.checklistBlue : .primary)
                    }.buttonStyle(.plain)
                }
                Spacer()
                Button("同步与冲突", systemImage: "wifi") { sheet = .sync }.buttonStyle(.plain)
                Text("本机保存 · 局域网同步").font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(width: 205).background(.regularMaterial)
            Divider()
            #endif
            VStack(spacing: 0) {
            HStack {
                Text(tab == .today ? "今天" : tab.title).font(.largeTitle.bold())
                Spacer()
                CircleIconButton(symbol: model.isSyncing ? "wifi" : "arrow.triangle.2.circlepath", label: "局域网同步") {
                    if model.lanStatus?.enabled == true && model.lanStatus?.pairedPeer != nil { Task { await model.syncNow() } } else { sheet = .sync }
                }.disabled(model.isSyncing)
                CircleIconButton(symbol: "gearshape", label: "设置与完整备份") { sheet = .settings }
            }.padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 12)
            if (model.lanStatus?.enabled ?? false) || model.isSyncing {
                HStack(spacing: 7) {
                    if model.isSyncing { ProgressView().controlSize(.small) } else { Image(systemName: "wifi").font(.caption) }
                    Text(model.isSyncing ? "正在与已配对设备交换变更…" : model.syncMessage).font(.caption).lineLimit(2)
                    Spacer(minLength: 0)
                    Button("详情") { sheet = .sync }.font(.caption)
                }.foregroundStyle(.secondary).padding(.horizontal, 22).padding(.bottom, 9)
            }
            if !model.notificationMessage.isEmpty && model.snapshot.tasks.contains(where: { !$0.isCompleted && $0.schedule?.reminder != nil }) {
                Text(model.notificationMessage).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.bottom, 6)
            }
            if let problem = model.problem {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(problem).font(.caption).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { model.problem = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭提示")
                }.padding(12).foregroundStyle(.red).background(.red.opacity(0.07)).padding(.horizontal, 16)
            }
            Group {
                switch tab {
                case .calendar: CalendarScreen(selectedDate: $calendarDay, onDay: { sheet = .day($0) }, onTask: { sheet = .task($0) })
                case .today: TodayScreen(onTask: { sheet = .task($0) })
                case .search: SearchScreen(onTask: { sheet = .task($0) }, onNote: { sheet = .note($0) }, onAnniversary: { sheet = .anniversary($0) })
                case .notebook: NotebookScreen(onNote: { sheet = .note($0) })
                case .anniversaries: AnniversariesScreen(onEdit: { sheet = .anniversary($0) })
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            #if !targetEnvironment(macCatalyst)
            HStack(spacing: 3) {
                ForEach(AppTab.allCases, id: \.rawValue) { item in
                    Button { tab = item } label: {
                        VStack(spacing: 4) {
                            Image(systemName: item.icon).font(.system(size: 21, weight: .semibold)).frame(height: 26)
                            Text(item.title).font(.caption2)
                        }.frame(maxWidth: .infinity).padding(.vertical, 11)
                            .foregroundStyle(tab == item ? Color.checklistBlue : Color.primary.opacity(0.8))
                            .background(tab == item ? Color.checklistBlue.opacity(0.08) : Color.clear, in: Capsule())
                    }.buttonStyle(.plain).accessibilityAddTraits(tab == item ? .isSelected : [])
                }
            }.padding(6).background(.regularMaterial, in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.8), lineWidth: 1)).padding(.horizontal, 16).padding(.bottom, 6)
            #endif
            }
        }
        .background(Color.checklistCanvas.ignoresSafeArea())
        #if targetEnvironment(macCatalyst)
        .frame(minWidth: 840, idealWidth: 1100, minHeight: 650, idealHeight: 800)
        #endif
        .overlay(alignment: .bottomTrailing) {
            if tab != .search {
                Menu {
                    Button("新建待办", systemImage: "checkmark.square") { newTask() }
                    Button("新建笔记", systemImage: "note.text.badge.plus") { sheet = .note(NoteItem(title: "", body: "")) }
                    Button("图片 / 语音快速新建", systemImage: "sparkles") { sheet = .capture }
                    Button("新建纪念日", systemImage: "hourglass.badge.plus") { sheet = .anniversary(Anniversary(title: "", day: .today, emoji: "🎉", repeatYearly: false)) }
                } label: {
                    Image(systemName: "plus").font(.system(size: 30, weight: .light)).foregroundStyle(.white).frame(width: 62, height: 62).background(Color.checklistBlue, in: Circle()).shadow(color: .checklistBlue.opacity(0.2), radius: 8, y: 4)
                }.accessibilityLabel("新建待办、笔记或纪念日").disabled(!model.isReady).padding(.trailing, 22).padding(.bottom, 90)
            }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .task(let task): TaskEditor(task: task, generation: model.snapshot.generation)
            case .note(let note): NoteEditor(note: note, generation: model.snapshot.generation)
            case .anniversary(let anniversary): AnniversaryEditor(item: anniversary, generation: model.snapshot.generation)
            case .day(let day): DayAgenda(day: day, onTask: { task in sheet = .task(task) }, onAdd: { newTask(day: day) })
            case .settings: SettingsScreen()
            case .sync: LocalSyncHost()
            case .capture:
                QuickCaptureView { drafts in
                    let generation = model.snapshot.generation
                    let saved = model.commit(generation: generation) { value in
                        for draft in drafts {
                            let detail = draft.body + (draft.originalText == draft.body ? "" : "\n\n原始识别：\n" + draft.originalText) + (draft.sourceText == draft.originalText ? "" : "\n\n整次原始输入：\n" + draft.sourceText)
                            switch draft.kind {
                            case .task:
                                guard !value.tasks.contains(where: { $0.id == draft.id }), !value.notes.contains(where: { $0.id == draft.id }) else { continue }
                                var task = TodoItem(id: draft.id, title: draft.title)
                                task.detail = detail
                                if let date = draft.dueDate {
                                    task.startDay = DayStamp(date: date)
                                    if draft.hasTime {
                                        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                                        task.timeMinutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                                    }
                                }
                                value.tasks.append(task)
                            case .note:
                                guard !value.tasks.contains(where: { $0.id == draft.id }), !value.notes.contains(where: { $0.id == draft.id }) else { continue }
                                let dateText = draft.dueDate.map { date in "\n\n识别的日期：" + DayStamp(date: date).rawValue + (draft.hasTime ? " " + date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) : "") } ?? ""
                                value.notes.append(NoteItem(id: draft.id, title: draft.title, body: detail + dateText))
                            }
                        }
                    }
                    if saved { sheet = nil }
                    return saved
                }
            }
        }
        .sheet(isPresented: $welcome) { WelcomeScreen { welcome = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { sheet = .settings } } }
        .onAppear {
            if !didOpen { welcome = true; didOpen = true }
            model.isModalOpen = welcome || sheet != nil
            routePendingNotification()
            Task { await model.activateLANIfEnabled() }
        }
        .onChange(of: sheet?.id) { _, value in
            model.isModalOpen = value != nil || welcome
            if value == nil, !welcome { resumePendingRoute() }
        }
        .onChange(of: welcome) { _, value in
            model.isModalOpen = value || sheet != nil
            if !value, sheet == nil { resumePendingRoute() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .checklistOpenNotification)) { _ in routePendingNotification() }
        .onReceive(NotificationCenter.default.publisher(for: .localChecklistSyncDidCommit).receive(on: DispatchQueue.main)) { _ in model.receivedSyncedData() }
        .onReceive(dayTicker) { _ in
            if scenePhase == .active { model.refresh(); Task { await model.reloadSyncStatus() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .checklistNewTask)) { _ in newTask() }
        .onReceive(NotificationCenter.default.publisher(for: .checklistNewNote)) { _ in sheet = .note(NoteItem(title: "", body: "")) }
        .onReceive(NotificationCenter.default.publisher(for: .checklistSync)) { _ in
            if model.lanStatus?.enabled == true && model.lanStatus?.pairedPeer != nil { Task { await model.syncNow() } } else { sheet = .sync }
        }
        .onOpenURL(perform: open)
    }

    private func newTask(day: DayStamp? = nil) {
        var task = TodoItem(title: "")
        task.startDay = day ?? (tab == .calendar ? DayStamp(date: calendarDay) : .today)
        sheet = .task(task)
    }
    private func resumePendingRoute() {
        guard let url = pendingURL else { return }; pendingURL = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            open(url)
        }
    }
    private func routePendingNotification() {
        guard let raw = UserDefaults.standard.string(forKey: NotificationAppDelegate.pendingTaskKey), UUID(uuidString: raw) != nil,
              let url = URL(string: "localchecklist://task?id=" + raw) else { return }
        UserDefaults.standard.removeObject(forKey: NotificationAppDelegate.pendingTaskKey)
        open(url)
    }
    private func open(_ url: URL) {
        if sheet != nil || welcome { pendingURL = url; return }
        guard url.scheme == "localchecklist", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let values = Dictionary(components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { first, _ in first })
        model.refresh()
        switch url.host {
        case "today": tab = .today
        case "calendar":
            tab = .calendar
            if let raw = values["day"], let day = DayStamp(rawValue: raw), let date = day.date() { calendarDay = date; sheet = .day(day) }
        case "add": newTask(day: values["day"].flatMap(DayStamp.init(rawValue:)))
        case "task":
            if let raw = values["id"], let id = UUID(uuidString: raw), let task = model.snapshot.tasks.first(where: { $0.id == id }) { sheet = .task(task) }
        default: break
        }
    }
}

struct WelcomeScreen: View {
    @Environment(\.dismiss) private var dismiss
    let onImport: () -> Void
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "checkmark.square.fill").font(.system(size: 64)).foregroundStyle(Color.checklistBlue)
            Text("本地清单").font(.largeTitle.bold())
            Text("待办、日历、笔记和重要日子\n本机保存，用局域网同步手机与 Mac").multilineTextAlignment(.center).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                Label("无需账号，只与你确认的设备配对", systemImage: "wifi")
                Label("设置中一键导出完整备份", systemImage: "externaldrive")
                Label("换装后，选择自己的备份恢复", systemImage: "arrow.clockwise")
            }.font(.subheadline).padding(20).background(Color.checklistCanvas, in: RoundedRectangle(cornerRadius: 20))
            Text("删除 App 可能同时删除本机数据。请先导出到“文件”中可保留的位置；要纯本地保存，请选择“在我的 iPhone 上”。系统备份排除是尽力请求，并非绝对保证。").font(.footnote).foregroundStyle(.secondary)
            Button("开始使用") { dismiss() }.buttonStyle(.borderedProminent).controlSize(.large)
            Button("从自己的备份恢复", action: onImport)
        }.padding(28)
    }
}

extension Notification.Name {
    static let checklistNewTask = Notification.Name("LocalChecklist.newTask")
    static let checklistNewNote = Notification.Name("LocalChecklist.newNote")
    static let checklistSync = Notification.Name("LocalChecklist.sync")
}
