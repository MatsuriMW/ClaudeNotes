import Foundation
import AppKit

// MARK: - Social Platform

struct SocialPlatform: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String           // display name, e.g. "小红书"
    var slashCommand: String   // e.g. "toxiaohongshu"
    var iconName: String       // SF Symbol
    /// The full system prompt sent to Claude.
    /// Should instruct Claude to rewrite 【原文】 in the platform's style.
    var rewritePrompt: String

    init(id: UUID = UUID(), name: String, slashCommand: String,
         iconName: String, rewritePrompt: String) {
        self.id = id
        self.name = name
        self.slashCommand = slashCommand
        self.iconName = iconName
        self.rewritePrompt = rewritePrompt
    }
}

// MARK: - Platform Rewrite Settings

@Observable
final class PlatformRewriteSettings {
    static let shared = PlatformRewriteSettings()

    var platforms: [SocialPlatform]

    private init() {
        platforms = Self.load() ?? Self.defaultPlatforms
    }

    func save() {
        if let data = try? JSONEncoder().encode(platforms) {
            UserDefaults.standard.set(data, forKey: "platformRewritePlatforms")
        }
    }

    func resetToDefaults() {
        platforms = Self.defaultPlatforms
        save()
    }

    private static func load() -> [SocialPlatform]? {
        guard let data = UserDefaults.standard.data(forKey: "platformRewritePlatforms"),
              let list = try? JSONDecoder().decode([SocialPlatform].self, from: data),
              !list.isEmpty else { return nil }
        return list
    }

    // MARK: - Defaults

    static let defaultPlatforms: [SocialPlatform] = [
        SocialPlatform(
            name: "小红书",
            slashCommand: "toxiaohongshu",
            iconName: "heart.circle",
            rewritePrompt: """
请将【原文】按照小红书平台的风格改写。小红书风格要点：
- 多用 emoji 表情，增加视觉活跃感
- 段落简短，每段2-3句话
- 第一人称，口语化，亲切自然
- 结尾加2-3个话题标签（如 #生活分享 #日常）
直接输出改写后的内容，不要加任何说明或解释。
"""
        ),
        SocialPlatform(
            name: "知乎",
            slashCommand: "tozhihu",
            iconName: "questionmark.circle",
            rewritePrompt: """
请将【原文】按照知乎平台的写作风格改写。知乎风格要点：
- 逻辑严谨，论点清晰
- 适当使用"首先/其次/最后"等结构词
- 客观理性，可引入数据或案例佐证
- 适合深度阅读，篇幅可适当展开
直接输出改写后的内容，不要加任何说明或解释。
"""
        ),
        SocialPlatform(
            name: "Twitter / X",
            slashCommand: "totwitter",
            iconName: "bird",
            rewritePrompt: """
请将【原文】改写为适合在 Twitter/X 发布的风格。Twitter 风格要点：
- 简洁有力，核心观点前置
- 建议控制在140字以内（中文）
- 可以加1-2个英文 hashtag
- 语气直接，有传播力
直接输出改写后的内容，不要加任何说明或解释。
"""
        ),
        SocialPlatform(
            name: "微博",
            slashCommand: "toweibo",
            iconName: "megaphone",
            rewritePrompt: """
请将【原文】按照微博平台的风格改写。微博风格要点：
- 短小精悍，通常在140字以内
- 情绪带动感强，适当用感叹号
- 口语化，可加表情符号
- 结尾可加话题标签 #xxx#
直接输出改写后的内容，不要加任何说明或解释。
"""
        ),
        SocialPlatform(
            name: "LinkedIn",
            slashCommand: "tolinkedin",
            iconName: "briefcase",
            rewritePrompt: """
请将【原文】按照 LinkedIn 平台的职场写作风格改写。LinkedIn 风格要点：
- 专业、成熟，有思考深度
- 可分享个人经历或洞察
- 结构清晰（可用换行/列点）
- 结尾可提出问题引发讨论
直接输出改写后的内容，不要加任何说明或解释。
"""
        ),
    ]
}

// MARK: - Rewrite Session (shared streaming state)

@Observable
final class RewriteSession {
    static let shared = RewriteSession()

    var platformName: String = ""
    var platformIcon: String = "sparkles"
    var content: String = ""
    var isStreaming: Bool = false
    var isActive: Bool = false

    private var streamTask: Task<Void, Never>?

    private init() {}

    func start(platform: SocialPlatform, sourceText: String) {
        streamTask?.cancel()
        platformName = platform.name
        platformIcon = platform.iconName
        content = ""
        isStreaming = true
        isActive = true

        let prompt = platform.rewritePrompt
        let paraPath = NSTemporaryDirectory() + "claudenotes-rewrite-\(UUID().uuidString).txt"
        let inputText = "\(prompt)\n\n【原文】\n\(sourceText)"
        guard (try? inputText.write(toFile: paraPath, atomically: true, encoding: .utf8)) != nil else {
            isActive = false; isStreaming = false; return
        }

        streamTask = Task { @MainActor in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // Pipe the full prompt+source to claude as stdin, using -p flag
            let escaped = "请根据以上要求改写【原文】，直接输出改写结果。"
                .replacingOccurrences(of: "'", with: "'\\''")
            process.arguments = ["-l", "-c",
                "cat '\(paraPath)' | claude -p '\(escaped)'"
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            defer {
                if process.isRunning { process.terminate() }
                try? FileManager.default.removeItem(atPath: paraPath)
                isStreaming = false
            }

            do { try process.run() } catch {
                isActive = false; return
            }

            var buf = Data()
            do {
                for try await byte in pipe.fileHandleForReading.bytes {
                    buf.append(byte)
                    if byte == UInt8(ascii: "\n") {
                        if let line = String(data: buf, encoding: .utf8) {
                            buf.removeAll()
                            content += line
                        }
                    }
                }
            } catch {}

            if !buf.isEmpty, let tail = String(data: buf, encoding: .utf8) {
                content += tail
            }
        }
    }

    func dismiss() {
        streamTask?.cancel()
        streamTask = nil
        isActive = false
        isStreaming = false
        content = ""
    }
}
