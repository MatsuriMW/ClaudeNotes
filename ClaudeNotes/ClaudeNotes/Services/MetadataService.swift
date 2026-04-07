import Foundation

// MARK: - Metadata Model

struct NoteMetadata {
    var tags: [String]        // Subject/discipline tags (AI-generated or manual)
    var author: String        // Author name (manual)
    var source: String        // Source URL or reference (manual)
}

// MARK: - Format

enum MetadataFormat: String, CaseIterable, Codable {
    case obsidian = "Obsidian"
    case logseq   = "Logseq"

    var displayName: String { rawValue }

    /// Generate the metadata block string for a given metadata struct.
    func block(metadata: NoteMetadata) -> String {
        let dateStr = isoDate()
        switch self {
        case .obsidian:
            var lines = ["---"]
            if !metadata.tags.isEmpty {
                lines.append("tags:")
                for tag in metadata.tags { lines.append("  - \(tag)") }
            }
            if !metadata.author.isEmpty  { lines.append("author: \"\(metadata.author)\"") }
            if !metadata.source.isEmpty  { lines.append("source: \"\(metadata.source)\"") }
            lines.append("date: \(dateStr)")
            lines.append("---")
            return lines.joined(separator: "\n") + "\n"

        case .logseq:
            var lines: [String] = []
            if !metadata.tags.isEmpty {
                lines.append("tags:: \(metadata.tags.joined(separator: ", "))")
            }
            if !metadata.author.isEmpty  { lines.append("author:: \(metadata.author)") }
            if !metadata.source.isEmpty  { lines.append("source:: \(metadata.source)") }
            lines.append("date:: \(dateStr)")
            return lines.joined(separator: "\n") + "\n"
        }
    }

    /// Insert (or replace existing) metadata at the top of `content`.
    func insertInto(_ content: String, metadata: NoteMetadata) -> String {
        let meta = block(metadata: metadata)
        let stripped = stripExistingMetadata(from: content)
        let separator = stripped.hasPrefix("\n") ? "" : "\n"
        return meta + separator + stripped
    }

    // MARK: - Strip existing metadata

    /// Remove any leading Obsidian YAML frontmatter or Logseq property lines.
    func stripExistingMetadata(from content: String) -> String {
        // Obsidian YAML frontmatter
        if content.hasPrefix("---\n") {
            let afterOpen = content.dropFirst(4)
            if let closeRange = afterOpen.range(of: "\n---\n") {
                return String(afterOpen[closeRange.upperBound...])
            } else if afterOpen.hasSuffix("\n---") || afterOpen == "---" {
                return ""
            }
        }
        // Logseq page-property lines (key:: value) at the top
        let lines = content.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty { i += 1; continue }
            let parts = t.components(separatedBy: "::")
            if parts.count >= 2, !parts[0].isEmpty, !parts[0].contains(" ") {
                i += 1; continue
            }
            break
        }
        if i > 0 {
            return lines.dropFirst(i).joined(separator: "\n")
        }
        return content
    }

    private func isoDate() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }
}

// MARK: - Service

actor MetadataService {
    static let shared = MetadataService()
    private init() {}

    /// Uses Claude CLI to suggest subject/discipline tags from note content.
    func generateTags(from content: String) async throws -> [String] {
        let systemPrompt = """
        You are an academic note-tagging assistant. Analyse the provided note and suggest 5–10 concise tags \
        covering its subject area, disciplines, key concepts, and any identifiable author names or sources \
        mentioned in the text.
        Rules:
        - Output ONLY a valid JSON array of strings — no explanation, no markdown fences.
        - Tags are lowercase; use hyphens for multi-word terms (e.g. "machine-learning", "cognitive-science").
        - Include discipline tags (e.g. "neuroscience"), topic tags (e.g. "synaptic-plasticity"), \
          and proper-noun tags where relevant (e.g. "donald-knuth").
        Example: ["computer-science", "algorithms", "dynamic-programming", "donald-knuth"]
        """

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn_meta_\(UUID().uuidString).txt")
        let truncated = String(content.unicodeScalars.prefix(8000))
        try truncated.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let escapedPath = tmp.path.replacingOccurrences(of: "'", with: "'\\''")
        let escapedSys  = systemPrompt.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "cat '\(escapedPath)' | claude -p --dangerously-skip-permissions --system-prompt '\(escapedSys)'"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", cmd]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError  = errPipe

        try process.run()
        process.waitUntilExit()

        let data   = outPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? "未知错误"
            throw MetadataError.claudeFailed(errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return parseJSON(output)
    }

    private func parseJSON(_ output: String) -> [String] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "["),
              let end   = trimmed.lastIndex(of: "]") else { return [] }
        let jsonStr = String(trimmed[start...end])
        guard let data = jsonStr.data(using: .utf8),
              let tags = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - Error

enum MetadataError: Error, LocalizedError {
    case claudeFailed(String)
    var errorDescription: String? {
        switch self {
        case .claudeFailed(let msg): return "Claude 调用失败：\(msg)"
        }
    }
}
