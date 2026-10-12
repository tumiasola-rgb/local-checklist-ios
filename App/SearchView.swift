import SwiftUI

struct SearchScreen: View {
    @EnvironmentObject private var model: AppModel
    let onTask: (TodoItem) -> Void
    let onNote: (NoteItem) -> Void
    let onAnniversary: (Anniversary) -> Void
    @State private var query = ""
    @State private var kind = "全部"
    @State private var includeCompleted = true
    private let kinds = ["全部", "待办", "笔记", "纪念日"]
    private var cleanQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func match(_ value: String) -> Bool { value.localizedStandardContains(cleanQuery.hasPrefix("#") ? String(cleanQuery.dropFirst()) : cleanQuery) }
    private var tasks: [TodoItem] {
        model.snapshot.tasks.filter { task in
            (includeCompleted || !task.isCompleted) && match([task.title, task.detail, task.tags.joined(separator: " "), model.listName(task.listID)].joined(separator: "\n"))
        }.sorted(by: taskOrder)
    }
    private var notes: [NoteItem] { model.snapshot.notes.filter { match([$0.title, $0.body, $0.tags.joined(separator: " ")].joined(separator: "\n")) }.sorted { $0.updatedAt > $1.updatedAt } }
    private var anniversaries: [Anniversary] { model.snapshot.anniversaries.filter { match($0.title) } }
    private var total: Int { (kind == "全部" || kind == "待办" ? tasks.count : 0) + (kind == "全部" || kind == "笔记" ? notes.count : 0) + (kind == "全部" || kind == "纪念日" ? anniversaries.count : 0) }
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                TextField("搜索待办、正文、标签或清单", text: $query).submitLabel(.search).onSubmit { model.rememberSearch(cleanQuery) }
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("清空搜索") }
            }.padding(15).background(.regularMaterial, in: Capsule()).padding(.horizontal, 16)
            Picker("搜索范围", selection: $kind) { ForEach(kinds, id: \.self) { Text($0) } }.pickerStyle(.segmented).padding(.horizontal, 16)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if cleanQuery.isEmpty {
                        if !model.snapshot.settings.searchHistory.isEmpty {
                            HStack { Text("搜索历史").font(.headline); Spacer(); Button("清空") { model.commit { $0.settings.searchHistory.removeAll() } }.font(.caption) }
                            Card { VStack(alignment: .leading, spacing: 18) { ForEach(model.snapshot.settings.searchHistory, id: \.self) { item in Button(item) { query = item }.foregroundStyle(.primary) } } }
                        }
                        let tags = Array(Set(model.snapshot.tasks.flatMap(\.tags) + model.snapshot.notes.flatMap(\.tags))).sorted()
                        if !tags.isEmpty {
                            Text("标签").font(.headline)
                            FlowChips(values: tags.map { "#" + $0 }) { query = $0 }
                        }
                        if !model.snapshot.lists.isEmpty {
                            Text("清单").font(.headline)
                            FlowChips(values: model.snapshot.lists.map(\.title)) { query = $0; kind = "待办" }
                        }
                        if model.snapshot.tasks.isEmpty && model.snapshot.notes.isEmpty { EmptyCard(symbol: "magnifyingglass", title: "一处找到所有记录", subtitle: "支持标题、正文、清单、标签和纪念日\n内容只在本机搜索") }
                    } else {
                        HStack {
                            Text("\(total) 条结果").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Toggle("含已完成", isOn: $includeCompleted).font(.caption).toggleStyle(.button)
                        }
                        if total == 0 { EmptyCard(symbol: "doc.text.magnifyingglass", title: "没有找到", subtitle: "换个词，或缩短关键词再试试") }
                        if (kind == "全部" || kind == "待办") && !tasks.isEmpty {
                            Text("待办").font(.headline)
                            Card { VStack(spacing: 16) { ForEach(tasks) { task in TaskRow(task: task) { model.rememberSearch(cleanQuery); onTask(task) } } } }
                        }
                        if (kind == "全部" || kind == "笔记") && !notes.isEmpty {
                            Text("笔记").font(.headline)
                            ForEach(notes) { note in
                                Button { model.rememberSearch(cleanQuery); onNote(note) } label: {
                                    Card { VStack(alignment: .leading, spacing: 8) { Label(note.title, systemImage: "note.text").font(.headline); Text(note.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) } }
                                }.buttonStyle(.plain)
                            }
                        }
                        if (kind == "全部" || kind == "纪念日") && !anniversaries.isEmpty {
                            Text("纪念日").font(.headline)
                            ForEach(anniversaries) { item in Button { model.rememberSearch(cleanQuery); onAnniversary(item) } label: { Card { HStack { Text(item.emoji); Text(item.title); Spacer(); Text(item.day.rawValue).font(.caption).foregroundStyle(.secondary) } } }.buttonStyle(.plain) }
                        }
                    }
                }.padding(.horizontal, 18).padding(.bottom, 30)
            }.scrollDismissesKeyboard(.interactively)
        }
    }
}

private struct FlowChips: View {
    let values: [String]
    let action: (String) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], alignment: .leading, spacing: 9) {
            ForEach(values, id: \.self) { value in Button(value) { action(value) }.font(.caption).lineLimit(2).padding(.vertical, 10).frame(maxWidth: .infinity).background(Color.checklistCard, in: Capsule()) }
        }
    }
}
