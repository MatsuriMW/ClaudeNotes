import SwiftUI
import SwiftData
import AppKit

struct NoteEditorView: View {
    @Bindable var note: Note
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = NoteEditorViewModel()
    @State private var isPreview = false
    @State private var showSlashCommand = false
    @State private var isClaudeWriting = false
    @State private var claudeWritingTask: Task<Void, Never>? = nil
    @State private var textViewHolder = TextViewHolder()
    @State private var showVersionHistory = false
    @State private var showMetadataGenerator = false
    @State private var showOutlinePanel = false
    @State private var showInsights = false
    @State private var versionTimerTask: Task<Void, Never>? = nil
    @FocusState private var isTitleFocused: Bool
    private let shortcutSettings = ShortcutSettings.shared
    private let editorSettings = EditorSettings.shared

    /// When set, the editor scrolls to and highlights the first match after opening.
    var highlightQuery: Binding<String?> = .constant(nil)

    /// Callback when user selects an LLM from slash command
    var onSlashCommand: ((LLMProvider, ChatMode) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                TextField("标题", text: $viewModel.title)
                    .textFieldStyle(.plain)
                    .font(.title)
                    .focused($isTitleFocused)
                    .onChange(of: viewModel.title) { _, _ in
                        viewModel.onTitleChanged()
                    }

                Spacer()

                // Version history button
                Button {
                    showVersionHistory = true
                } label: {
                    Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("历史版本")

                // File path indicator
                if let fileName = viewModel.fileName {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .font(.caption2)
                        Text(fileName)
                            .font(.caption)
                            .lineLimit(1)
                        if viewModel.hasUnsavedChanges {
                            Circle()
                                .fill(.orange)
                                .frame(width: 6, height: 6)
                                .help("有未保存的更改")
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 16)

            // Toolbar
            EditorToolbar(
                isPreview: $isPreview,
                wordCount: viewModel.content.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count,
                shortcutSettings: shortcutSettings,
                editorSettings: editorSettings,
                onSlashCommand: { showSlashCommand = true },
                onFind: { textViewHolder.textView?.showFindBar() },
                onFindReplace: { textViewHolder.textView?.showFindReplaceBar() },
                onClaudeWrite: { claudeContinueWriting() },
                isClaudeWriting: isClaudeWriting,
                onMetadata: { showMetadataGenerator = true },
                onOutline: { withAnimation { showOutlinePanel.toggle() } },
                isShowingOutline: showOutlinePanel,
                onInsights: { showInsights = true }
            )

            // Content area (optionally split with outline panel)
            if showOutlinePanel {
                HSplitView {
                    OutlinePanelView(
                        content: $viewModel.content,
                        onScrollToLine: { textViewHolder.scrollToLine($0) },
                        onContentChanged: { viewModel.onContentChanged() }
                    )
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
                    editorContentArea
                }
            } else {
                editorContentArea
            }
        }
        .background(.background)
        // ⌘R — focus the title field for quick rename
        .background {
            Button("") { isTitleFocused = true }
                .keyboardShortcut("r", modifiers: .command)
                .hidden()
        }
        .sheet(isPresented: $showVersionHistory) {
            VersionHistoryView(
                note: note,
                onRestore: { version in
                    viewModel.title = version.title
                    viewModel.content = version.content
                    viewModel.onContentChanged()
                    showVersionHistory = false
                },
                onDismiss: { showVersionHistory = false }
            )
        }
        .sheet(isPresented: $showMetadataGenerator) {
            MetadataGeneratorView(noteContent: viewModel.content) { updated in
                viewModel.content = updated
                viewModel.onContentChanged()
            }
        }
        .sheet(isPresented: $showInsights) {
            AIInsightsPanel(
                note: note,
                textViewHolder: textViewHolder,
                noteContent: viewModel.content,
                onInsert: { insertedContent, cursorOffset in
                    insertAtCursor(formatted: insertedContent, offset: cursorOffset)
                }
            )
        }
        .task(id: highlightQuery.wrappedValue) {
            guard let q = highlightQuery.wrappedValue else { return }
            // Brief delay: let NSTextView finish its initial layout pass
            try? await Task.sleep(for: .milliseconds(120))
            textViewHolder.jumpToFirstMatch(query: q)
            highlightQuery.wrappedValue = nil
        }
        .onAppear {
            viewModel.load(note: note)
            startVersionTimer()
        }
        .onChange(of: note.id) { oldID, _ in
            // Save fold state for the note we're leaving
            textViewHolder.textView?.saveState(for: oldID)
            saveVersionSnapshot()
            viewModel.saveImmediately()
            viewModel.load(note: note)
            isPreview = false
            showSlashCommand = false
            startVersionTimer()
        }
        .onChange(of: editorSettings.versionIntervalMinutes) { _, _ in
            startVersionTimer()
        }
        .onDisappear {
            textViewHolder.textView?.saveState(for: note.id)
            saveVersionSnapshot()
            viewModel.saveImmediately()
            versionTimerTask?.cancel()
        }
        // Listen for menu notifications
        .onReceive(NotificationCenter.default.publisher(for: .menuRevealInFinder)) { _ in
            revealInFinder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuOpenFile)) { _ in
            viewModel.openFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuSaveFile)) { _ in
            viewModel.saveToFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuSaveFileAs)) { _ in
            viewModel.saveToFile(saveAs: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuFormatAction)) { note in
            if let rawValue = note.object as? String,
               let action = ShortcutAction(rawValue: rawValue) {
                textViewHolder.applyAction(action)
            }
        }
    }

    @ViewBuilder
    private var editorContentArea: some View {
        ZStack(alignment: .bottomLeading) {
            if isPreview {
                MarkdownPreviewView(content: viewModel.content)
            } else {
                LayerEditorView(
                    text: $viewModel.content,
                    noteID: note.id,
                    shortcutSettings: shortcutSettings,
                    editorSettings: editorSettings,
                    holder: textViewHolder,
                    onTextChange: {
                        viewModel.onContentChanged()
                        detectSlashCommand()
                    },
                    onTogglePreview: {
                        withAnimation { isPreview.toggle() }
                    },
                    onClaudeWrite: {
                        claudeContinueWriting()
                    },
                    onRevealInFinder: viewModel.filePath != nil ? revealInFinder : nil,
                    outlineMode: editorSettings.editorMode == .outline,
                    typewriterMode: editorSettings.isTypewriterMode,
                    typewriterScrollFraction: editorSettings.typewriterScrollPosition.fraction ?? 0.5,
                    typewriterFocusMode: editorSettings.typewriterFocusMode,
                    typewriterMarkLine: editorSettings.typewriterMarkLine
                )
            }

            if showSlashCommand {
                SlashCommandPopup(
                    onSelect: { provider, mode in
                        showSlashCommand = false
                        removeTrailingSlash()
                        onSlashCommand?(provider, mode)
                    },
                    onWebSearch: { engine, query in
                        showSlashCommand = false
                        removeTrailingSlash()
                        if let url = engine.searchURL(for: query) {
                            NSWorkspace.shared.open(url)
                        }
                    },
                    onRewrite: { platform in
                        showSlashCommand = false
                        let source = extractBlockBeforeCursor()
                        removeTrailingSlash()
                        if let block = source, !block.isEmpty {
                            RewriteSession.shared.start(platform: platform, sourceText: block)
                        }
                    },
                    onDismiss: {
                        showSlashCommand = false
                    }
                )
                .padding(.leading, 20)
                .padding(.bottom, 20)
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottomLeading)))
            }
        }
    }

    /// Returns the paragraph or list block immediately before the line containing the cursor.
    /// Used by platform-rewrite commands to know what text to send to Claude.
    private func extractBlockBeforeCursor() -> String? {
        let ns = viewModel.content as NSString
        let len = ns.length
        let cursorLoc = min(textViewHolder.lastCursorLocation, len)

        // Find the start of the line the cursor is on (the "/" line)
        let slashLineStart = ns.lineRange(
            for: NSRange(location: max(0, cursorLoc - 1), length: 0)
        ).location

        guard slashLineStart > 0 else { return nil }

        // Text that precedes the "/" line, with trailing newlines stripped
        let before = ns.substring(to: slashLineStart)
            .replacingOccurrences(of: "\\n+$", with: "", options: .regularExpression)
        guard !before.isEmpty else { return nil }

        // Split by double newline → last block is the paragraph/list the user is in
        let blocks = before.components(separatedBy: "\n\n")
        let lastBlock = blocks.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return lastBlock.isEmpty ? nil : lastBlock
    }

    private func detectSlashCommand() {
        let text = viewModel.content
        guard text.hasSuffix("/") else {
            if showSlashCommand { showSlashCommand = false }
            return
        }

        let beforeSlash = text.dropLast()
        if beforeSlash.isEmpty || beforeSlash.hasSuffix("\n") {
            withAnimation(.easeOut(duration: 0.15)) {
                showSlashCommand = true
            }
        }
    }

    private func removeTrailingSlash() {
        if viewModel.content.hasSuffix("/") {
            viewModel.content.removeLast()
        }
    }

    /// Inserts `formatted` content at the current cursor position via TextViewHolder.
    /// If offset is provided (relative to current cursor), inserts there instead.
    private func insertAtCursor(formatted: String, offset: Int? = nil) {
        guard let tv = textViewHolder.textView else { return }
        let insertLoc: Int
        if let off = offset {
            insertLoc = min(textViewHolder.lastCursorLocation + off, (viewModel.content as NSString).length)
        } else {
            insertLoc = textViewHolder.lastCursorLocation
        }
        tv.insertText(formatted, replacementRange: NSRange(location: insertLoc, length: 0))
        viewModel.onContentChanged()
    }

    // MARK: - Version History

    private func saveVersionSnapshot() {
        let content = viewModel.content
        let title = viewModel.title
        guard !content.isEmpty else { return }

        let noteID = note.id
        let fetchDescriptor = FetchDescriptor<NoteVersion>(
            predicate: #Predicate { $0.noteID == noteID },
            sortBy: [SortDescriptor(\.savedAt, order: .reverse)]
        )
        let existing = (try? modelContext.fetch(fetchDescriptor)) ?? []
        if existing.first?.content == content { return }

        let version = NoteVersion(noteID: note.id, title: title, content: content)
        modelContext.insert(version)

        // Prune: keep at most maxVersionsPerNote versions per note
        let maxVersions = editorSettings.maxVersionsPerNote
        if existing.count >= maxVersions {
            let toDelete = existing.suffix(from: maxVersions - 1)
            for old in toDelete {
                modelContext.delete(old)
            }
        }

        // Auto-delete versions older than the configured threshold
        pruneOldVersions()
    }

    private func pruneOldVersions() {
        let days = editorSettings.autoDeleteVersionsDays
        guard days > 0 else { return }
        let cutoff = Date.now.addingTimeInterval(TimeInterval(-days * 86400))
        let descriptor = FetchDescriptor<NoteVersion>(
            predicate: #Predicate { $0.savedAt < cutoff }
        )
        let stale = (try? modelContext.fetch(descriptor)) ?? []
        for v in stale { modelContext.delete(v) }
    }

    private func startVersionTimer() {
        versionTimerTask?.cancel()
        let interval = editorSettings.versionIntervalMinutes
        guard interval > 0 else { return }
        versionTimerTask = Task { @MainActor in
            let seconds = UInt64(interval) * 60 * 1_000_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: seconds)
                guard !Task.isCancelled else { break }
                saveVersionSnapshot()
            }
        }
    }

    // MARK: - Claude 续写

    private func claudeContinueWriting() {
        // Toggle: if already writing, cancel and stop
        if isClaudeWriting {
            claudeWritingTask?.cancel()
            claudeWritingTask = nil
            isClaudeWriting = false
            return
        }

        guard let textView = textViewHolder.textView else { return }

        let isOutline = editorSettings.editorMode == .outline

        // Snapshot cursor location at keypress time
        let nsContent = viewModel.content as NSString
        let cursorLoc = min(textViewHolder.lastCursorLocation, nsContent.length)

        // Find the line the cursor is on
        let lineRange = nsContent.lineRange(for: NSRange(location: cursorLoc, length: 0))
        let lineText = nsContent.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lineText.isEmpty else { return }

        isClaudeWriting = true

        // Insertion point = start of the next line after cursor's current line
        let insertAt = lineRange.location + lineRange.length

        // Outline: indent + bullet under current item; Document: bare newline prefix (one blank line)
        let linePrefix: String
        let claudePrompt: String
        if isOutline {
            linePrefix = subItemPrefix(for: nsContent.substring(with: lineRange))
            claudePrompt = "请根据笔记的整体内容和风格，为【续写目标行】生成子要点续写，每行一个要点，保持原文语言和风格，不要重复原行，直接输出内容不要加任何解释："
        } else {
            linePrefix = ""
            claudePrompt = "请根据笔记的整体内容和风格，在【续写目标行】之后自然续写正文，段落流畅衔接，保持原文语言和风格，不要重复原内容，直接输出续写内容不要加任何解释："
        }

        // Write full document + target line to temp file so Claude has complete context
        let paraPath = NSTemporaryDirectory() + "claudenotes-para-\(UUID().uuidString).txt"
        let contextContent = "【笔记完整内容】\n\(viewModel.content)\n\n【续写目标行】\n\(lineText)"
        guard (try? contextContent.write(toFile: paraPath, atomically: true, encoding: .utf8)) != nil else {
            isClaudeWriting = false
            return
        }

        claudeWritingTask = Task { @MainActor in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            let escaped = claudePrompt.replacingOccurrences(of: "'", with: "'\\''")
            process.arguments = ["-l", "-c",
                "cat '\(paraPath)' | claude -p '\(escaped)'"
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            process.terminationHandler = { _ in }

            defer {
                if process.isRunning { process.terminate() }
                try? FileManager.default.removeItem(atPath: paraPath)
                isClaudeWriting = false
                claudeWritingTask = nil
            }

            do { try process.run() } catch { return }

            var offset = insertAt
            var buf = Data()
            // Document mode: prepend a blank separator line before the first streamed content
            var needsSeparator = !isOutline

            func flush(_ raw: String) {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                var toInsert = ""
                if needsSeparator {
                    toInsert = "\n"   // blank line between original text and continuation
                    needsSeparator = false
                }
                toInsert += linePrefix + trimmed + "\n"
                let currentOffset = offset
                textView.insertText(toInsert,
                    replacementRange: NSRange(location: currentOffset, length: 0))
                offset += (toInsert as NSString).length
            }

            do {
                for try await byte in pipe.fileHandleForReading.bytes {
                    buf.append(byte)
                    if byte == UInt8(ascii: "\n") {
                        if let line = String(data: buf, encoding: .utf8) {
                            buf.removeAll()
                            flush(line)
                        }
                    }
                }
            } catch {}

            // Flush any remaining partial line (no trailing newline from claude)
            if !buf.isEmpty, let line = String(data: buf, encoding: .utf8) {
                flush(line)
            }
        }
    }

    private func revealInFinder() {
        guard let path = viewModel.filePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Returns the sub-item bullet prefix for content generated under `paragraphText`.
    /// Inherits the parent's indentation and adds one level (2 spaces).
    private func subItemPrefix(for paragraphText: String) -> String {
        let firstLine = paragraphText
            .components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let leadingSpaces = firstLine.prefix(while: { $0 == " " }).count
        return String(repeating: " ", count: leadingSpaces + 2) + "- "
    }
}
