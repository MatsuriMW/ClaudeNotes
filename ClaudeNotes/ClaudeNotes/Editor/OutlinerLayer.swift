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

    var viewportRect: CGRect = .zero {
        didSet { updateVisibleRowLayers() }
    }

    var onFoldIndicatorTapped: (() -> Void)?

    private(set) var rowLayers: [RowLayer] = []

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
        for rowLayer in rowLayers {
            rowLayer.position = CGPoint(x: bounds.width / 2, y: bounds.height - y - rowLayer.bounds.height / 2)
            y += rowLayer.bounds.height
        }
        let totalHeight = y
        bounds = CGRect(x: 0, y: 0, width: textWidth + gutterWidth, height: totalHeight)
    }

    private func updateVisibleRowLayers() {
        var y: CGFloat = 0
        for rowLayer in rowLayers {
            let rowTop = bounds.height - y
            let rowBottom = rowTop - rowLayer.bounds.height
            let isVisible = rowBottom < visibleRect.maxY && rowTop > visibleRect.minY
            rowLayer.isHidden = !isVisible
            y += rowLayer.bounds.height
        }
    }

    // MARK: - Selection Rendering

    func updateSelection(_ selection: SelectionRange, lines: [LineMetrics]) {
        let coveredLines = selection.coveringLineIndices(in: lines)
        for (i, rowLayer) in rowLayers.enumerated() {
            if coveredLines.contains(i) {
                let rowRects = rectsForSelectionLine(selection: selection, line: lines[i], rowLayer: rowLayer)
                rowLayer.setSelectionRects(rowRects)
            } else {
                rowLayer.setSelectionRects([])
            }
        }
    }

    private func rectsForSelectionLine(selection: SelectionRange, line: LineMetrics, rowLayer: RowLayer) -> [CGRect] {
        let textStart = line.range.location
        let textEnd = NSMaxRange(line.range)
        let selStart = max(selection.start, textStart)
        let selEnd = min(selection.end, textEnd)

        guard selStart < selEnd else { return [] }

        // Use NSFont to estimate character width
        let charWidth = (font as NSFont).maximumAdvancement.width
        let indentX = gutterWidth + line.indentWidth
        let startX = indentX + CGFloat(selStart - textStart) * max(charWidth, 8)
        let endX = indentX + CGFloat(selEnd - textStart) * max(charWidth, 8)

        return [CGRect(x: startX, y: rowLayer.bounds.minY, width: max(0, endX - startX), height: rowLayer.bounds.height)]
    }

    // MARK: - Cursor

    func cursorRect(for offset: Int, lines: [LineMetrics]) -> CGRect? {
        for lm in lines {
            if offset >= lm.range.location && offset <= NSMaxRange(lm.range) {
                let charOffset = offset - lm.range.location
                let charWidth = (font as NSFont).maximumAdvancement.width
                guard let rowIdx = lines.firstIndex(where: { $0.range.location == lm.range.location }),
                      rowIdx < rowLayers.count else { return nil }
                let rowLayer = rowLayers[rowIdx]
                let indentX = gutterWidth + lm.indentWidth
                let x = indentX + CGFloat(charOffset) * max(charWidth, 8)
                return CGRect(x: x, y: rowLayer.bounds.minY, width: 2, height: rowLayer.bounds.height)
            }
        }
        return nil
    }

    // MARK: - Gutter Hit Testing

    func handleGutterClick(at point: CGPoint) {
        // Find which row layer contains this point (in our coordinate system)
        var y: CGFloat = 0
        for rowLayer in rowLayers {
            let rowTop = bounds.height - y
            let rowBottom = rowTop - rowLayer.bounds.height
            if point.y >= rowBottom && point.y <= rowTop {
                rowLayer.onFoldIndicatorTapped?()
                return
            }
            y += rowLayer.bounds.height
        }
    }
}
