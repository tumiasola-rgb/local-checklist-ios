import SwiftUI

func nextAnniversaryDay(_ item: Anniversary, today: DayStamp = .today) -> DayStamp {
    guard item.repeatYearly else { return item.day }
    let lowerBound = max(today, item.day)
    let year = Int(lowerBound.rawValue.prefix(4)) ?? 2026
    let suffix = String(item.day.rawValue.suffix(5))
    for candidateYear in year...min(year + 8, 9999) {
        if let candidate = DayStamp(rawValue: String(format: "%04d-%@", candidateYear, suffix)), candidate >= lowerBound { return candidate }
    }
    return item.day
}

struct AnniversariesScreen: View {
    @EnvironmentObject private var model: AppModel
    let onEdit: (Anniversary) -> Void
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if model.snapshot.anniversaries.isEmpty { EmptyCard(symbol: "hourglass", title: "总有值得记住的一天", subtitle: "倒数一个期待，或记住一个起点") }
                ForEach(model.snapshot.anniversaries.sorted { nextAnniversaryDay($0) < nextAnniversaryDay($1) }) { item in
                    let days = dayDifference(from: .today, to: nextAnniversaryDay(item))
                    Button { onEdit(item) } label: {
                        Card {
                            HStack(spacing: 14) {
                                Text(item.emoji).font(.system(size: 28)).frame(width: 48, height: 48).background(Color.orange.opacity(0.17), in: Circle())
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.title).font(.headline).lineLimit(2)
                                    Text(item.day.rawValue + (item.repeatYearly ? " · 每年" : "")).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text("\(abs(days))").font(.system(size: 35, weight: .medium, design: .rounded)).minimumScaleFactor(0.5)
                                    Text(days == 0 ? "就是今天" : (days > 0 ? "剩余天数" : "已过天数")).font(.caption)
                                }.foregroundStyle(days < 0 ? Color.mint : Color.checklistBlue)
                            }
                        }
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 16).padding(.bottom, 95)
        }
    }
}

struct AnniversaryEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var item: Anniversary
    let generation: UUID
    @State private var date = Date()
    @State private var deleting = false
    @State private var didInitialize = false
    @State private var wasNew = true
    @State private var openedGeneration: UUID?
    @State private var originalItem: Anniversary?
    @State private var editorError: String?
    private var existing: Bool { model.snapshot.anniversaries.contains { $0.id == item.id } }
    var body: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $item.title)
                TextField("图标（Emoji）", text: $item.emoji)
                DatePicker("公历日期", selection: $date, displayedComponents: .date)
                Toggle("每年重复", isOn: $item.repeatYearly)
                Section { Text("按日历天计算，不用秒数除以 24 小时。每年重复使用公历月日；2 月 29 日会寻找下一个有效闰年。农历节日请填写核实过的公历日期，并关闭每年重复。").font(.footnote).foregroundStyle(.secondary) }
                if existing { Button("删除纪念日", role: .destructive) { deleting = true } }
            }
            .navigationTitle(existing ? "编辑纪念日" : "新建纪念日").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        item.day = DayStamp(date: date); item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        if item.emoji.isEmpty { item.emoji = "🎉" }
                        if model.save(item, generation: openedGeneration ?? generation, isNew: wasNew, expectedOriginal: originalItem) { dismiss() } else { editorError = model.problem }
                    }.disabled(item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("删除这个纪念日？", isPresented: $deleting, titleVisibility: .visible) { Button("删除", role: .destructive) { if model.deleteAnniversary(item.id, generation: openedGeneration ?? generation, expectedOriginal: originalItem) { dismiss() } else { editorError = model.problem } } }
        }.alert("操作未完成", isPresented: Binding(get: { editorError != nil }, set: { if !$0 { editorError = nil } })) { Button("继续编辑", role: .cancel) {} } message: { Text(editorError ?? "") }
        .onAppear {
            guard !didInitialize else { return }; didInitialize = true; openedGeneration = generation; wasNew = !existing; originalItem = existing ? item : nil
            date = item.day.date() ?? Date()
        }
    }
}
