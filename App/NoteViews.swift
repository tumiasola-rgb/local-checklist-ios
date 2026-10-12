import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct NotebookScreen: View {
    @EnvironmentObject private var model: AppModel
    let onNote: (NoteItem) -> Void
    private var notes: [NoteItem] { model.snapshot.notes.sorted { $0.isPinned == $1.isPinned ? $0.updatedAt > $1.updatedAt : $0.isPinned } }
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if notes.isEmpty { EmptyCard(symbol: "note.text", title: "把灵感留在这里", subtitle: "随手写，自动保存\n长文字也可以分页生成图片分享") }
                ForEach(notes) { note in
                    Button { onNote(note) } label: {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(note.title).font(.headline).lineLimit(2)
                                    Spacer()
                                    if note.isPinned { Image(systemName: "pin.fill").foregroundStyle(Color.checklistBlue).font(.caption) }
                                }
                                Text(note.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                                HStack {
                                    Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    Spacer()
                                    Text(note.tags.map { "#" + $0 }.joined(separator: " ")).lineLimit(1)
                                }.font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 16).padding(.bottom, 95)
        }
    }
}

struct NoteEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var note: NoteItem
    let generation: UUID
    @State private var tags = ""
    @State private var didInitialize = false
    @State private var savedOnce = false
    @State private var openedGeneration: UUID?
    @State private var originalNote: NoteItem?
    @State private var status = "编辑后自动保存"
    @State private var pendingSave: Task<Void, Never>?
    @State private var deleting = false
    @State private var deleted = false
    @State private var discarding = false
    @State private var abandoned = false
    @State private var share: SharePayload?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Text(status).font(.caption).foregroundStyle(status == "保存失败，请重试" ? Color.red : Color.secondary)
                    Spacer()
                    Button {
                        guard save() else { return }
                        model.pinNote(note.id)
                        note.isPinned = model.snapshot.notes.first(where: { $0.id == note.id })?.isPinned ?? note.isPinned
                    } label: { Image(systemName: note.isPinned ? "pin.fill" : "pin") }.accessibilityLabel(note.isPinned ? "取消置顶" : "置顶笔记")
                }.padding(.horizontal, 20).padding(.vertical, 10)
                TextField("标题", text: $note.title, axis: .vertical).font(.title2.bold()).padding(.horizontal, 20)
                TextField("标签，用逗号分隔", text: $tags).font(.caption).padding(.horizontal, 20).padding(.vertical, 12)
                Divider()
                TextEditor(text: $note.body).font(.body).padding(.horizontal, 14).scrollContentBackground(.hidden)
            }.background(Color.checklistCard)
            .navigationTitle("笔记").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("生成图片分享", systemImage: "square.and.arrow.up") {
                            guard save() else { return }
                            do { share = try ShareImageMaker.note(preparedNote()) } catch { self.error = error.localizedDescription }
                        }
                        Button("复制当前草稿", systemImage: "doc.on.doc") { UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: note.title + "\n\n" + note.body]], options: [.localOnly: true]) }
                        Button("放弃未保存修改并关闭", role: .destructive) { discarding = true }
                        Button("删除笔记", role: .destructive) { deleting = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { if save() { dismiss() } } }
            }
            .confirmationDialog("删除这篇笔记？", isPresented: $deleting, titleVisibility: .visible) {
                Button("删除", role: .destructive) { pendingSave?.cancel(); if model.deleteNote(note.id, generation: openedGeneration ?? generation, expectedOriginal: originalNote) { deleted = true; dismiss() } else { status = "保存失败，请重试"; error = model.problem } }
            }
            .confirmationDialog("放弃尚未保存的修改并关闭？", isPresented: $discarding, titleVisibility: .visible) {
                Button("放弃未保存修改并关闭", role: .destructive) { pendingSave?.cancel(); abandoned = true; dismiss() }
            } message: { Text("此前已经成功自动保存的内容会保留。未保存的草稿会丢失，建议先复制当前草稿。") }
            .sheet(item: $share) { ShareSheet(payload: $0) }
            .alert("无法完成操作", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") }
        }
        .onAppear {
            guard !didInitialize else { return }; didInitialize = true
            openedGeneration = generation; savedOnce = model.snapshot.notes.contains { $0.id == note.id }; originalNote = savedOnce ? note : nil
            tags = note.tags.joined(separator: ", ")
        }
        .onChange(of: note.title) { _, _ in scheduleSave() }
        .onChange(of: note.body) { _, _ in scheduleSave() }
        .onChange(of: tags) { _, _ in scheduleSave() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in pendingSave?.cancel(); if !deleted && !abandoned { _ = save() } }
        .onDisappear { pendingSave?.cancel(); if !deleted && !abandoned { _ = save() } }
        .interactiveDismissDisabled(true)
    }
    private func preparedNote() -> NoteItem {
        var value = note
        value.tags = splitTags(tags)
        if value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = value.body.trimmingCharacters(in: .whitespacesAndNewlines)
            value.title = trimmed.isEmpty ? "新笔记" : String((trimmed.split(separator: "\n").first.map(String.init) ?? "新笔记").prefix(60))
        }
        return value
    }
    private func scheduleSave() {
        pendingSave?.cancel(); status = "正在保存…"
        pendingSave = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            _ = save()
        }
    }
    @discardableResult private func save() -> Bool {
        guard !deleted && !abandoned else { return true }
        guard !note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = "空白笔记不会保存"; return true }
        let result = model.save(preparedNote(), generation: openedGeneration ?? generation, isNew: !savedOnce, expectedOriginal: originalNote)
        if result { savedOnce = true; originalNote = model.snapshot.notes.first { $0.id == note.id } }
        status = result ? "已保存在本机" : "保存失败，请重试"
        if !result { error = model.problem }
        return result
    }
}
