import SwiftUI

struct FileNoteEditorView: View {
    let fileNote: FileNote
    /// When set, the editor scrolls to and highlights the first match after loading.
    var highlightQuery: Binding<String?> = .constant(nil)
    /// When set, the editor scrolls to the specified line (0-indexed) after loading.
    var jumpToLine: Int? = nil
    /// When set, highlights the specific task text with yellow background
    var highlightTaskText: String? = nil
    /// Called after the file is renamed on disk with the new URL.
    var onRename: ((URL) -> Void)?
    @State private var content = ""
    @State private var isPreview = false
    @State private var isSaved = true
    @State private var showMetadataGenerator = false
    @State private var showOutlinePanel = false
    @State private var saveDebounce: Task<Void, Never>?
    @State private var textViewHolder = TextViewHolder()
    private let editorSettings = EditorSettings.shared
    private let shortcutSettings = ShortcutSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack(spacing: 8) {
                Image(systemName: fileNote.url.pathExtension.lowercased() == "md" ? "doc.text" : "doc")
                    .foregroundStyle(.secondary)
                Text(fileNote.displayTitle)
                    .font(.title)

                Spacer()

                if !isSaved {
                    Button {
                        saveDebounce?.cancel()
                        writeFile()
                    } label: {
                        Label("保存", systemImage: "square.and.arrow.down")
                    }
                    .keyboardShortcut("s")
                }

                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.caption2)
                    Text(fileNote.url.path)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !isSaved {
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
                .onTapGesture {
                    NSWorkspace.shared.activateFileViewerSelecting([fileNote.url])
                }
                .help("在 Finder 中显示")
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 16)

            // Full editor toolbar
            EditorToolbar(
                isPreview: $isPreview,
                wordCount: content.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count,
                shortcutSettings: shortcutSettings,
                editorSettings: editorSettings,
                onFind: { textViewHolder.textView?.showFindBar() },
                onFindReplace: { textViewHolder.textView?.showFindReplaceBar() },
                onMetadata: { showMetadataGenerator = true },
                onOutline: { withAnimation { showOutlinePanel.toggle() } },
                isShowingOutline: showOutlinePanel
            )

            // Content area (optionally split with outline panel)
            if showOutlinePanel {
                HSplitView {
                    OutlinePanelView(
                        content: $content,
                        onScrollToLine: { textViewHolder.scrollToLine($0) },
                        onContentChanged: { isSaved = false; scheduleAutoSave() }
                    )
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
                    fileEditorContent
                }
            } else {
                fileEditorContent
            }
        }
        .background(.background)
        // ⌘R — rename the current file
        .background {
            Button("") { renameCurrentFile() }
                .keyboardShortcut("r", modifiers: .command)
                .hidden()
        }
        .task(id: highlightQuery.wrappedValue) {
            guard let q = highlightQuery.wrappedValue else { return }
            // File content loads on onAppear; wait for NSTextView layout
            try? await Task.sleep(for: .milliseconds(150))
            textViewHolder.jumpToFirstMatch(query: q)
            highlightQuery.wrappedValue = nil
        }
        .sheet(isPresented: $showMetadataGenerator) {
            MetadataGeneratorView(noteContent: content) { updated in
                content = updated
                isSaved = false
                scheduleAutoSave()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuRevealInFinder)) { _ in
            NSWorkspace.shared.activateFileViewerSelecting([fileNote.url])
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuFormatAction)) { note in
            if let rawValue = note.object as? String,
               let action = ShortcutAction(rawValue: rawValue) {
                textViewHolder.applyAction(action)
            }
        }
        .onAppear { loadContent() }
        .onDisappear {
            saveDebounce?.cancel()
            if !isSaved { writeFile() }
        }
    }

    @ViewBuilder
    private var fileEditorContent: some View {
        if isPreview {
            MarkdownPreviewView(content: content)
        } else {
            MarkdownTextView(
                text: $content,
                noteID: fileNote.stableID,
                shortcutSettings: shortcutSettings,
                editorSettings: editorSettings,
                holder: textViewHolder,
                onTextChange: {
                    isSaved = false
                    scheduleAutoSave()
                },
                onTogglePreview: {
                    withAnimation { isPreview.toggle() }
                },
                onRevealInFinder: { NSWorkspace.shared.activateFileViewerSelecting([fileNote.url]) },
                outlineMode: editorSettings.editorMode == .outline,
                typewriterMode: editorSettings.isTypewriterMode,
                typewriterScrollFraction: editorSettings.typewriterScrollPosition.fraction ?? 0.5,
                typewriterFocusMode: editorSettings.typewriterFocusMode,
                typewriterMarkLine: editorSettings.typewriterMarkLine,
                jumpToLine: jumpToLine,
                highlightTaskText: highlightTaskText
            )
        }
    }

    private func renameCurrentFile() {
        let alert = NSAlert()
        alert.messageText = "重命名文件"
        alert.informativeText = "请输入「\(fileNote.displayTitle)」的新名称："
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = fileNote.displayTitle
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }

        if let newURL = LibraryManager.shared.renameFile(url: fileNote.url, newName: newName) {
            onRename?(newURL)
        }
    }

    private func loadContent() {
        content = (try? String(contentsOf: fileNote.url, encoding: .utf8)) ?? ""
        isSaved = true
    }

    private func writeFile() {
        try? content.write(to: fileNote.url, atomically: true, encoding: .utf8)
        isSaved = true
    }

    private func scheduleAutoSave() {
        saveDebounce?.cancel()
        saveDebounce = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await MainActor.run { writeFile() }
        }
    }
}
