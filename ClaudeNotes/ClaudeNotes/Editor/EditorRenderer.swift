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
    let contentLayer: CALayer
    let cursorLayer: CATextLayer
    let scrollLayer: CALayer

    // MARK: - Scroll State

    private var scrollOffset: CGPoint = .zero
    private var visibleRect: CGRect = .zero

    // MARK: - Layout

    private var contentWidth: CGFloat = 0
    private(set) var cachedLineMetrics: [LineMetrics] = []

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
        scrollLayer.frame = CGRect(origin: .zero, size: CGSize(width: 100, height: 100))

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

    // MARK: - Content Size

    func setContentSize(width: CGFloat, height: CGFloat) {
        rootLayer.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        scrollLayer.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        contentWidth = width - 32  // gutter inset
        rebuildLayout()
    }

    // MARK: - Scroll

    func setScrollOffset(_ offset: CGPoint) {
        scrollOffset = offset
        outlinerLayer.scrollOffset = offset

        let halfW = scrollLayer.bounds.width / 2
        let halfH = scrollLayer.bounds.height / 2

        // Center contentLayer in scrollLayer
        contentLayer.position = CGPoint(x: halfW, y: halfH)

        // Apply scroll via sublayerTransform (3D translate).
        // The contentLayer is already centered at (halfW, halfH).
        // Its local origin (0,0) therefore sits at (halfW - offset.x, halfH + offset.y)
        // in scrollLayer viewport coordinates.
        var transform = CATransform3DIdentity
        transform.m41 = -offset.x
        transform.m42 = offset.y
        contentLayer.sublayerTransform = transform

        updateCursorVisibility()
    }

    func setVisibleRect(_ rect: CGRect) {
        visibleRect = rect
        outlinerLayer.viewportRect = rect
    }

    // MARK: - Layout

    private func rebuildLayout() {
        cachedLineMetrics = textStorage.buildLineMetrics(font: font, width: contentWidth)
        outlinerLayer.lineMetrics = cachedLineMetrics
        outlinerLayer.font = font
        outlinerLayer.textWidth = contentWidth
        outlinerLayer.gutterWidth = 32

        let totalHeight = cachedLineMetrics.reduce(0) { $0 + $1.rect.height }
        contentLayer.bounds = CGRect(origin: .zero, size: CGSize(width: contentWidth + 32, height: totalHeight))
        outlinerLayer.bounds = contentLayer.bounds
        outlinerLayer.frame = contentLayer.bounds

        updateSelection()
        updateCursor()
    }

    // MARK: - Selection

    private func updateSelection() {
        outlinerLayer.updateSelection(textStorage.selection, lines: cachedLineMetrics)
    }

    // MARK: - Cursor

    private func updateCursor() {
        guard textStorage.selection.isEmpty else {
            cursorLayer.isHidden = true
            return
        }
        cursorLayer.isHidden = false

        let offset = textStorage.cursorOffset
        guard let lineIdx = cachedLineMetrics.firstIndex(where: { offset >= $0.range.location && offset <= NSMaxRange($0.range) }) else {
            cursorLayer.isHidden = true
            return
        }

        let lm = cachedLineMetrics[lineIdx]
        let charOffset = offset - lm.range.location
        let charWidth = max((font as NSFont).maximumAdvancement.width, 8)

        var cumulativeBefore: CGFloat = 0
        for i in 0..<lineIdx {
            cumulativeBefore += cachedLineMetrics[i].rect.height
        }
        let totalDocHeight = cachedLineMetrics.reduce(0) { $0 + $1.rect.height }
        let docCursorY = totalDocHeight - (cumulativeBefore + lm.rect.minY)

        // Viewport Y: subtract scroll offset (doc.y → viewport.y = doc.y - scrollOffset.y,
        // but we also need to account for contentLayer being centered).
        // contentLayer is centered at (halfW, halfH) of scrollLayer.
        // In viewport: cursorY_viewport = docCursorY - scrollOffset.y
        // since contentLayer's local origin is what the transform shifts.
        let viewportCursorY = docCursorY - scrollOffset.y

        let x = 32 + lm.indentWidth + CGFloat(charOffset) * charWidth
        cursorLayer.frame = CGRect(
            x: x,
            y: viewportCursorY,
            width: 2,
            height: lm.rect.height
        )
    }

    private func updateCursorVisibility() {
        // Simple: always show cursor
    }

    // MARK: - Cursor rect for NSTextInputClient

    func cursorRect(for offset: Int) -> CGRect {
        outlinerLayer.cursorRect(for: offset, lines: cachedLineMetrics) ?? .zero
    }

    func characterIndex(for point: CGPoint) -> Int {
        // point is in scrollLayer coordinates (viewport).
        // Convert to document coordinates.
        let docY = point.y + scrollOffset.y

        var y: CGFloat = 0
        for lm in cachedLineMetrics {
            if docY >= y && docY < y + lm.rect.height {
                let charOffset = max(0, Int((point.x - 32) / max((font as NSFont).maximumAdvancement.width, 8)))
                return min(lm.range.location + charOffset, NSMaxRange(lm.range))
            }
            y += lm.rect.height
        }
        return (textStorage.rawText as NSString).length
    }

    // MARK: - Fold

    private func handleFoldTap() {
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
        let offset = textStorage.cursorOffset
        guard let lineIdx = cachedLineMetrics.firstIndex(where: { offset >= $0.range.location && offset <= NSMaxRange($0.range) }) else { return }

        var cumulativeBefore: CGFloat = 0
        for i in 0..<lineIdx {
            cumulativeBefore += cachedLineMetrics[i].rect.height
        }
        let lm = cachedLineMetrics[lineIdx]
        let totalH = cachedLineMetrics.reduce(0) { $0 + $1.rect.height }
        let docCursorY = totalH - (cumulativeBefore + lm.rect.minY)

        let viewportH = scrollLayer.bounds.height
        let targetY = docCursorY - viewportH * typewriterScrollFraction
        let clampedY = max(0, targetY)
        setScrollOffset(CGPoint(x: scrollOffset.x, y: clampedY))
    }

    // MARK: - Key Event (for shortcut handling)

    func handleKeyEvent(_ event: NSEvent) {
        // Forward to EditorTextInputView's keyDown if needed
        textInputView?.keyDown(with: event)
    }
}
