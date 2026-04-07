import SwiftData
import Foundation

@Model
final class AIAnalysis {
    var id: UUID
    var summary: String?
    var relatedTopics: [String]
    var insights: String?
    var analyzedContentHash: Int
    var analyzedAt: Date

    @Relationship
    var note: Note?

    func isStale(for content: String) -> Bool {
        return content.hashValue != analyzedContentHash
    }

    init() {
        self.id = UUID()
        self.relatedTopics = []
        self.analyzedContentHash = 0
        self.analyzedAt = .now
    }
}
