import Foundation
import AppKit
import CoreText
import Observation

// MARK: - EditorTextStorage

/// Core text model: holds raw text, fold state, cursor, and selection.
/// All mutations go through this class so it can emit change notifications.
@Observable
final class EditorTextStorage {

    // MARK: - Public State

    private(set) var rawText: String = ""
    private(set) var cursorOffset: Int = 0  // UTF-16 offset
    private(set) var selection: SelectionRange = SelectionRange(start: 0, end: 0)
    private(set) var foldRecords: [FoldRecord] = []

    var isFolding: Bool = false  // suppress callbacks during fold ops

    // MARK: - Callbacks

    var onTextChanged: ((String) -> Void)?
    var onSelectionChanged: ((SelectionRange) -> Void)?
    var onFoldStateChanged: (() -> Void)?

    // MARK: - Folded Display Text

    /// The text as displayed (fold placeholders expanded back to original).
    /// This is what gets saved to note.content.
    func trueContent() -> String {
        guard !foldRecords.isEmpty else { return rawText }
        var result = rawText as NSString
        let sorted = foldRecords.sorted { $0.placeholderRange.location > $1.placeholderRange.location }
        for record in sorted {
            let range = record.placeholderRange
            guard range.location + range.length <= result.length,
                  result.substring(with: range) == "…\n" else { continue }
            result = result.replacingCharacters(in: range, with: Self.expandRecord(record)) as NSString
        }
        return result as String
    }

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

    // MARK: - Text Mutations

    func setText(_ text: String) {
        rawText = text
        foldRecords.removeAll()
        cursorOffset = 0
        selection = SelectionRange(start: 0, end: 0)
    }

    /// Insert `string` at `offset` (UTF-16). Returns new cursor position.
    @discardableResult
    func insertText(_ string: String, at offset: Int) -> Int {
        let ns = rawText as NSString
        let safeOffset = min(offset, ns.length)
        let before = ns.substring(to: safeOffset)
        let after = ns.substring(from: safeOffset)
        rawText = before + string + after
        let newOffset = safeOffset + (string as NSString).length
        cursorOffset = newOffset
        selection = SelectionRange(start: newOffset, end: newOffset)
        shiftFoldPositions(editedRange: NSRange(location: safeOffset, length: 0), delta: (string as NSString).length)
        onTextChanged?(trueContent())
        return newOffset
    }

    /// Delete `length` characters starting at `offset`. Returns new cursor.
    @discardableResult
    func deleteText(at offset: Int, length: Int) -> Int {
        let ns = rawText as NSString
        let safeOffset = min(offset, ns.length)
        let safeLength = min(length, ns.length - safeOffset)
        guard safeLength > 0 else { return safeOffset }
        let before = ns.substring(to: safeOffset)
        let after = ns.substring(from: safeOffset + safeLength)
        rawText = before + after
        cursorOffset = safeOffset
        selection = SelectionRange(start: safeOffset, end: safeOffset)
        shiftFoldPositions(editedRange: NSRange(location: safeOffset, length: safeLength), delta: -safeLength)
        onTextChanged?(trueContent())
        return safeOffset
    }

    /// Replace range with string. Returns new cursor.
    @discardableResult
    func replaceText(range: NSRange, with string: String) -> Int {
        let ns = rawText as NSString
        let safeRange = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
        guard safeRange.length > 0 else { return min(range.location, ns.length) }
        let before = ns.substring(to: safeRange.location)
        let after = ns.substring(from: NSMaxRange(safeRange))
        rawText = before + string + after
        let newOffset = safeRange.location + (string as NSString).length
        cursorOffset = newOffset
        selection = SelectionRange(start: newOffset, end: newOffset)
        shiftFoldPositions(editedRange: safeRange, delta: (string as NSString).length - safeRange.length)
        onTextChanged?(trueContent())
        return newOffset
    }

    // MARK: - Selection

    func setSelection(_ sel: SelectionRange) {
        let safeLen = (rawText as NSString).length
        let s = min(max(0, sel.start), safeLen)
        let e = min(max(0, sel.end), safeLen)
        selection = SelectionRange(start: s, end: e)
        cursorOffset = e
        onSelectionChanged?(selection)
    }

    func moveCursor(to offset: Int) {
        let safeLen = (rawText as NSString).length
        let safe = min(max(0, offset), safeLen)
        cursorOffset = safe
        selection = SelectionRange(start: safe, end: safe)
        onSelectionChanged?(selection)
    }

    // MARK: - Fold Operations

