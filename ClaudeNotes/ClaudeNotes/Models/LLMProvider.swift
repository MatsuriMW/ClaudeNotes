import Foundation

enum ChatMode: String, CaseIterable, Identifiable {
    case api = "API"
    case web = "Web"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .api: return "API Key"
        case .web: return "Web 登录"
        }
    }

    var icon: String {
        switch self {
        case .api: return "key"
        case .web: return "globe"
        }
    }
}

struct LLMProvider: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    let iconName: String
    let colorHex: String
    let supportsAPI: Bool
    let apiBaseURL: String?
    let apiKeyPrefix: String  // Hint for user, e.g. "sk-ant-..."

    static let allProviders: [LLMProvider] = [
        LLMProvider(
            id: "claude",
            name: "Claude",
            url: URL(string: "https://claude.ai")!,
            iconName: "brain.head.profile",
            colorHex: "#D97757",
            supportsAPI: true,
            apiBaseURL: "https://api.anthropic.com/v1/messages",
            apiKeyPrefix: "sk-ant-..."
        ),
        LLMProvider(
            id: "chatgpt",
            name: "ChatGPT",
            url: URL(string: "https://chatgpt.com")!,
            iconName: "bubble.left.and.bubble.right",
            colorHex: "#10A37F",
            supportsAPI: true,
            apiBaseURL: "https://api.openai.com/v1/chat/completions",
            apiKeyPrefix: "sk-..."
        ),
        LLMProvider(
            id: "gemini",
            name: "Gemini",
            url: URL(string: "https://gemini.google.com")!,
            iconName: "sparkles",
            colorHex: "#4285F4",
            supportsAPI: true,
            apiBaseURL: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent",
            apiKeyPrefix: "AI..."
        ),
        LLMProvider(
            id: "deepseek",
            name: "DeepSeek",
            url: URL(string: "https://chat.deepseek.com")!,
            iconName: "magnifyingglass.circle",
            colorHex: "#4D6BFE",
            supportsAPI: true,
            apiBaseURL: "https://api.deepseek.com/v1/chat/completions",
            apiKeyPrefix: "sk-..."
        ),
        LLMProvider(
            id: "grok",
            name: "Grok",
            url: URL(string: "https://grok.com")!,
            iconName: "bolt.circle",
            colorHex: "#1DA1F2",
            supportsAPI: false,
            apiBaseURL: nil,
            apiKeyPrefix: ""
        ),
        LLMProvider(
            id: "copilot",
            name: "Copilot",
            url: URL(string: "https://copilot.microsoft.com")!,
            iconName: "circle.hexagongrid",
            colorHex: "#7B61FF",
            supportsAPI: false,
            apiBaseURL: nil,
            apiKeyPrefix: ""
        ),
        LLMProvider(
            id: "poe",
            name: "Poe",
            url: URL(string: "https://poe.com")!,
            iconName: "ellipsis.message",
            colorHex: "#6C5CE7",
            supportsAPI: false,
            apiBaseURL: nil,
            apiKeyPrefix: ""
        ),
    ]

    static func provider(for id: String) -> LLMProvider? {
        allProviders.first { $0.id == id }
    }
}
