import SwiftUI
import AppKit

// MARK: - TextViewHolder (lets NoteEditorView reach into the NSTextView directly)

final class TextViewHolder {
    weak var textView: MarkdownEditorNSTextView?
    /// Cursor location at the last selection-change event; used by 续写 to freeze
    /// the insertion point at keypress time even if focus later moves elsewhere.
    var lastCursorLocation: Int = 0

    /// Scrolls to the first case-insensitive match of `query` and shows the
    /// standard macOS animated find indicator (yellow highlight ring).
    func jumpToFirstMatch(query: String) {
        guard let tv = textView, !query.isEmpty else { return }
        let range = (tv.string as NSString).range(of: query, options: .caseInsensitive)
        guard range.location != NSNotFound else { return }
        tv.scrollRangeToVisible(range)
        tv.setSelectedRange(range)
        tv.showFindIndicator(for: range)
    }

    /// Scrolls the editor to the given 0-based line index and highlights it.
    /// Applies a formatting action programmatically (e.g. from a menu item).
    func applyAction(_ action: ShortcutAction) {
        textView?.applyShortcutAction(action)
    }

    func scrollToLine(_ lineIndex: Int) {
        guard let tv = textView, lineIndex >= 0 else { return }
        let lines = tv.string.components(separatedBy: "\n")
        guard lineIndex < lines.count else { return }
        var offset = 0
        for i in 0..<lineIndex {
            offset += (lines[i] as NSString).length + 1  // +1 for "\n"
        }
        let nsStr = tv.string as NSString
        let lineLen = (lines[lineIndex] as NSString).length
        let safeStart = min(offset, nsStr.length)
        let safeLen   = min(lineLen, nsStr.length - safeStart)
        let lineRange = NSRange(location: safeStart, length: safeLen)
        tv.scrollRangeToVisible(lineRange)
        tv.setSelectedRange(NSRange(location: safeStart, length: 0))
        if safeLen > 0 { tv.showFindIndicator(for: lineRange) }
    }
}

// MARK: - NSTextView Subclass with Configurable Shortcuts

class MarkdownEditorNSTextView: NSTextView {

    var onTextChange: ((String) -> Void)?
    var onTogglePreview: (() -> Void)?
    var onClaudeWrite: (() -> Void)?
    var onRevealInFinder: (() -> Void)?
    var shortcutSettings: ShortcutSettings?
    var editorSettings: EditorSettings?

    // MARK: - Editor Modes

    /// True when outline mode is active (Enter always produces a list item).
    var outlineMode: Bool = false
    /// True when typewriter mode is active (cursor line stays at a fixed viewport position).
    var typewriterMode: Bool = false {
        didSet { if oldValue != typewriterMode { applyTypewriterPadding() } }
    }
    /// Fraction of the viewport height where the cursor line is pinned (0=top … 1=bottom).
    var typewriterScrollFraction: CGFloat = 0.5
    /// What context to highlight; everything else is dimmed.
    var typewriterFocusMode: EditorSettings.TypewriterFocusMode = .off
    /// Draw a background tint behind the active line.
    var typewriterMarkLine: Bool = false

    // MARK: - Fold state

    private struct FoldRecord {
        var placeholderRange: NSRange
        let originalContent: String
        /// Folds that were suspended when this outer fold was applied;
        /// restored back into foldRecords when this fold is undone.
        var nestedFolds: [FoldRecord]
    }

