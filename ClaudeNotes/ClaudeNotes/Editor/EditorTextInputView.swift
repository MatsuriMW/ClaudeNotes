import AppKit

// MARK: - EditorRenderer (forward declaration — implemented in Task 7)
// Members listed here must match the actual EditorRenderer implementation in Task 7.

final class EditorRenderer {
    var outlinerLayer: OutlinerLayer { OutlinerLayer() }
    func refresh() {}
    func cursorRect(for offset: Int) -> NSRect? { nil }
    func characterIndex(for pt: CGPoint) -> Int? { nil }
    func handleKeyEvent(_ event: NSEvent) {}
}

// MARK: - EditorTextInputView

/// NSView subclass that implements NSTextInputClient to receive keyboard events and IME.
/// Coordinates with EditorTextStorage for text mutations and EditorRenderer for display.
final class EditorTextInputView: NSView, NSTextInputClient {

    // MARK: - Dependencies

    var textStorage: EditorTextStorage!
    weak var renderer: EditorRenderer?

    // MARK: - IME State
    // Prefixed with underscore to avoid clashing with NSTextInputClient protocol methods.

    private var _markedTextRange: NSRange?
    private var _selectedTextRange: NSRange = NSRange(location: 0, length: 0)

    // MARK: - Cursor Move Callback

