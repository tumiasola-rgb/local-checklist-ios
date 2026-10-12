import Foundation

extension SharedRepository {
    private static func sameEditableTask(_ lhs: TodoItem, _ rhs: TodoItem) -> Bool {
        lhs.title == rhs.title && lhs.detail == rhs.detail && lhs.listID == rhs.listID && lhs.tags == rhs.tags
            && lhs.startDay == rhs.startDay && lhs.endDay == rhs.endDay && lhs.timeMinutes == rhs.timeMinutes && lhs.schedule == rhs.schedule
    }

    /// Upserts editable task fields. An edit cannot undo a completion performed
    /// by a widget while the editor was open. Use `setTaskCompleted` for status.
    /// Pass `isNew: false` for an existing editor to reject concurrent deletion;
    /// pass `isNew: true` for a new draft to reject an accidental ID collision.
    @discardableResult
    public func saveTask(_ task: TodoItem, isNew: Bool? = nil, expectedGeneration: UUID? = nil, expectedOriginal: TodoItem? = nil) throws -> AppSnapshot {
        try update(expectedGeneration: expectedGeneration) { state in
            if let index = state.tasks.firstIndex(where: { $0.id == task.id }) {
                if isNew == true { throw RepositoryError.invalidData("a task with this ID already exists") }
                let latest = state.tasks[index]
                if let expectedOriginal, !Self.sameEditableTask(latest, expectedOriginal) { throw RepositoryError.staleContent }
                var edited = task
                edited.createdAt = latest.createdAt
                edited.isCompleted = latest.isCompleted
                edited.completedAt = latest.completedAt
                edited.updatedAt = max(Date(), latest.updatedAt)
                state.tasks[index] = edited
            } else {
                if isNew == false { throw RepositoryError.itemNotFound }
                state.tasks.append(task)
            }
        }
    }

    /// Sets an explicit desired state, making a repeated widget intent safe.
    @discardableResult
    public func setTaskCompleted(id: UUID, isCompleted: Bool, expectedGeneration: UUID? = nil) throws -> AppSnapshot {
        try update(expectedGeneration: expectedGeneration) { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { throw RepositoryError.itemNotFound }
            guard state.tasks[index].isCompleted != isCompleted else { return }
            let now = max(Date(), state.tasks[index].updatedAt)
            state.tasks[index].isCompleted = isCompleted
            state.tasks[index].completedAt = isCompleted ? now : nil
            state.tasks[index].updatedAt = now
            // Next occurrence is part of this exact local commit. Its ID and
            // content are deterministic across two offline devices. A previously
            // generated/deleted instance is never resurrected on re-completion.
            if isCompleted, let next = nextOccurrence(after: state.tasks[index]),
               !state.tasks.contains(where: { $0.id == next.id }), state.sync.entries[SyncPayload.task(next).key] == nil {
                state.tasks.append(next)
            }
        }
    }

    @discardableResult
    public func deleteTask(id: UUID, expectedGeneration: UUID? = nil, expectedOriginal: TodoItem? = nil) throws -> AppSnapshot {
        try update(expectedGeneration: expectedGeneration) { state in
            if let expectedOriginal, let latest = state.tasks.first(where: { $0.id == id }), latest != expectedOriginal {
                throw RepositoryError.staleContent
            }
            state.tasks.removeAll { $0.id == id }
        }
    }

    /// Content edits preserve the latest pin state. Pass isNew from the editor
    /// to detect a concurrent deletion instead of recreating the removed note.
    @discardableResult
    public func saveNote(_ note: NoteItem, isNew: Bool? = nil, expectedGeneration: UUID? = nil, expectedOriginal: NoteItem? = nil) throws -> AppSnapshot {
        try update(expectedGeneration: expectedGeneration) { state in
            if let index = state.notes.firstIndex(where: { $0.id == note.id }) {
                if isNew == true { throw RepositoryError.invalidData("a note with this ID already exists") }
                let latest = state.notes[index]
                if let expectedOriginal, latest.title != expectedOriginal.title || latest.body != expectedOriginal.body || latest.tags != expectedOriginal.tags {
                    throw RepositoryError.staleContent
                }
                var edited = note
                edited.createdAt = latest.createdAt
                edited.isPinned = latest.isPinned
                edited.updatedAt = max(Date(), latest.updatedAt)
                state.notes[index] = edited
            } else {
                if isNew == false { throw RepositoryError.itemNotFound }
                state.notes.append(note)
            }
        }
    }

