import Foundation

enum MarkdownFormat {
    case bold
    case italic
    case strikethrough
    case inlineCode
    case codeBlock
    case heading(Int)    // 1-6
    case link
    case image
    case unorderedList
    case orderedList
    case taskList
    case blockquote
    case horizontalRule
    case indent
    case outdent
}

struct FormatResult {
    let text: String
    let selectedRange: NSRange
}

enum MarkdownFormatter {

    // MARK: - Main Entry

    static func apply(_ format: MarkdownFormat, to text: String, selectedRange: NSRange, indentUnit: String = "    ") -> FormatResult {
        switch format {
        case .bold:
            return applyWrap("**", to: text, selectedRange: selectedRange)
        case .italic:
            return applyWrap("*", to: text, selectedRange: selectedRange)
        case .strikethrough:
            return applyWrap("~~", to: text, selectedRange: selectedRange)
        case .inlineCode:
            return applyWrap("`", to: text, selectedRange: selectedRange)
        case .codeBlock:
            return applyCodeBlock(to: text, selectedRange: selectedRange)
        case .heading(let level):
            return applyLinePrefix(String(repeating: "#", count: level) + " ", to: text, selectedRange: selectedRange)
        case .link:
            return applyLink(to: text, selectedRange: selectedRange)
        case .image:
            return applyImage(to: text, selectedRange: selectedRange)
        case .unorderedList:
            return applyLinePrefix("- ", to: text, selectedRange: selectedRange)
        case .orderedList:
            return applyOrderedList(to: text, selectedRange: selectedRange)
        case .taskList:
            return applyLinePrefix("- [ ] ", to: text, selectedRange: selectedRange)
        case .blockquote:
            return applyLinePrefix("> ", to: text, selectedRange: selectedRange)
        case .horizontalRule:
            return applyHorizontalRule(to: text, selectedRange: selectedRange)
        case .indent:
            return applyIndent(to: text, selectedRange: selectedRange, reverse: false, indentUnit: indentUnit)
        case .outdent:
            return applyIndent(to: text, selectedRange: selectedRange, reverse: true, indentUnit: indentUnit)
        }
    }

    // MARK: - Wrap Formatting (Bold, Italic, Strikethrough, Code)

    private static func applyWrap(_ marker: String, to text: String, selectedRange: NSRange) -> FormatResult {
        let nsText = text as NSString
        let markerLen = marker.count

        if selectedRange.length > 0 {
            // Text is selected — check if already wrapped
            let selectedText = nsText.substring(with: selectedRange)

            // Check if selection itself starts and ends with marker
            if selectedText.hasPrefix(marker) && selectedText.hasSuffix(marker) && selectedText.count > markerLen * 2 {
                // Unwrap: remove markers from inside selection
                let inner = String(selectedText.dropFirst(markerLen).dropLast(markerLen))
                let newText = nsText.replacingCharacters(in: selectedRange, with: inner)
                return FormatResult(
                    text: newText,
                    selectedRange: NSRange(location: selectedRange.location, length: inner.count)
                )
            }

            // Check if markers exist just outside the selection
            let beforeStart = selectedRange.location - markerLen
            let afterEnd = selectedRange.location + selectedRange.length
            if beforeStart >= 0 && afterEnd + markerLen <= nsText.length {
                let before = nsText.substring(with: NSRange(location: beforeStart, length: markerLen))
                let after = nsText.substring(with: NSRange(location: afterEnd, length: markerLen))
                if before == marker && after == marker {
                    // Unwrap: remove surrounding markers
                    let outerRange = NSRange(location: beforeStart, length: selectedRange.length + markerLen * 2)
                    let newText = nsText.replacingCharacters(in: outerRange, with: selectedText)
                    return FormatResult(
                        text: newText,
                        selectedRange: NSRange(location: beforeStart, length: selectedRange.length)
                    )
                }
            }

            // Wrap selection
            let wrapped = marker + selectedText + marker
            let newText = nsText.replacingCharacters(in: selectedRange, with: wrapped)
            return FormatResult(
                text: newText,
                selectedRange: NSRange(location: selectedRange.location + markerLen, length: selectedRange.length)
            )
        } else {
            // No selection — insert empty markers and place cursor between them
            let insertion = marker + marker
            let newText = nsText.replacingCharacters(in: selectedRange, with: insertion)
            return FormatResult(
                text: newText,
                selectedRange: NSRange(location: selectedRange.location + markerLen, length: 0)
            )
        }
    }

    // MARK: - Code Block

