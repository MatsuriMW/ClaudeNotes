import Foundation

struct NoteAnalysisResult: Codable {
    let summary: String
    let topics: [String]
    let insights: String
}

struct NoteExpansionResult: Codable {
    let suggestions: [String]
    let questions: [String]
}

struct NoteSummaryResult: Codable {
    let summary: String
    let keyPoints: [String]
}

enum AIError: Error, LocalizedError {
    case noAPIKey
    case requestFailed(String)
    case invalidResponse
    case decodingFailed(String)
    case providerNotSupported

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "请先在设置中配置该服务的 API Key"
        case .requestFailed(let message):
            return "请求失败: \(message)"
        case .invalidResponse:
            return "AI 返回了无效的响应"
        case .decodingFailed(let message):
            return "解析响应失败: \(message)"
        case .providerNotSupported:
            return "该服务不支持 API 模式，请使用 Web 模式"
        }
    }
}

/// A single message in a conversation
struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    let content: String
    let timestamp: Date = .now

    enum Role {
        case user
        case assistant
    }
}

actor AIService {
    static let shared = AIService()
    private init() {}

    // MARK: - Chat (Freeform, multi-provider)

    func chat(noteContent: String, userPrompt: String?, provider: LLMProvider, history: [ChatMessage] = []) async throws -> String {
        guard provider.supportsAPI else {
            throw AIError.providerNotSupported
        }

        guard let apiKey = KeychainService.shared.loadAPIKey(for: provider.id), !apiKey.isEmpty else {
            throw AIError.noAPIKey
        }

        var systemPrompt = """
        You are an AI assistant integrated into a note-taking app called ClaudeNotes. \
        The user is working on a note and wants your help. \
        Always respond in the same language as the note content. \
        Be helpful, concise, and insightful. \
        If the note contains questions, answer them directly. \
        If it's an article or notes, provide analysis, supplements, or improvements.
        """
        if let personaContext = await MainActor.run(body: { PersonaStore.shared.systemPromptContext }) {
            systemPrompt += "\n\n" + personaContext
        }

        var userMessage = "Here is the note the user is currently working on:\n\n---\n\(noteContent)\n---"
        if let prompt = userPrompt, !prompt.isEmpty {
            userMessage += "\n\nUser's request: \(prompt)"
        } else {
            userMessage += "\n\nPlease analyze this note, provide insights, answer any questions in it, and suggest improvements or supplementary content."
        }

        switch provider.id {
        case "claude":
            return try await sendClaudeRequest(apiKey: apiKey, system: systemPrompt, messages: buildClaudeMessages(userMessage: userMessage, history: history))
        case "chatgpt":
            return try await sendOpenAIRequest(apiKey: apiKey, system: systemPrompt, messages: buildOpenAIMessages(userMessage: userMessage, history: history), baseURL: provider.apiBaseURL!)
        case "gemini":
            return try await sendGeminiRequest(apiKey: apiKey, system: systemPrompt, userMessage: userMessage, history: history)
        case "deepseek":
            return try await sendOpenAIRequest(apiKey: apiKey, system: systemPrompt, messages: buildOpenAIMessages(userMessage: userMessage, history: history), baseURL: provider.apiBaseURL!)
        default:
            throw AIError.providerNotSupported
        }
    }

    /// Follow-up message in an ongoing conversation
    func followUp(message: String, provider: LLMProvider, history: [ChatMessage]) async throws -> String {
        guard provider.supportsAPI else {
            throw AIError.providerNotSupported
        }

        guard let apiKey = KeychainService.shared.loadAPIKey(for: provider.id), !apiKey.isEmpty else {
            throw AIError.noAPIKey
        }

        var systemPrompt = """
        You are an AI assistant in a note-taking app. Continue the conversation helpfully. \
        Always respond in the same language the user is using.
        """
        if let personaContext = await MainActor.run(body: { PersonaStore.shared.systemPromptContext }) {
            systemPrompt += "\n\n" + personaContext
        }

        switch provider.id {
        case "claude":
            return try await sendClaudeRequest(apiKey: apiKey, system: systemPrompt, messages: buildClaudeFollowUp(message: message, history: history))
        case "chatgpt", "deepseek":
            return try await sendOpenAIRequest(apiKey: apiKey, system: systemPrompt, messages: buildOpenAIFollowUp(message: message, history: history), baseURL: provider.apiBaseURL!)
        case "gemini":
            return try await sendGeminiFollowUp(apiKey: apiKey, system: systemPrompt, message: message, history: history)
        default:
            throw AIError.providerNotSupported
        }
    }

    // MARK: - Legacy structured analysis (still uses Claude)

    func analyzeNote(_ content: String) async throws -> NoteAnalysisResult {
        let responseText = try await sendClaudeRequest(
            apiKey: try getClaudeKey(),
            system: AIPrompts.systemPrompt,
            messages: [["role": "user", "content": AIPrompts.analyzeNote(content: content)]]
        )
        return try decodeJSON(NoteAnalysisResult.self, from: responseText)
    }

    func expandNote(_ content: String) async throws -> NoteExpansionResult {
        let responseText = try await sendClaudeRequest(
            apiKey: try getClaudeKey(),
            system: AIPrompts.systemPrompt,
            messages: [["role": "user", "content": AIPrompts.expandNote(content: content)]]
        )
        return try decodeJSON(NoteExpansionResult.self, from: responseText)
    }

    func summarizeNote(_ content: String) async throws -> NoteSummaryResult {
        let responseText = try await sendClaudeRequest(
            apiKey: try getClaudeKey(),
            system: AIPrompts.systemPrompt,
            messages: [["role": "user", "content": AIPrompts.summarizeNote(content: content)]]
        )
        return try decodeJSON(NoteSummaryResult.self, from: responseText)
    }

    // MARK: - Persona Analysis

    /// Token-budget constants.
    /// Claude's effective context is ~200 k tokens; 1 token ≈ 4 chars.
    /// We reserve ~400 k chars for the note corpus so the prompt + response stays safe.
    private static let singlePassCharBudget  = 400_000
    /// When a single pass would exceed the budget we split into chunks of this many notes.
    private static let chunkSize             = 60
    /// Minimum chars kept per note to preserve some signal even for huge libraries.
    private static let minCharsPerNote       = 400

    /// Analyzes the user's *entire* note library using the local `claude` CLI subprocess.
    /// For large libraries the analysis is done in two phases:
    ///   Phase 1 – extract personality signals from each batch of notes independently.
    ///   Phase 2 – synthesise all signals into the final JSON persona.
    /// `onProgress` is called on whatever thread the actor runs on; callers should
    /// dispatch to the main actor themselves.
    func analyzePersona(notes: [Note],
                        extraDocuments: [(title: String, content: String)] = [],
                        providerMode: AIProviderMode = .localCLI,
                        providerID: String? = nil,
                        onProgress: @Sendable (String) -> Void = { _ in }) async throws -> UserPersona {
        let sorted = notes.sorted { $0.modifiedAt > $1.modifiedAt }
        let totalNotes = sorted.count
        let totalWords = notes.reduce(0) { $0 + $1.wordCount }
            + extraDocuments.reduce(0) { $0 + $1.content.split(separator: " ").count }
        let totalDocs = totalNotes + extraDocuments.count

        let charPerNote = max(Self.minCharsPerNote,
                              Self.singlePassCharBudget / max(1, totalDocs))
        let totalEstimated = charPerNote * totalDocs

        let systemPrompt = "你是一位专业的心理学分析师和个人成长顾问。请严格按照 JSON 格式返回分析结果，不要添加任何其他文字。"
        let signalSystemPrompt = "你是一位心理分析师，请从笔记中提炼用户性格信号，简洁输出，不需要 JSON。"

        let raw: String
        if totalEstimated <= Self.singlePassCharBudget {
            let docSuffix = extraDocuments.isEmpty ? "" : " + \(extraDocuments.count) 个外部文档"
            onProgress("正在整理全部 \(totalNotes) 篇笔记\(docSuffix)…")
            let prompt = buildSinglePassPrompt(notes: sorted, extraDocuments: extraDocuments, charPerNote: charPerNote)

            if providerMode == .apiKey, let pid = providerID {
                raw = try await callPersonaAPI(prompt: prompt, systemPrompt: systemPrompt, providerID: pid)
            } else {
                raw = try await runClaude(prompt: prompt, systemPrompt: systemPrompt)
            }
        } else {
            let chunks = stride(from: 0, to: sorted.count, by: Self.chunkSize).map {
                Array(sorted[$0 ..< min($0 + Self.chunkSize, sorted.count)])
            }
            onProgress("笔记较多，将分 \(chunks.count) 批提取特征…")

            var signals: [String] = []
            for (idx, chunk) in chunks.enumerated() {
                onProgress("正在分析第 \(idx + 1)/\(chunks.count) 批（共 \(chunk.count) 篇）…")
                let prompt = buildSignalExtractionPrompt(notes: chunk,
                                                         batchIndex: idx + 1,
                                                         totalBatches: chunks.count)

                let signal: String
                if providerMode == .apiKey, let pid = providerID {
                    signal = try await callPersonaAPI(prompt: prompt, systemPrompt: signalSystemPrompt, providerID: pid)
                } else {
                    signal = try await runClaude(prompt: prompt, systemPrompt: signalSystemPrompt)
                }
                signals.append("【第\(idx + 1)批信号】\n\(signal)")
            }

            onProgress("正在综合全部信号，生成最终画像…")
            let synthesisPrompt = buildSynthesisPrompt(signals: signals,
                                                        extraDocuments: extraDocuments,
                                                        totalNotes: totalDocs)

            if providerMode == .apiKey, let pid = providerID {
                raw = try await callPersonaAPI(prompt: synthesisPrompt, systemPrompt: systemPrompt, providerID: pid)
            } else {
                raw = try await runClaude(prompt: synthesisPrompt, systemPrompt: systemPrompt)
            }
        }

        let resultProviderID: String
        if providerMode == .apiKey, let pid = providerID {
            resultProviderID = pid
        } else {
            resultProviderID = "claude-cli"
        }

        return try parsePersona(from: raw,
                                noteCount: totalDocs,
                                totalWords: totalWords,
                                providerID: resultProviderID,
                                analyzedNoteIDs: sorted.map(\.id))
    }

    // MARK: - Incremental patch analysis

    /// Updates an existing persona using only notes that are new or modified since the
    /// last analysis.  Stable traits (MBTI, core personality) are preserved unless the
    /// new notes contradict them strongly; volatile fields (recentFocus, interests,
    /// suggestions) are updated to reflect the user's current state.
    func patchPersona(existing: UserPersona,
                      newNotes: [Note],
                      allActiveNotes: [Note],
                      extraDocuments: [(title: String, content: String)] = [],
                      providerMode: AIProviderMode = .localCLI,
                      providerID: String? = nil,
                      onProgress: @Sendable (String) -> Void = { _ in }) async throws -> UserPersona {
        onProgress("正在分析 \(newNotes.count) 篇新内容…")

        let charPerNote = max(Self.minCharsPerNote,
                              Self.singlePassCharBudget / max(1, newNotes.count))

        let prompt = buildPatchPrompt(existing: existing,
                                      newNotes: newNotes.sorted { $0.modifiedAt > $1.modifiedAt },
                                      charPerNote: charPerNote,
                                      totalNoteCount: allActiveNotes.count)

        let systemPrompt = "你是一位专业的心理学分析师和个人成长顾问。请严格按照 JSON 格式返回分析结果，不要添加任何其他文字。"

        let raw: String
        if providerMode == .apiKey, let pid = providerID {
            raw = try await callPersonaAPI(prompt: prompt, systemPrompt: systemPrompt, providerID: pid)
        } else {
            raw = try await runClaude(prompt: prompt, systemPrompt: systemPrompt)
        }

        let totalWords = allActiveNotes.reduce(0) { $0 + $1.wordCount }
        // Union of previously analyzed IDs + IDs of all currently active notes
        let allIDs = Set(existing.analyzedNoteIDs).union(allActiveNotes.map(\.id))

        let resultProviderID: String
        if providerMode == .apiKey, let pid = providerID {
            resultProviderID = pid
        } else {
            resultProviderID = "claude-cli"
        }

        var updated = try parsePersona(from: raw,
                                       noteCount: allActiveNotes.count,
                                       totalWords: totalWords,
                                       providerID: resultProviderID,
                                       analyzedNoteIDs: Array(allIDs))
        // Preserve the original full-analysis timestamp; record the patch time separately.
        updated.generatedAt   = existing.generatedAt
        updated.lastPatchedAt = .now
        return updated
    }

    // MARK: - Prompt builders

    /// Builds a single-pass prompt that includes every note and extra document with a dynamic char cap.
    private func buildSinglePassPrompt(notes: [Note],
                                       extraDocuments: [(title: String, content: String)],
                                       charPerNote: Int) -> String {
        var sections: [String] = []
        for (i, note) in notes.enumerated() {
            let title = note.title.isEmpty ? "（无标题）" : note.title
            let body  = note.content.prefix(charPerNote)
            sections.append("【笔记\(i + 1)】\(title)\n\(body)")
        }
        for (i, doc) in extraDocuments.enumerated() {
            let body = doc.content.prefix(charPerNote)
            sections.append("【外部文档\(i + 1)】\(doc.title)\n\(body)")
        }
        let corpus = sections.joined(separator: "\n\n")
        let totalDocs = notes.count + extraDocuments.count
        let docSuffix = extraDocuments.isEmpty ? "" : "和 \(extraDocuments.count) 个外部文档"

        return """
        用户共有 \(notes.count) 篇笔记\(docSuffix)，以下是全部内容（每篇最多 \(charPerNote) 字）：

        \(corpus)

        ---

        \(personaJSONInstruction(totalNotes: totalDocs))
        """
    }

    /// Extracts raw personality signals from a single batch (no JSON required).
    private func buildSignalExtractionPrompt(notes: [Note],
                                              batchIndex: Int,
                                              totalBatches: Int) -> String {
        // Use a generous per-note cap within the chunk since each batch is small.
        let cap = max(Self.minCharsPerNote,
                      Self.singlePassCharBudget / max(1, notes.count))
        var sections: [String] = []
        for (i, note) in notes.enumerated() {
            let title = note.title.isEmpty ? "（无标题）" : note.title
            let body  = note.content.prefix(cap)
            sections.append("【笔记\(i + 1)】\(title)\n\(body)")
        }
        let corpus = sections.joined(separator: "\n\n")

        return """
        这是用户笔记库的第 \(batchIndex)/\(totalBatches) 批，共 \(notes.count) 篇。

        \(corpus)

        ---

        请从上述笔记中简洁地提炼：
        1. 体现的性格特质和认知风格（附简短证据）
        2. 出现的兴趣领域及频率
        3. 写作与表达风格特征
        4. 近期关注的主题

        直接以要点形式输出，不需要 JSON，不需要标题，尽量精简。
        """
    }

    /// Synthesises signals from all batches into the final persona JSON.
    /// Extra documents (library files) are appended after the batch signals.
    private func buildSynthesisPrompt(signals: [String],
                                      extraDocuments: [(title: String, content: String)],
                                      totalNotes: Int) -> String {
        var parts: [String] = []
        parts.append("以下是从用户笔记中逐批提取的性格分析信号：")
        parts.append(signals.joined(separator: "\n\n"))

        if !extraDocuments.isEmpty {
            parts.append("---\n以下是用户的外部文档（\(extraDocuments.count) 篇），也作为分析依据：")
            let cap = Self.minCharsPerNote * 2
            for (i, doc) in extraDocuments.enumerated() {
                parts.append("【外部文档\(i + 1)】\(doc.title)\n\(doc.content.prefix(cap))")
            }
        }

        parts.append("---")
        parts.append(personaJSONInstruction(totalNotes: totalNotes))

        return parts.joined(separator: "\n\n")
    }

    /// Shared instruction block for the final JSON persona generation.
    private func personaJSONInstruction(totalNotes: Int) -> String {
        """
        请深度分析上述内容，生成用户画像报告。要求：
        1. MBTI 推断需基于具体证据（思维方式、兴趣偏好、决策风格等）
        2. 性格特质 3–5 条，每条提供具体证据
        3. 兴趣领域 4–8 个，intensity 1（偶尔提及）到 5（核心关注）
        4. 建议 3–5 条，具体可执行，基于用户当前状态
        5. 所有文字均用中文，MBTI 四字母除外

        请严格按照以下 JSON 格式返回，不要添加任何其他文字：

        {
          "mbti": {
            "type": "XXXX",
            "confidence": "高/中/低",
            "reasoning": "推断理由，引用具体笔记证据",
            "dimensions": {
              "iVsE": 65,
              "nVsS": 80,
              "tVsF": 55,
              "jVsP": 30
            }
          },
          "personalityTraits": [
            { "name": "特质名", "description": "详细描述", "evidence": "笔记中的证据" }
          ],
          "interests": [
            { "name": "兴趣领域", "intensity": 1-5, "summary": "描述" }
          ],
          "writingStyle": "对写作风格和思维方式的描述",
          "recentFocus": "最近最关注的主题或方向（一两句话）",
          "summary": "150–200字的整体人格画像段落",
          "suggestions": ["建议1", "建议2", "建议3"]
        }

        dimensions 字段说明：每个维度取值 0–100，代表在该轴上的偏向程度。
        iVsE: 0=纯 E，100=纯 I（如 65 表示偏 I，倾向度 65%）
        nVsS: 0=纯 S，100=纯 N
        tVsF: 0=纯 F，100=纯 T
        jVsP: 0=纯 P，100=纯 J（如 30 表示偏 P，倾向度 70%）
        请根据证据给出合理的连续值，不要只填 0、50、100 等极端值。
        """
    }

    /// Builds the prompt for an incremental patch: passes the existing persona JSON
    /// alongside new/changed notes so Claude can do a targeted update.
    private func buildPatchPrompt(existing: UserPersona,
                                   newNotes: [Note],
                                   charPerNote: Int,
                                   totalNoteCount: Int) -> String {
        // Serialise the existing persona so Claude can see what's already known.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let existingJSON = (try? String(data: encoder.encode(existing), encoding: .utf8)) ?? "{}"

        var sections: [String] = []
        for (i, note) in newNotes.enumerated() {
            let title = note.title.isEmpty ? "（无标题）" : note.title
            let body  = note.content.prefix(charPerNote)
            sections.append("【新笔记\(i + 1)】\(title)\n\(body)")
        }
        let corpus = sections.joined(separator: "\n\n")

        return """
        以下是用户目前的个人画像（已基于历史笔记生成）：

        \(existingJSON)

        ---

        用户最近新增或修改了 \(newNotes.count) 篇笔记（库中共 \(totalNoteCount) 篇）：

        \(corpus)

        ---

        请根据新笔记对画像进行局部更新，遵循以下原则：
        1. MBTI 和核心性格特质变化缓慢——除非新笔记有强力反证，否则保持或做小幅修正
        2. 重点更新以下易变字段：recentFocus（近期关注）、interests（兴趣分布，尤其是强度变化和新出现的领域）、suggestions（基于最新状态给出建议）
        3. 如新笔记明显体现了不同的写作/思维风格，可更新 writingStyle
        4. summary 可根据新信息做适度修订，但不要大幅改写已有描述
        5. 所有文字均用中文，MBTI 四字母除外

        请严格按照以下 JSON 格式返回完整画像（包含所有字段），不要添加任何其他文字：

        {
          "mbti": {
            "type": "XXXX",
            "confidence": "高/中/低",
            "reasoning": "推断理由",
            "dimensions": { "iVsE": 65, "nVsS": 80, "tVsF": 55, "jVsP": 30 }
          },
          "personalityTraits": [
            { "name": "特质名", "description": "详细描述", "evidence": "证据" }
          ],
          "interests": [
            { "name": "兴趣领域", "intensity": 1-5, "summary": "描述" }
          ],
          "writingStyle": "写作与思维风格描述",
          "recentFocus": "近期最关注的主题（一两句话）",
          "summary": "150–200字的整体人格画像段落",
          "suggestions": ["建议1", "建议2", "建议3"]
        }
        """
    }

    // MARK: - Claude CLI runner

    /// Writes `prompt` to a temp file and pipes it to the local `claude` CLI.
    private func runClaude(prompt: String, systemPrompt: String) async throws -> String {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudenotes_persona_\(UUID().uuidString).txt")
        try prompt.write(to: tmpURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let escapedPath = tmpURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let escapedSystem = systemPrompt.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "cat '\(escapedPath)' | claude -p '\(escapedSystem)'"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", cmd]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do { try process.run() } catch {
            throw AIError.requestFailed("无法启动 claude CLI：\(error.localizedDescription)")
        }

        // 添加 5 分钟超时
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(300))
            process.terminate()
            throw AIError.requestFailed("claude CLI 超时（5 分钟），可能是网络问题或中转 API 响应慢")
        }

        var outputData = Data()
        do {
            for try await byte in outPipe.fileHandleForReading.bytes {
                outputData.append(byte)
            }
            timeoutTask.cancel()
        } catch {
            timeoutTask.cancel()
            throw error
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errMsg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let trimmed = errMsg.prefix(500).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AIError.requestFailed("claude CLI 退出码 \(process.terminationStatus)\(trimmed.isEmpty ? "" : "：\(trimmed)")")
        }

        let result = String(data: outputData, encoding: .utf8) ?? ""
        guard !result.isEmpty else {
            throw AIError.requestFailed("claude CLI 返回空结果")
        }
        return result
    }

    private func parsePersona(from raw: String,
                               noteCount: Int,
                               totalWords: Int,
                               providerID: String,
                               analyzedNoteIDs: [UUID] = []) throws -> UserPersona {
        // Extract JSON block
        let jsonString: String
        if let range = raw.range(of: "\\{[\\s\\S]*\\}", options: .regularExpression) {
            jsonString = String(raw[range])
        } else {
            jsonString = raw
        }
        guard let data = jsonString.data(using: .utf8) else { throw AIError.invalidResponse }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.decodingFailed("无法解析 JSON")
        }

        // MBTI
        let mbtiJSON = json["mbti"] as? [String: Any] ?? [:]
        var dimensions: UserPersona.MBTIDimensions?
        if let dimJSON = mbtiJSON["dimensions"] as? [String: Any] {
            dimensions = UserPersona.MBTIDimensions(
                iVsE: dimJSON["iVsE"] as? Int ?? 50,
                nVsS: dimJSON["nVsS"] as? Int ?? 50,
                tVsF: dimJSON["tVsF"] as? Int ?? 50,
                jVsP: dimJSON["jVsP"] as? Int ?? 50
            )
        }
        let mbti = UserPersona.MBTI(
            type: mbtiJSON["type"] as? String ?? "??",
            confidence: mbtiJSON["confidence"] as? String ?? "低",
            reasoning: mbtiJSON["reasoning"] as? String ?? "",
            dimensions: dimensions
        )

        // Personality traits
        let traitsJSON = json["personalityTraits"] as? [[String: Any]] ?? []
        let traits = traitsJSON.map {
            UserPersona.PersonalityTrait(
                name: $0["name"] as? String ?? "",
                description: $0["description"] as? String ?? "",
                evidence: $0["evidence"] as? String ?? ""
            )
        }

        // Interests
        let interestsJSON = json["interests"] as? [[String: Any]] ?? []
        let interests = interestsJSON.map {
            UserPersona.InterestArea(
                name: $0["name"] as? String ?? "",
                intensity: $0["intensity"] as? Int ?? 1,
                summary: $0["summary"] as? String ?? ""
            )
        }

        return UserPersona(
            mbti: mbti,
            personalityTraits: traits,
            interests: interests,
            writingStyle: json["writingStyle"] as? String ?? "",
            recentFocus: json["recentFocus"] as? String ?? "",
            summary: json["summary"] as? String ?? "",
            suggestions: json["suggestions"] as? [String] ?? [],
            generatedAt: .now,
            noteCount: noteCount,
            totalWords: totalWords,
            providerID: providerID,
            analyzedNoteIDs: analyzedNoteIDs
        )
    }

    // MARK: - Claude API

    private func getClaudeKey() throws -> String {
        guard let key = KeychainService.shared.loadAPIKey(for: "claude"), !key.isEmpty else {
            throw AIError.noAPIKey
        }
        return key
    }

    private func sendClaudeRequest(apiKey: String, system: String, messages: [[String: Any]], maxTokens: Int = 2048) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": "claude-opus-4-20250514",
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AIError.requestFailed("HTTP \(code): \(errorBody)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArray = json["content"] as? [[String: Any]],
              let firstContent = contentArray.first,
              let text = firstContent["text"] as? String else {
            throw AIError.invalidResponse
        }
        return text
    }

    private func buildClaudeMessages(userMessage: String, history: [ChatMessage]) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        for msg in history {
            messages.append([
                "role": msg.role == .user ? "user" : "assistant",
                "content": msg.content
            ])
        }
        messages.append(["role": "user", "content": userMessage])
        return messages
    }

    private func buildClaudeFollowUp(message: String, history: [ChatMessage]) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        for msg in history {
            messages.append([
                "role": msg.role == .user ? "user" : "assistant",
                "content": msg.content
            ])
        }
        messages.append(["role": "user", "content": message])
        return messages
    }

    // MARK: - OpenAI-compatible API (ChatGPT, DeepSeek)

    private func sendOpenAIRequest(apiKey: String, system: String, messages: [[String: String]], baseURL: String, maxTokens: Int = 2048) async throws -> String {
        let url = URL(string: baseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var allMessages: [[String: String]] = [["role": "system", "content": system]]
        allMessages.append(contentsOf: messages)

        let model = baseURL.contains("deepseek") ? "deepseek-chat" : "gpt-4o"

        let body: [String: Any] = [
            "model": model,
            "messages": allMessages,
            "max_tokens": maxTokens,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AIError.requestFailed("HTTP \(code): \(errorBody)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIError.invalidResponse
        }
        return content
    }

    private func buildOpenAIMessages(userMessage: String, history: [ChatMessage]) -> [[String: String]] {
        var messages: [[String: String]] = []
        for msg in history {
            messages.append([
                "role": msg.role == .user ? "user" : "assistant",
                "content": msg.content
            ])
        }
        messages.append(["role": "user", "content": userMessage])
        return messages
    }

    private func buildOpenAIFollowUp(message: String, history: [ChatMessage]) -> [[String: String]] {
        var messages: [[String: String]] = []
        for msg in history {
            messages.append([
                "role": msg.role == .user ? "user" : "assistant",
                "content": msg.content
            ])
        }
        messages.append(["role": "user", "content": message])
        return messages
    }

    // MARK: - Gemini API

    private func sendGeminiRequest(apiKey: String, system: String, userMessage: String, history: [ChatMessage]) async throws -> String {
        let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=\(apiKey)"
        let url = URL(string: urlStr)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var contents: [[String: Any]] = []
        for msg in history {
            contents.append([
                "role": msg.role == .user ? "user" : "model",
                "parts": [["text": msg.content]]
            ])
        }
        contents.append(["role": "user", "parts": [["text": userMessage]]])

        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
            "contents": contents
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AIError.requestFailed("HTTP \(code): \(errorBody)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw AIError.invalidResponse
        }
        return text
    }

    private func sendGeminiFollowUp(apiKey: String, system: String, message: String, history: [ChatMessage]) async throws -> String {
        return try await sendGeminiRequest(apiKey: apiKey, system: system, userMessage: message, history: history)
    }

    // MARK: - JSON Decoding

    private func decodeJSON<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let jsonString: String
        if let range = text.range(of: "\\{[\\s\\S]*\\}", options: .regularExpression) {
            jsonString = String(text[range])
        } else {
            jsonString = text
        }

        guard let data = jsonString.data(using: .utf8) else {
            throw AIError.decodingFailed("Cannot convert to data")
        }

        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AIError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Provider-based API calls for Persona and Inbox

    /// Call API for persona analysis using the specified provider
    private func callPersonaAPI(prompt: String, systemPrompt: String, providerID: String) async throws -> String {
        guard let provider = LLMProvider.provider(for: providerID), provider.supportsAPI else {
            throw AIError.providerNotSupported
        }

        guard let apiKey = KeychainService.shared.loadAPIKey(for: providerID), !apiKey.isEmpty else {
            throw AIError.noAPIKey
        }

        switch providerID {
        case "claude":
            return try await sendClaudeRequest(
                apiKey: apiKey,
                system: systemPrompt,
                messages: [["role": "user", "content": prompt]],
                maxTokens: 8192
            )
        case "chatgpt", "":
            return try await sendOpenAIRequest(
                apiKey: apiKey,
                system: systemPrompt,
                messages: [["role": "user", "content": prompt]],
                baseURL: provider.apiBaseURL!,
                maxTokens: 8192
            )
        case "gemini":
            return try await sendGeminiRequest(
                apiKey: apiKey,
                system: systemPrompt,
                userMessage: prompt,
                history: []
            )
        default:
            throw AIError.providerNotSupported
        }
    }

    /// Call API for inbox digest using the specified provider
    func callInboxAPI(prompt: String, systemPrompt: String, providerID: String) async throws -> String {
        guard let provider = LLMProvider.provider(for: providerID), provider.supportsAPI else {
            throw AIError.providerNotSupported
        }

        guard let apiKey = KeychainService.shared.loadAPIKey(for: providerID), !apiKey.isEmpty else {
            throw AIError.noAPIKey
        }

        switch providerID {
        case "claude":
            return try await sendClaudeRequest(
                apiKey: apiKey,
                system: systemPrompt,
                messages: [["role": "user", "content": prompt]],
                maxTokens: 4096
            )
        case "chatgpt", "":
            return try await sendOpenAIRequest(
                apiKey: apiKey,
                system: systemPrompt,
                messages: [["role": "user", "content": prompt]],
                baseURL: provider.apiBaseURL!,
                maxTokens: 4096
            )
        case "gemini":
            return try await sendGeminiRequest(
                apiKey: apiKey,
                system: systemPrompt,
                userMessage: prompt,
                history: []
            )
        default:
            throw AIError.providerNotSupported
        }
    }

    // MARK: - Search Query Optimization

    /// Uses Claude to reformulate a user's raw query into a better search query for the given engine.
    /// Falls back to the original query if optimization fails.
    func optimizeSearchQuery(_ rawQuery: String, forEngine engineName: String) async -> String {
        let systemPrompt = "You are a search query optimizer. Given a user's raw query and a target search engine, produce a concise, effective search query that will return the most relevant results. Output ONLY the optimized query string, nothing else."
        let userPrompt = """
        Target search engine: \(engineName)
        User's raw query: \(rawQuery)

        Rewrite this into a better search query for the target engine. Consider:
        - Use English keywords for international engines (Google, Perplexity, Wikipedia, etc.)
        - For Chinese engines (Baidu, Zhihu), use Chinese keywords
        - Add relevant year or qualifier if implied (e.g. "latest", "review", "2024")
        - Remove filler words, keep only key terms
        - Maximum 10 words / 20 Chinese characters

        Output ONLY the optimized query, no explanation.
        """

        // Use local CLI as default; if unavailable the fallback below handles it
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudenotes_query_\(UUID().uuidString).txt")
        guard (try? userPrompt.write(to: tmpURL, atomically: true, encoding: .utf8)) != nil else {
            return rawQuery
        }
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let escapedPath = tmpURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let escapedSys = systemPrompt.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "cat '\(escapedPath)' | claude -p '\(escapedSys)'"

        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", cmd]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            try process.run()

            var outputData = Data()
            for try await byte in pipe.fileHandleForReading.bytes {
                outputData.append(byte)
            }
            process.waitUntilExit()

            guard process.terminationStatus == 0,
                  let result = String(data: outputData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !result.isEmpty else {
                return rawQuery
            }

            // Strip any markdown fences the model might add
            let cleaned = result
                .replacingOccurrences(of: "^```.*$", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return cleaned.isEmpty ? rawQuery : cleaned
        } catch {
            return rawQuery
        }
    }
}
