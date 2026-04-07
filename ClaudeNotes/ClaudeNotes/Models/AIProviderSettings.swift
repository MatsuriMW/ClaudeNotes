import Foundation
import Observation

/// AI 提供商选择
enum AIProviderMode: String, Codable, CaseIterable {
    case localCLI = "local-cli"
    case apiKey = "api-key"

    var displayName: String {
        switch self {
        case .localCLI: return "本地 Claude CLI"
        case .apiKey: return "API Key"
        }
    }

    var description: String {
        switch self {
        case .localCLI: return "使用本地安装的 Claude Code CLI（免费，需安装）"
        case .apiKey: return "使用配置的 API Key（需要付费但更稳定）"
        }
    }
}

/// AI 提供商设置
@Observable
final class AIProviderSettings {
    static let shared = AIProviderSettings()

    /// 个人画像使用的提供商
    var personaProviderMode: AIProviderMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "personaProviderMode"),
                  let mode = AIProviderMode(rawValue: raw) else {
                return .localCLI // 默认使用本地 CLI
            }
            return mode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "personaProviderMode")
        }
    }

    /// 每日简报使用的提供商
    var inboxProviderMode: AIProviderMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "inboxProviderMode"),
                  let mode = AIProviderMode(rawValue: raw) else {
                return .apiKey // 默认优先使用 API Key，无 Key 时 fallback 到 CLI
            }
            return mode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "inboxProviderMode")
        }
    }

    /// API Key 模式下选择的具体提供商（仅当 mode == .apiKey 时使用）
    var personaAPIProvider: String? {
        get { UserDefaults.standard.string(forKey: "personaAPIProvider") }
        set { UserDefaults.standard.set(newValue, forKey: "personaAPIProvider") }
    }

    var inboxAPIProvider: String? {
        get { UserDefaults.standard.string(forKey: "inboxAPIProvider") }
        set { UserDefaults.standard.set(newValue, forKey: "inboxAPIProvider") }
    }

    private init() {}
}
