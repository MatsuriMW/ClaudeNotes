import SwiftUI
import AppKit
import SwiftData

struct AIChatPanel: View {
    let note: Note
    @Environment(\.modelContext) private var modelContext
    @Binding var selectedProvider: LLMProvider?
    @Binding var chatMode: ChatMode
    /// Called after a note is created from the export, with its UUID.
    var onExported: ((UUID) -> Void)?

    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasInitialAnalysis = false

    // Web mode state
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var webIsLoading = false
    @State private var currentURL = ""
    @State private var goBackTrigger = false
    @State private var goForwardTrigger = false
    @State private var reloadTrigger = false
    @State private var webInjectStatus: WebInjectStatus = .idle
    @State private var webInputText = ""
    @State private var exportToast: String?

    private let aiService = AIService.shared

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            Divider()

            if let provider = selectedProvider {
                switch chatMode {
                case .api:
                    if provider.supportsAPI {
                        apiChatView(provider: provider)
                    } else {
                        noAPIView(provider: provider)
                    }
                case .web:
                    webChatView(provider: provider)
                }
            } else {
                providerSelectionView
            }
        }
        .background(.background.secondary)
        .onChange(of: note.id) { _, _ in
            resetChat()
        }
        .onChange(of: selectedProvider) { _, _ in
            resetChat()
        }
        .onChange(of: chatMode) { _, _ in
            // Don't reset chat when switching modes, keep history
        }
    }

    // MARK: - Header

    private var panelHeader: some View {
        VStack(spacing: 8) {
            HStack {
                Label("AI 助手", systemImage: "brain")
                    .font(.headline)

                Spacer()

                // Export to note
                Button {
                    exportToNote()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("导出对话为笔记")
                .disabled(messages.isEmpty)
                .opacity(messages.isEmpty ? 0.4 : 1)
            }

            HStack(spacing: 8) {
                // Provider selector
                Menu {
                    ForEach(LLMProvider.allProviders) { provider in
                        Button {
                            selectedProvider = provider
                        } label: {
                            Label(provider.name, systemImage: provider.iconName)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if let provider = selectedProvider {
                            Image(systemName: provider.iconName)
                                .foregroundStyle(Color(hex: provider.colorHex) ?? .accentColor)
                            Text(provider.name)
                                .font(.subheadline.bold())
                        } else {
                            Image(systemName: "questionmark.circle")
                            Text("选择模型")
                                .font(.subheadline)
                        }
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Mode toggle
                Picker("", selection: $chatMode) {
                    ForEach(ChatMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.icon)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)

                Spacer()
            }

            // Export toast
            if let toast = exportToast {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption2)
                    Text(toast)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - API Chat View

    private func apiChatView(provider: LLMProvider) -> some View {
        VStack(spacing: 0) {
            // Check if API key is configured
            if !KeychainService.shared.hasAPIKey(for: provider.id) {
                noKeyView(provider: provider)
            } else {
                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if messages.isEmpty && !isLoading {
                                initialPromptView(provider: provider)
                            }

                            ForEach(messages) { message in
                                MessageBubble(message: message, providerColor: provider.colorHex)
                                    .id(message.id)
                            }

                            if isLoading {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("\(provider.name) 正在思考...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .id("loading")
                            }

                            if let error = errorMessage {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.yellow)
                                    Text(error)
                                        .font(.caption)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.yellow.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .padding(.horizontal, 12)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .onChange(of: messages.count) { _, _ in
                        withAnimation {
                            if let lastId = messages.last?.id {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            } else {
                                proxy.scrollTo("loading", anchor: .bottom)
                            }
                        }
                    }
                }

                Divider()

                // Input bar
                apiInputBar(provider: provider)
            }
        }
    }

    private func initialPromptView(provider: LLMProvider) -> some View {
        VStack(spacing: 12) {
            Image(systemName: provider.iconName)
                .font(.system(size: 32))
                .foregroundStyle(Color(hex: provider.colorHex) ?? .accentColor)

            Text("使用 \(provider.name) 分析笔记")
                .font(.subheadline.bold())

            Text("点击下方按钮发送当前笔记内容，或输入自定义问题")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await sendNoteForAnalysis(provider: provider) }
            } label: {
                Label("发送笔记内容", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
    }

    private func apiInputBar(provider: LLMProvider) -> some View {
        HStack(spacing: 8) {
            // Send note content button
            Button {
                Task { await sendNoteForAnalysis(provider: provider) }
            } label: {
                Image(systemName: "doc.text")
            }
            .buttonStyle(.borderless)
            .help("发送笔记内容给 AI")
            .disabled(isLoading)

            TextField("输入问题或补充指令...", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)
                .onSubmit {
                    guard !inputText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    Task { await sendFollowUp(provider: provider) }
                }

            Button {
                Task { await sendFollowUp(provider: provider) }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
        }
        .padding(10)
        .background(.bar)
    }

    // MARK: - Web Chat View

    private func webChatView(provider: LLMProvider) -> some View {
        VStack(spacing: 0) {
            // Top action bar
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    // Send note content to web chat
                    Button {
                        Task { await injectNoteToWebChat(provider: provider) }
                    } label: {
                        Label("发送笔记到对话", systemImage: "paperplane.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("将笔记内容自动填入对话框")
                    .disabled(note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    // Send note + auto-click send
                    Button {
                        Task { await injectAndSend(provider: provider) }
                    } label: {
                        Label("发送并提交", systemImage: "arrow.up.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("填入笔记内容并自动点击发送按钮")

                    Spacer()

                    // Copy as fallback
                    Button {
                        copyNoteToClipboard()
                        webInjectStatus = .copied
                        clearStatusAfterDelay()
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("复制笔记内容到剪贴板（手动粘贴）")

                    // Mini navigation
                    HStack(spacing: 4) {
                        Button { goBackTrigger.toggle() } label: {
                            Image(systemName: "chevron.left")
                                .font(.caption)
                        }
                        .disabled(!canGoBack)
                        Button { goForwardTrigger.toggle() } label: {
                            Image(systemName: "chevron.right")
                                .font(.caption)
                        }
                        .disabled(!canGoForward)
                        Button { reloadTrigger.toggle() } label: {
                            Image(systemName: webIsLoading ? "xmark" : "arrow.clockwise")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.borderless)
                }

                // Custom prompt input
                HStack(spacing: 6) {
                    TextField("自定义提示词（可选，附加在笔记内容后）", text: $webInputText)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)

                    if !webInputText.isEmpty {
                        Button {
                            Task { await injectCustomPrompt(provider: provider) }
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.subheadline)
                        }
                        .buttonStyle(.borderless)
                        .help("发送笔记内容 + 自定义提示词")
                    }
                }

                // Status message
                if webInjectStatus != .idle {
                    webStatusBar
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            // Web view
            LLMWebView(
                provider: provider,
                canGoBack: $canGoBack,
                canGoForward: $canGoForward,
                isLoading: $webIsLoading,
                currentURL: $currentURL,
                goBackTrigger: goBackTrigger,
                goForwardTrigger: goForwardTrigger,
                reloadTrigger: reloadTrigger
            )
        }
    }

    @ViewBuilder
    private var webStatusBar: some View {
        HStack(spacing: 6) {
            switch webInjectStatus {
            case .idle:
                EmptyView()
            case .injecting:
                ProgressView()
                    .controlSize(.mini)
                Text("正在填入内容...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption2)
                Text("已填入对话框")
                    .font(.caption2)
                    .foregroundStyle(.green)
            case .copied:
                Image(systemName: "doc.on.clipboard.fill")
                    .foregroundStyle(.blue)
                    .font(.caption2)
                Text("已复制到剪贴板，请手动粘贴")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption2)
                Text("填入失败（\(reason)），已复制到剪贴板")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .transition(.opacity)
    }

    // MARK: - No API Key View

    private func noKeyView(provider: LLMProvider) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "key")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text("未配置 \(provider.name) API Key")
                .font(.subheadline.bold())

            Text("请在设置中添加 API Key，\n或切换到 Web 登录模式")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("打开设置") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .buttonStyle(.bordered)

                Button("切换到 Web 模式") {
                    chatMode = .web
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func noAPIView(provider: LLMProvider) -> some View {
        VStack(spacing: 16) {
            Image(systemName: provider.iconName)
                .font(.system(size: 36))
                .foregroundStyle(Color(hex: provider.colorHex) ?? .accentColor)

            Text("\(provider.name) 暂不支持 API 模式")
                .font(.subheadline.bold())

            Button("切换到 Web 模式") {
                chatMode = .web
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Provider Selection View

    private var providerSelectionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "brain")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text("选择一个 AI 模型")
                .font(.subheadline.bold())

            Text("在编辑器中输入 / 唤起选择菜单\n或在上方下拉框中选择")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 6) {
                ForEach(LLMProvider.allProviders) { provider in
                    Button {
                        selectedProvider = provider
                    } label: {
                        HStack {
                            Image(systemName: provider.iconName)
                                .foregroundStyle(Color(hex: provider.colorHex) ?? .accentColor)
                                .frame(width: 20)
                            Text(provider.name)
                                .font(.subheadline)
                            Spacer()
                            if provider.supportsAPI && KeychainService.shared.hasAPIKey(for: provider.id) {
                                Image(systemName: "key.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.quaternary.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 200)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Web Injection Actions

    private func injectNoteToWebChat(provider: LLMProvider) async {
        let content = note.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        webInjectStatus = .injecting
        let webView = WebViewStore.shared.webView(for: provider)

        let textToInject = buildWebPrompt(noteContent: content, customPrompt: nil)
        let result = await WebChatInjector.injectNoteContent(textToInject, into: webView, provider: provider)

        if result.isSuccess {
            webInjectStatus = .success
        } else {
            // Fallback: copy to clipboard
            copyNoteToClipboard()
            webInjectStatus = .failed("请手动粘贴")
        }
        clearStatusAfterDelay()
    }

    private func injectAndSend(provider: LLMProvider) async {
        await injectNoteToWebChat(provider: provider)

        // Wait for injection to settle, then click send
        if case .success = webInjectStatus {
            try? await Task.sleep(for: .milliseconds(500))
            let webView = WebViewStore.shared.webView(for: provider)
            let sendScript = WebChatInjector.buildSendButtonScript(providerId: provider.id)
            _ = try? await webView.evaluateJavaScript(sendScript)
        }
    }

    private func injectCustomPrompt(provider: LLMProvider) async {
        let content = note.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = webInputText.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty || !prompt.isEmpty else { return }

        webInjectStatus = .injecting
        let webView = WebViewStore.shared.webView(for: provider)

        let textToInject = buildWebPrompt(noteContent: content, customPrompt: prompt)
        let result = await WebChatInjector.injectNoteContent(textToInject, into: webView, provider: provider)

        if result.isSuccess {
            webInjectStatus = .success
            webInputText = ""
            // Auto-send
            try? await Task.sleep(for: .milliseconds(500))
            let sendScript = WebChatInjector.buildSendButtonScript(providerId: provider.id)
            _ = try? await webView.evaluateJavaScript(sendScript)
        } else {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(textToInject, forType: .string)
            webInjectStatus = .failed("请手动粘贴")
        }
        clearStatusAfterDelay()
    }

    private func buildWebPrompt(noteContent: String, customPrompt: String?) -> String {
        var text = ""
        if let personaContext = PersonaStore.shared.systemPromptContext {
            text += personaContext + "\n\n"
        }
        text += "以下是我正在写的笔记内容：\n\n---\n\(noteContent)\n---\n"
        if let prompt = customPrompt, !prompt.isEmpty {
            text += "\n\(prompt)"
        } else {
            text += "\n请帮我分析这篇笔记，如果里面有问题请回答，并提供补充建议。"
        }
        return text
    }

    private func clearStatusAfterDelay() {
        Task {
            try? await Task.sleep(for: .seconds(4))
            await MainActor.run {
                withAnimation { webInjectStatus = .idle }
            }
        }
    }

    // MARK: - API Actions

    private func sendNoteForAnalysis(provider: LLMProvider) async {
        guard !note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "笔记内容为空"
            return
        }

        let noteSnippet = String(note.content.prefix(100))
        let userMsg = ChatMessage(role: .user, content: "📝 [发送了笔记内容]\n\(noteSnippet)\(note.content.count > 100 ? "..." : "")")
        messages.append(userMsg)
        isLoading = true
        errorMessage = nil

        do {
            let response = try await aiService.chat(
                noteContent: note.content,
                userPrompt: nil,
                provider: provider,
                history: []
            )
            messages.append(ChatMessage(role: .assistant, content: response))
            hasInitialAnalysis = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func sendFollowUp(provider: LLMProvider) async {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }

        messages.append(ChatMessage(role: .user, content: text))
        inputText = ""
        isLoading = true
        errorMessage = nil

        do {
            let response: String
            if !hasInitialAnalysis {
                // First message, include note context
                response = try await aiService.chat(
                    noteContent: note.content,
                    userPrompt: text,
                    provider: provider,
                    history: Array(messages.dropLast()) // exclude the message we just added
                )
                hasInitialAnalysis = true
            } else {
                response = try await aiService.followUp(
                    message: text,
                    provider: provider,
                    history: messages
                )
            }
            messages.append(ChatMessage(role: .assistant, content: response))
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func copyNoteToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(note.content, forType: .string)
    }

    // MARK: - Export

    private func exportToNote() {
        guard !messages.isEmpty else { return }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateStr = dateFormatter.string(from: Date())
        let providerName = selectedProvider?.name ?? "AI"
        var lines: [String] = [
            "# \(providerName) 对话导出 · \(dateStr)",
            "",
            "---",
            ""
        ]

        for msg in messages {
            let timeStr = msg.timestamp.formatted(date: .omitted, time: .shortened)
            let roleLabel = msg.role == .user ? "用户" : providerName
            lines.append("### \(timeStr) · \(roleLabel)")
            lines.append("")
            lines.append(msg.content)
            lines.append("")
            lines.append("---")
            lines.append("")
        }

        let formatted = lines.joined(separator: "\n")
        let newNote = Note(title: "\(providerName) 对话导出 · \(dateStr)", content: formatted)
        modelContext.insert(newNote)
        onExported?(newNote.id)

        exportToast = "已导出为笔记"
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { exportToast = nil }
        }
    }

    private func resetChat() {
        messages = []
        errorMessage = nil
        hasInitialAnalysis = false
        inputText = ""
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: ChatMessage
    let providerColor: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .assistant {
                Circle()
                    .fill(Color(hex: providerColor) ?? .blue)
                    .frame(width: 24, height: 24)
                    .overlay {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                    }
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(message.role == .user ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)

            if message.role == .user {
                Circle()
                    .fill(.secondary.opacity(0.3))
                    .frame(width: 24, height: 24)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - Web Inject Status

enum WebInjectStatus: Equatable {
    case idle
    case injecting
    case success
    case copied
    case failed(String)
}
