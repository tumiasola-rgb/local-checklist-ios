import SwiftUI
import UniformTypeIdentifiers

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw AppFailure.invalidImport }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private struct ImportReview: Identifiable {
    let id = UUID()
    let preview: ImportPreview
    let isRecovery: Bool
}

struct SettingsScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var exporting = false
    @State private var importing = false
    @State private var document = BackupDocument()
    @State private var review: ImportReview?
    @State private var notice: String?
    @State private var localSyncSettings = false
    var body: some View {
        NavigationStack {
            Form {
                Section("手机与 Mac") {
                    Button("局域网同步与冲突管理", systemImage: "wifi") { localSyncSettings = true }
                    Text("同一局域网、两端App打开，先配对再双向同步；两端始终保留本机副本。").font(.footnote).foregroundStyle(.secondary)
                }
                Section("完整备份与恢复") {
                    Button("一键导出整包备份", systemImage: "square.and.arrow.up") {
                        do { document = BackupDocument(data: try model.exportData()); exporting = true }
                        catch { notice = error.localizedDescription }
                    }.disabled(!model.isReady)
                    Button("从备份恢复", systemImage: "square.and.arrow.down") { importing = true }.disabled(!model.isReady)
                    Button("恢复上次导入前的数据", systemImage: "arrow.uturn.backward") {
                        do {
                            if let preview = try model.recoveryPreview() { review = ImportReview(preview: preview, isRecovery: true) }
                            else { notice = "尚无导入前恢复副本。第一次成功导入前会自动保存一份。" }
                        } catch { notice = error.localizedDescription }
                    }.disabled(!model.isReady)
                    Text("包含全部待办、完成状态、笔记、清单、标签、纪念日与设置。文件未加密，请保存在可信位置。删除 App 前务必导出；“文件”中的 App 自身文件夹也可能随卸载删除。建议保存在独立文件夹、外部介质或另一台设备。").font(.footnote).foregroundStyle(.secondary)
                }
                Section("本机提醒") {
                    Text(model.notificationMessage.isEmpty ? "本机尚未安排提醒" : model.notificationMessage).font(.footnote)
                    Button("允许本机提醒") { Task { await model.authorizeReminderFromUserAction() } }
                    Text("提醒规则可跨设备同步，系统通知权限不能。这里只为当前设备请求许可；系统已拒绝后需到系统设置修改。").font(.footnote).foregroundStyle(.secondary)
                }
                Section("日历") {
                    Picker("一周开始", selection: Binding(get: { model.snapshot.settings.firstWeekday }, set: { value in model.commit { $0.settings.firstWeekday = value } })) {
                        Text("星期日").tag(1); Text("星期一").tag(2); Text("星期二").tag(3); Text("星期三").tag(4); Text("星期四").tag(5); Text("星期五").tag(6); Text("星期六").tag(7)
                    }
                    Toggle("显示农历", isOn: Binding(get: { model.snapshot.settings.showLunar }, set: { value in model.commit { $0.settings.showLunar = value } }))
                }
                Section("整理") {
                    NavigationLink("管理清单") { ListManagerScreen() }
                    Text("标签直接在待办与笔记中输入。可在搜索页按标签或清单名称查找。").font(.footnote).foregroundStyle(.secondary)
                }
                #if !STANDALONE_APP
                Section("桌面小组件") {
                    Text("长按主屏幕空白处 → 编辑 → 添加小组件，搜索“本地清单”，分别添加“大月历”和“今天待办”。").font(.subheadline)
                    Text("点日期查看当天，点 + 打开 App 新建；今日小组件可直接勾选。iOS 管理刷新时机，后台刷新不是实时保证。").font(.footnote).foregroundStyle(.secondary)
                }
                #endif
                Section("本机副本与局域网") {
                    Text("资料保存在自己的设备上。只有你确认配对的两端才通过加密局域网交换。无账号、云同步、广告、统计或开发者服务器；图片和语音识别仍只在设备上处理。").font(.subheadline)
                    #if STANDALONE_APP
                    Text("资料保存在此 App 的本机目录。每次保存都请求排除系统备份，但无法保证永不进入系统设备备份。请定期导出备份；删除 App 会同时删除本机资料。导出选到 iCloud Drive 或第三方分享目标，是你主动选择的去向。").font(.footnote).foregroundStyle(.secondary)
                    #else
                    Text("每台设备各自使用 App Group 存储，手机App与小组件共用同一份。每次保存都请求排除系统备份；Apple 将此视为提示，无法保证永不进入系统或 iCloud 设备备份。导出选到 iCloud Drive 或第三方分享目标，是你主动选择的去向。").font(.footnote).foregroundStyle(.secondary)
                    #endif
                }
                Section("关于") {
                    LabeledContent("版本", value: "1.1 · 数据格式 v\(SharedRepository.currentVersion)")
                    Text("最低 iOS 17。使用公开系统 API；未来系统仍需进行兼容验证。此版本不包含外部清单迁移、日历订阅或法定休班表。提醒使用本机通知，需要本设备单独授权。Mac版使用原生Mac Catalyst；局域网配对与跨端实测仍需在自己的两台设备完成。").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "本地清单备份-\(DayStamp.today.rawValue)") { result in
                switch result {
                case .success: notice = "完整备份已导出。请确认“文件”中能找到它，再删除或重装 App。"
                case .failure(let error): if (error as NSError).code != NSUserCancelledError { notice = error.localizedDescription }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 20 * 1024 * 1024 else { throw AppFailure.invalidImport }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    review = ImportReview(preview: try model.previewImport(data), isRecovery: false)
                } catch { if (error as NSError).code != NSUserCancelledError { notice = error.localizedDescription } }
            }
            .sheet(isPresented: $localSyncSettings) { LocalSyncHost() }
            .sheet(item: $review) { value in ImportReviewScreen(preview: value.preview, isRecovery: value.isRecovery) { review = nil; notice = "恢复完成。若已开启局域网同步，请到同步页核对并恢复合并；不会自动把备份缺项传播为删除。" } }
            .alert("备份与恢复", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("好", role: .cancel) {} } message: { Text(notice ?? "") }
        }
    }
}