    var onCursorMoved: (() -> Void)?

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
    }

    // MARK: - NSTextInputClient

    @objc func hasMarkedText() -> Bool { _markedTextRange != nil }

    func markedRange() -> NSRange {
        _markedTextRange ?? NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        _selectedTextRange
    }

    func setMarkedText(_ string: Any, selectedRange selRange: NSRange, replacementRange replRange: NSRange) {
        let str: String
        if let s = string as? String { str = s }
        else if let attrStr = string as? NSAttributedString { str = attrStr.string }
        else { return }

        let repRange = replRange.location != NSNotFound
            ? replRange
            : _markedTextRange ?? NSRange(location: 0, length: 0)

        _ = textStorage.replaceText(range: repRange, with: str)
        _markedTextRange = NSRange(location: repRange.location, length: (str as NSString).length)
        _selectedTextRange = NSRange(
            location: repRange.location + selRange.location,
            length: selRange.length
        )
        renderer?.refresh()
    }

    func unmarkText() {
        _markedTextRange = nil
    }

    func selectedTextRange() -> NSRange? {
        guard _selectedTextRange.location != NSNotFound else { return nil }
        return _selectedTextRange
    }

    func setSelectedTextRange(_ range: NSRange) {
        _selectedTextRange = range
        textStorage.setSelection(SelectionRange(start: range.location, end: range.location + range.length))
        onCursorMoved?()
        renderer?.refresh()
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let ns = textStorage.rawText as NSString
        let safeRange = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
        guard safeRange.length > 0 else { return nil }
        if let ptr = actualRange { ptr.pointee = safeRange }
        return NSAttributedString(string: ns.substring(with: safeRange))
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.font, .foregroundColor]
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let offset = range.location
        if let rect = renderer?.cursorRect(for: offset) {
            if let ptr = actualRange { ptr.pointee = range }
            return convert(rect, from: nil)
        }
        return .zero
    }

    func characterIndex(for point: NSPoint) -> Int {
        let localPoint = convert(point, from: nil)
        return renderer?.characterIndex(for: localPoint) ?? 0
    }

    // MARK: - Keyboard Events

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Let NSTextInputClient handle IME first if we have marked text
        if hasMarkedText() {
            interpretKeyEvents([event])
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Handle modifier-only shortcuts (Cmd+B, etc.) - skip plain chars
        guard let chars = event.characters, !chars.isEmpty else {
            // Non-character keys (arrows, delete, etc.) handled below
            handleControlKey(event)
            return
        }

        // Check for modifier + character (Cmd+B etc.)
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            handleModifierKey(event)
            return
        }

        // Plain character input
        for ch in chars {
            if !ch.isASCII && !flags.contains(.option) {
                // Non-ASCII (CJK, etc.) - let IME handle it
                super.keyDown(with: event)
                return
            }
            // ASCII character: insert it
            let sel = _selectedTextRange
            let range = NSRange(location: sel.location, length: sel.length)
            _ = textStorage.replaceText(range: range, with: String(ch))
            onCursorMoved?()
            renderer?.refresh()
            return
        }
    }

    func insertText(_ string: Any, replacementRange replRange: NSRange) {
        let str: String
        if let s = string as? String { str = s }
        else if let attrStr = string as? NSAttributedString { str = attrStr.string }
        else { return }

        let repRange = replRange.location != NSNotFound
            ? replRange
            : _selectedTextRange
        _ = textStorage.replaceText(range: repRange, with: str)
        _markedTextRange = nil
        onCursorMoved?()
        renderer?.refresh()
    }

    private func handleModifierKey(_ event: NSEvent) {
        // Pass to renderer for shortcut handling
        renderer?.handleKeyEvent(event)
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
        case "h": deleteBackwardChar()
        case "d": deleteForwardChar()
        case "k": deleteToLineEnd()
        default: super.keyDown(with: event)
        }
    }

    private func moveCursor(delta: Int) {
        let newOffset = textStorage.cursorOffset + delta
        let safeLen = (textStorage.rawText as NSString).length
        textStorage.moveCursor(to: max(0, min(newOffset, safeLen)))
        onCursorMoved?()
        renderer?.refresh()
    }

    private func moveCursor(lineDelta: Int) {
        let ns = textStorage.rawText as NSString
        let loc = textStorage.cursorOffset
        let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
        let col = loc - lineRange.location

        if lineDelta < 0 && lineRange.location > 0 {
            let prevLineRange = ns.lineRange(for: NSRange(location: lineRange.location - 1, length: 0))
            let newLoc = prevLineRange.location + min(col, prevLineRange.length)
            textStorage.moveCursor(to: max(0, newLoc))
        } else if lineDelta > 0 {
            let nextLoc = NSMaxRange(lineRange)
            if nextLoc < ns.length {
                let nextLineRange = ns.lineRange(for: NSRange(location: nextLoc, length: 0))
                let newLoc = nextLoc + min(col, nextLineRange.length)
                textStorage.moveCursor(to: min(ns.length, newLoc))
            }
        }
        onCursorMoved?()
        renderer?.refresh()
    }

    private func moveToLineStart() {
        let ns = textStorage.rawText as NSString
        let lineRange = ns.lineRange(for: NSRange(location: textStorage.cursorOffset, length: 0))
        textStorage.moveCursor(to: lineRange.location)
        onCursorMoved?()
        renderer?.refresh()
    }

    private func moveToLineEnd() {
        let ns = textStorage.rawText as NSString
        let lineRange = ns.lineRange(for: NSRange(location: textStorage.cursorOffset, length: 0))
        textStorage.moveCursor(to: NSMaxRange(lineRange))
        onCursorMoved?()
        renderer?.refresh()
    }

    private func deleteBackwardChar() {
        let loc = textStorage.cursorOffset
        guard loc > 0 else { return }
        _ = textStorage.deleteText(at: loc - 1, length: 1)
        onCursorMoved?()
        renderer?.refresh()
    }

    private func deleteForwardChar() {
        let loc = textStorage.cursorOffset
        let len = (textStorage.rawText as NSString).length
        guard loc < len else { return }
        _ = textStorage.deleteText(at: loc, length: 1)
        onCursorMoved?()
        renderer?.refresh()
    }

    private func deleteToLineEnd() {
        let ns = textStorage.rawText as NSString
        let loc = textStorage.cursorOffset
        let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
        let endOfLine = NSMaxRange(lineRange)
        guard endOfLine > loc else { return }
        _ = textStorage.deleteText(at: loc, length: endOfLine - loc)
        onCursorMoved?()
        renderer?.refresh()
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let gutterW: CGFloat = 32

        if pt.x < gutterW {
            // Gutter click — fold indicator
            if let renderer = renderer {
                let docPt = CGPoint(x: pt.x, y: pt.y)
                renderer.outlinerLayer.handleGutterClick(at: docPt)
            }
            return
        }

        // Text click — set cursor or selection
        if let offset = renderer?.characterIndex(for: pt) {
            if event.modifierFlags.contains(.shift) {
                let cur = textStorage.cursorOffset
                let sel = SelectionRange(start: min(cur, offset), end: max(cur, offset))
                textStorage.setSelection(sel)
            } else {
                textStorage.moveCursor(to: offset)
            }
            onCursorMoved?()
            renderer?.refresh()
        }
    }

    // MARK: - Scroll

    override func scrollWheel(with event: NSEvent) {
        if let sv = enclosingScrollView {
            sv.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}