    private static func applyCodeBlock(to text: String, selectedRange: NSRange) -> FormatResult {
        let nsText = text as NSString
        let selectedText = selectedRange.length > 0 ? nsText.substring(with: selectedRange) : ""

        let codeBlock = "```\n\(selectedText)\n```"
        let newText = nsText.replacingCharacters(in: selectedRange, with: codeBlock)
        let cursorPos = selectedRange.location + 4 // after ```\n
        return FormatResult(
            text: newText,
            selectedRange: NSRange(location: cursorPos, length: selectedText.count)
        )
    }

    // MARK: - Line Prefix (Heading, List, Blockquote)

    private static func applyLinePrefix(_ prefix: String, to text: String, selectedRange: NSRange) -> FormatResult {
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: selectedRange)
        let lineContent = nsText.substring(with: lineRange)

        let lines = lineContent.components(separatedBy: "\n")

        // Base indent: indent of the first non-empty line.
        // Lines with MORE indentation are children and must be preserved unchanged.
        let baseIndent: Int = lines
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            .map { lineIndent($0) } ?? 0

        // Toggle detection considers only same-level non-empty lines.
        let sameLevelNonEmpty = lines.filter { line in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return !t.isEmpty && lineIndent(line) <= baseIndent
        }
        let allHavePrefix = !sameLevelNonEmpty.isEmpty && sameLevelNonEmpty.allSatisfy { line in
            line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(prefix)
        }

        var newLines: [String] = []
        var didRemove = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // Child lines (deeper indent) and empty lines pass through unchanged.
            if trimmed.isEmpty || lineIndent(line) > baseIndent {
                newLines.append(line)
                continue
            }

