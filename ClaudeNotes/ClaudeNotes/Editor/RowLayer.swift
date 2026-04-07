import Foundation
import QuartzCore
import AppKit
import CoreText

// MARK: - RowLayer

/// A CALayer representing one logical row in the document.
/// Contains: indent spacer, one or more LineFragmentLayers, and a fold indicator.
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
    private var gutterHitLayer: CALayer!

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

        let indicatorW: CGFloat = 16
        foldIndicatorLayer.frame = CGRect(
            x: indentWidth + 4,
            y: (bounds.height - 14) / 2,
            width: indicatorW,
            height: 14
        )
        gutterHitLayer.frame = CGRect(
            x: 0,
            y: 0,
            width: indentWidth + indicatorW + 4,
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
            let hitRects = rects.filter { fragLayer.frame.intersects($0) }
                .map { fragLayer.frame.intersection($0) }
            fragLayer.selectionRects = hitRects
            fragLayer.isSelected = !hitRects.isEmpty
        }
    }
}
