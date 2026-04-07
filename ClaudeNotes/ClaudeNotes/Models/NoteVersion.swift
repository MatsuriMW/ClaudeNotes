import SwiftData
import Foundation

@Model
final class NoteVersion {
    var id: UUID
    var noteID: UUID
    var title: String
    var content: String
    var savedAt: Date

    init(noteID: UUID, title: String, content: String) {
        self.id = UUID()
        self.noteID = noteID
        self.title = title
        self.content = content
        self.savedAt = .now
    }
}
