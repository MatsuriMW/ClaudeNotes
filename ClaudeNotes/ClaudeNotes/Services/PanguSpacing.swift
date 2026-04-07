import Foundation

/// "Pangu Spacing" — 盘古之白
/// Adds a space between CJK characters and half-width letters/digits.
/// Character ranges match the pangu.js library used by obsidian-pangu.
enum PanguSpacing {

    /// All CJK and related Unicode blocks that should be spaced away from Latin/digits.
    private static let cjkClass: String = {
        let ranges = [
            "\\u2e80-\\u2eff", // CJK Radicals Supplement
            "\\u2f00-\\u2fdf", // Kangxi Radicals
            "\\u3040-\\u309f", // Hiragana
            "\\u30a0-\\u30ff", // Katakana
            "\\u3100-\\u312f", // Bopomofo
            "\\u3200-\\u32ff", // Enclosed CJK Letters and Months
            "\\u3400-\\u4dbf", // CJK Extension A
            "\\u4e00-\\u9fff", // CJK Unified Ideographs
            "\\uac00-\\ud7af", // Hangul Syllables
            "\\uf900-\\ufaff", // CJK Compatibility Ideographs
            "\\ufe30-\\ufe4f", // CJK Compatibility Forms
        ]
        return "[" + ranges.joined() + "]"
    }()

    /// Apply pangu spacing to `text`, returning the modified string.
    static func apply(to text: String) -> String {
        var result = text
        let cjk = cjkClass
        let ans = "[A-Za-z0-9]"

        // CJK followed by Latin/digit
        result = result.replacingOccurrences(
            of: "(\(cjk))(\(ans))",
            with: "$1 $2",
            options: .regularExpression
        )

        // Latin/digit followed by CJK
        result = result.replacingOccurrences(
            of: "(\(ans))(\(cjk))",
            with: "$1 $2",
            options: .regularExpression
        )

        // Collapse any accidental double spaces introduced by the above
        result = result.replacingOccurrences(
            of: "(\(cjk)) {2,}(\(ans))",
            with: "$1 $2",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "(\(ans)) {2,}(\(cjk))",
            with: "$1 $2",
            options: .regularExpression
        )

        return result
    }
}
