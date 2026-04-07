import SwiftUI
import AppKit

// MARK: - Data Model

struct OutlineEntry: Identifiable {
    /// Stable across re-renders as long as content doesn't change structure.
    var id: Int { lineIndex }
    let level: Int
    let text: String
    let lineIndex: Int
}

// MARK: - Panel

struct OutlinePanelView: View {
    @Binding var content: String
    var onScrollToLine: (Int) -> Void = { _ in }
    var onContentChanged: () -> Void = {}

    @State private var searchText = ""
    @State private var maxLevel: Double = 6
    /// lineIndex of the entry currently in edit mode, or nil.
    @State private var editingLineIndex: Int? = nil
    @State private var editingText = ""
    /// lineIndex of the row the mouse is currently hovering over (used for ⌘R shortcut).
    @State private var hoveredLineIndex: Int? = nil

    private var allHeadings: [OutlineEntry] {
        Self.parseHeadings(from: content)
    }

    private var actualMaxLevel: Int {
        allHeadings.map { $0.level }.max() ?? 1
    }

    private var filteredHeadings: [OutlineEntry] {
        let effectiveMax = Int(min(maxLevel, Double(actualMaxLevel)))
        let byLevel = allHeadings.filter { $0.level <= effectiveMax }
        guard !searchText.isEmpty else { return byLevel }
        return byLevel.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            levelSlider
            Divider()
            headingList
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Sub-views

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            TextField("搜索大纲", text: $searchText)
                .textFieldStyle(.plain)
                .font(.caption)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private var levelSlider: some View {
        HStack(spacing: 6) {
            Text("H1")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            Slider(value: $maxLevel, in: 1...max(1.0, Double(actualMaxLevel)), step: 1)
                .onChange(of: actualMaxLevel) { _, newMax in
                    if maxLevel > Double(newMax) { maxLevel = Double(newMax) }
                }
            Text("H\(Int(min(maxLevel, Double(actualMaxLevel))))")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar.opacity(0.6))
    }

    @ViewBuilder
    private var headingList: some View {
        if filteredHeadings.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "list.bullet.indent")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
                Text(allHeadings.isEmpty ? "文档中暂无标题" : "无匹配结果")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredHeadings) { entry in
                        OutlineRow(
                            entry: entry,
                            isEditing: editingLineIndex == entry.lineIndex,
                            editingText: $editingText,
                            onTap: { onScrollToLine(entry.lineIndex) },
                            onStartEdit: {
                                editingLineIndex = entry.lineIndex
                                editingText = entry.text
                            },
                            onCommitEdit: { commitEdit(entry: entry) },
                            onCancelEdit: { editingLineIndex = nil },
                            onIndent: { changeLevel(entry: entry, delta: +1) },
                            onDedent: { changeLevel(entry: entry, delta: -1) },
                            onIndentEdit: { commitAndChangeLevel(entry: entry, delta: -1) },
                            onDedentEdit: { commitAndChangeLevel(entry: entry, delta: +1) },
                            onMoveUp: { moveSection(entry: entry, direction: -1) },
                            onMoveDown: { moveSection(entry: entry, direction: +1) },
                            onHoverChanged: { hovered in
                                hoveredLineIndex = hovered ? entry.lineIndex : nil
                            },
                            onDropFrom: { srcLineIndex in
                                moveSectionBefore(sourceLineIndex: srcLineIndex,
                                                  targetLineIndex: entry.lineIndex)
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
            // Hidden ⌘R rename shortcut — active when a row is hovered and not already editing
            .overlay(alignment: .topLeading) {
                if let li = hoveredLineIndex,
                   let entry = filteredHeadings.first(where: { $0.lineIndex == li }),
                   editingLineIndex == nil {
                    Button("") {
                        editingLineIndex = entry.lineIndex
                        editingText = entry.text
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                }
            }
        }
    }

    // MARK: - Logic

    static func parseHeadings(from content: String) -> [OutlineEntry] {
        content.components(separatedBy: "\n").enumerated().compactMap { i, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { return nil }
            let hashCount = trimmed.prefix(while: { $0 == "#" }).count
            guard hashCount <= 6 else { return nil }
            let afterHashes = String(trimmed.dropFirst(hashCount))
            guard afterHashes.hasPrefix(" ") else { return nil }
            let text = afterHashes.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return OutlineEntry(level: hashCount, text: text, lineIndex: i)
        }
    }

    private func commitEdit(entry: OutlineEntry) {
        let newText = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newText.isEmpty else { editingLineIndex = nil; return }
        var lines = content.components(separatedBy: "\n")
        guard entry.lineIndex < lines.count else { editingLineIndex = nil; return }
        lines[entry.lineIndex] = String(repeating: "#", count: entry.level) + " " + newText
        content = lines.joined(separator: "\n")
        onContentChanged()
        editingLineIndex = nil
    }

    /// Commits the current edit text and simultaneously changes the heading level.
    /// Called by Tab / Shift+Tab inside the edit text field.
    private func commitAndChangeLevel(entry: OutlineEntry, delta: Int) {
        let newText = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalText = newText.isEmpty ? entry.text : newText
        let newLevel = max(1, min(6, entry.level + delta))
        var lines = content.components(separatedBy: "\n")
        guard entry.lineIndex < lines.count else { editingLineIndex = nil; return }
        lines[entry.lineIndex] = String(repeating: "#", count: newLevel) + " " + finalText
        content = lines.joined(separator: "\n")
        onContentChanged()
        editingLineIndex = nil
    }

    /// Returns the line index just past the last line belonging to this heading's section.
    /// A section ends when a heading of equal or lower level number (higher importance) appears.
    private func sectionEndLine(lines: [String], from startLine: Int, level: Int) -> Int {
        var i = startLine + 1
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" }).count
                guard hashes >= 1, hashes <= 6 else { i += 1; continue }
                let rest = String(trimmed.dropFirst(hashes))
                guard rest.isEmpty || rest.hasPrefix(" ") else { i += 1; continue }
                if hashes <= level { break }
            }
            i += 1
        }
        return i
    }

