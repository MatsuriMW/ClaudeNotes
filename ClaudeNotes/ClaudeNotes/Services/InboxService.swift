import Foundation

actor InboxService {
    static let shared = InboxService()
    private init() {}

    // MARK: - Content Cleanup

    /// Remove warning/disclaimer blockquote blocks that Claude sometimes appends.
    static func stripWarningBlocks(from markdown: String) -> String {
        let warningKeywords = ["网络搜索权限", "WebSearch", "Google News 实时搜索链接", "授权开启", "说明：因"]
        let lines = markdown.components(separatedBy: "\n")
        var result: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            // Blockquote line containing a warning keyword — skip the entire blockquote block
            if line.hasPrefix(">") && warningKeywords.contains(where: { line.contains($0) }) {
                // Skip consecutive blockquote lines
                while i < lines.count && lines[i].hasPrefix(">") {
                    i += 1
                }
                // Also drop a trailing blank line if present
                if i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    i += 1
                }
                continue
            }
            result.append(line)
            i += 1
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - HackerNews

    private struct HNStory {
        let title: String
        let url: String
        let score: Int
        let by: String
    }

    private func fetchHNTopStories(count: Int = 10) async -> [HNStory] {
        guard let idsURL = URL(string: "https://hacker-news.firebaseio.com/v0/topstories.json"),
              let idsData = try? await URLSession.shared.data(from: idsURL).0,
              let ids = try? JSONDecoder().decode([Int].self, from: idsData) else { return [] }

        var stories: [HNStory] = []
        for id in ids.prefix(count) {
            guard let itemURL = URL(string: "https://hacker-news.firebaseio.com/v0/item/\(id).json"),
                  let itemData = try? await URLSession.shared.data(from: itemURL).0,
                  let json = try? JSONSerialization.jsonObject(with: itemData) as? [String: Any] else { continue }
            let title = json["title"] as? String ?? "(no title)"
            let url = json["url"] as? String ?? "https://news.ycombinator.com/item?id=\(id)"
            let score = json["score"] as? Int ?? 0
            let by = json["by"] as? String ?? ""
            stories.append(HNStory(title: title, url: url, score: score, by: by))
        }
        return stories
    }

    // MARK: - Generate Digest

    func generateDigest(topics: [InboxTopic], keywords: [String] = []) async throws -> InboxDigest {
        guard !topics.isEmpty || !keywords.isEmpty else {
            throw AIError.requestFailed("请先添加关键词或启用至少一个主题")
        }

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh-Hans")
        fmt.dateStyle = .long
        fmt.timeStyle = .none
        let today = fmt.string(from: Date())
        var promptLines: [String] = []

        promptLines.append("今天是 \(today)。")
        promptLines.append("请为用户生成一份今日信息简报，输出纯 Markdown 格式，以 `# 今日简报 · \(today)` 作为一级标题。")
        promptLines.append("""
        格式要求（必须严格遵守）：
        - 每个主题/关键词作为二级标题（## 主题名）
        - 每条新闻标题必须是可点击的 Markdown 链接，格式：**[新闻标题](完整URL)**
        - 链接后注明来源媒体名，格式：**[标题](URL)** — 来源名
        - 标题下方跟 1-2 句中文摘要
        - 每个主题列出 3-5 条内容
        - 必须使用 WebSearch 工具搜索真实文章，每条附精准文章直链（非搜索页链接）
        - 示例格式：
          **[Apple Vision Pro Sales Disappoint](https://theverge.com/...)** — The Verge
          苹果头显设备销量不及预期，分析师下调全年出货量预测…
        """)
        promptLines.append("所有输出使用中文（链接文字和来源名可保留英文）。不要输出任何前言、说明、警告框、免责声明或提示信息，直接输出 Markdown 正文，结尾不要加任何注释或说明。")

        var allTopicNames: [String] = []
        var hnBlock: String? = nil

        // Keyword sections
        if !keywords.isEmpty {
            promptLines.append("\n---\n## 关键词追踪\n")
            promptLines.append("以下关键词每个单独作为一个二级标题，分别搜索最新资讯：")
            for kw in keywords {
                promptLines.append("- **\(kw)**")
                allTopicNames.append(kw)
            }
        }

        // Topic sections
        if !topics.isEmpty {
            promptLines.append("\n---\n## 订阅主题\n")
            for topic in topics {
                allTopicNames.append(topic.name)
                if topic.name == "HackerNews 热门" {
                    let stories = await fetchHNTopStories(count: 10)
                    if !stories.isEmpty {
                        var block = "HackerNews 真实数据（请整理为简报并附原始链接，标题已是真实 URL）：\n"
                        for (i, s) in stories.enumerated() {
                            block += "\(i + 1). [\(s.title)](\(s.url)) ↑\(s.score) by \(s.by)\n"
                        }
                        hnBlock = block
                        promptLines.append("- **HackerNews 热门**：使用下方提供的真实数据，每条保留原始链接，补充中文摘要")
                    } else {
                        promptLines.append("- **HackerNews 热门**：搜索今日 HackerNews 热门前 10 条并附链接")
                    }
                } else {
                    promptLines.append("- **\(topic.name)**：\(topic.searchPrompt)，每条必须附来源 URL")
                }
            }
        }

        if let hn = hnBlock {
            promptLines.append("\n---\n以下为 HackerNews 真实数据供整理：\n\n\(hn)")
        }

        let fullPrompt = promptLines.joined(separator: "\n")
        let sysPrompt = "你是一个信息整合助手，擅长搜索网络最新资讯并整理为带来源链接的 Markdown 简报。请直接输出 Markdown，不要有任何额外解释。每条新闻必须包含可点击的来源链接。"

        // 强制使用本地 Claude CLI
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudenotes_inbox_\(UUID().uuidString).txt")
        try fullPrompt.write(to: tmpURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let escapedPath = tmpURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let escapedSys = sysPrompt.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "cat '\(escapedPath)' | claude -p --system-prompt '\(escapedSys)'"

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
            let trimmed = errMsg.prefix(300).trimmingCharacters(in: .whitespacesAndNewlines)
            let hint: String
            if trimmed.contains("permission") || trimmed.contains("Permission") || process.terminationStatus == 1 {
                hint = "（可能需要先在终端运行 claude 授权，或检查 Claude Code 配置）"
            } else {
                hint = ""
            }
            throw AIError.requestFailed("claude CLI 退出码 \(process.terminationStatus)\(hint.isEmpty ? "" : " \(hint)")\(trimmed.isEmpty ? "" : "：\(trimmed)")")
        }

        let raw = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "（无内容）"

        let content = InboxService.stripWarningBlocks(from: raw)
        return InboxDigest(content: content, topicNames: allTopicNames)
    }
}
