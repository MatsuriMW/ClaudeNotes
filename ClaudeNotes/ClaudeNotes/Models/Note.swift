import SwiftData
import Foundation

@Model
final class Note {
    var id: UUID
    var title: String
    var content: String
    var createdAt: Date
    var modifiedAt: Date
    var isPinned: Bool
    var isDeleted: Bool
    var filePath: String?

    @Relationship(deleteRule: .nullify, inverse: \NoteFolder.notes)
    var folder: NoteFolder?

    @Relationship(deleteRule: .cascade)
    var aiAnalysis: AIAnalysis?

    var wordCount: Int {
        content.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    var contentPreview: String {
        let plain = content
            .replacingOccurrences(of: #"[#*_~`>\[\]()!-]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
        return String(plain.prefix(120))
    }

    init(title: String = "", content: String = "", folder: NoteFolder? = nil) {
        self.id = UUID()
        self.title = title
        self.content = content
        self.createdAt = .now
        self.modifiedAt = .now
        self.isPinned = false
        self.isDeleted = false
        self.filePath = nil
        self.folder = folder
    }
}
