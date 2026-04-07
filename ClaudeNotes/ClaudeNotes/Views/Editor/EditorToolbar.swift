import SwiftUI

struct EditorToolbar: View {
    @Binding var isPreview: Bool
    let wordCount: Int
    var shortcutSettings: ShortcutSettings
    var editorSettings: EditorSettings
    var onSlashCommand: (() -> Void)?
    var onFind: (() -> Void)?
    var onFindReplace: (() -> Void)?
    var onClaudeWrite: (() -> Void)?
    var isClaudeWriting: Bool = false
    var onMetadata: (() -> Void)?
    var onOutline: (() -> Void)?
    var isShowingOutline: Bool = false
    var onInsights: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
                // Mode toggle — single button, keyboard shortcut works in both modes
                let toggleBinding = shortcutSettings.binding(for: .togglePreview)
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { isPreview.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isPreview ? "eye.fill" : "pencil")
                            .font(.caption)
                        Text(isPreview ? "预览" : "编辑")
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(toggleBinding.swiftUIKey, modifiers: toggleBinding.swiftUIModifiers)
                .help("切换编辑/预览  \(toggleBinding.displayString)")

                // Editing mode toggle (doc / outline) — hidden in preview
                if !isPreview {
                    Divider().frame(height: 18)

                    HStack(spacing: 1) {
                        ForEach(EditorSettings.EditorMode.allCases, id: \.rawValue) { mode in
                            Button {
                                editorSettings.editorMode = mode
                            } label: {
                                Text(mode.displayName)
                                    .font(.caption)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(editorSettings.editorMode == mode
                                        ? Color.accentColor.opacity(0.18)
                                        : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                            .help(mode == .document ? "文档编辑模式" : "大纲编辑模式（Enter 自动创建列表项）")
                        }
                    }
                    .padding(1)
                    .background(.quaternary.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                }

                Divider().frame(height: 18)

                // Find / Find & Replace
                HStack(spacing: 4) {
                    Button { onFind?() } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("查找  \(shortcutSettings.binding(for: .findInNote).displayString)")

                    Button { onFindReplace?() } label: {
                        Image(systemName: "arrow.2.squarepath")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("查找与替换  \(shortcutSettings.binding(for: .findReplaceInNote).displayString)")
                }

                Divider().frame(height: 18)

                // AI
                Button {
                    onSlashCommand?()
                } label: {
                    HStack(spacing: 3) {
                        Text("/")
                            .font(.subheadline.bold().monospaced())
                        Text("AI")
                            .font(.caption)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("唤起 AI 助手")

                // Claude 续写
                Button {
                    onClaudeWrite?()
                } label: {
                    HStack(spacing: 3) {
                        if isClaudeWriting {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.caption)
                        }
                        Text(isClaudeWriting ? "续写中…" : "续写")
                            .font(.caption)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(isClaudeWriting ? Color.accentColor.opacity(0.15) : Color.clear)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .disabled(isClaudeWriting)
                .help("让 Claude 续写笔记  \(shortcutSettings.binding(for: .claudeWrite).displayString)（再按停止）")

                // Metadata generator
                Button {
                    onMetadata?()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "tag")
                            .font(.caption)
                        Text("元数据")
                            .font(.caption)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("AI 生成标签与元数据（Obsidian / Logseq 格式）")

                // AI Insights
                Button {
                    onInsights?()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "brain.head.profile")
                            .font(.caption)
                        Text("AI 分析")
                            .font(.caption)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("分析笔记、生成摘要与洞察")

                // Outline panel toggle
                let outlineBinding = shortcutSettings.binding(for: .toggleOutline)
                Button {
                    onOutline?()
                } label: {
                    Image(systemName: "list.bullet.indent")
                        .font(.caption)
                        .foregroundStyle(isShowingOutline ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(outlineBinding.swiftUIKey, modifiers: outlineBinding.swiftUIModifiers)
                .help("\(isShowingOutline ? "关闭" : "打开")大纲面板  \(outlineBinding.displayString)")

                Spacer()

                Text("\(wordCount) 字")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

// MARK: - Notification Extensions

extension Notification.Name {
    static let vaultSearchRequested = Notification.Name("vaultSearchRequested")
}
