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