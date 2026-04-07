import SwiftUI

// MARK: - Slash Command Popup

struct SlashCommandPopup: View {
    /// Called when the user picks an AI chat provider.
    let onSelect: (LLMProvider, ChatMode) -> Void
    /// Called when the user picks a web search engine and confirms a query.
    var onWebSearch: ((ExternalSearchEngine, String) -> Void)?
    /// Called when the user picks a social platform rewrite command.
    var onRewrite: ((SocialPlatform) -> Void)?
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var selectedIndex = 0
    /// Non-nil while showing phase 2 (query input) for a chosen web search engine.
    @State private var queryEngine: ExternalSearchEngine? = nil
    @State private var queryText = ""
    @State private var isOptimizingQuery = false

    // MARK: - Filtered entries

    private var allEntries: [SlashEntry] {
        let ai: [SlashEntry] = SlashCommandItem.allItems.map { .aiChat($0) }
        let web: [SlashEntry] = ExternalSearchSettings.shared.engines.map { .webSearch($0) }
        let rewrite: [SlashEntry] = PlatformRewriteSettings.shared.platforms.map { .rewrite($0) }
        return ai + web + rewrite
    }

    private var filteredEntries: [SlashEntry] {
        guard !searchText.isEmpty else { return allEntries }
        let q = searchText.lowercased()
        return allEntries.filter { $0.matchesQuery(q) }
    }

    // MARK: - Body

    var body: some View {
        Group {
            if let engine = queryEngine {
                queryInputView(engine: engine)
            } else {
                commandListView
            }
        }
        .frame(width: 280)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }

    // MARK: Phase 1 — command selection

    private var commandListView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "slash.circle")
                    .foregroundStyle(.secondary)
                TextField("搜索 AI 模型或网页搜索...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
            }
            .padding(10)

            Divider()

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { idx, entry in
                        SlashEntryRow(entry: entry, isSelected: idx == selectedIndex)
                            .onTapGesture { activate(entry) }
                            .onHover { if $0 { selectedIndex = idx } }
                    }
                    if filteredEntries.isEmpty {
                        Text("未找到匹配项")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(12)
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 280)
        }
        .onKeyPress(.escape) { onDismiss(); return .handled }
        .onKeyPress(.downArrow) {
            selectedIndex = min(selectedIndex + 1, filteredEntries.count - 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            selectedIndex = max(selectedIndex - 1, 0)
            return .handled
        }
        .onKeyPress(.return) {
            if !filteredEntries.isEmpty { activate(filteredEntries[selectedIndex]) }
            return .handled
        }
    }

    // MARK: Phase 2 — query input

    @ViewBuilder
    private func queryInputView(engine: ExternalSearchEngine) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    queryEngine = nil
                    queryText = ""
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("返回")

                Image(systemName: engine.iconName)
                    .foregroundStyle(.secondary)
                Text("在 \(engine.name) 中搜索")
                    .font(.subheadline.bold())

                if isOptimizingQuery {
                    ProgressView()
                        .controlSize(.mini)
                        .padding(.leading, 4)
                    Text("AI 优化中…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(10)

            Divider()

            TextField("输入内容，按回车打开浏览器…", text: $queryText)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .padding(10)
                .disabled(isOptimizingQuery)
                .onSubmit {
                    Task { await submitQuery(for: engine) }
                }
        }
        .onKeyPress(.escape) {
            queryEngine = nil; queryText = ""; return .handled
        }
    }

    // MARK: - Helpers

    private func activate(_ entry: SlashEntry) {
        switch entry {
        case .aiChat(let item):
            onSelect(item.provider, item.mode)
        case .webSearch(let engine):
            queryEngine = engine
            queryText = ""
            selectedIndex = 0
        case .rewrite(let platform):
            onRewrite?(platform)
        }
    }

    private func submitQuery(for engine: ExternalSearchEngine) async {
        let q = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        isOptimizingQuery = true
        let finalQuery = await AIService.shared.optimizeSearchQuery(q, forEngine: engine.name)
        isOptimizingQuery = false
        onWebSearch?(engine, finalQuery)
        queryEngine = nil
        queryText = ""
    }
}

// MARK: - Unified Entry

enum SlashEntry: Identifiable {
    case aiChat(SlashCommandItem)
    case webSearch(ExternalSearchEngine)
    case rewrite(SocialPlatform)

    var id: String {
        switch self {
        case .aiChat(let i): return "ai-\(i.id)"
        case .webSearch(let e): return "web-\(e.id.uuidString)"
        case .rewrite(let p): return "rw-\(p.id.uuidString)"
        }
    }

    func matchesQuery(_ q: String) -> Bool {
        switch self {
        case .aiChat(let i):
            return i.title.lowercased().contains(q) ||
                   i.provider.name.lowercased().contains(q)
        case .webSearch(let e):
            return e.name.lowercased().contains(q) ||
                   e.slashCommand.lowercased().contains(q)
        case .rewrite(let p):
            return p.name.lowercased().contains(q) ||
                   p.slashCommand.lowercased().contains(q)
        }
    }
}

// MARK: - Entry Row

private struct SlashEntryRow: View {
    let entry: SlashEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            switch entry {
            case .aiChat(let item):
                Image(systemName: item.provider.iconName)
                    .font(.system(size: 16))
                    .foregroundStyle(Color(hex: item.provider.colorHex) ?? .accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color(hex: item.provider.colorHex)?.opacity(0.1) ?? .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(item.title).font(.subheadline.bold())
                        Image(systemName: item.mode.icon)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                if item.mode == .api && KeychainService.shared.hasAPIKey(for: item.provider.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }

            case .webSearch(let engine):
                Image(systemName: engine.iconName)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.name).font(.subheadline.bold())
                    Text("/\(engine.slashCommand)")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                let sc = engine.shortcutDisplayString
                if sc != "—" {
                    Text(sc)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

            case .rewrite(let platform):
                Image(systemName: platform.iconName)
                    .font(.system(size: 16))
                    .foregroundStyle(.purple)
                    .frame(width: 28, height: 28)
                    .background(Color.purple.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(platform.name).font(.subheadline.bold())
                    Text("/\(platform.slashCommand)")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                Text("改写")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? .blue.opacity(0.1) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

// MARK: - Slash Command Item (AI chat)

struct SlashCommandItem: Identifiable {
    let id: String
    let provider: LLMProvider
    let mode: ChatMode
    let title: String
    let subtitle: String

    static var allItems: [SlashCommandItem] {
        var items: [SlashCommandItem] = []
        for provider in LLMProvider.allProviders {
            if provider.supportsAPI {
                let hasKey = KeychainService.shared.hasAPIKey(for: provider.id)
                items.append(SlashCommandItem(
                    id: "\(provider.id)-api",
                    provider: provider,
                    mode: .api,
                    title: "\(provider.name) (API)",
                    subtitle: hasKey ? "已配置 API Key" : "需要配置 API Key"
                ))
            }
            items.append(SlashCommandItem(
                id: "\(provider.id)-web",
                provider: provider,
                mode: .web,
                title: "\(provider.name) (Web)",
                subtitle: "使用浏览器登录"
            ))
        }
        return items
    }
}