    private var foldRecords: [FoldRecord] = []
    /// True while we are programmatically replacing text for fold/unfold (suppresses sync).
    var isFolding = false
    var hasFoldedContent: Bool { !foldRecords.isEmpty }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }

        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // User-defined shortcuts take highest priority over all built-ins and menu items
        if let settings = shortcutSettings, !key.isEmpty,
           let action = settings.action(forKey: key, modifiers: event.modifierFlags) {
            if handleAction(action) { return true }
        }

        // Built-in font size: Cmd+= / Cmd+- / Cmd+0
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command || flags == [.command, .shift] {
            if key == "=" { adjustFontSize(1);  return true }
            if key == "-" { adjustFontSize(-1); return true }
            if key == "0" { resetFontSize();    return true }
        }

        // Cmd+[ / Cmd+] for indentation (only when indentShortcut is .command)
        if flags == .command, editorSettings?.indentShortcut == .command {
            if key == "[" {
                handleOutdent()
                return true
            }
            if key == "]" {
                handleIndent()
                return true
            }
        }

        // ⌘/ — cycle list-item status through TODO → DOING → DONE → (none) in outline mode
        if flags == .command && key == "/" && outlineMode {
            cycleListItemStatus()
            return true
        }

        // Mod+Enter (Option+Enter) — insert newline and return cursor to original line
        if flags == .option && key == "\r" {
            insertLineBreakAndReturn()
            return true
        }

        // External search: Cmd-based shortcuts with selected text
        if !key.isEmpty {
            for engine in ExternalSearchSettings.shared.engines {
                guard let sc = engine.shortcut, sc.matches(key: key, modifiers: event.modifierFlags) else { continue }
                let sel = selectedRange()
                if sel.length > 0 {
                    let selected = (string as NSString).substring(with: sel)
                    if let url = engine.searchURL(for: selected) {
                        NSWorkspace.shared.open(url)
                        return true
                    }
                }
                break
            }
        }

        return super.performKeyEquivalent(with: event)
    }

    /// Intercept non-Cmd user shortcuts before NSTextView's built-in keyDown handling.
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !flags.isEmpty {
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if let settings = shortcutSettings, !key.isEmpty,
               let action = settings.action(forKey: key, modifiers: event.modifierFlags) {
                if handleAction(action) { return }
            }
            // External search: ⌥-based shortcuts with selected text
            if !key.isEmpty {
                for engine in ExternalSearchSettings.shared.engines {
                    guard let sc = engine.shortcut,
                          sc.matches(key: key, modifiers: event.modifierFlags) else { continue }
                    let sel = selectedRange()
                    if sel.length > 0 {
                        let selected = (string as NSString).substring(with: sel)
                        if let url = engine.searchURL(for: selected) {
                            NSWorkspace.shared.open(url)
                            return
                        }
                    }
                    break
                }
            }
        }
        super.keyDown(with: event)
    }

    // MARK: - Smart list editing

    /// Parses list-item metadata from a raw line (including trailing newline).
    /// Returns `(indent, bulletLen, nextBullet)` or `nil` if the line isn't a list item.
    /// - `indent`:     leading whitespace string
    /// - `bulletLen`:  character count of the current bullet marker (e.g. `"- "` = 2)
    /// - `nextBullet`: marker string to use for the continuation line
    private func listItemInfo(in line: String) -> (indent: String, bulletLen: Int, nextBullet: String)? {
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        let rest = String(line.dropFirst(indent.count)).trimmingCharacters(in: .newlines)

        // Task list (must come before plain "- " check)
        let taskPairs: [(String, String)] = [
            ("- [ ] ", "- [ ] "), ("- [x] ", "- [ ] "),
            ("* [ ] ", "* [ ] "), ("* [x] ", "* [ ] "),
        ]
        for (cur, nxt) in taskPairs where rest.hasPrefix(cur) {
            return (indent, cur.count, nxt)
        }

        // Unordered
        for bullet in ["- ", "* ", "+ "] where rest.hasPrefix(bullet) {
            return (indent, bullet.count, bullet)
        }

        // Ordered: digits followed by ". "
        var numStr = ""
        var idx = rest.startIndex
        while idx < rest.endIndex && rest[idx].isNumber {
            numStr.append(rest[idx])
            idx = rest.index(after: idx)
        }
        if !numStr.isEmpty, idx < rest.endIndex, rest[idx] == "." {
            let afterDot = rest.index(after: idx)
            if afterDot < rest.endIndex, rest[afterDot] == " " {
                let num = Int(numStr) ?? 1
                return (indent, numStr.count + 2, "\(num + 1). ")
            }
        }
        return nil
    }

    // MARK: - Outline helpers

    /// Returns a range covering `range` plus all following lines that are deeper-indented
    /// than the FIRST line of `range` (i.e. the full subtree in outline mode).
    /// Stops at a blank line or any line whose indentation is ≤ the first line's.
    private func outlineSubtreeRange(for range: NSRange) -> NSRange {
        let ns = string as NSString
        let len = ns.length
        let firstLineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
        let firstLine = ns.substring(with: firstLineRange)
        let baseIndent = firstLine.prefix(while: { $0 == " " || $0 == "\t" }).count

        var end = NSMaxRange(range)
        while end < len {
            let nextLineRange = ns.lineRange(for: NSRange(location: end, length: 0))
            let nextLine = ns.substring(with: nextLineRange)
            let trimmed = nextLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { break }
            let nextIndent = nextLine.prefix(while: { $0 == " " || $0 == "\t" }).count
            if nextIndent <= baseIndent { break }
            end = NSMaxRange(nextLineRange)
        }
        return NSRange(location: range.location, length: end - range.location)
    }

    /// Returns the range of all children (deeper-indented lines) of the given parent line.
    /// Returns nil if the line has no children.
    private func childrenRange(of parentLineRange: NSRange) -> NSRange? {
        let ns = string as NSString
        let len = ns.length
        let parentLine = ns.substring(with: parentLineRange)
        let baseIndent = parentLine.prefix(while: { $0 == " " || $0 == "\t" }).count

        var end = NSMaxRange(parentLineRange)
        var foundChild = false
        while end < len {
            let nextLineRange = ns.lineRange(for: NSRange(location: end, length: 0))
            let nextLine = ns.substring(with: nextLineRange)
            let trimmed = nextLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { break }
            let nextIndent = nextLine.prefix(while: { $0 == " " || $0 == "\t" }).count
            if nextIndent <= baseIndent {
                break
            }
            foundChild = true
            end = NSMaxRange(nextLineRange)
        }

        return foundChild ? NSRange(location: NSMaxRange(parentLineRange), length: end - NSMaxRange(parentLineRange)) : nil
    }

    /// Gets the full subtree range (current line + all children) and the lines within it.
    /// - Parameter lineRange: The NSRange of the current line
    /// - Returns: (fullRange, lines) where fullRange includes the entire subtree and lines contains the text of each line (trimmed)
    /// - Important: Hierarchy is determined by the number of spaces BEFORE the dash only.
    ///   Level 1: `- item` (0 spaces), Level 2: `    - item` (4 spaces), etc.
    private func getSubtreeWithLines(from lineRange: NSRange) -> (NSRange, [String]) {
        let ns = string as NSString
        let firstLine = ns.substring(with: lineRange)

        // Count spaces before the dash for the first line
        let baseSpaces = countSpacesBeforeDash(firstLine)

        var end = NSMaxRange(lineRange)
        var lines = [firstLine.trimmingCharacters(in: .newlines)]

        while end < ns.length {
            let nextLineRange = ns.lineRange(for: NSRange(location: end, length: 0))
            let nextLine = ns.substring(with: nextLineRange)
            let trimmed = nextLine.trimmingCharacters(in: .whitespacesAndNewlines)

            // Count spaces before dash for this line
            let nextSpaces = countSpacesBeforeDash(nextLine)

            // Stop if this line has equal or fewer spaces than parent (same level or higher)
            if nextSpaces <= baseSpaces {
                break
            }

            // Stop at empty lines (non-list content breaks the outline structure)
            if trimmed.isEmpty {
                break
            }

            lines.append(trimmed)
            end = NSMaxRange(nextLineRange)
        }

        let fullRange = NSRange(location: lineRange.location, length: end - lineRange.location)
        return (fullRange, lines)
    }

    /// Counts the number of spaces/tabs before the dash in a line.
    /// Used to determine list item hierarchy level.
    private func countSpacesBeforeDash(_ line: String) -> Int {
        var count = 0
        for char in line {
            if char == " " || char == "\t" {
                count += (char == "\t") ? 4 : 1  // Treat tab as 4 spaces
            } else if char == "-" {
                return count  // Found the dash, return space count
            } else {
                return 0  // Non-whitespace before dash, not a proper list item
            }
        }
        return 0
    }

    /// Adds `prefix` to (or removes it from) the beginning of every line within `range`.
    /// The cursor is restored to approximately the same position on the first line
    /// (offset by `savedCursorOffset` characters from `range.location`, adjusted for the change).
    private func addOrRemovePrefixFromLines(in range: NSRange, prefix: String,
                                             remove: Bool, savedCursorOffset: Int) {
        let ns = string as NSString
        let rangeEnd = NSMaxRange(range)
        var result = ""
        var pos = range.location
        while pos < rangeEnd {
            let lr = ns.lineRange(for: NSRange(location: pos, length: 0))
            var lineText = ns.substring(with: lr)
            if remove {
                if lineText.hasPrefix(prefix) { lineText = String(lineText.dropFirst(prefix.count)) }
            } else {
                lineText = prefix + lineText
            }
            result += lineText
            let nextPos = NSMaxRange(lr)
            if nextPos <= pos { break }
            pos = nextPos
        }
        guard shouldChangeText(in: range, replacementString: result) else { return }
        textStorage!.beginEditing()
        textStorage!.replaceCharacters(in: range, with: result)
        textStorage!.endEditing()
        didChangeText()
        let delta = remove ? -(prefix as NSString).length : (prefix as NSString).length
        let newCursor = max(range.location, range.location + savedCursorOffset + delta)
        setSelectedRange(NSRange(location: newCursor, length: 0))
    }

    /// Smart Enter: continue list items or exit an empty list item.
    override func insertNewline(_ sender: Any?) {
        let sel = selectedRange()
        let ns = string as NSString
        let len = ns.length
        guard len > 0, sel.length == 0 else {
            super.insertNewline(sender)
            return
        }
        let loc = min(sel.location, len - 1)
        let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
        let line = ns.substring(with: lineRange)

        guard let info = listItemInfo(in: line) else {
            if outlineMode {
                // Outline mode: new lines always start a "- " list item.
                let insertion = "\n- "
                guard shouldChangeText(in: sel, replacementString: insertion) else { return }
                textStorage!.beginEditing()
                textStorage!.replaceCharacters(in: sel, with: insertion)
                textStorage!.endEditing()
                didChangeText()
                let newCursor = sel.location + (insertion as NSString).length
                setSelectedRange(NSRange(location: newCursor, length: 0))
            } else {
                super.insertNewline(sender)
            }
            return
        }

        let contentStart = info.indent.count + info.bulletLen
        let lineBody = line.trimmingCharacters(in: .newlines)
        let content = contentStart < lineBody.count
            ? String(lineBody.dropFirst(contentStart))
            : ""

        if content.isEmpty {
            // Empty list item → exit the list (remove indent + bullet from current line).
            // Work through shouldChangeText so undo is registered properly.
            let bulletRange = NSRange(location: lineRange.location,
                                      length: info.indent.count + info.bulletLen)
            guard shouldChangeText(in: bulletRange, replacementString: "") else { return }
            textStorage!.beginEditing()
            textStorage!.replaceCharacters(in: bulletRange, with: "")
            textStorage!.endEditing()
            didChangeText()
            // Place cursor at the start of what was the bullet (now empty line).
            setSelectedRange(NSRange(location: bulletRange.location, length: 0))
        } else {
            // Continue the list on the next line.
            // The replacement range IS the cursor, so NSTextView cursor tracking is fine.
            let insertion = "\n" + info.indent + info.nextBullet
            guard shouldChangeText(in: sel, replacementString: insertion) else { return }
            textStorage!.beginEditing()
            textStorage!.replaceCharacters(in: sel, with: insertion)
            textStorage!.endEditing()
            didChangeText()
            let newCursor = sel.location + (insertion as NSString).length
            setSelectedRange(NSRange(location: newCursor, length: 0))
        }
    }

    /// Mod+Enter: insert a newline after the current line, then return cursor to original line.
    /// This is like Logseq's "create sibling without changing focus" behavior.
    private func insertLineBreakAndReturn() {
        let sel = selectedRange()
        let ns = string as NSString
        let len = ns.length
        guard len > 0, sel.length == 0 else { return }

        let loc = min(sel.location, len - 1)
        let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
        let line = ns.substring(with: lineRange)

        // Determine if we're in a list item and what its prefix is
        var newLinePrefix = ""
        if let info = listItemInfo(in: line) {
            // Continue the list with same indent + bullet
            newLinePrefix = "\n" + info.indent + info.nextBullet
        }

        // Get the range from cursor to end of line
        let rangeToEnd = NSRange(location: loc, length: NSMaxRange(lineRange) - loc)

        // Insert newline + prefix after cursor
        guard shouldChangeText(in: rangeToEnd, replacementString: newLinePrefix) else { return }
        textStorage!.beginEditing()
        textStorage!.replaceCharacters(in: rangeToEnd, with: newLinePrefix)
        textStorage!.endEditing()
        didChangeText()

        // Return cursor to original position
        setSelectedRange(sel)
    }

    /// Smart Backspace: when cursor is right after a list bullet, remove the bullet.
    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length == 0, sel.location > 0 else {
            super.deleteBackward(sender)
            return
        }
        let ns = string as NSString
        let len = ns.length
        guard len > 0 else {
            super.deleteBackward(sender)
            return
        }

        let loc = min(sel.location, len - 1)
        let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
        let line = ns.substring(with: lineRange)

        guard let info = listItemInfo(in: line) else {
            super.deleteBackward(sender)
            return
        }

        // Only intercept when cursor is exactly at the first content character
        // (right after the indent + bullet marker).
        let contentStart = lineRange.location + info.indent.count + info.bulletLen
        guard sel.location == contentStart else {
            super.deleteBackward(sender)
            return
        }

        // Remove the bullet marker, keeping the indent.
        let bulletRange = NSRange(location: lineRange.location + info.indent.count,
                                   length: info.bulletLen)
        guard shouldChangeText(in: bulletRange, replacementString: "") else { return }
        textStorage!.beginEditing()
        textStorage!.replaceCharacters(in: bulletRange, with: "")
        textStorage!.endEditing()
        didChangeText()
        // Cursor lands right where the bullet was (= indent end).
        setSelectedRange(NSRange(location: bulletRange.location, length: 0))
    }

    /// Intercept Tab key to respect the user's indent shortcut setting.
    /// On list item lines, Tab indents the entire item instead of inserting whitespace.
    override func insertTab(_ sender: Any?) {
        let sel = selectedRange()
        let ns = string as NSString
        let len = ns.length

        // Check if user wants Tab to handle indentation
        guard let settings = editorSettings, settings.indentShortcut == .tab else {
            super.insertTab(sender)
            return
        }

        if sel.length == 0, len > 0 {
            let loc = min(sel.location, len - 1)
            let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
            if let _ = listItemInfo(in: ns.substring(with: lineRange)) {
                // On list item lines, Tab indents the entire item
                handleIndent()
                return
            }
        }

        // Insert tab character (or spaces if user wants, but for simplicity just use tab)
        super.insertTab(sender)
    }

    /// Shift-Tab on list item lines: outdent the item.
    override func insertBacktab(_ sender: Any?) {
        // Check if user wants Tab/Shift-Tab to handle indentation
        guard let settings = editorSettings, settings.indentShortcut == .tab else {
            super.insertBacktab(sender)
            return
        }

        let sel = selectedRange()
        let ns = string as NSString
        let len = ns.length
        guard sel.length == 0, len > 0 else { return }

        let loc = min(sel.location, len - 1)
        let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
        let line = ns.substring(with: lineRange)

        guard let _ = listItemInfo(in: line) else { return }

        handleOutdent()
    }

    /// Handle indentation (Cmd+] or Tab when enabled)
    /// Only affects the current list item, not its children
    private func handleIndent() {
        let sel = selectedRange()
        let ns = string as NSString
        let indentStr = editorSettings?.indentUnit.string ?? "  "

        // Get the current line range
        var affectedRange: NSRange
        if sel.length == 0 {
            let loc = min(sel.location, ns.length - 1)
            affectedRange = ns.lineRange(for: NSRange(location: loc, length: 0))
        } else {
            // Multi-line selection: use the selected range directly
            let start = ns.lineRange(for: NSRange(location: sel.location, length: 0)).location
            let end   = ns.lineRange(for: NSRange(location: sel.location + sel.length - 1, length: 0)).location
            let endLineRange = ns.lineRange(for: NSRange(location: end, length: 0))
            affectedRange = NSRange(location: start, length: endLineRange.location + endLineRange.length - start)
        }

        let currentLine = ns.substring(with: affectedRange).trimmingCharacters(in: .newlines)

        // Only indent list items (lines starting with dash)
        guard let info = listItemInfo(in: currentLine) else { return }

        // Build new line: add indent after bullet
        let bulletEnd = info.indent.count + info.bulletLen
        let newLine = String(currentLine.prefix(bulletEnd)) + indentStr + String(currentLine.dropFirst(bulletEnd))

        let newText = newLine + "\n"

        guard shouldChangeText(in: affectedRange, replacementString: newText) else { return }
        textStorage!.beginEditing()
        textStorage!.replaceCharacters(in: affectedRange, with: newText)
        textStorage!.endEditing()
        didChangeText()

        // Position cursor after the indented bullet
        let newCursor = affectedRange.location + (newText as NSString).length
        setSelectedRange(NSRange(location: newCursor, length: 0))
        self.window?.makeFirstResponder(self)
    }

    /// Handle outdent (Shift+Tab or Cmd+[ when enabled)
    /// Only affects the current list item, not its children
    private func handleOutdent() {
        let sel = selectedRange()
        let ns = string as NSString
        let indentStr = editorSettings?.indentUnit.string ?? "  "
        let indentLen = (indentStr as NSString).length

        // Get the current line range
        var affectedRange: NSRange
        if sel.length == 0 {
            let loc = min(sel.location, ns.length - 1)
            affectedRange = ns.lineRange(for: NSRange(location: loc, length: 0))
        } else {
            // Multi-line selection: use the selected range directly
            let start = ns.lineRange(for: NSRange(location: sel.location, length: 0)).location
            let end   = ns.lineRange(for: NSRange(location: sel.location + sel.length - 1, length: 0)).location
            let endLineRange = ns.lineRange(for: NSRange(location: end, length: 0))
            affectedRange = NSRange(location: start, length: endLineRange.location + endLineRange.length - start)
        }

        let currentLine = ns.substring(with: affectedRange).trimmingCharacters(in: .newlines)

        // Only outdent list items (lines starting with dash)
        guard let info = listItemInfo(in: currentLine) else { return }

        // Remove indent from after the bullet
        let afterBullet = info.indent.count + info.bulletLen
        let content = String(currentLine.dropFirst(afterBullet))
        let contentIndent = String(content.prefix(while: { $0 == " " || $0 == "\t" }))
        let toRemove = min(contentIndent.count, indentLen)

        // Build new line: remove indent from content
        let newLine: String
        if toRemove > 0 {
            newLine = info.indent + String(currentLine.prefix(afterBullet)) + String(content.dropFirst(toRemove))
        } else {
            // If no content indent, move the entire bullet prefix back (including the indent before bullet)
            let lineStart = currentLine.prefix(afterBullet)
            newLine = String(lineStart.dropFirst(min(indentLen, countSpacesBeforeDash(currentLine))))
        }

        let newText = newLine + "\n"

        guard shouldChangeText(in: affectedRange, replacementString: newText) else { return }
        textStorage!.beginEditing()
        textStorage!.replaceCharacters(in: affectedRange, with: newText)
        textStorage!.endEditing()
        didChangeText()

        // Position cursor at the start of the outdented content
        setSelectedRange(NSRange(location: affectedRange.location, length: 0))
        self.window?.makeFirstResponder(self)
    }

    // MARK: - Typewriter Mode

    /// Updates the top/bottom text container inset so that lines at the very beginning/end
    /// of the document can still be pinned at the configured viewport fraction.
    /// Call whenever `typewriterMode` or the scroll view height changes.
    func applyTypewriterPadding() {
        guard let scrollView = enclosingScrollView else { return }
        let halfH = scrollView.contentView.bounds.height * typewriterScrollFraction
        let vPad  = typewriterMode ? max(12, halfH) : 12
        textContainerInset = NSSize(width: textContainerInset.width, height: vPad)
        // Force layout so document height updates before we scroll
        layoutManager?.ensureLayout(for: textContainer!)
    }

    /// Scrolls so the cursor line sits at `typewriterScrollFraction` of the visible viewport.
    /// No-ops when typewriter mode is off.
    func scrollCursorToCenter() {
        // Redraw is needed whenever the cursor moves and focus overlay / line mark is active,
        // regardless of whether typewriter scroll is also on.
        if typewriterMarkLine || typewriterFocusMode != .off {
            setNeedsDisplay(visibleRect)
        }

        guard typewriterMode,
              let lm = layoutManager,
              let scrollView = enclosingScrollView else { return }

        let sel   = selectedRange()
        let nsLen = (string as NSString).length
        guard nsLen > 0 else { return }

        let safeLoc  = min(sel.location, nsLen - 1)
        let glyphIdx = lm.glyphIndexForCharacter(at: safeLoc)
        var lineRect = lm.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
        lineRect     = lineRect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)

        let visibleH = scrollView.contentView.bounds.height
        let docH     = scrollView.documentView?.bounds.height ?? visibleH
        let targetY  = lineRect.midY - visibleH * typewriterScrollFraction
        let clampedY = max(0, min(targetY, docH - visibleH))

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Typewriter drawing (line highlight + focus overlay)

    /// Returns the NSRange that represents the current focus context
    /// (line, sentence, or paragraph) around the cursor.
    private func focusContextRange() -> NSRange {
        let sel   = selectedRange()
        let ns    = string as NSString
        let len   = ns.length
        let loc   = min(max(sel.location, 0), max(len - 1, 0))
        switch typewriterFocusMode {
        case .off:
            return NSRange(location: 0, length: len)
        case .line:
            return ns.lineRange(for: NSRange(location: loc, length: 0))
        case .sentence:
            // Expand to sentence boundaries using the system tokeniser
            if let swiftRange = Range(NSRange(location: loc, length: 0), in: string) {
                var start = swiftRange.lowerBound
                var end   = swiftRange.upperBound
                string.enumerateSubstrings(in: string.startIndex...,
                                           options: [.bySentences]) { _, range, _, _ in
                    if range.contains(swiftRange.lowerBound) ||
                       range.lowerBound == swiftRange.lowerBound {
                        start = range.lowerBound
                        end   = range.upperBound
                    }
                }
                return NSRange(start..<end, in: string)
            }
            return ns.lineRange(for: NSRange(location: loc, length: 0))
        case .paragraph:
            return ns.paragraphRange(for: NSRange(location: loc, length: 0))
        }
    }

    /// Returns the union of all line fragment rects for `range`, in text-view coordinates.
    private func rectsForRange(_ range: NSRange) -> [NSRect] {
        guard let lm = layoutManager else { return [] }
        var rects: [NSRect] = []
        var glyphRange = NSRange()
        lm.characterRange(forGlyphRange: range, actualGlyphRange: nil)
        lm.glyphRange(forCharacterRange: range, actualCharacterRange: &glyphRange)
        lm.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, _ in
            let r = rect.offsetBy(dx: self.textContainerOrigin.x,
                                  dy: self.textContainerOrigin.y)
            rects.append(r)
        }
        return rects
    }

    /// Draw a subtle background tint behind the cursor line (called from drawBackground).
    private func drawTypewriterLineHighlight() {
        guard let lm = layoutManager else { return }
        let sel  = selectedRange()
        let len  = (string as NSString).length
        guard len > 0 else { return }
        let loc  = min(sel.location, len - 1)
        let idx  = lm.glyphIndexForCharacter(at: loc)
        var lr   = lm.lineFragmentRect(forGlyphAt: idx, effectiveRange: nil)
        lr       = lr.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let full = NSRect(x: bounds.minX, y: lr.minY, width: bounds.width, height: lr.height)
        NSColor.textColor.withAlphaComponent(0.06).setFill()
        full.fill()
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if typewriterMode, typewriterMarkLine {
            drawTypewriterLineHighlight()
        }
    }

    /// Draw a translucent overlay over everything outside the focus context.
    /// Called from draw(_:) after super, so it renders on top of text.
    private func drawTypewriterFocusOverlay(in dirtyRect: NSRect) {
        let contextRange = focusContextRange()
        let rects        = rectsForRange(contextRange)
        guard !rects.isEmpty else { return }

        // Combine all fragment rects into one bounding box for the context band
        let band = rects.reduce(rects[0]) { $0.union($1) }

        // Dim color adapts to light / dark mode
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let dimAlpha: CGFloat = 0.55
        let dimColor = isDark
            ? NSColor.black.withAlphaComponent(dimAlpha)
            : NSColor.white.withAlphaComponent(dimAlpha)
        dimColor.setFill()

        // Two rects: above and below the focus band
        let aboveRect = NSRect(x: bounds.minX, y: band.maxY,
                               width: bounds.width,
                               height: max(0, bounds.maxY - band.maxY))
        let belowRect = NSRect(x: bounds.minX, y: bounds.minY,
                               width: bounds.width,
                               height: max(0, band.minY - bounds.minY))
        aboveRect.intersection(dirtyRect).fill()
        belowRect.intersection(dirtyRect).fill()
    }

    override func didChangeText() {
        super.didChangeText()
        scrollCursorToCenter()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-apply padding when the view enters a window (scroll view height now known)
        if typewriterMode { applyTypewriterPadding() }
        // Observe scroll view resize so padding stays correct when window is resized
        if let sv = enclosingScrollView {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollViewDidResize),
                name: NSView.frameDidChangeNotification,
                object: sv)
            sv.postsFrameChangedNotifications = true
        }
    }

    @objc private func scrollViewDidResize() {
        if typewriterMode { applyTypewriterPadding() }
    }

    // MARK: - Font size

    private func adjustFontSize(_ delta: CGFloat) {
        let current = font?.pointSize ?? 14
        let newSize = max(9, min(32, current + delta))
        applyFontSize(newSize)
    }

    private func resetFontSize() {
        applyFontSize(14)
    }

    private func applyFontSize(_ size: CGFloat) {
        if let es = editorSettings {
            es.fontSize = Double(size)
            font = es.makeNSFont()
        } else {
            font = .monospacedSystemFont(ofSize: size, weight: .regular)
            UserDefaults.standard.set(Double(size), forKey: "editorFontSize")
        }
    }

    func applyEditorSettings(_ s: EditorSettings) {
        font = s.makeNSFont()
        isAutomaticSpellingCorrectionEnabled = s.spellingCheck
        isContinuousSpellCheckingEnabled = s.spellingCheck
        isAutomaticQuoteSubstitutionEnabled = s.smartQuotes
        isAutomaticDashSubstitutionEnabled = s.smartQuotes

        // Line height via default paragraph style
        let ps = NSMutableParagraphStyle()
        ps.lineHeightMultiple = s.lineHeightMultiple
        defaultParagraphStyle = ps
        typingAttributes[.paragraphStyle] = ps

        // Re-apply wiki link highlighting with the (possibly new) color
        highlightWikiLinks()
    }

    // MARK: - [[Wiki Link]] Syntax Highlighting

    private static let wikiLinkRegex = try! NSRegularExpression(pattern: "\\[\\[.+?\\]\\]")

    func highlightWikiLinks(in storage: NSTextStorage? = nil) {
        let s = storage ?? textStorage
        guard let s, s.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: s.length)

        // Clear any previous wiki-link coloring (returns to textView's default textColor)
        s.removeAttribute(.foregroundColor, range: fullRange)
        s.removeAttribute(.underlineStyle, range: fullRange)

        let wikiColor = editorSettings?.wikiLinkColor ?? .systemBlue
        for match in Self.wikiLinkRegex.matches(in: s.string, range: fullRange) {
            let r = match.range
            // Brackets in a slightly dimmer shade, inner text in full accent color
            s.addAttribute(.foregroundColor, value: wikiColor.withAlphaComponent(0.5), range: NSRange(location: r.location, length: 2))
            if r.length > 4 {
                let innerRange = NSRange(location: r.location + 2, length: r.length - 4)
                s.addAttribute(.foregroundColor, value: wikiColor, range: innerRange)
                s.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: innerRange)
            }
            s.addAttribute(.foregroundColor, value: wikiColor.withAlphaComponent(0.5), range: NSRange(location: r.location + r.length - 2, length: 2))
        }
    }

    func showFindBar() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        performFindPanelAction(item)
    }

    func showFindReplaceBar() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showReplaceInterface.rawValue
        performFindPanelAction(item)
    }

    /// Called from menu items (via notification) to apply an action without a key event.
    func applyShortcutAction(_ action: ShortcutAction) {
        _ = handleAction(action)
    }

    private func handleAction(_ action: ShortcutAction) -> Bool {
        switch action {
        case .panguSpacing:
            applyPanguSpacing()
            return true
        case .togglePreview:
            onTogglePreview?()
            return true
        case .claudeWrite:
            onClaudeWrite?()
            return true
        case .revealInFinder:
            onRevealInFinder?()
            return true
        case .findInNote:
            showFindBar()
            return true
        case .findReplaceInNote:
            showFindReplaceBar()
            return true
        case .searchAllNotes:
            NotificationCenter.default.post(name: .vaultSearchRequested, object: nil)
            return true
        case .selectLine:
            selectLine()
            return true
        case .selectWord:
            selectWord()
            return true
        case .selectSentence:
            selectSentence()
            return true
        case .selectParagraph:
            selectMarkdownParagraph()
            return true
        case .selectList:
            selectListBranch()
            return true
        case .deselectLine, .deselectWord, .deselectSentence, .deselectParagraph, .deselectList:
            performDeselect()
            return true
        case .foldBlock:
            foldAtCursor()
            return true
        case .unfoldBlock:
            unfoldAtCursor()
            return true
        case .foldAll:
            foldAllBlocks()
            return true
        case .unfoldAll:
            unfoldAll()
            return true
        case .moveLineUp:
            moveLine(up: true)
            return true
        case .moveLineDown:
            moveLine(up: false)
            return true
        case .indent:
            // On a heading line: decrease level (H2→H1, fewer #). Otherwise: normal indent.
            if headingLevelAtCursor() != nil {
                applyHeadingLevelChange(delta: -1)
            } else {
                handleIndent()
            }
            return true
        case .outdent:
            // On a heading line: increase level (H1→H2, more #). Otherwise: normal outdent.
            if headingLevelAtCursor() != nil {
                applyHeadingLevelChange(delta: +1)
            } else {
                handleOutdent()
            }
            return true
        default:
            if let format = action.markdownFormat {
                applyFormat(format)
                return true
            }
            return false
        }
    }

    // MARK: - Outline Status Cycle (⌘/)

    /// Cycles the status prefix of the current list item through:
    /// (none) → TODO → DOING → DONE → (none)
    /// Only acts when the cursor is on an unordered list line.
    private func cycleListItemStatus() {
        let ns     = string as NSString
        let len    = ns.length
        let sel    = selectedRange()
        guard len > 0 else { return }

        let loc       = min(sel.location, len - 1)
        let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
        let rawLine   = ns.substring(with: lineRange)

        // Parse leading indent
        let indent     = String(rawLine.prefix(while: { $0 == " " || $0 == "\t" }))
        let afterIndent = String(rawLine.dropFirst(indent.count))

        // Must be an unordered list item
        let bulletMarkers = ["- ", "* ", "+ "]
        guard let bullet = bulletMarkers.first(where: { afterIndent.hasPrefix($0) }) else { return }

        var body = String(afterIndent.dropFirst(bullet.count))
        // Preserve trailing newline separately
        let trailingNL: String
        if body.hasSuffix("\n") {
            trailingNL = "\n"
            body = String(body.dropLast())
        } else {
            trailingNL = ""
        }

        // Determine next state in the cycle
        let states = ["TODO", "DOING", "DONE"]
        let newBody: String
        if let current = states.first(where: { body == $0 || body.hasPrefix($0 + " ") }) {
            let idx      = states.firstIndex(of: current)!
            let nextIdx  = (idx + 1) % (states.count + 1)   // +1 = "no status" slot
            let bodyText = body.hasPrefix(current + " ")
                ? String(body.dropFirst(current.count + 1))
                : ""                                         // item was exactly "TODO" etc.
            if nextIdx == states.count {
                newBody = bodyText                           // remove status
            } else {
                newBody = states[nextIdx] + (bodyText.isEmpty ? "" : " " + bodyText)
            }
        } else {
            newBody = "TODO" + (body.isEmpty ? "" : " " + body)   // add status
        }

        let newLine = indent + bullet + newBody + trailingNL
        guard shouldChangeText(in: lineRange, replacementString: newLine) else { return }
        textStorage!.beginEditing()
        textStorage!.replaceCharacters(in: lineRange, with: newLine)
        textStorage!.endEditing()
        didChangeText()

        // Keep cursor clamped within the new line
        let newEnd = lineRange.location + (newLine as NSString).length
        let newLoc = min(sel.location, newEnd)
        setSelectedRange(NSRange(location: newLoc, length: 0))
    }

    // MARK: - Heading Level Change

    /// Returns the heading level (1–6) of the line containing the cursor, or nil.
    private func headingLevelAtCursor() -> Int? {
        let loc = selectedRange().location
        let nsStr = string as NSString
        let lineRange = nsStr.lineRange(for: NSRange(location: loc, length: 0))
        let lineText = nsStr.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
        guard lineText.hasPrefix("#") else { return nil }
        let count = lineText.prefix(while: { $0 == "#" }).count
        guard count >= 1, count <= 6 else { return nil }
        let rest = String(lineText.dropFirst(count))
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        return count
    }

    /// Changes the heading level of the current line by `delta` (−1 promotes, +1 demotes).
    private func applyHeadingLevelChange(delta: Int) {
        let loc = selectedRange().location
        let nsStr = string as NSString
        let lineRange = nsStr.lineRange(for: NSRange(location: loc, length: 0))
        let lineText = nsStr.substring(with: lineRange)
        let trimmed = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return }
        let currentLevel = trimmed.prefix(while: { $0 == "#" }).count
        guard currentLevel >= 1, currentLevel <= 6 else { return }
        let rest = String(trimmed.dropFirst(currentLevel))
        guard rest.isEmpty || rest.hasPrefix(" ") else { return }
        let headingText = rest.hasPrefix(" ") ? String(rest.dropFirst()) : rest
        let newLevel = max(1, min(6, currentLevel + delta))
        guard newLevel != currentLevel else { return }
        let trailingNewline = lineText.hasSuffix("\n") ? "\n" : ""
        let newLine = String(repeating: "#", count: newLevel) + " " + headingText + trailingNewline
        let fullRange = NSRange(location: 0, length: nsStr.length)
        let newContent = nsStr.replacingCharacters(in: lineRange, with: newLine)
        if shouldChangeText(in: fullRange, replacementString: newContent) {
            let storage = textStorage!
            storage.beginEditing()
            storage.replaceCharacters(in: fullRange, with: newContent)
            storage.endEditing()
            didChangeText()
            setSelectedRange(NSRange(location: lineRange.location, length: 0))
        }
    }

    private func applyFormat(_ format: MarkdownFormat) {
        let currentRange = selectedRange()
        let indentUnit = editorSettings?.indentUnit.string ?? "    "
        let result = MarkdownFormatter.apply(format, to: string, selectedRange: currentRange, indentUnit: indentUnit)

        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        if shouldChangeText(in: fullRange, replacementString: result.text) {
            let storage = textStorage!
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: result.text)
            storage.endEditing()
            didChangeText()
            // didChangeText() fires textDidChange → updateBinding(trueContent()); no extra call needed.
            setSelectedRange(result.selectedRange)
        }
    }

    // MARK: - Move Line Up / Down

    /// Moves the current line (or all lines covered by the selection) up or down by one line.
    /// Subtree-aware: when moving a single line, the entire subtree moves together.
    /// Preserves the cursor's relative offset within the moved block.
    private func moveLine(up: Bool) {
        let sel = selectedRange()
        let ns = string as NSString
        let len = ns.length
        guard len > 0 else { return }

        // Compute the "block" = all lines touched by the current selection.
        let startLineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let endLineRange: NSRange = {
            guard sel.length > 0 else { return startLineRange }
            // NSMaxRange(sel) - 1 avoids including a trailing empty line when selection ends
            // exactly on a newline boundary.
            let endLoc = max(sel.location, NSMaxRange(sel) - 1)
            return ns.lineRange(for: NSRange(location: endLoc, length: 0))
        }()

        // If single-line selection, include the full subtree (Bike Outliner style)
        let blockRange: NSRange
        if sel.length == 0 || NSEqualRanges(startLineRange, endLineRange) {
            // Single line: get full subtree
            let (subtreeRange, _) = getSubtreeWithLines(from: startLineRange)
            blockRange = subtreeRange
        } else {
            // Multi-line selection: use the selected range
            blockRange = NSUnionRange(startLineRange, endLineRange)
        }

        // Cursor offset relative to block start — preserved after the swap.
        let cursorOffsetInBlock = sel.location - blockRange.location

        if up {
            // Nothing to move if already on the first line.
            guard blockRange.location > 0 else { return }

            let lineAboveRange = ns.lineRange(
                for: NSRange(location: blockRange.location - 1, length: 0))
            let combinedRange = NSRange(location: lineAboveRange.location,
                                        length: NSMaxRange(blockRange) - lineAboveRange.location)

            let lineAboveText = ns.substring(with: lineAboveRange)
            let blockText     = ns.substring(with: blockRange)

            // lineAboveText always has a trailing \n (it's above the block).
            // blockText may lack a trailing \n when it's the document's last line.
            let newText: String
            if blockText.hasSuffix("\n") {
                newText = blockText + lineAboveText
            } else {
                // Move the \n from lineAbove to end of block so total length stays the same.
                newText = blockText + "\n" + String(lineAboveText.dropLast())
            }

            guard shouldChangeText(in: combinedRange, replacementString: newText) else { return }
            textStorage!.beginEditing()
            textStorage!.replaceCharacters(in: combinedRange, with: newText)
            textStorage!.endEditing()
            didChangeText()

            let newCursor = lineAboveRange.location + cursorOffsetInBlock
            setSelectedRange(NSRange(location: newCursor, length: sel.length))

        } else {
            // Nothing to move if already on the last line.
            let blockEnd = NSMaxRange(blockRange)
            guard blockEnd < len else { return }

            let lineBelowRange = ns.lineRange(for: NSRange(location: blockEnd, length: 0))
            let combinedRange = NSRange(location: blockRange.location,
                                        length: NSMaxRange(lineBelowRange) - blockRange.location)

            let blockText     = ns.substring(with: blockRange)
            let lineBelowText = ns.substring(with: lineBelowRange)

            // blockText always has a trailing \n (line below exists).
            // lineBelowText may lack a trailing \n when it's the document's last line.
            let newText: String
            let blockStartInNew: Int  // offset of block content within newText
            if lineBelowText.hasSuffix("\n") {
                newText = lineBelowText + blockText
                blockStartInNew = lineBelowText.count
            } else {
                // Move the \n from block to end of lineBelow so total length stays the same.
                newText = lineBelowText + "\n" + String(blockText.dropLast())
                blockStartInNew = lineBelowText.count + 1
            }

            guard shouldChangeText(in: combinedRange, replacementString: newText) else { return }
            textStorage!.beginEditing()
            textStorage!.replaceCharacters(in: combinedRange, with: newText)
            textStorage!.endEditing()
            didChangeText()

            let newCursor = blockRange.location + blockStartInNew + cursorOffsetInBlock
            setSelectedRange(NSRange(location: newCursor, length: sel.length))
        }

        // didChangeText() above already syncs content via textDidChange delegate.
        scrollRangeToVisible(selectedRange())
    }

    private func applyPanguSpacing() {
        let sel = selectedRange()
        let nsString = string as NSString

        // Apply to selection only; fall back to whole document when nothing is selected
        let applyRange = sel.length > 0
            ? sel
            : NSRange(location: 0, length: nsString.length)

        let original = nsString.substring(with: applyRange)
        let modified = PanguSpacing.apply(to: original)
        guard modified != original else { return }

        if shouldChangeText(in: applyRange, replacementString: modified) {
            let storage = textStorage!
            storage.beginEditing()
            storage.replaceCharacters(in: applyRange, with: modified)
            storage.endEditing()
            didChangeText()

            // Leave cursor at the end of the replaced range
            let newLen = (modified as NSString).length
            setSelectedRange(NSRange(location: applyRange.location + newLen, length: 0))
            // didChangeText() above already syncs content via textDidChange delegate.
        }
    }

    // MARK: - Smart Selection state
    // Tracks consecutive presses of the same selection shortcut, and cross-mode
    // extension (switching from one shortcut to another while selection is active).
    //
    // Rule: as long as the current selection still matches what the last smart-select
    // set (cursor hasn't moved / user hasn't typed), pressing ANY smart-select shortcut
    // extends the selection forward by one more unit of the new type.

    private var lastSmartSelectAction: ShortcutAction? = nil
    private var lastSmartSelectRange: NSRange = NSRange(location: NSNotFound, length: 0)
    private var smartSelectCount: Int = 0
    /// Stack of selection states before each extension — enables undo via deselect.
    private var selectionHistory: [NSRange] = []

    /// Updates state and returns `(count, cross)` where:
    /// - `count`  = consecutive same-action press count (≥1)
    /// - `cross`  = true when switching to a *different* action while selection is unchanged
    ///
    /// No time limit — as long as the selection hasn't changed, any smart-select press extends.
    @discardableResult
    private func updateSmartSelect(for action: ShortcutAction) -> (count: Int, cross: Bool) {
        let sel = selectedRange()
        let selActive = sel.length > 0 && sel == lastSmartSelectRange
        let sameAction = lastSmartSelectAction == action

        let count: Int
        let cross: Bool

        if selActive && sameAction {
            count = smartSelectCount + 1; cross = false
        } else if selActive && !sameAction {
            count = 1; cross = true
        } else {
            count = 1; cross = false
            selectionHistory.removeAll()  // Fresh start — discard undo history
        }

        smartSelectCount = count
        lastSmartSelectAction = action
        // Note: lastSmartSelectRange is updated by each individual selection function
        return (count, cross)
    }

    // MARK: - Smart Selection

    /// Select current line. Press again (or switch to another smart-select) to extend.
    private func selectLine() {
        let (count, cross) = updateSmartSelect(for: .selectLine)
        let ns = string as NSString
        let len = ns.length
        guard len > 0 else { return }
        let sel = selectedRange()
        selectionHistory.append(sel)          // save state for deselect undo

        if count > 1 || cross {
            // Extend: add the next line after the current selection end
            let selEnd = sel.location + sel.length
            if selEnd < len {
                let nextLine = ns.lineRange(for: NSRange(location: selEnd, length: 0))
                let newRange = NSRange(location: sel.location,
                                       length: nextLine.location + nextLine.length - sel.location)
                setSelectedRange(newRange)
                lastSmartSelectRange = newRange
            } else {
                selectionHistory.removeLast()  // nothing changed, discard
            }
            return
        }

        let loc = min(sel.location, len - 1)
        let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
        setSelectedRange(lineRange)
        lastSmartSelectRange = lineRange
    }

    /// Select the word at the cursor; press again (or cross-mode) to include the next word.
    private func selectWord() {
        let (count, cross) = updateSmartSelect(for: .selectWord)
        let ns = string as NSString
        let len = ns.length
        guard len > 0 else { return }
        let sel = selectedRange()
        selectionHistory.append(sel)

        if count > 1 || cross {
            // Extend: skip whitespace then grab the next word
            var pos = sel.location + sel.length
            while pos < len, CharacterSet.whitespaces.contains(sc(pos, in: ns)) { pos += 1 }
            if pos < len {
                let next = selectionRange(forProposedRange: NSRange(location: pos, length: 0),
                                          granularity: .selectByWord)
                let newRange = NSRange(location: sel.location,
                                       length: next.location + next.length - sel.location)
                setSelectedRange(newRange)
                lastSmartSelectRange = newRange
            } else {
                selectionHistory.removeLast()
            }
            return
        }

        let loc = min(sel.location, len - 1)
        let wordRange = selectionRange(forProposedRange: NSRange(location: loc, length: 0),
                                       granularity: .selectByWord)
        setSelectedRange(wordRange)
        lastSmartSelectRange = wordRange
    }

    /// Select the sentence at the cursor; press again (or cross-mode) to extend.
    private func selectSentence() {
        let (count, cross) = updateSmartSelect(for: .selectSentence)
        let ns = string as NSString
        let len = ns.length
        guard len > 0 else { return }
        let sel = selectedRange()
        selectionHistory.append(sel)

        if count > 1 || cross {
            // Extend: find the end of the next sentence from selection end
            let nextEnd = sentenceEnd(from: sel.location + sel.length, in: ns, len: len)
            if nextEnd > sel.location + sel.length {
                let newRange = NSRange(location: sel.location, length: nextEnd - sel.location)
                setSelectedRange(newRange)
                lastSmartSelectRange = newRange
            } else {
                selectionHistory.removeLast()
            }
            return
        }

        let loc = min(sel.location, len - 1)
        let r = sentenceRange(around: loc, in: ns, len: len)
        setSelectedRange(r)
        lastSmartSelectRange = r
    }

    /// Select the Markdown paragraph at the cursor.
    /// Press again to extend to the next paragraph.
    /// Three consecutive same-action presses → select the entire document.
    /// Cross-mode: if another smart-select is active, extend by the next paragraph.
    private func selectMarkdownParagraph() {
        let (count, cross) = updateSmartSelect(for: .selectParagraph)
        let ns = string as NSString
        let len = ns.length
        guard len > 0 else { return }
        let sel = selectedRange()

        selectionHistory.append(sel)

        // 3rd+ same-action press → select all (not triggered by cross-mode)
        if !cross && count >= 3 {
            let all = NSRange(location: 0, length: len)
            setSelectedRange(all)
            lastSmartSelectRange = all
            return
        }

        // 2nd same-action press OR cross-mode → extend to the next paragraph
        if count >= 2 || cross {
            let selEnd = sel.location + sel.length
            // Skip blank separator lines
            var nextStart = selEnd
            while nextStart < len {
                let lr = ns.lineRange(for: NSRange(location: nextStart, length: 0))
                if !ns.substring(with: lr).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                nextStart = lr.location + lr.length
            }
            // Advance to end of the next paragraph
            var nextEnd = nextStart
            while nextEnd < len {
                let lr = ns.lineRange(for: NSRange(location: nextEnd, length: 0))
                nextEnd = lr.location + lr.length
                if ns.substring(with: lr).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                if nextEnd >= len { break }
            }
            if nextStart < len {
                let newRange = NSRange(location: sel.location, length: nextEnd - sel.location)
                setSelectedRange(newRange)
                lastSmartSelectRange = newRange
            } else {
                selectionHistory.removeLast()
            }
            return
        }

        // 1st press → select the paragraph containing the cursor
        let loc = min(sel.location, len - 1)
        var start = loc
        while start > 0 {
            let prev = ns.lineRange(for: NSRange(location: start - 1, length: 0))
            if ns.substring(with: prev).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            start = prev.location
        }
        var end = loc
        while end < len {
            let lr = ns.lineRange(for: NSRange(location: end, length: 0))
            end = lr.location + lr.length
            if ns.substring(with: lr).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            if end >= len { break }
        }
        let paraRange = NSRange(location: start, length: end - start)
        setSelectedRange(paraRange)
        lastSmartSelectRange = paraRange
    }

    /// Select the current list item and all its indented children (no extend mode).
    private func selectListBranch() {
        let ns = string as NSString
        let len = ns.length
        guard len > 0 else { return }
        let prevSel = selectedRange()

        // Reset smart-select state (list branch doesn't support extend)
        selectionHistory.removeAll()
        lastSmartSelectAction = .selectList
        smartSelectCount = 1

        let loc = min(prevSel.location, len - 1)
        let itemRange = ns.lineRange(for: NSRange(location: loc, length: 0))
        let baseIndent = leadingIndent(of: ns.substring(with: itemRange))

        var end = itemRange.location + itemRange.length
        var pos = end
        while pos < len {
            let nextRange = ns.lineRange(for: NSRange(location: pos, length: 0))
            let nextLine  = ns.substring(with: nextRange)
            if nextLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            if leadingIndent(of: nextLine) <= baseIndent { break }
            end = nextRange.location + nextRange.length
            pos = end
        }
        let newRange = NSRange(location: itemRange.location, length: end - itemRange.location)
        selectionHistory.append(prevSel)      // save cursor for single deselect
        setSelectedRange(newRange)
        lastSmartSelectRange = newRange
    }

    // MARK: - Deselect (undo last selection extension)

    /// Pops the last selection state from history, restoring the selection to what it
    /// was just before the most recent smart-select extension.
    private func performDeselect() {
        guard !selectionHistory.isEmpty else { return }
        let prev = selectionHistory.removeLast()
        setSelectedRange(prev)
        lastSmartSelectRange = prev
        smartSelectCount = selectionHistory.count
    }

    // MARK: - Selection helpers

    /// Safe unichar → UnicodeScalar conversion; returns null scalar for surrogate halves.
    private func sc(_ i: Int, in ns: NSString) -> UnicodeScalar {
        UnicodeScalar(UInt32(ns.character(at: i))) ?? UnicodeScalar("\0")
    }

    private func sentenceRange(around loc: Int, in ns: NSString, len: Int) -> NSRange {
        let terminators = CharacterSet(charactersIn: ".!?。！？")
        let wsNl = CharacterSet.whitespacesAndNewlines
        var start = loc
        while start > 0 {
            let scalar = sc(start - 1, in: ns)
            let prev   = start >= 2 ? sc(start - 2, in: ns) : UnicodeScalar("\0")
            if terminators.contains(prev), wsNl.contains(scalar) { break }
            if scalar.value == UInt32(UInt8(ascii: "\n")) { break }
            start -= 1
        }
        while start < loc, wsNl.contains(sc(start, in: ns)) { start += 1 }
        let end = sentenceEnd(from: loc, in: ns, len: len)
        return NSRange(location: start, length: end - start)
    }

    private func sentenceEnd(from pos: Int, in ns: NSString, len: Int) -> Int {
        let terminators = CharacterSet(charactersIn: ".!?。！？")
        var end = pos
        while end < len {
            let scalar = sc(end, in: ns)
            end += 1
            if terminators.contains(scalar) { break }
            if scalar.value == UInt32(UInt8(ascii: "\n")) { break }
        }
        return end
    }

    private func leadingIndent(of line: String) -> Int {
        var count = 0
        for ch in line {
            if ch == " " { count += 1 }
            else if ch == "\t" { count += 4 }
            else { break }
        }
        return count
    }

    private var newlineChar: unichar { unichar(UInt8(ascii: "\n")) }

    // MARK: - Folding

    /// Fold upward: if cursor is inside a child item, fold at the parent one level above.
    /// If there is no parent (already at the top level), fold the current line's own children.
    /// Successive presses keep climbing one level higher.
    func foldAtCursor() {
        let loc = selectedRange().location
        let ns = string as NSString
        let len = ns.length
        guard len > 0 else { return }
        let safeLoc = min(loc, len - 1)

        if let parentRange = findParentLine(of: safeLoc) {
            // Don't fold a parent that is already folded
            guard !foldRecords.contains(where: { NSLocationInRange($0.placeholderRange.location, parentRange) }) else { return }
            guard let children = childrenRange(forLineAt: parentRange.location) else { return }
            performFold(childrenRange: children)
        } else {
            // No parent — fold the current line's own children (top-level item)
            let lineRange = ns.lineRange(for: NSRange(location: safeLoc, length: 0))
            guard !foldRecords.contains(where: { NSLocationInRange($0.placeholderRange.location, lineRange) }) else { return }
            guard let children = childrenRange(forLineAt: safeLoc) else { return }
            performFold(childrenRange: children)
        }
    }

    /// Unfold one level: unfold the fold on the current line (if any).
    /// After unfolding, cursor moves into the first revealed child so the next
    /// press continues unfolding inward.
    func unfoldAtCursor() {
        let loc = selectedRange().location
        let ns = string as NSString
        let len = ns.length
        guard len > 0 else { return }
        let lineRange = ns.lineRange(for: NSRange(location: min(loc, len - 1), length: 0))
        if let idx = foldRecords.firstIndex(where: { NSLocationInRange($0.placeholderRange.location, lineRange) }) {
            unfoldRecord(at: idx)
        }
    }

    /// Find the parent line of the line at `location`.
    /// - List items: nearest list item above with strictly smaller indent
    /// - Headings: nearest heading above with lower level
    /// - Plain text: nearest foldable line (heading or list item) above
    private func findParentLine(of location: Int) -> NSRange? {
        let ns = string as NSString
        let len = ns.length
        guard len > 0, location > 0 else { return nil }
        let safeLoc = min(location, len - 1)

        let currentLineRange = ns.lineRange(for: NSRange(location: safeLoc, length: 0))
        guard currentLineRange.location > 0 else { return nil }

        let currentLine    = ns.substring(with: currentLineRange)
        let currentTrimmed = currentLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let isList         = isListItem(currentTrimmed)
        let currentIndent  = isList ? leadingIndent(of: currentLine) : Int.max
        let curHeadLevel   = headingLevel(of: currentTrimmed)

        var searchPos = currentLineRange.location
        while searchPos > 0 {
            searchPos -= 1
            let prevRange   = ns.lineRange(for: NSRange(location: searchPos, length: 0))
            let prevLine    = ns.substring(with: prevRange)
            let prevTrimmed = prevLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if isList {
                if isListItem(prevTrimmed) && leadingIndent(of: prevLine) < currentIndent {
                    return prevRange  // Parent list item with lower indent
                }
                if headingLevel(of: prevTrimmed) != nil {
                    return prevRange  // Enclosing heading acts as parent
                }
            } else if let curLevel = curHeadLevel {
                if let prevLevel = headingLevel(of: prevTrimmed), prevLevel < curLevel {
                    return prevRange  // Parent heading
                }
            } else {
                // Plain text: nearest foldable ancestor
                if isListItem(prevTrimmed) || headingLevel(of: prevTrimmed) != nil {
                    return prevRange
                }
            }

            searchPos = prevRange.location
        }
        return nil
    }

    func foldAllBlocks() {
        if !foldRecords.isEmpty { unfoldAll(sync: false) }

        let ns = string as NSString
        let len = ns.length
        var blocks: [NSRange] = []
        var charIndex = 0

        while charIndex < len {
            let lineRange = ns.lineRange(for: NSRange(location: charIndex, length: 0))
            guard lineRange.length > 0 else { break }
            if let children = childrenRange(forLineAt: charIndex) {
                blocks.append(children)
                charIndex = children.location + children.length
            } else {
                charIndex = lineRange.location + lineRange.length
            }
        }

        // Fold bottom-to-top so positions above are unaffected
        for children in blocks.sorted(by: { $0.location > $1.location }) {
            performFold(childrenRange: children)
        }
    }

    func unfoldAll(sync: Bool = true) {
        guard !foldRecords.isEmpty else { return }
        isFolding = true
        let storage = textStorage!
        let sorted = foldRecords.sorted { $0.placeholderRange.location > $1.placeholderRange.location }
        foldRecords.removeAll()
        storage.beginEditing()
        for record in sorted {
            storage.replaceCharacters(in: record.placeholderRange, with: record.originalContent)
        }
        storage.endEditing()
        isFolding = false
        needsDisplay = true
        if sync { onTextChange?(string) }
    }

    func clearFolds() {
        foldRecords.removeAll()
        needsDisplay = true
    }

    // MARK: - Fold / cursor state persistence

    /// Converts current fold records + cursor to true-content coordinates and saves to disk.
    func saveState(for noteID: UUID) {
        let phLen = ("…\n" as NSString).length   // always 2
        let sorted = foldRecords.sorted { $0.placeholderRange.location < $1.placeholderRange.location }
        var cumExpansion = 0
        var foldInfos: [SavedEditorState.FoldInfo] = []
        for fold in sorted {
            let trueOff = fold.placeholderRange.location + cumExpansion
            let origLen = (fold.originalContent as NSString).length
            foldInfos.append(.init(trueOffset: trueOff, originalLength: origLen))
            cumExpansion += origLen - phLen
        }

        // Cursor: displayed → true content
        let displayedCursor = selectedRange().location
        var trueCursor = displayedCursor
        for fold in sorted where fold.placeholderRange.location < displayedCursor {
            trueCursor += (fold.originalContent as NSString).length - phLen
        }

        EditorStateStore.shared.save(
            SavedEditorState(folds: foldInfos, cursorOffset: trueCursor),
            for: noteID
        )
    }

    /// Applies persisted folds + restores cursor. Call AFTER `string` has been set to the true content.
    func restoreState(for noteID: UUID) {
        guard let state = EditorStateStore.shared.state(for: noteID) else {
            setSelectedRange(NSRange(location: 0, length: 0))
            return
        }
        let phLen = ("…\n" as NSString).length   // always 2
        let _ = string as NSString

        // Apply folds in ASCENDING order of trueOffset.
        // Each fold shifts all subsequent offsets, so we track a running total.
        let sortedFolds = state.folds.sorted { $0.trueOffset < $1.trueOffset }
        var totalShift = 0
        for foldInfo in sortedFolds {
            let adjustedOffset = foldInfo.trueOffset + totalShift
            let len = foldInfo.originalLength
            guard len > 1,
                  adjustedOffset >= 0,
                  adjustedOffset + len <= (string as NSString).length,
                  (string as NSString).character(at: adjustedOffset) == 0x0A /* '\n' */ else {
                totalShift += phLen - len   // keep shift in sync even for skipped folds
                continue
            }
            let childrenRange = NSRange(location: adjustedOffset + 1, length: len - 1)
            performFold(childrenRange: childrenRange)
            totalShift += phLen - len
        }

        // Convert true-content cursor → displayed cursor
        var displayedCursor = state.cursorOffset
        for foldInfo in sortedFolds {
            let trueEnd = foldInfo.trueOffset + foldInfo.originalLength
            if trueEnd <= state.cursorOffset {
                // Fold is entirely before cursor
                displayedCursor += phLen - foldInfo.originalLength
            } else if foldInfo.trueOffset < state.cursorOffset {
                // Cursor was inside folded content — place at fold start
                displayedCursor = foldInfo.trueOffset
                // apply shifts from earlier folds
                var shift = 0
                for earlier in sortedFolds where earlier.trueOffset < foldInfo.trueOffset {
                    shift += phLen - earlier.originalLength
                }
                displayedCursor += shift
                break
            }
        }

        let safeLen = (string as NSString).length
        let safeCursor = min(max(0, displayedCursor), safeLen)
        setSelectedRange(NSRange(location: safeCursor, length: 0))
        scrollRangeToVisible(NSRange(location: safeCursor, length: 0))
    }

    /// Jump to a specific line (0-indexed)
    func jumpToLine(_ line: Int, centerInViewport: Bool = false) {
        let lines = string.components(separatedBy: "\n")
        guard line >= 0 && line < lines.count else { return }

        // Calculate the character position at the start of the target line
        var targetPosition = 0
        for i in 0..<line {
            targetPosition += lines[i].count + 1  // +1 for the newline character
        }

        let safeLen = (string as NSString).length
        let safePosition = min(targetPosition, safeLen)

        setSelectedRange(NSRange(location: safePosition, length: 0))

        if centerInViewport, let scrollView = enclosingScrollView {
            // Get visible height and estimate line height
            let visibleHeight = scrollView.documentVisibleRect.height
            let lineHeight = self.font?.boundingRectForFont.height ?? 20

            // Position the line at approximately 1/3 from the top
            let targetY = CGFloat(line) * lineHeight - visibleHeight * 0.33
            let scrollPoint = NSPoint(x: 0, y: max(0, targetY))
            scrollView.contentView.scroll(to: scrollPoint)
        } else {
            scrollRangeToVisible(NSRange(location: safePosition, length: 0))
        }
    }

    /// Highlight task text with yellow background and dim other content
    func highlightTaskText(_ taskText: String) {
        guard let textStorage = self.textStorage else { return }

        let fullText = string as NSString
        let searchRange = NSRange(location: 0, length: fullText.length)

        // First, dim all non-task content
        textStorage.addAttribute(.foregroundColor, value: NSColor.textColor.withAlphaComponent(0.15), range: searchRange)

        // Find and highlight task text
        var currentLocation = 0
        var foundAny = false
        while currentLocation < fullText.length {
            let searchRange = NSRange(location: currentLocation, length: fullText.length - currentLocation)
            let foundRange = fullText.range(of: taskText, options: .caseInsensitive, range: searchRange)

            if foundRange.location == NSNotFound {
                break
            }

            // Restore normal color for the task text
            textStorage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: foundRange)
            // Apply yellow background highlight
            textStorage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.4), range: foundRange)
            foundAny = true
            currentLocation = foundRange.location + foundRange.length
        }

        // Set selection to the first match
        if foundAny {
            let searchOptions: NSString.CompareOptions = [.caseInsensitive]
            let firstMatch = fullText.range(of: taskText, options: searchOptions)
            if firstMatch.location != NSNotFound {
                setSelectedRange(firstMatch)
                scrollRangeToVisible(firstMatch)
            }
        }
    }

    /// Called by the storage delegate after every user edit to keep fold
    /// record positions in sync with the modified text.
    /// `editedRange` is in the NEW text coordinate space; `delta` = changeInLength.
    func shiftFoldPositions(editedRange: NSRange, delta: Int) {
        guard !foldRecords.isEmpty else { return }
        // Characters originally at position >= oldEditEnd shift by delta.
        let oldEditEnd = editedRange.location + editedRange.length - delta
        for i in foldRecords.indices {
            if foldRecords[i].placeholderRange.location >= oldEditEnd {
                foldRecords[i].placeholderRange.location += delta
            }
        }
        needsDisplay = true
    }

    /// Reconstructs the full note content with all fold placeholders (`…\n`)
    /// replaced by their original text, including recursively nested folds.
    /// This is what gets saved to `note.content`; folding is display-only.
    func trueContent() -> String {
        guard !foldRecords.isEmpty else { return string }
        var result = string as NSString
        let sorted = foldRecords.sorted { $0.placeholderRange.location > $1.placeholderRange.location }
        for record in sorted {
            let range = record.placeholderRange
            guard range.location + range.length <= result.length,
                  result.substring(with: range) == "…\n" else { continue }
            result = result.replacingCharacters(in: range, with: Self.expandRecord(record)) as NSString
        }
        return result as String
    }

    /// Recursively expands a fold record's originalContent by substituting
    /// nested fold placeholders (stored with positions RELATIVE to that content).
    private static func expandRecord(_ record: FoldRecord) -> String {
        guard !record.nestedFolds.isEmpty else { return record.originalContent }
        var result = record.originalContent as NSString
        let sorted = record.nestedFolds.sorted { $0.placeholderRange.location > $1.placeholderRange.location }
        for nested in sorted {
            let range = nested.placeholderRange
            guard range.location + range.length <= result.length,
                  result.substring(with: range) == "…\n" else { continue }
            result = result.replacingCharacters(in: range, with: expandRecord(nested)) as NSString
        }
        return result as String
    }

    private func unfoldRecord(at index: Int) {
        let record = foldRecords.remove(at: index)
        isFolding = true
        let storage = textStorage!
        storage.beginEditing()
        storage.replaceCharacters(in: record.placeholderRange, with: record.originalContent)
        storage.endEditing()
        isFolding = false

        let delta = (record.originalContent as NSString).length - record.placeholderRange.length
        for i in foldRecords.indices {
            if foldRecords[i].placeholderRange.location > record.placeholderRange.location {
                foldRecords[i].placeholderRange.location += delta
            }
        }

        // Re-activate nested folds, converting their positions from relative
        // (relative to this record's foldRange.location) back to absolute.
        let base = record.placeholderRange.location
        foldRecords.append(contentsOf: record.nestedFolds.map { nested in
            var r = nested
            r.placeholderRange.location += base
            return r
        })

        // Move cursor to the first revealed child line (past the leading \n).
        let childrenStart = record.placeholderRange.location + 1
        let safeStart = min(childrenStart, (string as NSString).length)
        setSelectedRange(NSRange(location: safeStart, length: 0))
        needsDisplay = true
        // Sync the full unfolded content (other folds may still be active)
        onTextChange?(trueContent())
    }

    private func performFold(childrenRange: NSRange) {
        guard childrenRange.location > 0 else { return }
        let foldRange = NSRange(location: childrenRange.location - 1,
                                length: 1 + childrenRange.length)
        let ns = string as NSString
        let originalContent = ns.substring(with: foldRange)  // "\n" + children
        let placeholder = "…\n"

        // Collect inner folds inside foldRange, convert their positions to RELATIVE
        // (offset from foldRange.location).  Relative positions stay correct even
        // when the outer fold record shifts due to user edits above it.
        let nested = foldRecords
            .filter { NSLocationInRange($0.placeholderRange.location, foldRange) }
            .map { record -> FoldRecord in
                var r = record
                r.placeholderRange.location -= foldRange.location
                return r
            }
        foldRecords.removeAll { NSLocationInRange($0.placeholderRange.location, foldRange) }

        isFolding = true
        let storage = textStorage!
        storage.beginEditing()
        storage.replaceCharacters(in: foldRange, with: placeholder)
        storage.endEditing()
        isFolding = false

        let phLen = (placeholder as NSString).length
        foldRecords.append(FoldRecord(
            placeholderRange: NSRange(location: foldRange.location, length: phLen),
            originalContent: originalContent,
            nestedFolds: nested
        ))
        setSelectedRange(NSRange(location: foldRange.location, length: 0))
        needsDisplay = true
    }

    // MARK: - Block detection helpers

    /// Returns the range of children lines for the foldable block whose parent line
    /// contains `location`. Returns nil if the line has no children to fold.
    private func childrenRange(forLineAt location: Int) -> NSRange? {
        let ns = string as NSString
        let len = ns.length
        guard len > 0 else { return nil }
        let safeLoc = min(location, len - 1)

        let currentLineRange = ns.lineRange(for: NSRange(location: safeLoc, length: 0))
        let currentLine = ns.substring(with: currentLineRange)
        let trimmed = currentLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let childStart = currentLineRange.location + currentLineRange.length
        guard childStart < len else { return nil }

        // Heading block
        if let level = headingLevel(of: trimmed) {
            var end = childStart
            while end < len {
                let r = ns.lineRange(for: NSRange(location: end, length: 0))
                guard r.length > 0 else { break }
                let t = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
                if let l = headingLevel(of: t), l <= level { break }
                end = r.location + r.length
            }
            guard end > childStart else { return nil }
            return NSRange(location: childStart, length: end - childStart)
        }

        // List item block
        if isListItem(trimmed) {
            let baseIndent = leadingIndent(of: currentLine)
            var end = childStart
            while end < len {
                let r = ns.lineRange(for: NSRange(location: end, length: 0))
                guard r.length > 0 else { break }
                let nextLine = ns.substring(with: r)
                let nextTrimmed = nextLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if nextTrimmed.isEmpty { break }
                if leadingIndent(of: nextLine) <= baseIndent { break }
                end = r.location + r.length
            }
            guard end > childStart else { return nil }
            return NSRange(location: childStart, length: end - childStart)
        }

        return nil
    }

    private func headingLevel(of trimmed: String) -> Int? {
        guard trimmed.hasPrefix("#") else { return nil }
        var level = 0
        for ch in trimmed {
            if ch == "#" { level += 1 }
            else if ch == " " { return (1...6).contains(level) ? level : nil }
            else { return nil }
        }
        return nil
    }

    private func isListItem(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") { return true }
        if trimmed.hasPrefix("- [") || trimmed.hasPrefix("* [") || trimmed.hasPrefix("+ [") { return true }
        // Ordered list: "1. " etc.
        var i = trimmed.startIndex
        while i < trimmed.endIndex, trimmed[i].isNumber { i = trimmed.index(after: i) }
        if i > trimmed.startIndex, i < trimmed.endIndex, trimmed[i] == "." { return true }
        return false
    }

    // MARK: - Gutter drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawFoldIndicators()
        if typewriterFocusMode != .off {
            drawTypewriterFocusOverlay(in: dirtyRect)
        }
    }

    private func drawFoldIndicators() {
        guard let lm = layoutManager, let tc = textContainer else { return }
        let origin = textContainerOrigin
        let ns = string as NSString
        let len = ns.length

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        // Draw ▶ for folded blocks (at the parent line's Y position)
        for record in foldRecords {
            let parentEnd = record.placeholderRange.location
            guard parentEnd > 0 else { continue }
            let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: parentEnd - 1, length: 1),
                                       actualCharacterRange: nil)
            guard glyphs.location != NSNotFound else { continue }
            let lineRect = lm.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            drawIndicator("▶", lineRect: lineRect.offsetBy(dx: origin.x, dy: origin.y), attrs: attrs)
        }

        // Draw ▾ for foldable-but-not-yet-folded lines
        var charIndex = 0
        while charIndex < len {
            let lineRange = ns.lineRange(for: NSRange(location: charIndex, length: 0))
            guard lineRange.length > 0 else { break }

            let line = ns.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // A line is already folded if any fold placeholder falls within it
            let alreadyFolded = foldRecords.contains { NSLocationInRange($0.placeholderRange.location, lineRange) }

            if !trimmed.isEmpty && !alreadyFolded &&
               (headingLevel(of: trimmed) != nil || isListItem(trimmed)) &&
               childrenRange(forLineAt: charIndex) != nil {
                let glyphs = lm.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
                if glyphs.location != NSNotFound {
                    let lineRect = lm.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                    drawIndicator("▾", lineRect: lineRect.offsetBy(dx: origin.x, dy: origin.y), attrs: attrs)
                }
            }

            charIndex = lineRange.location + lineRange.length
        }
        _ = tc  // suppress unused warning
    }

    private func drawIndicator(_ symbol: String, lineRect: CGRect, attrs: [NSAttributedString.Key: Any]) {
        let size = (symbol as NSString).size(withAttributes: attrs)
        let x = textContainerInset.width - size.width - 4
        let y = lineRect.minY + (lineRect.height - size.height) / 2
        (symbol as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }

    // MARK: - Gutter mouse click

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Gutter area: left of textContainerInset.width
        if point.x < textContainerInset.width - 2,
           let lm = layoutManager, let tc = textContainer {
            let containerPt = NSPoint(x: 0, y: point.y - textContainerOrigin.y)
            let glyphIdx = lm.glyphIndex(for: containerPt, in: tc)
            let charIdx = lm.characterIndexForGlyph(at: glyphIdx)

            // Find which line was clicked
            let ns = string as NSString
            let len2 = ns.length
            guard len2 > 0 else { super.mouseDown(with: event); return }
            let clickedLineRange = ns.lineRange(for: NSRange(location: min(charIdx, len2 - 1), length: 0))

            // If this line is folded, unfold it; otherwise fold it
            if let idx = foldRecords.firstIndex(where: { NSLocationInRange($0.placeholderRange.location, clickedLineRange) }) {
                unfoldRecord(at: idx)
            } else if let children = childrenRange(forLineAt: charIdx) {
                performFold(childrenRange: children)
            }
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: - Prevent editing inside fold placeholders

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if isFolding { return true }
        for record in foldRecords {
            if NSIntersectionRange(affectedCharRange, record.placeholderRange).length > 0 {
                return false
            }
        }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    // MARK: - Paired symbol wrapping

    /// When text is selected and the user types an opening bracket, wrap the
    /// selection with the matching pair instead of replacing it.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let insertStr: String
        if let s = string as? String { insertStr = s }
        else if let as_ = string as? NSAttributedString { insertStr = as_.string }
        else { super.insertText(string, replacementRange: replacementRange); return }

        let sel = selectedRange()
        let pairsEnabled = editorSettings?.autoPairBrackets ?? true
        guard pairsEnabled,
              sel.length > 0,
              insertStr.count == 1,
              let closing = pairMap[insertStr] else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        let ns = self.string as NSString
        let selected = ns.substring(with: sel)
        let wrapped = insertStr + selected + closing
        super.insertText(wrapped, replacementRange: sel)
        // Re-select just the original text (inside the new pair)
        setSelectedRange(NSRange(location: sel.location + 1, length: sel.length))
    }

    private let pairMap: [String: String] = [
        "(": ")",
        "[": "]",
        "{": "}",
        "（": "）",
        "【": "】",
        "《": "》",
        "「": "」",
        "『": "』",
        "〔": "〕",
        "〈": "〉",
        "<": ">",
    ]
}