            // Same-level line: work on the trimmed content, then reattach indent.
            let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))

            if prefix.hasPrefix("#") {
                let stripped = removeHeadingPrefix(from: trimmed)
                if stripped != trimmed && trimmed.hasPrefix(prefix) {
                    // Same heading level — toggle off
                    newLines.append(indent + stripped)
                    didRemove = true
                } else {
                    // Replace any existing heading with new level
                    newLines.append(indent + prefix + stripped)
                }
            } else if allHavePrefix {
                // Toggle off: remove prefix from the trimmed content
                newLines.append(indent + String(trimmed.dropFirst(prefix.count)))
                didRemove = true
            } else {
                // Toggle on: strip any existing list-type prefix, then add new one
                let stripped = removeListPrefix(from: trimmed)
                newLines.append(indent + prefix + stripped)
            }
        }

        let newLineContent = newLines.joined(separator: "\n")
        let newText = nsText.replacingCharacters(in: lineRange, with: newLineContent)
        let lengthDiff = newLineContent.count - lineContent.count

        return FormatResult(
            text: newText,
            selectedRange: NSRange(
                location: selectedRange.location + (didRemove ? min(0, lengthDiff) : prefix.count),
                length: max(0, selectedRange.length + lengthDiff)
            )
        )
    }

    /// Number of "indent units" represented by the leading whitespace of `line`.
    /// Tabs count as 4 spaces for comparison purposes.
    private static func lineIndent(_ line: String) -> Int {
        var count = 0
        for ch in line {
            if ch == " " { count += 1 }
            else if ch == "\t" { count += 4 }
            else { break }
        }
        return count
    }

    private static func removeHeadingPrefix(from line: String) -> String {
        if let match = line.range(of: "^#{1,6}\\s*", options: .regularExpression) {
            return String(line[match.upperBound...])
        }
        return line
    }

    private static func removeListPrefix(from line: String) -> String {
        // Remove common list prefixes: "- ", "* ", "1. ", "- [ ] ", "- [x] ", "> "
        let patterns = [
            "^- \\[[ x]\\] ",  // task list
            "^\\d+\\.\\s+",     // ordered list
            "^[-*+]\\s+",       // unordered list
            "^>\\s*",           // blockquote
        ]
        for pattern in patterns {
            if let match = line.range(of: pattern, options: .regularExpression) {
                return String(line[match.upperBound...])
            }
        }
        return line
    }

    // MARK: - Ordered List

    private static func applyOrderedList(to text: String, selectedRange: NSRange) -> FormatResult {
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: selectedRange)
        let lineContent = nsText.substring(with: lineRange)

        let lines = lineContent.components(separatedBy: "\n")
        var newLines: [String] = []
        var allOrdered = true

        // Check if all lines are already ordered
        for line in lines where !line.isEmpty {
            if line.range(of: "^\\d+\\.\\s", options: .regularExpression) == nil {
                allOrdered = false
                break
            }
        }

        if allOrdered && lines.contains(where: { !$0.isEmpty }) {
            // Remove ordered list
            for line in lines {
                newLines.append(removeListPrefix(from: line))
            }
        } else {
            // Add ordered list
            var num = 1
            for line in lines {
                if line.isEmpty {
                    newLines.append(line)
                } else {
                    let stripped = removeListPrefix(from: line)
                    newLines.append("\(num). \(stripped)")
                    num += 1
                }
            }
        }

        let newLineContent = newLines.joined(separator: "\n")
        let newText = nsText.replacingCharacters(in: lineRange, with: newLineContent)
        let lengthDiff = newLineContent.count - lineContent.count

        return FormatResult(
            text: newText,
            selectedRange: NSRange(
                location: selectedRange.location,
                length: max(0, selectedRange.length + lengthDiff)
            )
        )
    }

    // MARK: - Link / Image

    private static func applyLink(to text: String, selectedRange: NSRange) -> FormatResult {
        let nsText = text as NSString
        let selectedText = selectedRange.length > 0 ? nsText.substring(with: selectedRange) : "链接文字"
        let linkMd = "[\(selectedText)](url)"
        let newText = nsText.replacingCharacters(in: selectedRange, with: linkMd)
        // Select "url" so user can type the URL
        let urlStart = selectedRange.location + selectedText.count + 2 // after ](
        return FormatResult(
            text: newText,
            selectedRange: NSRange(location: urlStart, length: 3)
        )
    }

    private static func applyImage(to text: String, selectedRange: NSRange) -> FormatResult {
        let nsText = text as NSString
        let selectedText = selectedRange.length > 0 ? nsText.substring(with: selectedRange) : "alt text"
        let imgMd = "![\(selectedText)](url)"
        let newText = nsText.replacingCharacters(in: selectedRange, with: imgMd)
        let urlStart = selectedRange.location + selectedText.count + 3 // after ](
        return FormatResult(
            text: newText,
            selectedRange: NSRange(location: urlStart, length: 3)
        )
    }

    // MARK: - Horizontal Rule

    private static func applyHorizontalRule(to text: String, selectedRange: NSRange) -> FormatResult {
        let nsText = text as NSString
        // Insert horizontal rule on a new line
        let lineRange = nsText.lineRange(for: selectedRange)
        let lineEnd = lineRange.location + lineRange.length

        let insertion = "\n---\n"
        let newText = nsText.replacingCharacters(in: NSRange(location: lineEnd, length: 0), with: insertion)
        return FormatResult(
            text: newText,
            selectedRange: NSRange(location: lineEnd + insertion.count, length: 0)
        )
    }

    // MARK: - Indent / Outdent

    private static func applyIndent(to text: String, selectedRange: NSRange, reverse: Bool, indentUnit: String = "    ") -> FormatResult {
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: selectedRange)
        let lineContent = nsText.substring(with: lineRange)

        let lines = lineContent.components(separatedBy: "\n")
        var newLines: [String] = []
        // Maximum number of leading spaces to strip when outdenting
        let maxStripSpaces = max(indentUnit.filter { $0 == " " }.count, 4)

        for line in lines {
            if reverse {
                // Outdent: remove leading indentUnit, or fall back to tab/spaces
                if line.hasPrefix(indentUnit) {
                    newLines.append(String(line.dropFirst(indentUnit.count)))
                } else if line.hasPrefix("\t") {
                    newLines.append(String(line.dropFirst(1)))
                } else {
                    var stripped = line
                    var removed = 0
                    while removed < maxStripSpaces && stripped.hasPrefix(" ") {
                        stripped = String(stripped.dropFirst())
                        removed += 1
                    }
                    newLines.append(stripped)
                }
            } else {
                // Indent
                if line.isEmpty && lines.last == line {
                    newLines.append(line) // don't indent trailing empty line
                } else {
                    newLines.append(indentUnit + line)
                }
            }
        }

        let newLineContent = newLines.joined(separator: "\n")
        let newText = nsText.replacingCharacters(in: lineRange, with: newLineContent)
        let lengthDiff = newLineContent.count - lineContent.count
        let unitLen = indentUnit.count

        return FormatResult(
            text: newText,
            selectedRange: NSRange(
                location: max(lineRange.location, selectedRange.location + (reverse ? min(0, lengthDiff) : unitLen)),
                length: max(0, selectedRange.length + lengthDiff)
            )
        )
    }
}
