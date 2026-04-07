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

    var customBackgroundColor: NSColor = .clear {
        didSet { setNeedsDisplay() }
    }

    var isSelected: Bool = false {
        didSet { setNeedsDisplay() }
    }

    var selectionRects: [CGRect] = [] {
        didSet { setNeedsDisplay() }
    }

    var wikiLinkColor: NSColor = .systemBlue {
        didSet { setNeedsDisplay() }
    }

    var isWikiLink: Bool = false {
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
        isOpaque = false
    }

    override func draw(in ctx: CGContext) {
        guard let line = ctLine else { return }

        let bounds = ctx.boundingBoxOfClipPath
        ctx.saveGState()

        // Draw selection background
        if isSelected {
            ctx.setFillColor(selectionColor.cgColor)
            for rect in selectionRects {
                ctx.fill(rect)
            }
        }

        // Set up coordinate system for CTLine
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1.0, y: -1.0)

        // Set text color
        ctx.setFillColor(isWikiLink ? wikiLinkColor.cgColor : textColor.cgColor)

        // Position pen at start of line
        let penOffset = CTLineGetOffsetForStringIndex(line, 0, nil)
        ctx.textPosition = CGPoint(x: -penOffset, y: 0)

        // Draw the CTLine
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
