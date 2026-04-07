import Foundation
import AppKit
import Observation

// MARK: - LayerEditorViewModel

/// Bridges existing shortcut/action logic to the new LayerEditor renderer.
/// Ports MarkdownEditorNSTextView.handleAction() to the new stack.
@Observable
final class LayerEditorViewModel {

    var textStorage: EditorTextStorage!
    var renderer: EditorRenderer!
    var shortcutSettings: ShortcutSettings!
    var editorSettings: EditorSettings!

    // MARK: - Action Dispatch

    func handleAction(_ action: ShortcutAction) -> Bool {
        switch action {
        case .panguSpacing:
            applyPanguSpacing(); return true
        case .togglePreview:
            return true  // handled by parent
        case .toggleOutline:
            return true  // handled by parent
        case .claudeWrite:
            return true  // handled by parent
        case .revealInFinder:
            return true  // handled by parent
        case .findInNote:
            return true  // TODO: find bar
        case .findReplaceInNote:
            return true  // TODO: find/replace bar
        case .selectLine:
            selectLine(); return true
        case .selectWord:
            selectWord(); return true
        case .selectSentence:
            selectSentence(); return true
        case .selectParagraph:
            selectParagraph(); return true
        case .selectList:
            selectListBranch(); return true
        case .deselectLine, .deselectWord, .deselectSentence, .deselectParagraph, .deselectList:
            deselect(); return true
        case .foldBlock:
            let foldLine = textStorage.cursorOffset
            let lines = renderer.cachedLineMetrics
            let idx = lines.firstIndex { foldLine >= $0.range.location && foldLine <= NSMaxRange($0.range) } ?? 0
            textStorage.foldAtCursor(lines: lines, cursorLine: idx)
            renderer.rebuildLayout(); return true
        case .unfoldBlock:
            let unfoldLine = textStorage.cursorOffset
            let ulLines = renderer.cachedLineMetrics
            let uIdx = ulLines.firstIndex { unfoldLine >= $0.range.location && unfoldLine <= NSMaxRange($0.range) } ?? 0
            textStorage.unfoldAtCursor(cursorLine: uIdx, lines: ulLines)
            renderer.rebuildLayout(); return true
        case .foldAll:
            textStorage.foldAll(lines: renderer.cachedLineMetrics); return true
        case .unfoldAll:
            textStorage.unfoldAll(); return true
        case .moveLineUp:
            moveLine(up: true); return true
        case .moveLineDown:
            moveLine(up: false); return true
        case .indent:
            if headingLevelAtCursor() != nil {
                applyHeadingLevelChange(delta: -1)
            } else {
                indentOrOutdent(delta: +1)
            }
            return true
        case .outdent:
            if headingLevelAtCursor() != nil {
                applyHeadingLevelChange(delta: +1)
            } else {
                indentOrOutdent(delta: -1)
            }
            return true
        default:
            if let fmt = action.markdownFormat {
                applyFormat(fmt); return true
            }
            return false
        }
    }

    // MARK: - Selection

    private func selectLine() {
        let ns = textStorage.rawText as NSString
        let loc = textStorage.cursorOffset
        guard ns.length > 0 else { return }
        let lineRange = ns.lineRange(for: NSRange(location: min(loc, ns.length - 1), length: 0))
        textStorage.setSelection(SelectionRange(start: lineRange.location, end: NSMaxRange(lineRange)))
        renderer.refresh()
    }

    private func selectWord() {
        let ns = textStorage.rawText as NSString
        let loc = textStorage.cursorOffset
        guard loc < ns.length else { return }
        let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
        let line = ns.substring(with: lineRange)
        let relLoc = loc - lineRange.location
        var start = relLoc, end = relLoc
        while start > 0 {
            let idx = line.index(line.startIndex, offsetBy: start - 1)
            if line[idx].isWhitespace { break }
            start -= 1
        }
        while end < line.count {
            let idx = line.index(line.startIndex, offsetBy: end)
            if line[idx].isWhitespace { break }
            end += 1
        }
        textStorage.setSelection(SelectionRange(
            start: lineRange.location + start,
            end: lineRange.location + end
        ))
        renderer.refresh()
    }

    private func selectSentence() {
        let ns = textStorage.rawText as NSString
        let loc = textStorage.cursorOffset
        let terminators = CharacterSet(charactersIn: ".!?。！？")
        var start = loc
        while start > 0 {
            let prev = ns.character(at: start - 1)
            if terminators.contains(UnicodeScalar(UInt32(prev))!) { break }
            start -= 1
        }
        var end = loc
        while end < ns.length {
            let cur = ns.character(at: end)
            if terminators.contains(UnicodeScalar(UInt32(cur))!) { end += 1; break }
            end += 1
        }
        textStorage.setSelection(SelectionRange(start: start, end: end))
        renderer.refresh()
    }

    private func selectParagraph() {
        let ns = textStorage.rawText as NSString
        let loc = textStorage.cursorOffset
        var start = loc
        while start > 0 {
            let prev = ns.lineRange(for: NSRange(location: start - 1, length: 0))
            if ns.substring(with: prev).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            start = prev.location
        }
        var end = loc
        while end < ns.length {
            let lr = ns.lineRange(for: NSRange(location: end, length: 0))
            end = NSMaxRange(lr)
            if ns.substring(with: lr).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
        }
        textStorage.setSelection(SelectionRange(start: start, end: end))
        renderer.refresh()
    }

