# Layer Editor Rebuild Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `MarkdownEditorNSTextView` (NSTextView subclass) with a custom Layer-tree rendering architecture using CoreText for CPU-side text layout and CALayer for rendering via CoreAnimation. Preserve all existing functionality: fold/unfold, typewriter mode, smart selection, outline indent/outdent with over-indent support.

**Architecture:** Three-layer model: (1) `EditorTextStorage` holds the text, fold state, cursor, and selection; (2) `EditorRenderer` owns a CALayer tree (`OutlinerLayer > RowLayer > LineFragmentLayer`) and drives CoreText layout; (3) `EditorTextInputView` is an `NSView` + `NSTextInputClient` that captures keyboard and IME events and feeds them into `EditorTextStorage`.

**Tech Stack:** CoreText (CTFrame, CTLine, CTLineFragment), CALayer / CATextLayer, NSView + NSTextInputClient, SwiftUI NSViewRepresentable.

---

## File Map

```
Create: ClaudeNotes/Editor/EditorTextStorage.swift       — text model, fold, cursor/selection
Create: ClaudeNotes/Editor/EditorTypes.swift              — LineFragment, LineMetrics, SelectionRange, FoldRecord
Create: ClaudeNotes/Editor/LineFragmentLayer.swift        — CALayer subclass: renders one CTLine fragment
Create: ClaudeNotes/Editor/RowLayer.swift                 — CALayer: one row = indent + multiple fragments + fold indicator
Create: ClaudeNotes/Editor/OutlinerLayer.swift            — CALayer: manages all RowLayers, scroll offset, visible range
Create: ClaudeNotes/Editor/EditorRenderer.swift           — owns layer tree, drives layout/render cycle
Create: ClaudeNotes/Editor/EditorTextInputView.swift      — NSView + NSTextInputClient, keyboard + IME
Create: ClaudeNotes/Editor/LayerEditorView.swift          — SwiftUI NSViewRepresentable wrapper
Create: ClaudeNotes/Editor/LayerEditorViewModel.swift    — @Observable bridging old ViewModel calls to new renderer
Modify: ClaudeNotes/Views/Editor/NoteEditorView.swift      — swap MarkdownTextView for LayerEditorView
Modify: ClaudeNotes/Views/Editor/NoteEditorViewModel.swift — adapt if needed
Rename: ClaudeNotes/Views/Editor/MarkdownTextView.swift → MarkdownTextView-legacy.swift (keep for reference, comment out)
```

---

### Task 1: `EditorTypes.swift` — Shared data types

**Files:**
- Create: `ClaudeNotes/Editor/EditorTypes.swift`

- [ ] **Step 1: Create EditorTypes.swift with all shared types**

```swift
import Foundation
import CoreGraphics

// MARK: - Line Fragment

/// A single laid-out fragment of text within one logical line.
/// Produced by CoreText during the layout pass.
struct LineFragment {
    let text: String
    let ctLine: CTLine           // the CoreText line object
    let rect: CGRect             // bounding rect in document coordinates
    let range: NSRange           // character range in raw text
}

/// Metrics for one logical line (may span multiple fragments due to wrapping).
struct LineMetrics {
    let fragments: [LineFragment]
    let rect: CGRect             // union of all fragment rects
    let range: NSRange           // full character range in raw text
    let indentWidth: CGFloat     // indent offset for this row
    let isFoldable: Bool         // true if this line has children (heading or list item)
    let isFolded: Bool           // true if this line's children are currently hidden
    let foldIndentHint: CGFloat // extra indent hint when collapsed (for over-indent visual)
}

// MARK: - Selection

struct SelectionRange: Equatable {
    var start: Int   // UTF-16 offset in raw (folded) text
    var end: Int     // UTF-16 offset in raw (folded) text

    var isEmpty: Bool { start == end }
    var length: Int { max(0, end - start) }

    /// Returns all line indices covered by this selection (0-based).
    func coveringLineIndices(in lineMap: [LineMetrics]) -> [Int] {
        var result: [Int] = []
        for (i, lm) in lineMap.enumerated() {
            if NSIntersectionRange(
                NSRange(location: start, length: max(0, end - start)),
                lm.range
            ).length > 0 {
                result.append(i)
            }
        }
        return result
    }
}

// MARK: - Fold Record

struct FoldRecord {
    var placeholderRange: NSRange  // range of "…\n" in the folded text
    let originalContent: String    // "\n" + all child lines
    var nestedFolds: [FoldRecord] // folds that were inside this fold
}

// MARK: - Document Metrics

struct DocumentMetrics {
    let lineMetrics: [LineMetrics]
    let totalHeight: CGFloat
    /// Maps a character offset → line index (binary searchable).
    let offsetToLineIndex: [(offset: Int, lineIndex: Int)]
}

- [ ] **Step 2: Verify the file compiles (syntax check)**
Run: `swiftc -parse ClaudeNotes/Editor/EditorTypes.swift 2>&1 | head -20`
Expected: no errors

- [ ] **Step 3: Commit**
```bash
git add ClaudeNotes/Editor/EditorTypes.swift
git commit -m "feat(editor): add EditorTypes shared data model"
```

---

### Task 2: `EditorTextStorage.swift` — Text model, fold, cursor/selection

**Files:**
- Create: `ClaudeNotes/Editor/EditorTextStorage.swift`

- [ ] **Step 1: Create EditorTextStorage.swift**

```swift
import Foundation
import AppKit

// MARK: - EditorTextStorage

