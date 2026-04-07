import SwiftData
import Foundation

@Model
final class NoteFolder {
    var id: UUID
    var name: String
    var createdAt: Date
    var notes: [Note]

    var activeNotes: [Note] {
        notes.filter { !$0.isDeleted }
    }

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = .now
        self.notes = []
    }
}