    /// Moves a heading section (heading line + all sub-content) up or down past the adjacent
    /// sibling heading at the same or higher importance level. direction: -1 = up, +1 = down.
    private func moveSection(entry: OutlineEntry, direction: Int) {
        let lines = content.components(separatedBy: "\n")
        let sectionStart = entry.lineIndex
        let sectionEnd = sectionEndLine(lines: lines, from: sectionStart, level: entry.level)
        let sectionLines = Array(lines[sectionStart..<sectionEnd])

        if direction < 0 {
            // Move up: find the start of the preceding sibling/parent heading
            var prevStart: Int? = nil
            var i = sectionStart - 1
            while i >= 0 {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") {
                    let hashes = trimmed.prefix(while: { $0 == "#" }).count
                    guard hashes >= 1, hashes <= 6 else { i -= 1; continue }
                    let rest = String(trimmed.dropFirst(hashes))
                    guard rest.isEmpty || rest.hasPrefix(" ") else { i -= 1; continue }
                    if hashes <= entry.level { prevStart = i; break }
                }
                i -= 1
            }
            guard let prev = prevStart else { return }
            let prevLines = Array(lines[prev..<sectionStart])
            var newLines = Array(lines[0..<prev])
            newLines += sectionLines
            newLines += prevLines
            newLines += Array(lines[sectionEnd...])
            content = newLines.joined(separator: "\n")
            onContentChanged()
        } else {
            // Move down: the next section starts at sectionEnd
            guard sectionEnd < lines.count else { return }
            // Verify the next line is a heading at same or higher importance
            let nextTrimmed = lines[sectionEnd].trimmingCharacters(in: .whitespaces)
            guard nextTrimmed.hasPrefix("#") else { return }
            let nextHashes = nextTrimmed.prefix(while: { $0 == "#" }).count
            guard nextHashes >= 1, nextHashes <= 6 else { return }
            let nextRest = String(nextTrimmed.dropFirst(nextHashes))
            guard nextRest.isEmpty || nextRest.hasPrefix(" ") else { return }
            guard nextHashes <= entry.level else { return }
            let nextSectionEnd = sectionEndLine(lines: lines, from: sectionEnd, level: nextHashes)
            let nextLines = Array(lines[sectionEnd..<nextSectionEnd])
            var newLines = Array(lines[0..<sectionStart])
            newLines += nextLines
            newLines += sectionLines
            newLines += Array(lines[nextSectionEnd...])
            content = newLines.joined(separator: "\n")
            onContentChanged()
        }
    }

    /// Drag-and-drop reorder: moves the source section to just before the target section.
    private func moveSectionBefore(sourceLineIndex: Int, targetLineIndex: Int) {
        guard sourceLineIndex != targetLineIndex else { return }
        guard let sourceEntry = allHeadings.first(where: { $0.lineIndex == sourceLineIndex }),
              let targetEntry = allHeadings.first(where: { $0.lineIndex == targetLineIndex }) else { return }
        let srcStart = sourceEntry.lineIndex
        let srcEnd   = sectionEndLine(lines: content.components(separatedBy: "\n"),
                                      from: srcStart, level: sourceEntry.level)
        var lines = content.components(separatedBy: "\n")
        let srcSection = Array(lines[srcStart..<srcEnd])
        lines.removeSubrange(srcStart..<srcEnd)
        var tgtStart = targetEntry.lineIndex
        if tgtStart > srcStart { tgtStart -= (srcEnd - srcStart) }
        tgtStart = max(0, min(lines.count, tgtStart))
        lines.insert(contentsOf: srcSection, at: tgtStart)
        content = lines.joined(separator: "\n")
        onContentChanged()
    }

    private func changeLevel(entry: OutlineEntry, delta: Int) {
        let newLevel = max(1, min(6, entry.level + delta))
        guard newLevel != entry.level else { return }
        var lines = content.components(separatedBy: "\n")
        guard entry.lineIndex < lines.count else { return }
        lines[entry.lineIndex] = String(repeating: "#", count: newLevel) + " " + entry.text
        content = lines.joined(separator: "\n")
        onContentChanged()
        editingLineIndex = nil
    }
}