// MARK: - SwiftUI Wrapper

struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var noteID: UUID
    var shortcutSettings: ShortcutSettings
    var editorSettings: EditorSettings
    var holder: TextViewHolder? = nil
    var onTextChange: (() -> Void)?
    var onTogglePreview: (() -> Void)?
    var onClaudeWrite: (() -> Void)?
    var onRevealInFinder: (() -> Void)?
    var outlineMode: Bool = false
    var typewriterMode: Bool = false
    var typewriterScrollFraction: CGFloat = 0.5
    var typewriterFocusMode: EditorSettings.TypewriterFocusMode = .off
    var typewriterMarkLine: Bool = false
    var jumpToLine: Int? = nil
    var highlightTaskText: String? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let contentSize = scrollView.contentSize

        let textContainer = NSTextContainer(size: NSSize(
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        ))
        textContainer.widthTracksTextView = true

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)
        textStorage.delegate = context.coordinator  // track edits for fold position updates

        let textView = MarkdownEditorNSTextView(
            frame: NSRect(origin: .zero, size: contentSize),
            textContainer: textContainer
        )
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        // Appearance
        textView.textColor = .textColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 32, height: 12)
        textView.insertionPointColor = .controlAccentColor

        // Behavior (base — will be overridden by applyEditorSettings below)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        // Apply all editor settings (font, line height, toggles)
        textView.editorSettings = editorSettings
        textView.applyEditorSettings(editorSettings)

        // Set initial text
        textView.string = text

        // Callbacks
        textView.delegate = context.coordinator
        textView.shortcutSettings = shortcutSettings
        textView.editorSettings = editorSettings
        textView.onTogglePreview = onTogglePreview
        textView.onClaudeWrite = onClaudeWrite
        textView.onRevealInFinder = onRevealInFinder
        let coordinator = context.coordinator
        textView.onTextChange = { newText in
            coordinator.updateBinding(newText)
        }

        context.coordinator.textView = textView
        holder?.textView = textView

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownEditorNSTextView else { return }

        // Keep coordinator's parent reference current so callbacks see latest holder/closures
        context.coordinator.parent = self

        // Update lightweight references (no side effects)
        textView.shortcutSettings = shortcutSettings
        textView.editorSettings = editorSettings
        textView.onTogglePreview = onTogglePreview
        textView.onClaudeWrite = onClaudeWrite
        textView.onRevealInFinder = onRevealInFinder
        textView.outlineMode            = outlineMode
        textView.typewriterMode         = typewriterMode
        textView.typewriterScrollFraction = typewriterScrollFraction
        textView.typewriterFocusMode    = typewriterFocusMode
        textView.typewriterMarkLine     = typewriterMarkLine

        // Apply display settings (font, colors, paragraph style) only when they changed.
        // applyEditorSettings modifies text storage attributes, so calling it on every
        // keystroke (NoteEditorView re-renders for word count on every character) is
        // expensive and can interfere with cursor stability.
        let sv = editorSettings.settingsVersion
        if sv != context.coordinator.lastSettingsVersion {
            context.coordinator.lastSettingsVersion = sv
            textView.applyEditorSettings(editorSettings)
        }

        // Only reset text when it changed externally — NOT on every normal keystroke.
        // Compare true content (folds expanded) against the binding value.
        let noteChanged = noteID != context.coordinator.lastNoteID
        // Chinese IME: never reset the text view's content while the user is composing.
        // textView.string= clears marked text, causing cursor jumps and swallowed characters.
        // The composition will commit normally and textDidChange will sync the binding then.
        if !context.coordinator.isUpdating && !textView.hasMarkedText()
            && (noteChanged || textView.trueContent() != text) {
            context.coordinator.isUpdating = true
            let savedRange = textView.selectedRange()
            textView.clearFolds()
            textView.string = text
            textView.highlightWikiLinks()  // apply [[...]] colors after programmatic set
            context.coordinator.isUpdating = false

            if noteChanged {
                // Restore persisted fold state and cursor for the newly loaded note.
                context.coordinator.lastNoteID = noteID
                textView.restoreState(for: noteID)
            } else {
                // Restore cursor and scroll position (textView.string= resets both to top).
                let newLen = (text as NSString).length
                let restoreAt = min(savedRange.location, newLen)
                textView.setSelectedRange(NSRange(location: restoreAt, length: 0))
                textView.scrollRangeToVisible(NSRange(location: restoreAt, length: 0))
            }

            // Handle jumpToLine if provided
            if let line = jumpToLine, line >= 0 {
                DispatchQueue.main.async {
                    textView.jumpToLine(line, centerInViewport: true)
                }
            }

            // Handle task text highlighting
            if let taskText = highlightTaskText, !taskText.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    textView.highlightTaskText(taskText)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: MarkdownTextView
        weak var textView: MarkdownEditorNSTextView?
        var isUpdating = false
        var lastNoteID: UUID? = nil
        /// Tracks the last EditorSettings.settingsVersion applied to the text view.
        /// applyEditorSettings is skipped when this matches the current version.
        var lastSettingsVersion: Int = -1

        init(_ parent: MarkdownTextView) {
            self.parent = parent
        }

        func updateBinding(_ newText: String) {
            guard !isUpdating else { return }
            isUpdating = true
            parent.text = newText
            parent.onTextChange?()
            isUpdating = false
        }

        // MARK: NSTextStorageDelegate

        // willProcessEditing: intentionally left empty.
        // Do NOT call highlightWikiLinks here — it calls removeAttribute/addAttribute on the
        // full document range, which merges into the NSTextStorage editedRange and causes
        // didProcessEditing to receive [0, fullLength] instead of the actual character-edit
        // range.  shiftFoldPositions then computes oldEditEnd = fullLength-1 and skips shifting
        // all fold records that follow the cursor, causing fold positions to drift after every
        // keystroke.  The drifted positions make trueContent() return the placeholder "…\n"
        // instead of the true text, which triggers the full textView.string= reset in
        // updateNSView and jumps the cursor to the end of the document.
        func textStorage(_ textStorage: NSTextStorage,
                         willProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange,
                         changeInLength delta: Int) {}

        // didProcessEditing: keep fold record positions in sync with the text, then apply
        // [[wiki link]] syntax highlighting.  Apple docs explicitly permit attribute changes
        // here and guarantee the editedRange reflects only character edits, so
        // shiftFoldPositions receives the correct narrow range.  The subsequent attribute
        // changes from highlightWikiLinks re-fire didProcessEditing with .editedAttributes
        // only; the .editedCharacters guard below stops the recursion.
        func textStorage(_ textStorage: NSTextStorage,
                         didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange,
                         changeInLength delta: Int) {
            guard !isUpdating,
                  let tv = textView,
                  !tv.isFolding,
                  editedMask.contains(.editedCharacters) else { return }
            // Fold positions must track every edit including IME composition steps.
            tv.shiftFoldPositions(editedRange: editedRange, delta: delta)
            // Chinese IME: skip attribute changes while composing.  highlightWikiLinks
            // applies removeAttribute/addAttribute over ranges that overlap the marked-text
            // range, stripping the IME's composition underline and corrupting its state.
            // The highlight runs once after the final commit (hasMarkedText returns false).
            guard !tv.hasMarkedText() else { return }
            tv.highlightWikiLinks(in: textStorage)
        }

        // MARK: NSTextViewDelegate
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownEditorNSTextView else { return }
            guard !isUpdating, !textView.isFolding else { return }
            // Chinese IME: while the user is composing (marked text present), the text storage
            // holds intermediate pinyin/candidates — not committed characters.  Don't push these
            // to the binding: that would trigger updateNSView → textView.string = text which
            // destroys the marked-text range and jumps the cursor.  The final commit fires
            // textDidChange once more with hasMarkedText() == false, at which point we sync.
            guard !textView.hasMarkedText() else { return }
            // Fold positions were already updated by storageDidProcessEditing above.
            // Sync the TRUE content (placeholders expanded) so note.content stays clean.
            updateBinding(textView.trueContent())
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdating,
                  let textView = notification.object as? MarkdownEditorNSTextView else { return }
            // Don't update cursor tracking or scroll during IME composition — selection
            // changes continuously as the user navigates candidates, and scrolling here
            // interferes with the candidate window position.
            guard !textView.hasMarkedText() else { return }
            parent.holder?.lastCursorLocation = textView.selectedRange().location
            textView.scrollCursorToCenter()
        }
    }
}