    @discardableResult
    public func setNotePinned(id: UUID, isPinned: Bool, expectedGeneration: UUID? = nil) throws -> AppSnapshot {
        try update(expectedGeneration: expectedGeneration) { state in
            guard let index = state.notes.firstIndex(where: { $0.id == id }) else { throw RepositoryError.itemNotFound }
            guard state.notes[index].isPinned != isPinned else { return }
            state.notes[index].isPinned = isPinned
            state.notes[index].updatedAt = max(Date(), state.notes[index].updatedAt)
        }
    }

    @discardableResult
    public func deleteNote(id: UUID, expectedGeneration: UUID? = nil, expectedOriginal: NoteItem? = nil) throws -> AppSnapshot {
        try update(expectedGeneration: expectedGeneration) { state in
            if let expectedOriginal, let latest = state.notes.first(where: { $0.id == id }), latest != expectedOriginal {
                throw RepositoryError.staleContent
            }
            state.notes.removeAll { $0.id == id }
        }
    }

    @discardableResult
    public func saveAnniversary(_ anniversary: Anniversary, isNew: Bool? = nil, expectedGeneration: UUID? = nil, expectedOriginal: Anniversary? = nil) throws -> AppSnapshot {
        try update(expectedGeneration: expectedGeneration) { state in
            if let index = state.anniversaries.firstIndex(where: { $0.id == anniversary.id }) {
                if isNew == true { throw RepositoryError.invalidData("an anniversary with this ID already exists") }
                if let expectedOriginal, state.anniversaries[index] != expectedOriginal { throw RepositoryError.staleContent }
                state.anniversaries[index] = anniversary
            } else {
                if isNew == false { throw RepositoryError.itemNotFound }
                state.anniversaries.append(anniversary)
            }
        }
    }

    @discardableResult
    public func deleteAnniversary(id: UUID, expectedGeneration: UUID? = nil, expectedOriginal: Anniversary? = nil) throws -> AppSnapshot {
        try update(expectedGeneration: expectedGeneration) { state in
            if let expectedOriginal, let latest = state.anniversaries.first(where: { $0.id == id }), latest != expectedOriginal {
                throw RepositoryError.staleContent
            }
            state.anniversaries.removeAll { $0.id == id }
        }
    }

    @discardableResult
    public func saveList(_ list: Checklist, isNew: Bool? = nil, expectedGeneration: UUID? = nil, expectedOriginal: Checklist? = nil) throws -> AppSnapshot {
        try update(expectedGeneration: expectedGeneration) { state in
            if let index = state.lists.firstIndex(where: { $0.id == list.id }) {
                if isNew == true { throw RepositoryError.invalidData("a list with this ID already exists") }
                if let expectedOriginal, state.lists[index] != expectedOriginal { throw RepositoryError.staleContent }
                state.lists[index] = list
            } else {
                if isNew == false { throw RepositoryError.itemNotFound }
                state.lists.append(list)
            }
        }
    }

    /// Deleting a list retains its tasks and moves them to the unassigned group.
    @discardableResult
    public func deleteList(id: UUID, expectedGeneration: UUID? = nil, expectedOriginal: Checklist? = nil) throws -> AppSnapshot {
        try update(expectedGeneration: expectedGeneration) { state in
            if let expectedOriginal, let latest = state.lists.first(where: { $0.id == id }), latest != expectedOriginal {
                throw RepositoryError.staleContent
            }
            state.lists.removeAll { $0.id == id }
            for index in state.tasks.indices where state.tasks[index].listID == id {
                state.tasks[index].listID = nil
                state.tasks[index].updatedAt = max(Date(), state.tasks[index].updatedAt)
            }
            if state.settings.defaultListID == id { state.settings.defaultListID = nil }
        }
    }

    @discardableResult
    public func saveSettings(_ settings: Settings, expectedGeneration: UUID? = nil) throws -> AppSnapshot {
        try update(expectedGeneration: expectedGeneration) { $0.settings = settings }
    }

    /// Adds local search history without replacing other, newer settings.
    @discardableResult
    public func recordSearch(_ query: String, expectedGeneration: UUID? = nil) throws -> AppSnapshot {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return try read() }
        return try update(expectedGeneration: expectedGeneration) { state in
            state.settings.searchHistory.removeAll { $0.caseInsensitiveCompare(clean) == .orderedSame }
            state.settings.searchHistory.insert(clean, at: 0)
            state.settings.searchHistory = Array(state.settings.searchHistory.prefix(30))
        }
    }
}