    private func selectListBranch() {
        let ns = textStorage.rawText as NSString
        let loc = textStorage.cursorOffset
        let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
        let baseIndent = leadingIndent(of: ns.substring(with: lineRange))
        var end = NSMaxRange(lineRange)
        var pos = end
        while pos < ns.length {
            let nr = ns.lineRange(for: NSRange(location: pos, length: 0))
            if ns.substring(with: nr).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            if leadingIndent(of: ns.substring(with: nr)) <= baseIndent { break }
            end = NSMaxRange(nr)
            pos = end
        }
        textStorage.setSelection(SelectionRange(start: lineRange.location, end: end))
        renderer.refresh()
    }

    private func deselect() {
        textStorage.setSelection(SelectionRange(start: textStorage.cursorOffset, end: textStorage.cursorOffset))
        renderer.refresh()
    }

    // MARK: - Line Movement

    private func moveLine(up: Bool) {
        let ns = textStorage.rawText as NSString
        let len = ns.length
        guard len > 0 else { return }

        let cursor = textStorage.cursorOffset
        let curLineRange = ns.lineRange(for: NSRange(location: cursor, length: 0))
        let curLineText = ns.substring(with: curLineRange)

        if up {
            guard curLineRange.location > 0 else { return }
            let aboveRange = ns.lineRange(for: NSRange(location: curLineRange.location - 1, length: 0))
            let aboveText = ns.substring(with: aboveRange)
            let combined = NSRange(location: aboveRange.location, length: NSMaxRange(curLineRange) - aboveRange.location)
            let newText = curLineText + aboveText
            _ = textStorage.replaceText(range: combined, with: newText)
        } else {
            guard NSMaxRange(curLineRange) < len else { return }
            let belowRange = ns.lineRange(for: NSRange(location: NSMaxRange(curLineRange), length: 0))
            let belowText = ns.substring(with: belowRange)
            let combined = NSRange(location: curLineRange.location, length: NSMaxRange(belowRange) - curLineRange.location)
            let newText = belowText + curLineText
            _ = textStorage.replaceText(range: combined, with: newText)
        }
        renderer.refresh()
    }

    // MARK: - Indent / Over-indent

    /// Over-indent: allows indent to exceed child indent level.
    /// Children do NOT move with the parent.
    private func indentOrOutdent(delta: Int) {
        let ns = textStorage.rawText as NSString
        let sel = textStorage.selection
        let indentStr = editorSettings?.indentUnit.string ?? "    "
        let indentLen = (indentStr as NSString).length

        let startLineRange = ns.lineRange(for: NSRange(location: sel.start, length: 0))
        let endLineRange: NSRange = {
            if sel.length == 0 { return startLineRange }
            let endLoc = max(sel.start, sel.end - 1)
            return ns.lineRange(for: NSRange(location: endLoc, length: 0))
        }()
        let blockRange = NSRange(location: startLineRange.location, length: NSMaxRange(endLineRange) - startLineRange.location)
        let blockText = ns.substring(with: blockRange)

        var newLines: [String] = []
        for line in blockText.components(separatedBy: "\n") {
            if delta > 0 {
                newLines.append(indentStr + line)
            } else {
                let leadingSpaces = line.prefix(while: { $0 == " " || $0 == "\t" })
                let removeLen = min(leadingSpaces.count, indentLen)
                newLines.append(String(line.dropFirst(removeLen)))
            }
        }
        let newText = newLines.joined(separator: "\n")
        _ = textStorage.replaceText(range: blockRange, with: newText)
        renderer.refresh()
    }

    // MARK: - Format

    private func applyFormat(_ format: MarkdownFormat) {
        let sel = textStorage.selection
        let range = NSRange(location: sel.start, length: max(0, sel.end - sel.start))
        let result = MarkdownFormatter.apply(format, to: textStorage.rawText, selectedRange: range,
                                             indentUnit: editorSettings?.indentUnit.string ?? "    ")
        _ = textStorage.replaceText(range: NSRange(location: 0, length: (textStorage.rawText as NSString).length), with: result.text)
        textStorage.setSelection(SelectionRange(start: result.selectedRange.location, end: NSMaxRange(result.selectedRange)))
        renderer.refresh()
    }

    private func applyPanguSpacing() {
        let ns = textStorage.rawText as NSString
        let sel = textStorage.selection
        let applyRange = sel.length > 0
            ? NSRange(location: sel.start, length: sel.length)
            : NSRange(location: 0, length: ns.length)
        let original = ns.substring(with: applyRange)
        let modified = PanguSpacing.apply(to: original)
        guard modified != original else { return }
        _ = textStorage.replaceText(range: applyRange, with: modified)
        renderer.refresh()
    }

    // MARK: - Headings

    private func headingLevelAtCursor() -> Int? {
        let ns = textStorage.rawText as NSString
        let loc = textStorage.cursorOffset
        let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
        let line = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 }
            else if ch == " " { return (1...6).contains(level) ? level : nil }
            else { return nil }
        }
        return nil
    }

    private func applyHeadingLevelChange(delta: Int) {
        let ns = textStorage.rawText as NSString
        let loc = textStorage.cursorOffset
        let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
        let line = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let currentLevel = headingLevelAtCursor() else { return }
        let headingText = line.dropFirst(currentLevel + 1)
        let newLevel = max(1, min(6, currentLevel + delta))
        let newLine = String(repeating: "#", count: newLevel) + " " + headingText + "\n"
        _ = textStorage.replaceText(range: lineRange, with: newLine)
        renderer.refresh()
    }

    // MARK: - Helpers

    private func leadingIndent(of line: String) -> Int {
        var count = 0
        for ch in line {
            if ch == " " { count += 1 }
            else if ch == "\t" { count += 4 }
            else { break }
        }
        return count
    }
}
