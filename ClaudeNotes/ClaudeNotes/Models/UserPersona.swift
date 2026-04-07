import Foundation
import Observation

// MARK: - Data Model

struct UserPersona: Codable {

    // MARK: - Nested Types

    struct MBTIDimensions: Codable {
        /// 0 = pure E, 100 = pure I
        var iVsE: Int
        /// 0 = pure S, 100 = pure N
        var nVsS: Int
        /// 0 = pure F, 100 = pure T
        var tVsF: Int
        /// 0 = pure P, 100 = pure J
        var jVsP: Int
    }

    struct MBTI: Codable {
        var type: String          // e.g. "INTP"
        var confidence: String    // "高" / "中" / "低"
        var reasoning: String
        var dimensions: MBTIDimensions?
    }

    struct PersonalityTrait: Codable, Identifiable {
        var id: String { name }
        var name: String
        var description: String
        var evidence: String
    }

    struct InterestArea: Codable, Identifiable {
        var id: String { name }
        var name: String
        var intensity: Int        // 1–5
        var summary: String
    }

    // MARK: - Fields

    var mbti: MBTI
    var personalityTraits: [PersonalityTrait]
    var interests: [InterestArea]
    var writingStyle: String
    var recentFocus: String
    var summary: String
    var suggestions: [String]

    // MARK: - Metadata

    var generatedAt: Date
    var lastPatchedAt: Date?
    var noteCount: Int
    var totalWords: Int
    var providerID: String
    var analyzedNoteIDs: [UUID]

    // MARK: - Memberwise init

    init(mbti: MBTI,
         personalityTraits: [PersonalityTrait],
         interests: [InterestArea],
         writingStyle: String,
         recentFocus: String,
         summary: String,
         suggestions: [String],
         generatedAt: Date,
         lastPatchedAt: Date? = nil,
         noteCount: Int,
         totalWords: Int,
         providerID: String,
         analyzedNoteIDs: [UUID] = []) {
        self.mbti               = mbti
        self.personalityTraits  = personalityTraits
        self.interests          = interests
        self.writingStyle       = writingStyle
        self.recentFocus        = recentFocus
        self.summary            = summary
        self.suggestions        = suggestions
        self.generatedAt        = generatedAt
        self.lastPatchedAt      = lastPatchedAt
        self.noteCount          = noteCount
        self.totalWords         = totalWords
        self.providerID         = providerID
        self.analyzedNoteIDs    = analyzedNoteIDs
    }

    // MARK: - Backward-compatible Decodable

    enum CodingKeys: String, CodingKey {
        case mbti, personalityTraits, interests, writingStyle
        case recentFocus, summary, suggestions
        case generatedAt, lastPatchedAt, noteCount, totalWords, providerID
        case analyzedNoteIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mbti              = try c.decode(MBTI.self,                  forKey: .mbti)
        personalityTraits = try c.decode([PersonalityTrait].self,    forKey: .personalityTraits)
        interests         = try c.decode([InterestArea].self,        forKey: .interests)
        writingStyle      = try c.decode(String.self,                forKey: .writingStyle)
        recentFocus       = try c.decode(String.self,                forKey: .recentFocus)
        summary           = try c.decode(String.self,                forKey: .summary)
        suggestions       = try c.decode([String].self,              forKey: .suggestions)
        generatedAt       = try c.decode(Date.self,                  forKey: .generatedAt)
        lastPatchedAt     = try? c.decode(Date.self,                 forKey: .lastPatchedAt)
        noteCount         = try c.decode(Int.self,                   forKey: .noteCount)
        totalWords        = try c.decode(Int.self,                   forKey: .totalWords)
        providerID        = try c.decode(String.self,                forKey: .providerID)
        analyzedNoteIDs   = (try? c.decode([UUID].self,              forKey: .analyzedNoteIDs)) ?? []
    }

    // MARK: - Staleness

    static let updateIntervalDays = 7
    static let newNoteThreshold   = 5

    var isStale: Bool {
        let days = Calendar.current.dateComponents([.day], from: generatedAt, to: .now).day ?? 0
        return days >= Self.updateIntervalDays
    }

    func newNoteCount(from activeNotes: [Note]) -> Int {
        let seen = Set(analyzedNoteIDs)
        let cutoff = lastPatchedAt ?? generatedAt
        return activeNotes.filter { !seen.contains($0.id) || $0.modifiedAt > cutoff }.count
    }

    func needsUpdateFor(currentNoteCount: Int) -> Bool {
        isStale || (currentNoteCount - noteCount) >= Self.newNoteThreshold
    }

    var ageDescription: String {
        let days = Calendar.current.dateComponents([.day], from: generatedAt, to: .now).day ?? 0
        if days == 0 { return "今天" }
        if days == 1 { return "昨天" }
        return "\(days) 天前"
    }
}

// MARK: - Store

@Observable
final class PersonaStore {
    static let shared = PersonaStore()

