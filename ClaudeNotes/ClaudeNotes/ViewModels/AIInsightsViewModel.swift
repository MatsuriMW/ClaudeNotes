import SwiftUI
import SwiftData

@Observable
final class AIInsightsViewModel {
    var isLoading = false
    var errorMessage: String?

    // Analysis results (live, not necessarily persisted yet)
    var summary: String?
    var topics: [String] = []
    var insights: String?

    private let aiService = AIService.shared

    @MainActor
    func loadAnalysis(for note: Note) async {
        // Check cached analysis
        if let cached = note.aiAnalysis,
           cached.analyzedContentHash == note.content.hashValue {
            summary = cached.summary
            topics = cached.relatedTopics
            insights = cached.insights
            return
        }

        guard !note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            summary = nil
            topics = []
            insights = nil
            errorMessage = "笔记内容为空，无法分析"
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let result = try await aiService.analyzeNote(note.content)

            summary = result.summary
            topics = result.topics
            insights = result.insights

            // Cache the result
            let analysis = note.aiAnalysis ?? AIAnalysis()
            analysis.summary = result.summary
            analysis.relatedTopics = result.topics
            analysis.insights = result.insights
            analysis.analyzedContentHash = note.content.hashValue
            analysis.analyzedAt = .now
            note.aiAnalysis = analysis
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func clear() {
        summary = nil
        topics = []
        insights = nil
        errorMessage = nil
        isLoading = false
    }
}