private struct ImportReviewScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let preview: ImportPreview
    let isRecovery: Bool
    let onDone: () -> Void
    @State private var importing = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("已验证的备份") {
                    LabeledContent("导出时间", value: preview.exportedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("待办", value: "\(preview.counts.tasks)")
                    LabeledContent("笔记", value: "\(preview.counts.notes)")
                    LabeledContent("纪念日", value: "\(preview.counts.anniversaries)")
                    LabeledContent("清单", value: "\(preview.counts.lists)")
                }
                Section("这一步会覆盖本机资料") {
                    Text("目前本机有 \(model.snapshot.tasks.count) 条待办、\(model.snapshot.notes.count) 篇笔记。确认后用此备份整体替换，不做合并。")
                    Text("替换前自动保存一份本机恢复副本。验证或写入失败时不会清空现有数据。恢复副本也在 App 内，删除 App 后不能依赖它。").font(.footnote).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                    Button(isRecovery ? "确认恢复上次导入前数据" : "确认覆盖并恢复", role: .destructive) {
                        guard !importing else { return }; importing = true
                        do { try model.restore(preview); onDone() } catch { self.error = error.localizedDescription; importing = false }
                    }.disabled(importing)
                }
            }.navigationTitle("恢复预览").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(importing) } }
        }.interactiveDismissDisabled(importing)
    }
}

private struct ListManagerScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: Checklist?
    var body: some View {
        List {
            Text("收集箱始终保留。删除清单会把其中待办移回收集箱，待办不会删除。").font(.footnote).foregroundStyle(.secondary)
            ForEach(model.snapshot.lists) { list in
                Button { editing = list } label: { HStack { Circle().fill(Color(hex: list.colorHex)).frame(width: 11, height: 11); Text(list.title).foregroundStyle(.primary) } }
            }
            Button("新增清单", systemImage: "plus") { editing = Checklist(title: "", colorHex: "#536DFE") }
        }.navigationTitle("清单").sheet(item: $editing) { ListEditor(list: $0) }
    }
}

private struct ListEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var list: Checklist
    @State private var deleting = false
    @State private var wasNew = true
    @State private var openedGeneration: UUID?
    @State private var originalList: Checklist?
    @State private var editorError: String?
    let colors = ["#536DFE", "#9575CD", "#4DB6AC", "#F4A261", "#EF6C83"]
    var body: some View {
        NavigationStack {
            Form {
                TextField("清单名称", text: $list.title)
                Picker("颜色", selection: $list.colorHex) { ForEach(colors, id: \.self) { value in Text(value).foregroundStyle(Color(hex: value)).tag(value) } }
                if model.snapshot.lists.contains(where: { $0.id == list.id }) { Button("删除清单", role: .destructive) { deleting = true } }
            }.navigationTitle("编辑清单").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            list.title = list.title.trimmingCharacters(in: .whitespacesAndNewlines)
                            if model.save(list, generation: openedGeneration ?? model.snapshot.generation, isNew: wasNew, expectedOriginal: originalList) { dismiss() } else { editorError = model.problem }
                        }.disabled(list.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .confirmationDialog("删除清单并将待办移回收集箱？", isPresented: $deleting, titleVisibility: .visible) {
                    Button("删除清单", role: .destructive) {
                        if model.deleteList(list.id, generation: openedGeneration ?? model.snapshot.generation, expectedOriginal: originalList) { dismiss() } else { editorError = model.problem }
                    }
                }
        }.alert("操作未完成", isPresented: Binding(get: { editorError != nil }, set: { if !$0 { editorError = nil } })) { Button("继续编辑", role: .cancel) {} } message: { Text(editorError ?? "") }
        .onAppear {
            if openedGeneration == nil { openedGeneration = model.snapshot.generation; wasNew = !model.snapshot.lists.contains { $0.id == list.id }; originalList = wasNew ? nil : list }
        }
    }
}
