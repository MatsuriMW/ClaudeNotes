import Foundation
import AppKit

// MARK: - External Search Engine

struct ExternalSearchEngine: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    /// URL template; must include `{query}` as the placeholder.
    var urlTemplate: String
    /// Slash-command keyword without the leading slash, e.g. `"askgoogle"`.
    var slashCommand: String
    /// SF Symbol name used in the slash-command popup and settings.
    var iconName: String
    /// Optional keyboard shortcut (⌥-based by default).
    /// When non-nil and selected text exists, opens the browser immediately.
    var shortcut: ShortcutBinding?

    init(id: UUID = UUID(), name: String, urlTemplate: String,
         slashCommand: String, iconName: String,
         shortcut: ShortcutBinding? = nil) {
        self.id = id
        self.name = name
        self.urlTemplate = urlTemplate
        self.slashCommand = slashCommand
        self.iconName = iconName
        self.shortcut = shortcut
    }

    /// Returns the search URL with the query percent-encoded.
    func searchURL(for query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return URL(string: urlTemplate.replacingOccurrences(of: "{query}", with: encoded))
    }

    var shortcutDisplayString: String { shortcut?.displayString ?? "—" }
}

// MARK: - Settings Store

@Observable
final class ExternalSearchSettings {
    static let shared = ExternalSearchSettings()

    var engines: [ExternalSearchEngine]
    /// The engine used when the user invokes `/askai`.
    var defaultAIChatbotID: UUID?

    private init() {
        engines = Self.loadEngines() ?? Self.defaultEngines
        if let str = UserDefaults.standard.string(forKey: "externalSearchDefaultAI"),
           let uuid = UUID(uuidString: str) {
            defaultAIChatbotID = uuid
        } else {
            defaultAIChatbotID = engines.first(where: { $0.slashCommand == "askai" })?.id
        }
    }

    var defaultAIChatbot: ExternalSearchEngine? {
        guard let id = defaultAIChatbotID else {
            return engines.first(where: { $0.slashCommand == "askai" })
        }
        return engines.first(where: { $0.id == id })
    }

    func save() {
        if let data = try? JSONEncoder().encode(engines) {
            UserDefaults.standard.set(data, forKey: "externalSearchEngines")
        }
        UserDefaults.standard.set(defaultAIChatbotID?.uuidString,
                                  forKey: "externalSearchDefaultAI")
    }

    func resetToDefaults() {
        engines = Self.defaultEngines
        defaultAIChatbotID = engines.first(where: { $0.slashCommand == "askai" })?.id
        save()
    }

    private static func loadEngines() -> [ExternalSearchEngine]? {
        guard let data = UserDefaults.standard.data(forKey: "externalSearchEngines"),
              let list = try? JSONDecoder().decode([ExternalSearchEngine].self, from: data),
              !list.isEmpty else { return nil }
        return list
    }

    // MARK: - Built-in defaults

    static let defaultEngines: [ExternalSearchEngine] = [
        ExternalSearchEngine(
            id: UUID(uuidString: "11111111-0000-0000-0000-000000000001")!,
            name: "ChatGPT",
            urlTemplate: "https://chat.openai.com/?q={query}",
            slashCommand: "askai",
            iconName: "brain.head.profile",
            shortcut: ShortcutBinding(key: "a", command: false, shift: false,
                                      control: false, option: true)
        ),
        ExternalSearchEngine(
            name: "Perplexity",
            urlTemplate: "https://www.perplexity.ai/search?q={query}",
            slashCommand: "askpx",
            iconName: "safari",
            shortcut: ShortcutBinding(key: "p", command: false, shift: false,
                                      control: false, option: true)
        ),
        ExternalSearchEngine(
            name: "Google",
            urlTemplate: "https://www.google.com/search?q={query}",
            slashCommand: "askgoogle",
            iconName: "magnifyingglass",
            shortcut: ShortcutBinding(key: "g", command: false, shift: false,
                                      control: false, option: true)
        ),
        ExternalSearchEngine(
            name: "Wikipedia",
            urlTemplate: "https://en.wikipedia.org/w/index.php?search={query}",
            slashCommand: "askwiki",
            iconName: "books.vertical",
            shortcut: ShortcutBinding(key: "w", command: false, shift: false,
                                      control: false, option: true)
        ),
        ExternalSearchEngine(
            name: "百度",
            urlTemplate: "https://www.baidu.com/s?wd={query}",
            slashCommand: "askbd",
            iconName: "globe.asia.australia",
            shortcut: ShortcutBinding(key: "b", command: false, shift: false,
                                      control: false, option: true)
        ),
        ExternalSearchEngine(
            name: "DuckDuckGo",
            urlTemplate: "https://duckduckgo.com/?q={query}",
            slashCommand: "askduck",
            iconName: "hand.raised",
            shortcut: ShortcutBinding(key: "d", command: false, shift: false,
                                      control: false, option: true)
        ),
        ExternalSearchEngine(
            name: "知乎",
            urlTemplate: "https://www.zhihu.com/search?q={query}",
            slashCommand: "askzh",
            iconName: "questionmark.circle",
            shortcut: ShortcutBinding(key: "z", command: false, shift: false,
                                      control: false, option: true)
        ),
        ExternalSearchEngine(
            name: "IMDB",
            urlTemplate: "https://www.imdb.com/find?q={query}",
            slashCommand: "askimdb",
            iconName: "film",
            shortcut: ShortcutBinding(key: "8", command: false, shift: false,
                                      control: false, option: true)
        ),
        ExternalSearchEngine(
            name: "豆瓣",
            urlTemplate: "https://www.douban.com/search?q={query}",
            slashCommand: "askdb",
            iconName: "leaf",
            shortcut: nil
        ),
    ]
}