// MARK: - Row

private struct OutlineRow: View {
    let entry: OutlineEntry
    let isEditing: Bool
    @Binding var editingText: String
    var onTap: () -> Void
    var onStartEdit: () -> Void
    var onCommitEdit: () -> Void
    var onCancelEdit: () -> Void
    /// Level change from normal-row hover buttons (no text to commit).
    var onIndent: () -> Void
    var onDedent: () -> Void
    /// Level change from edit-mode Tab/Shift+Tab (commits current text first).
    var onIndentEdit: () -> Void
    var onDedentEdit: () -> Void
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onHoverChanged: (Bool) -> Void = { _ in }
    /// Called when another heading (identified by its lineIndex) is dropped onto this row.
    var onDropFrom: (Int) -> Void = { _ in }

    @State private var isHovered = false
    @State private var isDropTarget = false

    private var indent: CGFloat { CGFloat((entry.level - 1) * 12) }

    private var rowFont: Font {
        switch entry.level {
        case 1: return .system(size: 13, weight: .semibold)
        case 2: return .system(size: 12, weight: .medium)
        case 3: return .system(size: 12)
        default: return .system(size: 11)
        }
    }

    private var rowColor: Color {
        switch entry.level {
        case 1, 2: return .primary
        case 3: return Color(nsColor: .labelColor).opacity(0.85)
        default: return .secondary
        }
    }

    var body: some View {
        if isEditing {
            editRow
        } else {
            normalRow
        }
    }