/// Core text model: holds raw text, fold state, cursor, and selection.
/// All mutations go through this class so it can emit change notifications.
final class EditorTextStorage: @Observable {

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
        // childrenRange is stored implicitly: lines after cursorLine with deeper indent
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
            let lm = lines[block.lineIdx]
            let placeholder = "…\n"
            let ns = rawText as NSString
            guard block.childrenRange.location >= 0, NSMaxRange(block.childrenRange) <= ns.length else { continue }
            let originalContent = ns.substring(with: block.childrenRange)
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
        var lineIndex = 0

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
            lineIndex += 1
        }
        return result
    }

    private func layoutLine(_ text: String, font: NSFont, width: CGFloat, baseOffset: CGFloat) -> [LineFragment] {
        var fragments: [LineFragment] = []
        let attrStr = NSAttributedString(string: text, attributes: [.font: font])
        let fullRange = CFRange(location: 0, length: attrStr.length)
        var fitRange: CFIndex = 0
        var xOffset: CGFloat = baseOffset
        let mutableAttr = NSMutableAttributedString(attributedString: attrStr)

        CTFrameGetLineOrigins(CTFrameCreateWithAttributedString(attrStr as CFAttributedString), CFRangeMake(0, 0), nil)

        // Use CTFramesetter to do wrapping
        let framesetter = CTFramesetterCreateWithAttributedString(attrStr as CFAttributedString)
        let suggestedSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, fullRange, nil, CGSize(width: width, height: CGFloat.greatestFiniteMagnitude), nil
        )
        let path = CGPath(rect: CGRect(x: 0, y: -suggestedSize.height, width: width, height: suggestedSize.height), transform: nil)
        guard let frame = CTFramesetterCreateFrame(framesetter, fullRange, path, nil) else { return fragments }

        var originsBuffer = [CGPoint](repeating: .zero, count: 64)
        let originCount = CTFrameGetLineOrigins(frame, fullRange, &originsBuffer)

        for i in 0..<originCount {
            let lineOrigin = originsBuffer[i]
            let line = CTFrameGetLine(frame, CFRange(location: CFIndex(i), length: 0))!
            let lineRange = CTLineGetStringRange(line)
            let ascent = CTLineGetTypographicAscent(line)
            let descent = CTLineGetTypographicDescent(line)
            let bounds = CTLineGetBoundsWithOptions(line, [])
            let y = lineOrigin.y - descent
            let fragmentText = (text as NSString).substring(with: NSRange(location: lineRange.location, length: lineRange.length))
            fragments.append(LineFragment(
                text: fragmentText,
                ctLine: line,
                rect: CGRect(x: xOffset + lineOrigin.x, y: y, width: bounds.width, height: ascent + descent),
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
        return CGFloat(count) * 8  // monospaced approximation; updated by font metrics
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

- [ ] **Step 2: Verify the file compiles**
Run: `swiftc -parse ClaudeNotes/Editor/EditorTextStorage.swift 2>&1 | head -20`
Expected: no errors

- [ ] **Step 3: Commit**
```bash
git add ClaudeNotes/Editor/EditorTextStorage.swift
git commit -m "feat(editor): add EditorTextStorage text model with fold support"
```

---

### Task 3: `LineFragmentLayer.swift` — Render one CTLine fragment

**Files:**
- Create: `ClaudeNotes/Editor/LineFragmentLayer.swift`

- [ ] **Step 1: Create LineFragmentLayer.swift**

```swift
import QuartzCore
import AppKit
import CoreText

// MARK: - LineFragmentLayer

/// Renders a single CTLine into a CALayer.
/// The layer's `contents` is set to a CGImage produced by rendering the CTLine
/// into a CGContext at the appropriate resolution.
final class LineFragmentLayer: CALayer {

    var ctLine: CTLine? {
        didSet { setNeedsDisplay() }
    }

    var textColor: NSColor = .textColor {
        didSet { setNeedsDisplay() }
    }

    var backgroundColor: NSColor = .clear {
        didSet { setNeedsDisplay() }
    }

    var isSelected: Bool = false {
        didSet { setNeedsDisplay() }
    }

    var selectionRects: [CGRect] = [] {
        didSet { setNeedsDisplay() }
    }

    override init() {
        super.init()
        commonInit()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func commonInit() {
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        opaque = false
    }

    override func draw(in ctx: CGContext) {
        guard let line = ctLine else { return }

        let bounds = ctx.boundingBoxOfClipPath
        ctx.saveGState()

        // Draw background
        if isSelected {
            ctx.setFillColor(selectionColor.cgColor)
            for rect in selectionRects {
                ctx.fill(rect)
            }
        }

        // Draw the CTLine
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1.0, y: -1.0)

        // Set text color
        let attributedLine = CTLineCreateWithAttributedString(
            CTLineGetAttributes(line).first ?? NSAttributedString()
        )
        // Actually: just draw with the ctline directly and set fill color in context
        ctx.setFillColor(textColor.cgColor)

        let penOffset = CTLineGetOffsetForStringIndex(line, 0, nil)
        ctx.textPosition = CGPoint(x: -penOffset, y: 0)
        CTLineDraw(line, ctx)

        ctx.restoreGState()
    }

    private var selectionColor: NSColor {
        if #available(macOS 10.14, *) {
            return NSColor.controlAccentColor.withAlphaComponent(0.3)
        }
        return NSColor.selectedTextBackgroundColor.withAlphaComponent(0.5)
    }
}

- [ ] **Step 2: Verify the file compiles**
Run: `swiftc -parse ClaudeNotes/Editor/LineFragmentLayer.swift 2>&1 | head -20`
Expected: no errors

- [ ] **Step 3: Commit**
```bash
git add ClaudeNotes/Editor/LineFragmentLayer.swift
git commit -m "feat(editor): add LineFragmentLayer for CTLine rendering"
```

---

### Task 4: `RowLayer.swift` — One document row = indent + fragments + fold indicator

**Files:**
- Create: `ClaudeNotes/Editor/RowLayer.swift`

- [ ] **Step 1: Create RowLayer.swift**

```swift
import QuartzCore
import AppKit
import CoreText

// MARK: - RowLayer

/// A CALayer representing one logical row in the document.
/// Contains: indent spacer, one or more LineFragmentLayers, and a fold indicator.
/// RowLayer is positioned absolutely within OutlinerLayer.
final class RowLayer: CALayer {

    var lineMetrics: LineMetrics? {
        didSet { rebuildSublayers() }
    }

    var font: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular) {
        didSet { rebuildSublayers() }
    }

    var indentWidth: CGFloat = 0 {
        didSet { positionSublayers() }
    }

    var isFoldable: Bool = false {
        didSet { updateFoldIndicator() }
    }

    var isFolded: Bool = false {
        didSet { updateFoldIndicator() }
    }

    var onFoldIndicatorTapped: (() -> Void)?

    private var indentLayer: CALayer!
    private var fragmentLayers: [LineFragmentLayer] = []
    private var foldIndicatorLayer: CATextLayer!
    private var gutterHitLayer: CALayer!  // invisible click target in gutter

    override init() {
        super.init()
        setupLayers()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        setupLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupLayers() {
        indentLayer = CALayer()
        indentLayer.backgroundColor = NSColor.clear.cgColor
        addSublayer(indentLayer)

        foldIndicatorLayer = CATextLayer()
        foldIndicatorLayer.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        foldIndicatorLayer.fontSize = 10
        foldIndicatorLayer.foregroundColor = NSColor.tertiaryLabelColor.cgColor
        foldIndicatorLayer.alignmentMode = .center
        foldIndicatorLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        foldIndicatorLayer.isWrapped = false
        addSublayer(foldIndicatorLayer)

        gutterHitLayer = CALayer()
        gutterHitLayer.backgroundColor = NSColor.clear.cgColor
        gutterHitLayer.onClick = { [weak self] in
            self?.onFoldIndicatorTapped?()
        }
        addSublayer(gutterHitLayer)

        updateFoldIndicator()
    }

    private func rebuildSublayers() {
        fragmentLayers.forEach { $0.removeFromSuperlayer() }
        fragmentLayers.removeAll()

        guard let lm = lineMetrics else {
            bounds = .zero
            return
        }

        var totalHeight: CGFloat = 0
        for fragment in lm.fragments {
            let fragLayer = LineFragmentLayer()
            fragLayer.ctLine = fragment.ctLine
            fragLayer.textColor = .textColor
            fragLayer.frame = CGRect(x: fragment.rect.minX, y: fragment.rect.minY, width: fragment.rect.width, height: fragment.rect.height)
            addSublayer(fragLayer)
            fragmentLayers.append(fragLayer)
            totalHeight = max(totalHeight, fragment.rect.maxY)
        }

        bounds = CGRect(x: 0, y: 0, width: lm.rect.width, height: max(totalHeight, 20))
        positionSublayers()
    }

    private func positionSublayers() {
        indentLayer.frame = CGRect(x: 0, y: 0, width: indentWidth, height: bounds.height)

        // Position fold indicator in gutter (left of indent)
        let indicatorW: CGFloat = 16
        foldIndicatorLayer.frame = CGRect(
            x: indentWidth + 4,
            y: (bounds.height - 14) / 2,
            width: indicatorW,
            height: 14
        )
        gutterHitLayer.frame = CGRect(
            x: indentWidth - 16,
            y: 0,
            width: 32,
            height: bounds.height
        )
    }

    private func updateFoldIndicator() {
        if isFoldable && !isFolded {
            foldIndicatorLayer.string = "▾"
            foldIndicatorLayer.isHidden = false
        } else if isFoldable && isFolded {
            foldIndicatorLayer.string = "▶"
            foldIndicatorLayer.isHidden = false
        } else {
            foldIndicatorLayer.string = nil
            foldIndicatorLayer.isHidden = true
        }
    }

    /// Set selection highlight on this row's fragment layers.
    func setSelectionRects(_ rects: [CGRect]) {
        for fragLayer in fragmentLayers {
            let hitRects = rects.filter { CGRectIntersects($0, fragLayer.frame) }
                .map { CGRectIntersection($0, fragLayer.frame) }
            fragLayer.selectionRects = hitRects
            fragLayer.isSelected = !hitRects.isEmpty
        }
    }
}

// MARK: - CALayer Click Handling

extension CALayer {
    private struct AssociatedKeys {
        static var onClick = UnsafeRawPointer.bitCast(objectClass, to: UnsafeMutableRawPointer.self)
    }

    var onClick: (() -> Void)? {
        get { objc_getAssociatedObject(self, &AssociatedKeys.onClick) as? () -> Void }
        set { objc_setAssociatedObject(self, &AssociatedKeys.onClick, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

- [ ] **Step 2: Verify the file compiles**
Run: `swiftc -parse ClaudeNotes/Editor/RowLayer.swift 2>&1 | head -20`
Expected: no errors

- [ ] **Step 3: Commit**
```bash
git add ClaudeNotes/Editor/RowLayer.swift
git commit -m "feat(editor): add RowLayer for one document row with fold indicator"
```

---

### Task 5: `OutlinerLayer.swift` — Document layer tree management

**Files:**
- Create: `ClaudeNotes/Editor/OutlinerLayer.swift`

- [ ] **Step 1: Create OutlinerLayer.swift**

```swift
import QuartzCore
import AppKit

// MARK: - OutlinerLayer

/// The root layer for the document. Manages all RowLayers, handles scrolling,
/// visible range calculation, and delegates click events.
final class OutlinerLayer: CALayer {

    var lineMetrics: [LineMetrics] = [] {
        didSet { rebuildRowLayers() }
    }

    var font: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular) {
        didSet { rebuildRowLayers() }
    }

    var gutterWidth: CGFloat = 32 {
        didSet { rebuildRowLayers() }
    }

    var textWidth: CGFloat = 0 {
        didSet { rebuildRowLayers() }
    }

    var scrollOffset: CGPoint = .zero {
        didSet { updateRowPositions() }
    }

    var visibleRect: CGRect = .zero {
        didSet { updateVisibleRowLayers() }
    }

    var onFoldIndicatorTapped: (() -> Void)?

    private(set) var rowLayers: [RowLayer] = []
    private var lineHeight: CGFloat { font.lineHeight }

    override init() {
        super.init()
        commonInit()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func commonInit() {
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
    }

    // MARK: - Layout

    private func rebuildRowLayers() {
        rowLayers.forEach { $0.removeFromSuperlayer() }
        rowLayers.removeAll()

        for lm in lineMetrics {
            let rowLayer = RowLayer()
            rowLayer.lineMetrics = lm
            rowLayer.font = font
            rowLayer.indentWidth = gutterWidth + lm.indentWidth
            rowLayer.isFoldable = lm.isFoldable
            rowLayer.isFolded = lm.isFolded
            rowLayer.onFoldIndicatorTapped = onFoldIndicatorTapped
            rowLayer.frame = CGRect(x: 0, y: 0, width: textWidth + gutterWidth, height: lm.rect.height)
            addSublayer(rowLayer)
            rowLayers.append(rowLayer)
        }

        updateRowPositions()
    }

    private func updateRowPositions() {
        var y: CGFloat = 0
        for (i, rowLayer) in rowLayers.enumerated() {
            rowLayer.position = CGPoint(x: bounds.width / 2, y: bounds.height - y - rowLayer.bounds.height / 2)
            rowLayer.scrollOffset = scrollOffset
            y += rowLayer.bounds.height
        }
        let totalHeight = y
        bounds = CGRect(x: 0, y: 0, width: textWidth + gutterWidth, height: totalHeight)
    }

    private func updateVisibleRowLayers() {
        for rowLayer in rowLayers {
            let worldY = rowLayer.position.y + bounds.height / 2
            let localY = worldY + scrollOffset.y
            let isVisible = localY > visibleRect.minY - rowLayer.bounds.height
                && localY < visibleRect.maxY + rowLayer.bounds.height
            rowLayer.isHidden = !isVisible
        }
    }

    // MARK: - Selection Rendering

    func updateSelection(_ selection: SelectionRange, lines: [LineMetrics]) {
        let coveredLines = selection.coveringLineIndices(in: lines)
        for (i, rowLayer) in rowLayers.enumerated() {
            if coveredLines.contains(i) {
                // Compute selection rects within this row
                let rowRects = rectsForSelectionLine(selection: selection, line: lines[i], rowFrame: rowLayer.frame)
                rowLayer.setSelectionRects(rowRects)
            } else {
                rowLayer.setSelectionRects([])
            }
        }
    }

    private func rectsForSelectionLine(selection: SelectionRange, line: LineMetrics, rowFrame: CGRect) -> [CGRect] {
        // Simplified: highlight the whole row
        // TODO: per-character selection rects using CTLineGetOffsetForStringIndex
        let textStart = line.range.location
        let textEnd = NSMaxRange(line.range)
        let selStart = max(selection.start, textStart)
        let selEnd = min(selection.end, textEnd)

        guard selStart < selEnd else { return [] }

        // Approximate character width from font
        let charWidth = font.advanceWidth(for: NSFontDescriptor())
        let indentX = gutterWidth + line.indentWidth
        let startX = indentX + CGFloat(selStart - textStart) * charWidth
        let endX = indentX + CGFloat(selEnd - textStart) * charWidth

        return [CGRect(x: startX, y: rowFrame.minY, width: endX - startX, height: rowFrame.height)]
    }

    // MARK: - Cursor

    func cursorRect(for offset: Int, lines: [LineMetrics]) -> CGRect? {
        for lm in lines {
            if offset >= lm.range.location && offset <= NSMaxRange(lm.range) {
                let charOffset = offset - lm.range.location
                let charWidth = font.advanceWidth(for: NSFontDescriptor())
                let rowIdx = lines.firstIndex(where: { $0.range.location == lm.range.location }) ?? 0
                guard rowIdx < rowLayers.count else { return nil }
                let rowLayer = rowLayers[rowIdx]
                let indentX = gutterWidth + lm.indentWidth
                let x = indentX + CGFloat(charOffset) * charWidth
                return CGRect(x: x, y: rowLayer.frame.minY, width: 2, height: rowLayer.frame.height)
            }
        }
        return nil
    }
}

- [ ] **Step 2: Verify the file compiles**
Run: `swiftc -parse ClaudeNotes/Editor/OutlinerLayer.swift 2>&1 | head -20`
Expected: no errors

- [ ] **Step 3: Commit**
```bash
git add ClaudeNotes/Editor/OutlinerLayer.swift
git commit -m "feat(editor): add OutlinerLayer managing all RowLayers"
```

---

### Task 6: `EditorTextInputView.swift` — NSView + NSTextInputClient for keyboard + IME

**Files:**
- Create: `ClaudeNotes/Editor/EditorTextInputView.swift`

This is the most critical file. It replaces NSTextView as the input receiver.

- [ ] **Step 1: Create EditorTextInputView.swift**

```swift
import AppKit

// MARK: - EditorTextInputView

/// NSView subclass that implements NSTextInputClient to receive keyboard events and IME.
/// Coordinates with EditorTextStorage for text mutations and EditorRenderer for display.
final class EditorTextInputView: NSView, NSTextInputClient {

    // MARK: - Dependencies

    var textStorage: EditorTextStorage!
    weak var renderer: EditorRenderer?

    // MARK: - IME State

    private var markedTextRange: NSRange?
    private var selectedTextRange: NSRange = NSRange(location: 0, length: 0)

    // MARK: - Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        wantsLayer = true
    }

    // MARK: - NSTextInputClient

    var hasMarkedText: Bool { markedTextRange != nil }

    func markedRange() -> NSRange {
        markedTextRange ?? NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        selectedTextRange
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let str: String
        if let s = string as? String { str = s }
        else if let as_ = string as? NSAttributedString { str = as_.string }
        else { return }

        let repRange = replacementRange.location != NSNotFound
            ? replacementRange
            : markedTextRange ?? NSRange(location: 0, length: 0)

        textStorage.replaceText(range: repRange, with: str)
        markedTextRange = NSRange(location: repRange.location, length: (str as NSString).length)
        selectedTextRange = NSRange(
            location: repRange.location + selectedRange.location,
            length: selectedRange.length
        )
        renderer?.refresh()
    }

    func unmarkText() {
        markedTextRange = nil
    }

    func selectedTextRange() -> NSRange? {
        guard selectedTextRange.location != NSNotFound else { return nil }
        return selectedTextRange
    }

    func setSelectedTextRange(_ range: NSRange) {
        selectedTextRange = range
        textStorage.setSelection(SelectionRange(start: range.location, end: range.location + range.length))
        renderer?.refresh()
    }

    func attributedSubstring(forProposedRange range: NSRange) -> NSAttributedString? {
        let ns = textStorage.rawText as NSString
        let safeRange = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
        guard safeRange.length > 0 else { return nil }
        return NSAttributedString(string: ns.substring(with: safeRange))
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.font, .foregroundColor]
    }

    func firstRect(forCharacterRange range: NSRange) -> NSRect {
        // Return cursor rect as approximation
        let offset = range.location
        if let rect = renderer?.cursorRect(for: offset) {
            return convert(rect, from: renderer?.contentLayer)
        }
        return .zero
    }

    func characterIndex(for point: NSPoint) -> Int {
        renderer?.characterIndex(for: convert(point, from: nil)) ?? 0
    }

    // MARK: - Keyboard Events

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Let NSTextInputClient handle IME first
        if hasMarkedText {
            if interpretKeyEvents([event]) { return }
        }

        // Handle plain text input
        if let chars = event.characters, !chars.isEmpty {
            for char in chars {
                if char.isASCII || !event.modifierFlags.contains(.option) {
                    // Plain character
                    let sel = selectedTextRange
                    let range = NSRange(location: sel.location, length: sel.length)
                    textStorage.replaceText(range: range, with: String(char))
                    renderer?.refresh()
                    return
                }
            }
        }

        // Non-character keys: arrow, backspace, delete, return
        handleControlKey(event)
    }

    override func interpretKeyEvents(_ eventArray: [NSEvent]) {
        for event in eventArray {
            if hasMarkedText || insertText(event, replacementRange: selectedTextRange) {
                return
            }
        }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let str: String
        if let s = string as? String { str = s }
        else if let as_ = string as? NSAttributedString { str = as_.string }
        else { return }

        let repRange = replacementRange.location != NSNotFound
            ? replacementRange
            : selectedTextRange
        textStorage.replaceText(range: repRange, with: str)
        markedTextRange = nil
        renderer?.refresh()
    }

    private func handleControlKey(_ event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch key {
        case "f": moveCursor(delta: 1)
        case "b": moveCursor(delta: -1)
        case "p": moveCursor(lineDelta: -1)
        case "n": moveCursor(lineDelta: 1)
        case "a": moveToLineStart()
        case "e": moveToLineEnd()
        case "d": deleteForward()
        default: super.keyDown(with: event)
        }
    }

    private func moveCursor(delta: Int) {
        let newOffset = textStorage.cursorOffset + delta
        textStorage.moveCursor(to: newOffset)
        renderer?.refresh()
    }

    private func moveCursor(lineDelta: Int) {
        // Move cursor up/down by finding the line boundary
        let ns = textStorage.rawText as NSString
        let loc = textStorage.cursorOffset
        let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
        if lineDelta < 0 && lineRange.location > 0 {
            let prevLineRange = ns.lineRange(for: NSRange(location: lineRange.location - 1, length: 0))
            let col = loc - lineRange.location
            let newLoc = prevLineRange.location + min(col, prevLineRange.length)
            textStorage.moveCursor(to: max(0, newLoc))
        } else if lineDelta > 0 {
            let nextLoc = NSMaxRange(lineRange)
            let col = loc - lineRange.location
            if nextLoc < ns.length {
                let nextLineRange = ns.lineRange(for: NSRange(location: nextLoc, length: 0))
                let newLoc = nextLoc + min(col, nextLineRange.length)
                textStorage.moveCursor(to: min(ns.length, newLoc))
            }
        }
        renderer?.refresh()
    }

    private func moveToLineStart() {
        let ns = textStorage.rawText as NSString
        let lineRange = ns.lineRange(for: NSRange(location: textStorage.cursorOffset, length: 0))
        textStorage.moveCursor(to: lineRange.location)
        renderer?.refresh()
    }

    private func moveToLineEnd() {
        let ns = textStorage.rawText as NSString
        let lineRange = ns.lineRange(for: NSRange(location: textStorage.cursorOffset, length: 0))
        textStorage.moveCursor(to: NSMaxRange(lineRange) - 1)
        renderer?.refresh()
    }

    private func deleteForward() {
        let loc = textStorage.cursorOffset
        let len = textStorage.rawText.count
        if loc < len {
            _ = textStorage.deleteText(at: loc, length: 1)
            renderer?.refresh()
        }
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let offset = renderer?.characterIndex(for: pt) {
            if event.modifierFlags.contains(.shift) {
                let cur = textStorage.cursorOffset
                let sel = SelectionRange(start: min(cur, offset), end: max(cur, offset))
                textStorage.setSelection(sel)
            } else {
                textStorage.moveCursor(to: offset)
            }
            renderer?.refresh()
        }
    }
}

- [ ] **Step 2: Verify the file compiles**
Run: `swiftc -parse ClaudeNotes/Editor/EditorTextInputView.swift 2>&1 | head -20`
Expected: no errors

- [ ] **Step 3: Commit**
```bash
git add ClaudeNotes/Editor/EditorTextInputView.swift
git commit -m "feat(editor): add EditorTextInputView with NSTextInputClient"
```

---

### Task 7: `EditorRenderer.swift` — Owns layer tree, drives layout/render, cursor, scroll

**Files:**
- Create: `ClaudeNotes/Editor/EditorRenderer.swift`

- [ ] **Step 1: Create EditorRenderer.swift**

```swift
import QuartzCore
import AppKit
import CoreText

// MARK: - EditorRenderer

/// Owns the CALayer tree (OutlinerLayer) and drives the layout/render cycle.
/// Receives mutations from EditorTextStorage and repaints the layer tree.
final class EditorRenderer: NSObject {

    // MARK: - Dependencies

    let textStorage: EditorTextStorage
    weak var textInputView: EditorTextInputView?

    // MARK: - Settings

    var font: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    var indentUnit: String = "    "
    var lineHeightMultiple: CGFloat = 1.4
    var typewriterMode: Bool = false
    var typewriterScrollFraction: CGFloat = 0.5
    var typewriterFocusMode: EditorSettings.TypewriterFocusMode = .off
    var typewriterMarkLine: Bool = false

    // MARK: - Layers

    let rootLayer: CALayer
    let outlinerLayer: OutlinerLayer
    let contentLayer: CALayer  // scrollable content
    let cursorLayer: CATextLayer
    let scrollLayer: CALayer    // clips content to viewport

    // MARK: - Scroll State

    private var scrollOffset: CGPoint = .zero
    private var visibleRect: CGRect = .zero

    // MARK: - Layout

    private var contentWidth: CGFloat = 0
    private var cachedLineMetrics: [LineMetrics] = []

    // MARK: - Init

    init(textStorage: EditorTextStorage) {
        self.textStorage = textStorage
        self.rootLayer = CALayer()
        self.outlinerLayer = OutlinerLayer()
        self.contentLayer = CALayer()
        self.cursorLayer = CATextLayer()
        self.scrollLayer = CALayer()

        super.init()

        rootLayer.backgroundColor = NSColor.clear.cgColor
        rootLayer.frame = CGRect(origin: .zero, size: CGSize(width: 100, height: 100))

        scrollLayer.backgroundColor = NSColor.clear.cgColor
        scrollLayer.masksToBounds = true

        cursorLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        cursorLayer.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        cursorLayer.fontSize = 14
        cursorLayer.string = "|"
        cursorLayer.foregroundColor = NSColor.textColor.cgColor
        cursorLayer.isWrapped = false

        rootLayer.addSublayer(scrollLayer)
        scrollLayer.addSublayer(contentLayer)
        contentLayer.addSublayer(outlinerLayer)
        contentLayer.addSublayer(cursorLayer)

        outlinerLayer.onFoldIndicatorTapped = { [weak self] in
            self?.handleFoldTap()
        }

        textStorage.onTextChanged = { [weak self] _ in self?.rebuildLayout() }
        textStorage.onSelectionChanged = { [weak self] _ in self?.updateSelection() }
        textStorage.onFoldStateChanged = { [weak self] in self?.rebuildLayout() }
    }

    // MARK: - Layout

    func setContentSize(width: CGFloat, height: CGFloat) {
        rootLayer.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        scrollLayer.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        contentWidth = width - 32  // gutter inset
        rebuildLayout()
    }

    func setScrollOffset(_ offset: CGPoint) {
        scrollOffset = offset
        outlinerLayer.scrollOffset = offset
        contentLayer.position = CGPoint(x: width/2, y: height - offset.y)
        updateCursorVisibility()
    }

    func setVisibleRect(_ rect: CGRect) {
        visibleRect = rect
        outlinerLayer.visibleRect = rect
    }

    private func rebuildLayout() {
        let effectiveFont = font
        cachedLineMetrics = textStorage.buildLineMetrics(font: effectiveFont, width: contentWidth)
        outlinerLayer.lineMetrics = cachedLineMetrics
        outlinerLayer.font = effectiveFont
        outlinerLayer.textWidth = contentWidth
        outlinerLayer.gutterWidth = 32

        let totalHeight = cachedLineMetrics.reduce(0) { $0 + $1.rect.height }
        contentLayer.bounds = CGRect(origin: .zero, size: CGSize(width: contentWidth + 32, height: totalHeight))
        outlinerLayer.bounds = contentLayer.bounds

        updateSelection()
        updateCursor()
    }

    // MARK: - Selection

    private func updateSelection() {
        outlinerLayer.updateSelection(textStorage.selection, lines: cachedLineMetrics)
    }

    // MARK: - Cursor

    private func updateCursor() {
        guard !textStorage.selection.isEmpty == false else {
            cursorLayer.isHidden = true
            return
        }
        cursorLayer.isHidden = false
        let offset = textStorage.cursorOffset
        if let rect = outlinerLayer.cursorRect(for: offset, lines: cachedLineMetrics) {
            let screenRect = CGRect(
                x: rect.minX + scrollLayer.frame.width/2 - contentWidth/2,
                y: rect.minY + scrollLayer.frame.height/2,
                width: 2,
                height: rect.height
            )
            cursorLayer.frame = screenRect
        }
        updateCursorBlink()
    }

    private func updateCursorBlink() {
        cursorLayer.isHidden = false
    }

    private func updateCursorVisibility() {
        // Hide cursor if it's outside visible rect
        // (simplified — always show for now)
    }

    // MARK: - Cursor rect for NSTextInputClient

    func cursorRect(for offset: Int) -> CGRect {
        outlinerLayer.cursorRect(for: offset, lines: cachedLineMetrics) ?? .zero
    }

    func characterIndex(for point: CGPoint) -> Int {
        // Convert point to document coordinates
        let docX = point.x - scrollLayer.frame.width/2 + contentWidth/2
        let docY = point.y + scrollOffset.y

        var y: CGFloat = 0
        for lm in cachedLineMetrics {
            if docY >= y && docY < y + lm.rect.height {
                // Find approximate character index
                let charOffset = max(0, Int((docX - 32) / (font.advanceWidth ?? 8)))
                return min(lm.range.location + charOffset, NSMaxRange(lm.range))
            }
            y += lm.rect.height
        }
        return (textStorage.rawText as NSString).length
    }

    // MARK: - Fold

    private func handleFoldTap() {
        // Find the line at cursor and toggle fold
        let cursorLine = findLineIndex(at: textStorage.cursorOffset)
        if textStorage.selection.isEmpty {
            textStorage.foldAtCursor(lines: cachedLineMetrics, cursorLine: cursorLine)
        } else {
            textStorage.unfoldAtCursor(cursorLine: cursorLine, lines: cachedLineMetrics)
        }
        rebuildLayout()
    }

    private func findLineIndex(at offset: Int) -> Int {
        cachedLineMetrics.firstIndex { offset >= $0.range.location && offset <= NSMaxRange($0.range) } ?? 0
    }

    // MARK: - Refresh

    func refresh() {
        rebuildLayout()
    }

    // MARK: - Typewriter Scroll

    func scrollToCursor() {
        guard typewriterMode else { return }
        let cursorRect = self.cursorRect(for: textStorage.cursorOffset)
        guard !cursorRect.isEmpty else { return }
        let viewportH = scrollLayer.bounds.height
        let targetY = cursorRect.midY - viewportH * typewriterScrollFraction
        let clampedY = max(0, targetY)
        setScrollOffset(CGPoint(x: scrollOffset.x, y: clampedY))
    }
}

- [ ] **Step 2: Verify the file compiles**
Run: `swiftc -parse ClaudeNotes/Editor/EditorRenderer.swift 2>&1 | head -20`
Expected: no errors

- [ ] **Step 3: Commit**
```bash
git add ClaudeNotes/Editor/EditorRenderer.swift
git commit -m "feat(editor): add EditorRenderer coordinating layer tree and layout"
```

---

### Task 8: `LayerEditorView.swift` — SwiftUI NSViewRepresentable wrapper

**Files:**
- Create: `ClaudeNotes/Editor/LayerEditorView.swift`

- [ ] **Step 1: Create LayerEditorView.swift**

```swift
import SwiftUI
import AppKit

// MARK: - LayerEditorView

struct LayerEditorView: NSViewRepresentable {

    @Binding var text: String
    var noteID: UUID
    var shortcutSettings: ShortcutSettings
    var editorSettings: EditorSettings
    var holder: TextViewHolder?
    var onTextChange: (() -> Void)?
    var onTogglePreview: (() -> Void)?
    var onClaudeWrite: (() -> Void)?
    var onRevealInFinder: (() -> Void)?
    var outlineMode: Bool = false
    var typewriterMode: Bool = false
    var typewriterScrollFraction: CGFloat = 0.5
    var typewriterFocusMode: EditorSettings.TypewriterFocusMode = .off
    var typewriterMarkLine: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let contentSize = scrollView.contentSize

        // Create the editor stack
        let textStorage = EditorTextStorage()
        let renderer = EditorRenderer(textStorage: textStorage)
        let inputView = EditorTextInputView(frame: NSRect(origin: .zero, size: contentSize))
        inputView.textStorage = textStorage
        inputView.renderer = renderer
        renderer.textInputView = inputView

        // Apply settings
        renderer.font = editorSettings.makeNSFont()
        renderer.lineHeightMultiple = CGFloat(editorSettings.lineHeightMultiple)
        renderer.typewriterMode = typewriterMode
        renderer.typewriterScrollFraction = typewriterScrollFraction
        renderer.typewriterFocusMode = typewriterFocusMode
        renderer.typewriterMarkLine = typewriterMarkLine

        // Connect text callbacks
        textStorage.onTextChanged = { newContent in
            Task { @MainActor in
                context.coordinator.isUpdating = true
                text = newContent
                context.coordinator.isUpdating = false
                onTextChange?()
            }
        }

        // Make the input view the document view
        scrollView.documentView = inputView

        // Configure scroll view
        inputView.minSize = NSSize(width: 0, height: 0)
        inputView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        inputView.isVerticallyResizable = true
        inputView.isHorizontallyResizable = false
        inputView.autoresizingMask = [.width]

        // Track scroll events
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { _ in
            let offset = scrollView.contentView.bounds.origin
            renderer.setScrollOffset(offset)
            renderer.setVisibleRect(scrollView.documentVisibleRect)
        }

        // Initial layout
        renderer.setContentSize(width: contentSize.width, height: contentSize.height)

        // Set initial text
        textStorage.setText(text)

        context.coordinator.renderer = renderer
        context.coordinator.textStorage = textStorage
        context.coordinator.inputView = inputView
        holder?.textView = inputView  // keep old interface for compatibility

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let inputView = scrollView.documentView as? EditorTextInputView,
              let renderer = context.coordinator.renderer,
              let textStorage = context.coordinator.textStorage else { return }

        // Apply settings changes
        renderer.font = editorSettings.makeNSFont()
        renderer.lineHeightMultiple = CGFloat(editorSettings.lineHeightMultiple)
        renderer.typewriterMode = typewriterMode
        renderer.typewriterScrollFraction = typewriterScrollFraction
        renderer.typewriterFocusMode = typewriterFocusMode
        renderer.typewriterMarkLine = typewriterMarkLine

        // External text change (e.g., note switch)
        if !context.coordinator.isUpdating && textStorage.trueContent() != text {
            context.coordinator.isUpdating = true
            textStorage.setText(text)
            context.coordinator.isUpdating = false
            renderer.rebuildLayout()
        }

        // Resize
        let sz = scrollView.contentSize
        renderer.setContentSize(width: sz.width, height: sz.height)
        inputView.frame.size = sz
    }

    class Coordinator: NSObject {
        var parent: LayerEditorView
        weak var renderer: EditorRenderer?
        weak var textStorage: EditorTextStorage?
        weak var inputView: EditorTextInputView?
        var isUpdating = false

        init(_ parent: LayerEditorView) {
            self.parent = parent
        }
    }
}

- [ ] **Step 2: Verify the file compiles**
Run: `swiftc -parse ClaudeNotes/Editor/LayerEditorView.swift 2>&1 | head -20`
Expected: no errors

- [ ] **Step 3: Commit**
```bash
git add ClaudeNotes/Editor/LayerEditorView.swift
git commit -m "feat(editor): add LayerEditorView SwiftUI wrapper"
```

---

### Task 9: `LayerEditorViewModel.swift` — Bridge existing shortcuts/actions to new renderer

**Files:**
- Create: `ClaudeNotes/Editor/LayerEditorViewModel.swift`

This bridges existing `ShortcutAction` handling and the old `MarkdownEditorNSTextView.handleAction` logic to the new `EditorTextStorage` + `EditorRenderer` stack.

- [ ] **Step 1: Create LayerEditorViewModel.swift**

```swift
import Foundation
import AppKit

// MARK: - LayerEditorViewModel

/// Bridges existing shortcut/action logic to the new LayerEditor renderer.
/// This is essentially a port of MarkdownEditorNSTextView.handleAction().
final class LayerEditorViewModel: @Observable {

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
            renderer.handleFoldAction(); return true
        case .unfoldBlock:
            renderer.handleUnfoldAction(); return true
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
        while start > 0 && !line[line.index(line.startIndex, offsetBy: start - 1)].isWhitespace { start -= 1 }
        while end < line.count && !line[line.index(line.startIndex, offsetBy: end)].isWhitespace { end += 1 }
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
        // Same as MarkdownEditorNSTextView.selectListBranch
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
        // Port from MarkdownEditorNSTextView.moveLine
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

        // Determine line range from selection
        let startLineRange = ns.lineRange(for: NSRange(location: sel.start, length: 0))
        let endLineRange: NSRange = {
            if sel.length == 0 { return startLineRange }
            let endLoc = max(sel.start, NSMaxRange(sel) - 1)
            return ns.lineRange(for: NSRange(location: endLoc, length: 0))
        }()
        let blockRange = NSRange(location: startLineRange.location, length: NSMaxRange(endLineRange) - startLineRange.location)
        let blockText = ns.substring(with: blockRange)

        // For indent: just prepend indentStr to each line
        // For outdent: remove up to indentLen spaces from start of each line
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
        let result = MarkdownFormatter.apply(format, to: textStorage.rawText, selectedRange: range, indentUnit: editorSettings?.indentUnit.string ?? "    ")
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

- [ ] **Step 2: Verify the file compiles**
Run: `swiftc -parse ClaudeNotes/Editor/LayerEditorViewModel.swift 2>&1 | head -20`
Expected: no errors

- [ ] **Step 3: Commit**
```bash
git add ClaudeNotes/Editor/LayerEditorViewModel.swift
git commit -m "feat(editor): add LayerEditorViewModel bridging shortcuts/actions to new renderer"
```

---

### Task 10: Update `NoteEditorView.swift` — Swap MarkdownTextView for LayerEditorView

**Files:**
- Modify: `ClaudeNotes/Views/Editor/NoteEditorView.swift`

- [ ] **Step 1: Read NoteEditorView.swift to identify the exact change points**
Run: `grep -n "MarkdownTextView" ClaudeNotes/Views/Editor/NoteEditorView.swift | head -10`
Expected: list of line numbers where MarkdownTextView is referenced

- [ ] **Step 2: Replace MarkdownTextView with LayerEditorView in NoteEditorView.swift**

Locate the `if isPreview` block inside `editorContentArea`. Replace:

```swift
// OLD:
MarkdownTextView(
    text: $viewModel.content,
    ...
)

// NEW:
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
```

- [ ] **Step 3: Verify build succeeds**
Run: `xcodebuild -scheme ClaudeNotes -configuration Debug build 2>&1 | grep -E "error:|warning:" | head -20`
Expected: no errors

- [ ] **Step 4: Commit**
```bash
git add ClaudeNotes/Views/Editor/NoteEditorView.swift
git commit -m "feat(editor): swap MarkdownTextView for LayerEditorView in NoteEditorView"
```

---

### Task 11: Update `TextViewHolder` interface compatibility

**Files:**
- Modify: `ClaudeNotes/Views/Editor/MarkdownTextView.swift`

The `TextViewHolder` class expects a `MarkdownEditorNSTextView` reference. We'll make it generic so it can accept either the old NSTextView or the new `EditorTextInputView`.

- [ ] **Step 1: Modify TextViewHolder to accept any NSObject**

In `MarkdownTextView.swift`, locate `final class TextViewHolder` and change:

```swift
// OLD:
weak var textView: MarkdownEditorNSTextView?

// NEW:
weak var textView: NSView?

// Update all uses inside TextViewHolder methods:
func jumpToFirstMatch(query: String) {
    guard let tv = textView, let editorTV = tv as? MarkdownEditorNSTextView else { return }
    // existing code using editorTV...
}
```

- [ ] **Step 2: Update TextViewHolder.applyAction to support new editor**

Add a branch to dispatch to `LayerEditorViewModel` if the view is an `EditorTextInputView`:

```swift
func applyAction(_ action: ShortcutAction) {
    if let inputView = textView as? EditorTextInputView,
       let renderer = inputView.renderer,
       let viewModel = renderer.viewModel {
        _ = viewModel.handleAction(action)
        return
    }
    textView?.applyShortcutAction(action)
}
```

- [ ] **Step 3: Commit**
```bash
git add ClaudeNotes/Views/Editor/MarkdownTextView.swift
git commit -m "feat(editor): make TextViewHolder compatible with both old and new editors"
```

---

### Task 12: Rename old MarkdownTextView to MarkdownTextView-legacy.swift

**Files:**
- Rename: `ClaudeNotes/Views/Editor/MarkdownTextView.swift` → `MarkdownTextView-legacy.swift`

- [ ] **Step 1: Rename the file**
Run: `git mv ClaudeNotes/Views/Editor/MarkdownTextView.swift ClaudeNotes/Views/Editor/MarkdownTextView-legacy.swift`

- [ ] **Step 2: Add a comment at the top of the file explaining it's legacy**
```swift
// MARK: - LEGACY EDITOR
// This file contains the old NSTextView-based editor.
// It is kept for reference during migration to the new LayerEditor.
// TODO: Remove after LayerEditor is stable.
```

- [ ] **Step 3: Commit**
```bash
git add ClaudeNotes/Views/Editor/MarkdownTextView-legacy.swift
git commit -m "refactor(editor): rename old MarkdownTextView to legacy"
```

---

### Task 13: Update EditorRenderer for typewriter scroll callback

**Files:**
- Modify: `ClaudeNotes/Editor/EditorRenderer.swift`

The typewriter scroll logic needs to be called after every cursor move.

- [ ] **Step 1: Add scrollToCursor callback to EditorTextInputView**

In `EditorTextInputView.swift`, add a `weak var onCursorMoved: (() -> Void)?` property and call it after every cursor change:

```swift
// In EditorTextInputView.swift
var onCursorMoved: (() -> Void)?

private func moveCursor(delta: Int) {
    let newOffset = textStorage.cursorOffset + delta
    textStorage.moveCursor(to: newOffset)
    onCursorMoved?()
    renderer?.refresh()
}
// Do the same for moveCursor(lineDelta:), moveToLineStart(), moveToLineEnd(), deleteForward()
```

- [ ] **Step 2: Connect typewriter scroll in LayerEditorView**

In `LayerEditorView.makeNSView`, after creating `inputView`, set:

```swift
inputView.onCursorMoved = { [weak renderer] in
    renderer?.scrollToCursor()
}
```

- [ ] **Step 3: Commit**
```bash
git add ClaudeNotes/Editor/EditorTextInputView.swift ClaudeNotes/Editor/LayerEditorView.swift
git commit -m "feat(editor): add typewriter scroll callback to new editor"
```

---

### Task 14: Port fold indicator click handling

**Files:**
- Modify: `ClaudeNotes/Editor/EditorTextInputView.swift`

The gutter click handling from the old NSTextView needs to be reimplemented.

- [ ] **Step 1: Override mouseDown in EditorTextInputView to detect gutter clicks**

```swift
override func mouseDown(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)
    let gutterW: CGFloat = 32

    if pt.x < gutterW {
        if let renderer = renderer {
            let docPt = convert(pt, to: renderer.outlinerLayer)
            if let layer = renderer.outlinerLayer.hitTest(docPt) as? RowLayer {
                layer.onFoldIndicatorTapped?()
                return
            }
        }
    }
    super.mouseDown(with: event)
}
```

- [ ] **Step 2: Commit**
```bash
git add ClaudeNotes/Editor/EditorTextInputView.swift
git commit -m "feat(editor): add gutter click handling for fold indicators"
```

---

### Task 15: Port wiki-link highlighting to new renderer

**Files:**
- Modify: `ClaudeNotes/Editor/EditorTextStorage.swift`, `ClaudeNotes/Editor/LineFragmentLayer.swift`

The old editor uses NSTextStorage attributes to highlight wiki links. The new editor needs to do this during fragment layout.

- [ ] **Step 1: Add wiki-link detection to EditorTextStorage**

```swift
private static let wikiLinkRegex = try! NSRegularExpression(pattern: "\\[\\[.+?\\]\\]")

func wikiLinkRanges(in range: NSRange) -> [NSRange] {
    let ns = rawText as NSString
    let matches = wikiLinkRegex.matches(in: ns.substring(with: range), range: NSRange(location: 0, length: (ns.substring(with: range) as NSString).length))
    return matches.map { NSRange(location: $0.range.location + range.location, length: $0.range.length) }
}
```

- [ ] **Step 2: Apply wiki-link color in LineFragmentLayer**

```swift
var wikiLinkColor: NSColor = .systemBlue {
    didSet { setNeedsDisplay() }
}

override func draw(in ctx: CGContext) {
    // existing code...
    if let range = wikiLinkRange, let linkColor = wikiLinkColor {
        ctx.setFillColor(linkColor.cgColor)
        // draw link text...
    }
}
```

- [ ] **Step 3: Commit**
```bash
git add ClaudeNotes/Editor/EditorTextStorage.swift ClaudeNotes/Editor/LineFragmentLayer.swift
git commit -m "feat(editor): add wiki-link highlighting to new renderer"
```

---

### Task 16: Port smart selection extend behavior

**Files:**
- Modify: `ClaudeNotes/Editor/LayerEditorViewModel.swift`

The old editor has complex smart selection state tracking. Port this logic.

- [ ] **Step 1: Add smart selection state to LayerEditorViewModel**

```swift
private var lastSmartSelectAction: ShortcutAction? = nil
private var lastSmartSelectRange: NSRange = NSRange(location: NSNotFound, length: 0)
private var smartSelectCount: Int = 0
private var selectionHistory: [NSRange] = []

@discardableResult
private func updateSmartSelect(for action: ShortcutAction) -> (count: Int, cross: Bool) {
    let sel = textStorage.selection
    let selActive = sel.length > 0 && sel.start == lastSmartSelectRange.location && sel.length == lastSmartSelectRange.length
    let sameAction = lastSmartSelectAction == action

    let count: Int
    let cross: Bool

    if selActive && sameAction {
        count = smartSelectCount + 1; cross = false
    } else if selActive && !sameAction {
        count = 1; cross = true
    } else {
        count = 1; cross = false
        selectionHistory.removeAll()
    }

    smartSelectCount = count
    lastSmartSelectAction = action
    return (count, cross)
}
```

- [ ] **Step 2: Update selectLine/selectWord/selectSentence/selectParagraph to use updateSmartSelect**

Replace the simple selection with extend logic as in the old `MarkdownEditorNSTextView.selectLine` etc.

- [ ] **Step 3: Commit**
```bash
git add ClaudeNotes/Editor/LayerEditorViewModel.swift
git commit -m "feat(editor): port smart selection extend behavior to new renderer"
```

---

### Task 17: Port over-indent behavior (Tab/Shift+Tab beyond child indent)

**Files:**
- Modify: `ClaudeNotes/Editor/LayerEditorViewModel.swift`

The key feature: Tab/Shift+Tab should allow indenting a line beyond its children's indent level.

- [ ] **Step 1: Verify the current indentOrOutdent implementation already supports this**

The existing `indentOrOutdent(delta:)` method already adds/removes indent independently of child indent, which means it supports over-indent. The current implementation is correct.

- [ ] **Step 2: Add a unit test to verify over-indent behavior**

Create a test file: `ClaudeNotes/EditorTests/LayerEditorViewModelTests.swift` with a test case that indents a parent line beyond its child's indent and verifies the child stays in place.

- [ ] **Step 3: Commit**
```bash
git add ClaudeNotes/Editor/LayerEditorViewModel.swift ClaudeNotes/EditorTests/LayerEditorViewModelTests.swift
git commit -m "feat(editor): verify over-indent behavior works as expected"
```

---

### Task 18: Port typewriter focus overlay

**Files:**
- Modify: `ClaudeNotes/Editor/EditorRenderer.swift`, `ClaudeNotes/Editor/OutlinerLayer.swift`

The old editor draws a translucent overlay over everything outside the focus context (line/sentence/paragraph).

- [ ] **Step 1: Add focus overlay layer to OutlinerLayer**

```swift
private var focusOverlayLayer: CALayer!

private func setupLayers() {
    // existing code...
    focusOverlayLayer = CALayer()
    focusOverlayLayer.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
    focusOverlayLayer.isHidden = true
    addSublayer(focusOverlayLayer)
}

func updateFocusOverlay(mode: EditorSettings.TypewriterFocusMode, cursorLine: Int) {
    guard mode != .off, cursorLine < rowLayers.count else {
        focusOverlayLayer.isHidden = true
        return
    }
    let focusRow = rowLayers[cursorLine]
    let focusRect = focusRow.frame
    let above = CGRect(x: bounds.minX, y: focusRow.frame.maxY, width: bounds.width, height: max(0, bounds.maxY - focusRow.frame.maxY))
    let below = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(0, focusRow.frame.minY - bounds.minY))
    // Create two sublayers or use one layer with a complex path
    focusOverlayLayer.isHidden = false
}
```

- [ ] **Step 2: Commit**
```bash
git add ClaudeNotes/Editor/EditorRenderer.swift ClaudeNotes/Editor/OutlinerLayer.swift
git commit -m "feat(editor): add typewriter focus overlay to new renderer"
```

---

### Task 19: Port typewriter line highlight

**Files:**
- Modify: `ClaudeNotes/Editor/RowLayer.swift`

The old editor draws a subtle background tint behind the cursor line.

- [ ] **Step 1: Add background tint layer to RowLayer**

```swift
private var highlightLayer: CALayer!

private func setupLayers() {
    // existing code...
    highlightLayer = CALayer()
    highlightLayer.backgroundColor = NSColor.textColor.withAlphaComponent(0.06).cgColor
    highlightLayer.isHidden = true
    insertSublayer(highlightLayer, at: 0)  // behind everything
}

var isHighlighted: Bool = false {
    didSet { highlightLayer.isHidden = !isHighlighted }
}
```

- [ ] **Step 2: Update OutlinerLayer to set highlight on cursor row**

```swift
func updateCursorHighlight(cursorLine: Int, enabled: Bool) {
    for (i, rowLayer) in rowLayers.enumerated() {
        rowLayer.isHighlighted = enabled && (i == cursorLine)
    }
}
```

- [ ] **Step 3: Commit**
```bash
git add ClaudeNotes/Editor/RowLayer.swift ClaudeNotes/Editor/OutlinerLayer.swift
git commit -m "feat(editor): add typewriter line highlight to new renderer"
```

---

### Task 20: Port state persistence (fold state + cursor per note)

**Files:**
- Modify: `ClaudeNotes/Editor/LayerEditorView.swift`

The old editor calls `textView.saveState(for:)` and `textView.restoreState(for:)` to persist fold state and cursor offset per note.

- [ ] **Step 1: Add state persistence to LayerEditorView.makeNSView**

```swift
.onAppear {
    // Restore state
    if let state = EditorStateStore.shared.state(for: noteID) {
        textStorage.restoreFrom(state: state, lines: cachedLineMetrics)
    }
}
.onDisappear {
    // Save state
    textStorage.saveState(for: noteID, lines: cachedLineMetrics)
}
```

- [ ] **Step 2: Implement saveState/restoreFrom in EditorTextStorage**

```swift
func saveState(for noteID: UUID, lines: [LineMetrics]) {
    let phLen = ("…\n" as NSString).length
    let sorted = foldRecords.sorted { $0.placeholderRange.location < $1.placeholderRange.location }
    var cumExpansion = 0
    var foldInfos: [SavedEditorState.FoldInfo] = []
    for fold in sorted {
        let trueOff = fold.placeholderRange.location + cumExpansion
        let origLen = (fold.originalContent as NSString).length
        foldInfos.append(.init(trueOffset: trueOff, originalLength: origLen))
        cumExpansion += origLen - phLen
    }
    EditorStateStore.shared.save(
        SavedEditorState(folds: foldInfos, cursorOffset: cursorOffset),
        for: noteID
    )
}

func restoreFrom(state: SavedEditorState, lines: [LineMetrics]) {
    let phLen = ("…\n" as NSString).length
    let sortedFolds = state.folds.sorted { $0.trueOffset < $1.trueOffset }
    var totalShift = 0
    for foldInfo in sortedFolds {
        let adjustedOffset = foldInfo.trueOffset + totalShift
        let len = foldInfo.originalLength
        guard len > 1,
              adjustedOffset >= 0,
              adjustedOffset + len <= (rawText as NSString).length else {
            totalShift += phLen - len
            continue
        }
        // Perform fold at adjustedOffset
        // ... reuse foldAtCursor logic
        totalShift += phLen - len
    }
    cursorOffset = min(state.cursorOffset, (rawText as NSString).length)
}
```

- [ ] **Step 3: Commit**
```bash
git add ClaudeNotes/Editor/LayerEditorView.swift ClaudeNotes/Editor/EditorTextStorage.swift
git commit -m "feat(editor): add state persistence to new editor"
```

---

### Task 21: Integration test — end-to-end smoke test

**Files:**
- Create: `ClaudeNotes/EditorTests/LayerEditorIntegrationTests.swift`

- [ ] **Step 1: Create integration test**

```swift
import XCTest
@testable import ClaudeNotes

final class LayerEditorIntegrationTests: XCTestCase {

    func testBasicTyping() {
        let storage = EditorTextStorage()
        storage.setText("Hello")
        XCTAssertEqual(storage.rawText, "Hello")
        storage.insertText(" World", at: 5)
        XCTAssertEqual(storage.rawText, "Hello World")
    }

    func testFoldUnfold() {
        let storage = EditorTextStorage()
        storage.setText("""
- Parent
  - Child
  - Another
""")
        let lines = storage.buildLineMetrics(font: .monospacedSystemFont(ofSize: 14, weight: .regular), width: 500)
        storage.foldAtCursor(lines: lines, cursorLine: 0)
        XCTAssertTrue(storage.rawText.contains("…"))
        storage.unfoldAll()
        XCTAssertFalse(storage.rawText.contains("…"))
    }

    func testSelection() {
        let storage = EditorTextStorage()
        storage.setText("Line 1\nLine 2\nLine 3")
        storage.setSelection(SelectionRange(start: 0, end: 6))
        XCTAssertEqual(storage.selection.start, 0)
        XCTAssertEqual(storage.selection.end, 6)
    }
}
```

- [ ] **Step 2: Run tests**
Run: `xcodebuild test -scheme ClaudeNotes -destination 'platform=macOS' 2>&1 | grep -E "Test Suite|Test Case" | tail -20`
Expected: all tests pass

- [ ] **Step 3: Commit**
```bash
git add ClaudeNotes/EditorTests/LayerEditorIntegrationTests.swift
git commit -m "test(editor): add basic integration tests for new editor"
```

---

### Task 22: Manual smoke test — open ClaudeNotes and verify core functionality

- [ ] **Step 1: Build and run ClaudeNotes**
Run: `xcodebuild -scheme ClaudeNotes -configuration Debug build && open build/Debug/ClaudeNotes.app`

- [ ] **Step 2: Test basic typing**
1. Create a new note
2. Type "Hello world"
3. Verify text appears

- [ ] **Step 3: Test fold/unfold**
1. Type a heading: "# Heading"
2. Type text below it
3. Click the fold indicator (▾)
4. Verify it collapses to ▶
5. Click ▶
6. Verify it expands back

- [ ] **Step 4: Test typewriter mode**
1. Enable typewriter mode in settings
2. Type multiple lines
3. Verify the cursor stays at the configured viewport position

- [ ] **Step 5: Test selection**
1. Type "Line 1\nLine 2\nLine 3"
2. Press the "select line" shortcut
3. Verify the first line is selected
4. Press the shortcut again
5. Verify selection extends to the second line

- [ ] **Step 6: Test over-indent**
1. Type "- Parent\n  - Child"
2. Place cursor on "Parent"
3. Press Tab (or Cmd+] if configured)
4. Verify the parent indents but the child does NOT move

- [ ] **Step 7: Test wiki-link highlighting**
1. Type "[[Link]]"
2. Verify the link is colored blue with underline

- [ ] **Step 8: Test shortcuts**
1. Type "hello"
2. Select it
3. Press Cmd+B (or configured shortcut)
4. Verify it becomes "**hello**"

- [ ] **Step 9: Test state persistence**
1. Create a note with some folds
2. Switch to another note
3. Switch back
4. Verify folds are restored

- [ ] **Step 10: Test IME**
1. Switch to Chinese input
2. Type "nihao" and select "你好"
3. Verify the characters appear correctly

---

## Final Checklist

- [ ] All tests pass
- [ ] Manual smoke test passes
- [ ] No compilation errors or warnings
- [ ] Code follows CONVENTIONS.md guidelines
- [ ] All files have proper `// MARK:` sections
- [ ] Commit messages follow the pattern: `feat(editor): ...` or `fix(editor): ...`
- [ ] Legacy MarkdownTextView-legacy.swift is commented out

---

## Rollback Plan

If the new editor has critical issues:

1. In `NoteEditorView.swift`, revert `LayerEditorView` back to `MarkdownTextView`
2. Uncomment the old `MarkdownTextView-legacy.swift` implementation
3. Rename `MarkdownTextView-legacy.swift` back to `MarkdownTextView.swift`
4. Rebuild and test

---

**End of Plan**
