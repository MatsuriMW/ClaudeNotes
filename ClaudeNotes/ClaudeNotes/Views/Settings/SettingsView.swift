import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AIProviderSettingsView()
                .tabItem {
                    Label("AI 提供商", systemImage: "cpu")
                }

            APIKeysSettingsView()
                .tabItem {
                    Label("API Keys", systemImage: "key")
                }

            EditorSettingsView()
                .tabItem {
                    Label("文本编辑器", systemImage: "textformat")
                }

            ShortcutSettingsView()
                .tabItem {
                    Label("快捷键", systemImage: "keyboard")
                }

            ExternalSearchSettingsView()
                .tabItem {
                    Label("外部搜索", systemImage: "arrow.up.right.circle")
                }

            PlatformRewriteSettingsView()
                .tabItem {
                    Label("AI 改写", systemImage: "sparkles")
                }

            AboutSettingsView()
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
        }
        .frame(width: 600, height: 620)
    }
}

// MARK: - API Keys Settings

private struct APIKeysSettingsView: View {
    @State private var providers = LLMProvider.allProviders.filter { $0.supportsAPI }

    var body: some View {
        Form {
            Section {
                Text("配置 API Key 后，可以在笔记中使用 API 模式与 AI 对话。\n不配置也可以使用 Web 登录模式。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(providers) { provider in
                APIKeyRow(provider: provider)
            }
        }
        .formStyle(.grouped)
    }
}

private struct APIKeyRow: View {
    let provider: LLMProvider

    @State private var apiKey = ""
    @State private var hasKey = false
    @State private var showKey = false
    @State private var message: String?
    @State private var isError = false

    private let keychain = KeychainService.shared

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: provider.iconName)
                        .foregroundStyle(Color(hex: provider.colorHex) ?? .accentColor)
                    Text(provider.name)
                        .font(.headline)

                    if hasKey {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }

                HStack {
                    if showKey {
                        TextField(provider.apiKeyPrefix, text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                    } else {
                        SecureField(provider.apiKeyPrefix, text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        showKey.toggle()
                    } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                    }
                    .help(showKey ? "隐藏" : "显示")
                }

                HStack(spacing: 8) {
                    Button("保存") { saveKey() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)

                    if hasKey {
                        Button("删除", role: .destructive) { deleteKey() }
                            .controlSize(.small)
                    }

                    if let msg = message {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(isError ? .red : .green)
                    }
                }
            }
        }
        .onAppear { loadKey() }
    }

    private func loadKey() {
        if let existing = keychain.loadAPIKey(for: provider.id) {
            apiKey = existing
            hasKey = true
        }
    }

    private func saveKey() {
        do {
            try keychain.saveAPIKey(apiKey.trimmingCharacters(in: .whitespaces), for: provider.id)
            hasKey = true
            message = "已保存"
            isError = false
            clearMessage()
        } catch {
            message = "保存失败"
            isError = true
            clearMessage()
        }
    }

    private func deleteKey() {
        do {
            try keychain.deleteAPIKey(for: provider.id)
            apiKey = ""
            hasKey = false
            message = "已删除"
            isError = false
            clearMessage()
        } catch {
            message = "删除失败"
            isError = true
            clearMessage()
        }
    }

    private func clearMessage() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run { message = nil }
        }
    }
}

// MARK: - About

private struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("ClaudeNotes")
                        .font(.title2.bold())

                    Text("一款支持 AI 的智能笔记应用。")
                        .foregroundStyle(.secondary)

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("支持的 AI 服务:")
                            .font(.subheadline.bold())

                        ForEach(LLMProvider.allProviders) { provider in
                            HStack(spacing: 6) {
                                Image(systemName: provider.iconName)
                                    .foregroundStyle(Color(hex: provider.colorHex) ?? .accentColor)
                                    .frame(width: 16)
                                Text(provider.name)
                                    .font(.subheadline)
                                if provider.supportsAPI {
                                    Text("API + Web")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.blue.opacity(0.1))
                                        .clipShape(Capsule())
                                } else {
                                    Text("Web")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.secondary.opacity(0.1))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("使用方式:")
                            .font(.subheadline.bold())
                        Text("• API 模式: 在设置中配置 API Key")
                            .font(.caption)
                        Text("• Web 模式: 直接登录 AI 服务的网页版")
                            .font(.caption)
                        Text("• 在编辑器中输入 / 唤起 AI 选择菜单")
                            .font(.caption)
                    }

                    Text("API Key 安全地存储在 macOS 钥匙串中。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AI Provider Settings

private struct AIProviderSettingsView: View {
    @State private var settings = AIProviderSettings.shared
    @State private var availableProviders = LLMProvider.allProviders.filter { $0.supportsAPI }

    var body: some View {
        Form {
            Section {
                Text("选择个人画像和每日简报的 AI 提供商。\n\n本地 Claude CLI：免费但需要安装 Claude Code\nAPI Keys：使用在 API Keys 标签页中配置的密钥")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 个人画像设置
            Section("个人画像分析") {
                Picker("提供商", selection: $settings.personaProviderMode) {
                    ForEach(AIProviderMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode as AIProviderMode)
                    }
                }
                .pickerStyle(.inline)

                Text(settings.personaProviderMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.personaProviderMode == .apiKey {
                    Picker("选择 API 服务", selection: Binding(
                        get: { settings.personaAPIProvider ?? "claude" },
                        set: { settings.personaAPIProvider = $0 }
                    )) {
                        ForEach(availableProviders) { provider in
                            Text(provider.name).tag(provider.id)
                        }
                    }
                }
            }

            // 每日简报设置
            Section("每日简报生成") {
                Picker("提供商", selection: $settings.inboxProviderMode) {
                    ForEach(AIProviderMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode as AIProviderMode)
                    }
                }
                .pickerStyle(.inline)

                Text(settings.inboxProviderMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.inboxProviderMode == .apiKey {
                    Picker("选择 API 服务", selection: Binding(
                        get: { settings.inboxAPIProvider ?? "claude" },
                        set: { settings.inboxAPIProvider = $0 }
                    )) {
                        ForEach(availableProviders) { provider in
                            Text(provider.name).tag(provider.id)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