    private var normalRow: some View {
        HStack(spacing: 4) {
            if indent > 0 { Spacer().frame(width: indent) }

            if entry.level > 1 {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 2, height: 10)
            }

            Text(entry.text)
                .font(rowFont)
                .foregroundStyle(rowColor)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if isHovered {
                HStack(spacing: 2) {
                    Button { onMoveUp() } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("上移段落")

                    Button { onMoveDown() } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("下移段落")

                    Divider().frame(height: 10)

                    Button { onDedent() } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(entry.level <= 1 ? Color.secondary.opacity(0.3) : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("标题升级  H\(entry.level) → H\(max(1, entry.level - 1))")
                    .disabled(entry.level <= 1)

                    Button { onIndent() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(entry.level >= 6 ? Color.secondary.opacity(0.3) : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("标题降级  H\(entry.level) → H\(min(6, entry.level + 1))")
                    .disabled(entry.level >= 6)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .background(isHovered ? Color.secondary.opacity(0.07) : Color.clear)
        .overlay(alignment: .top) {
            if isDropTarget {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onStartEdit() }
        .onTapGesture(count: 1) { onTap() }
        .onHover { v in isHovered = v; onHoverChanged(v) }
        .draggable(String(entry.lineIndex))
        .dropDestination(for: String.self) { items, _ in
            guard let src = items.first.flatMap(Int.init) else { return false }
            onDropFrom(src)
            return true
        } isTargeted: { isDropTarget = $0 }
        .contextMenu {
            Button("跳转到此处") { onTap() }
            Button("编辑标题") { onStartEdit() }
            Divider()
            Button("上移段落") { onMoveUp() }
            Button("下移段落") { onMoveDown() }
            Divider()
            Button("标题升级  H\(entry.level) → H\(max(1, entry.level - 1))") { onDedent() }
                .disabled(entry.level <= 1)
            Button("标题降级  H\(entry.level) → H\(min(6, entry.level + 1))") { onIndent() }
                .disabled(entry.level >= 6)
        }
    }

    private var editRow: some View {
        HStack(spacing: 6) {
            if indent > 0 { Spacer().frame(width: indent) }

            Text(String(repeating: "#", count: entry.level))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(minWidth: 14, alignment: .leading)

            AutoSelectTextField(
                text: $editingText,
                onCommit: onCommitEdit,
                onCancel: onCancelEdit,
                onTab: onIndentEdit,
                onShiftTab: onDedentEdit
            )
            .font(rowFont)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
    }
}

// MARK: - Auto-Select Text Field

/// NSTextField that becomes first responder with all text selected on appear.
/// Tab → onTab (heading level +1 + commit), Shift+Tab → onShiftTab (level −1 + commit).
private struct AutoSelectTextField: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void
    var onCancel: () -> Void
    var onTab: () -> Void = {}
    var onShiftTab: () -> Void = {}

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.delegate = context.coordinator
        tf.isBordered = true
        tf.bezelStyle = .roundedBezel
        tf.focusRingType = .default
        tf.stringValue = text
        DispatchQueue.main.async {
            guard let window = tf.window else { return }
            window.makeFirstResponder(tf)
            tf.currentEditor()?.selectAll(nil)
        }
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        guard tf.currentEditor() == nil else { return }
        tf.stringValue = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AutoSelectTextField
        /// Tracks whether a key command (Enter/Esc/Tab) already handled the end-of-edit,
        /// so that the subsequent focus-loss event doesn't double-fire.
        var commandHandled = false

        init(parent: AutoSelectTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }

        /// Fired when the text field loses focus for any reason (key command or click-away).
        /// If no key command was already handled, treat it as a commit (click outside = save).
        func controlTextDidEndEditing(_ obj: Notification) {
            if commandHandled {
                commandHandled = false
            } else {
                parent.onCommit()
            }
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                commandHandled = true; parent.onCommit(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                commandHandled = true; parent.onCancel(); return true
            case #selector(NSResponder.insertTab(_:)):
                commandHandled = true; parent.onTab(); return true
            case #selector(NSResponder.insertBacktab(_:)):
                commandHandled = true; parent.onShiftTab(); return true
            default:
                return false
            }
        }
    }
}
