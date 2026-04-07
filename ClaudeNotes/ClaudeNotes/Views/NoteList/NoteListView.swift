import SwiftUI
import SwiftData

struct NoteListView: View {
    @Environment(\.modelContext) private var modelContext
    let folder: NoteFolder?
    /// The ID of the note currently open in the active tab — used to highlight the row.
    let activeNoteID: UUID?
    let onSelect: (Note) -> Void

    @Query(filter: #Predicate<Note> { note in
        note.isDeleted == false
    }, sort: [SortDescriptor(\Note.modifiedAt, order: .reverse)]) private var allNotes: [Note]
    @State private var searchText = ""
    @State private var selectedNote: Note? = nil

    init(folder: NoteFolder?, activeNoteID: UUID?, onSelect: @escaping (Note) -> Void) {
        self.folder = folder
        self.activeNoteID = activeNoteID
        self.onSelect = onSelect
    }

    private var filteredNotes: [Note] {
        var notes = allNotes

        if let folder {
            notes = notes.filter { $0.folder?.id == folder.id }
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            notes = notes.filter {
                $0.title.lowercased().contains(query) ||
                $0.content.lowercased().contains(query)
            }
        }

        return notes.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.modifiedAt > rhs.modifiedAt
        }
    }

    var body: some View {
        List(selection: $selectedNote) {
            ForEach(filteredNotes) { note in
                NoteRow(note: note)
                    .tag(note)
                    .contextMenu {
                        Button(note.isPinned ? "取消置顶" : "置顶") {
                            note.isPinned.toggle()
                        }
                        Divider()
                        Button("删除", role: .destructive) {
                            deleteNote(note)
                        }
                    }
            }
        }
        .searchable(text: $searchText, prompt: "搜索笔记")
        .overlay {
            if filteredNotes.isEmpty {
                ContentUnavailableView {
                    Label(searchText.isEmpty ? "暂无笔记" : "未找到结果",
                          systemImage: searchText.isEmpty ? "note.text" : "magnifyingglass")
                } description: {
                    Text(searchText.isEmpty ? "按 ⌘N 创建新笔记" : "尝试其他搜索词")
                }
            }
        }
        .onChange(of: selectedNote) { _, note in
            if let note { onSelect(note) }
        }
        // Keep the list highlight in sync with the active tab
        .onChange(of: activeNoteID) { _, id in
            selectedNote = id.flatMap { targetID in filteredNotes.first { $0.id == targetID } }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 260)
    }

    private func deleteNote(_ note: Note) {
        if selectedNote?.id == note.id { selectedNote = nil }
        note.isDeleted = true
    }
}