    // ── Persisted state ──────────────────────────────────────────────────────
    private(set) var persona: UserPersona?

    // ── Background analysis state (observed by SidebarView & PersonaView) ───
    var isAnalyzing: Bool     = false
    var analysisProgress: String = ""
    var analysisCompleted: Bool  = false
    var analysisError: String?   = nil

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ClaudeNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("user_persona.json")
        load()
    }

    // MARK: - Persistence

    func save(_ p: UserPersona) {
        persona = p
        if let data = try? JSONEncoder().encode(p) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func clear() {
        persona = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        persona = try? JSONDecoder().decode(UserPersona.self, from: data)
    }

    // MARK: - Background analysis

    /// Full analysis of all notes. Returns immediately; updates `isAnalyzing` / `analysisCompleted`.
    func startAnalysis(notes: [Note]) {
        guard !isAnalyzing, !notes.isEmpty else { return }
        isAnalyzing = true
        analysisCompleted = false
        analysisError = nil
        let extraDocs = loadLibraryDocuments()
        let suffix = extraDocs.isEmpty ? "" : " + \(extraDocs.count) 个外部文档"
        analysisProgress = "正在准备分析全部 \(notes.count) 篇笔记\(suffix)…"

        // 强制使用本地 Claude CLI
        let progressPrefix = "正在调用本地 Claude CLI"

        Task {
            do {
                let result = try await AIService.shared.analyzePersona(
                    notes: notes,
                    extraDocuments: extraDocs,
                    providerMode: .localCLI,
                    providerID: nil
                ) { msg in
                    Task { @MainActor in self.analysisProgress = "\(progressPrefix)，\(msg)" }
                }
                await MainActor.run {
                    self.save(result)
                    self.isAnalyzing = false
                    self.analysisProgress = ""
                    self.analysisCompleted = true
                }
            } catch {
                await MainActor.run {
                    self.analysisError = error.localizedDescription
                    self.isAnalyzing = false
                    self.analysisProgress = ""
                }
            }
        }
    }

    /// Incremental patch using only new/changed notes. Returns immediately.
    func startPatch(existing: UserPersona, newNotes: [Note], allActiveNotes: [Note]) {
        guard !isAnalyzing, !newNotes.isEmpty else { return }
        isAnalyzing = true
        analysisCompleted = false
        analysisError = nil
        analysisProgress = "正在准备增量更新（\(newNotes.count) 篇新内容）…"
        let extraDocs = loadLibraryDocuments()

        // 强制使用本地 Claude CLI
        let progressPrefix = "正在调用本地 Claude CLI"

        Task {
            do {
                let result = try await AIService.shared.patchPersona(
                    existing: existing,
                    newNotes: newNotes,
                    allActiveNotes: allActiveNotes,
                    extraDocuments: extraDocs,
                    providerMode: .localCLI,
                    providerID: nil
                ) { msg in
                    Task { @MainActor in self.analysisProgress = "\(progressPrefix)，\(msg)" }
                }
                await MainActor.run {
                    self.save(result)
                    self.isAnalyzing = false
                    self.analysisProgress = ""
                    self.analysisCompleted = true
                }
            } catch {
                await MainActor.run {
                    self.analysisError = error.localizedDescription
                    self.isAnalyzing = false
                    self.analysisProgress = ""
                }
            }
        }
    }

    // MARK: - LLM context

    /// A concise text summary of the persona for use as system-prompt background context.
    var systemPromptContext: String? {
        guard let p = persona else { return nil }
        var lines: [String] = []
        lines.append("## User Profile (from personal persona analysis)")
        lines.append("MBTI: \(p.mbti.type) (confidence: \(p.mbti.confidence)) — \(p.mbti.reasoning)")
        lines.append("Summary: \(p.summary)")
        if !p.recentFocus.isEmpty {
            lines.append("Recent focus: \(p.recentFocus)")
        }
        if !p.interests.isEmpty {
            let top = p.interests.sorted { $0.intensity > $1.intensity }.prefix(6)
            lines.append("Top interests: \(top.map { "\($0.name)(\($0.intensity)/5)" }.joined(separator: ", "))")
        }
        if !p.personalityTraits.isEmpty {
            lines.append("Personality traits: \(p.personalityTraits.map(\.name).joined(separator: ", "))")
        }
        if !p.writingStyle.isEmpty {
            lines.append("Writing style: \(p.writingStyle)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Private helpers

    private func loadLibraryDocuments() -> [(title: String, content: String)] {
        let lib = LibraryManager.shared
        var seen = Set<URL>()
        var docs: [(title: String, content: String)] = []
        for file in lib.libraries.flatMap(\.files) + lib.openedFiles {
            guard seen.insert(file.url).inserted else { continue }
            guard let text = try? String(contentsOf: file.url, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            docs.append((file.displayTitle, text))
        }
        return docs
    }
}