    func foldAtCursor(lines: [LineMetrics], cursorLine: Int) {
        guard cursorLine < lines.count else { return }
        let lm = lines[cursorLine]
        guard lm.isFoldable, !lm.isFolded else { return }
        // childrenRange: lines after cursorLine with deeper indent
        let baseIndent = lm.indentWidth
        var childEndLine = cursorLine + 1
        while childEndLine < lines.count && lines[childEndLine].indentWidth > baseIndent {
            childEndLine += 1
        }
        guard childEndLine > cursorLine + 1 else { return }

        // Build children range in raw text coordinates
        let childrenStart = lm.range.location + lm.range.length  // start of first child line
        let lastChild = lines[childEndLine - 1]
        let childrenEnd = NSMaxRange(lastChild.range)
        let childrenRange = NSRange(location: childrenStart, length: childrenEnd - childrenStart)
        let ns = rawText as NSString
        guard childrenRange.location >= 0, NSMaxRange(childrenRange) <= ns.length else { return }
        let originalContent = ns.substring(with: childrenRange)
        let placeholder = "…\n"

        isFolding = true
        let before = ns.substring(to: childrenRange.location)
        let after = ns.substring(from: NSMaxRange(childrenRange))
        rawText = before + placeholder + after
        isFolding = false

        // Collect inner folds
        let nested = foldRecords.filter { NSLocationInRange($0.placeholderRange.location, childrenRange) }
            .map { rec -> FoldRecord in
                var r = rec
                r.placeholderRange.location -= childrenRange.location
                return r
            }
        foldRecords.removeAll { NSLocationInRange($0.placeholderRange.location, childrenRange) }

        foldRecords.append(FoldRecord(
            placeholderRange: NSRange(location: childrenRange.location, length: (placeholder as NSString).length),
            originalContent: originalContent,
            nestedFolds: nested
        ))
        onTextChanged?(trueContent())
        onFoldStateChanged?()
    }

    func unfoldAtCursor(cursorLine: Int, lines: [LineMetrics]) {
        guard let idx = foldRecords.firstIndex(where: { rec in
            lines.contains { NSLocationInRange(rec.placeholderRange.location, $0.range) }
        }) else { return }
        unfoldRecord(at: idx, lines: lines)
    }

    private func unfoldRecord(at idx: Int, lines: [LineMetrics]) {
        let record = foldRecords.remove(at: idx)
        isFolding = true
        let ns = rawText as NSString
        let before = ns.substring(to: record.placeholderRange.location)
        let after = ns.substring(from: NSMaxRange(record.placeholderRange))
        rawText = before + record.originalContent + after
        isFolding = false

        let delta = (record.originalContent as NSString).length - record.placeholderRange.length
        for i in foldRecords.indices where foldRecords[i].placeholderRange.location > record.placeholderRange.location {
            foldRecords[i].placeholderRange.location += delta
        }

        // Re-activate nested folds
        let base = record.placeholderRange.location
        foldRecords.append(contentsOf: record.nestedFolds.map { nested in
            var r = nested
            r.placeholderRange.location += base
            return r
        })

        onTextChanged?(trueContent())
        onFoldStateChanged?()
    }

    func foldAll(lines: [LineMetrics]) {
        guard !foldRecords.isEmpty else { return }
        unfoldAll()
        var blocks: [(childrenRange: NSRange, lineIdx: Int)] = []
        for (i, lm) in lines.enumerated() {
            guard lm.isFoldable else { continue }
            var childEndLine = i + 1
            let baseIndent = lm.indentWidth
            while childEndLine < lines.count && lines[childEndLine].indentWidth > baseIndent {
                childEndLine += 1
            }
            guard childEndLine > i + 1 else { continue }
            let childrenStart = lm.range.location + lm.range.length
            let lastChild = lines[childEndLine - 1]
            let childrenEnd = NSMaxRange(lastChild.range)
            blocks.append((NSRange(location: childrenStart, length: childrenEnd - childrenStart), i))
        }
        for block in blocks.sorted(by: { $0.childrenRange.location > $1.childrenRange.location }) {
            let ns = rawText as NSString
            guard block.childrenRange.location >= 0, NSMaxRange(block.childrenRange) <= ns.length else { continue }
            let originalContent = ns.substring(with: block.childrenRange)
            let placeholder = "…\n"
            isFolding = true
            let before = ns.substring(to: block.childrenRange.location)
            let after = ns.substring(from: NSMaxRange(block.childrenRange))
            rawText = before + placeholder + after
            isFolding = false
            foldRecords.append(FoldRecord(
                placeholderRange: NSRange(location: block.childrenRange.location, length: (placeholder as NSString).length),
                originalContent: originalContent,
                nestedFolds: []
            ))
        }
        onTextChanged?(trueContent())
        onFoldStateChanged?()
    }

    func unfoldAll() {
        guard !foldRecords.isEmpty else { return }
        isFolding = true
        rawText = trueContent()
        isFolding = false
        foldRecords.removeAll()
        onTextChanged?(rawText)
        onFoldStateChanged?()
    }

    // MARK: - Fold Position Sync

    private func shiftFoldPositions(editedRange: NSRange, delta: Int) {
        guard !foldRecords.isEmpty else { return }
        let oldEditEnd = editedRange.location + editedRange.length - delta
        for i in foldRecords.indices {
            if foldRecords[i].placeholderRange.location >= oldEditEnd {
                foldRecords[i].placeholderRange.location += delta
            }
        }
    }

    // MARK: - Line Map (from raw text, fold-aware)

    /// Build line metrics from rawText, respecting fold state.
    /// Folded lines are NOT included in the output (they are hidden).
    func buildLineMetrics(font: NSFont, width: CGFloat) -> [LineMetrics] {
        var result: [LineMetrics] = []
        let ns = rawText as NSString

        var charIndex = 0
        while charIndex < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: charIndex, length: 0))
            let lineText = ns.substring(with: lineRange)

            // Skip lines inside a fold
            let isInsideFold = foldRecords.contains { NSLocationInRange(charIndex, $0.placeholderRange) }
            if !isInsideFold {
                let fragments = layoutLine(lineText, font: font, width: width, baseOffset: 0)
                let rect = fragments.reduce(CGRect.null) { $0.union($1.rect) }
                let indentWidth = measureIndent(lineText)
                let trimmed = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
                let isFoldable = isFoldableLine(trimmed)
                let isFolded = foldRecords.contains { NSLocationInRange($0.placeholderRange.location, lineRange) }
                result.append(LineMetrics(
                    fragments: fragments,
                    rect: rect,
                    range: lineRange,
                    indentWidth: indentWidth,
                    isFoldable: isFoldable,
                    isFolded: isFolded,
                    foldIndentHint: 0
                ))
            }
            charIndex = NSMaxRange(lineRange)
        }
        return result
    }

    private func layoutLine(_ text: String, font: NSFont, width: CGFloat, baseOffset: CGFloat) -> [LineFragment] {
        var fragments: [LineFragment] = []
        let attrStr = NSAttributedString(string: text, attributes: [.font: font])
        let fullRange = CFRange(location: 0, length: attrStr.length)

        let framesetter = CTFramesetterCreateWithAttributedString(attrStr as CFAttributedString)
        let suggestedSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, fullRange, nil,
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude), nil
        )
        let path = CGPath(rect: CGRect(x: 0, y: -suggestedSize.height, width: width, height: suggestedSize.height), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, fullRange, path, nil)

        let lines = CTFrameGetLines(frame) as! [CTLine]
        for i in 0..<lines.count {
            let line = lines[i]
            let lineRange = CoreText.CTLineGetStringRange(line)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            _ = CoreText.CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let bounds = CoreText.CTLineGetBoundsWithOptions(line, [])
            let fragmentText = (text as NSString).substring(with: NSRange(location: lineRange.location, length: lineRange.length))
            var origins = [CGPoint.zero]
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
            let originY = origins.count > 0 ? origins[0].y : 0
            let y = originY - descent
            fragments.append(LineFragment(
                text: fragmentText,
                ctLine: line,
                rect: CGRect(x: baseOffset, y: y, width: bounds.width, height: ascent + descent),
                range: NSRange(location: lineRange.location, length: lineRange.length)
            ))
        }
        return fragments
    }

    private func measureIndent(_ line: String) -> CGFloat {
        var count = 0
        for ch in line {
            if ch == " " { count += 1 }
            else if ch == "\t" { count += 4 }
            else { break }
        }
        return CGFloat(count) * 8  // monospaced approximation
    }

    private func isFoldableLine(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("#") { return true }
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") { return true }
        if trimmed.hasPrefix("- [") || trimmed.hasPrefix("* [") || trimmed.hasPrefix("+ [") { return true }
        var i = trimmed.startIndex
        while i < trimmed.endIndex, trimmed[i].isNumber { i = trimmed.index(after: i) }
        if i > trimmed.startIndex, i < trimmed.endIndex, trimmed[i] == "." { return true }
        return false
    }
}
