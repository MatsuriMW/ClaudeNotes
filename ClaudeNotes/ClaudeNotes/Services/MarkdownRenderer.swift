import Foundation

/// Converts a Markdown string to an HTML fragment.
enum MarkdownRenderer {

    // MARK: - Footnote state (set once per top-level toHTML call, cleared after)
    // Safe for single-threaded (main-actor) UI use.
    private static var _fnNumbers: [String: Int] = [:]

    // MARK: - Public

    static func toHTML(_ markdown: String) -> String {
        // ── Step 0: Extract Mermaid blocks ────────────────────────────────────
        var working = markdown
        var mermaidHTMLs: [String] = []
        let mermaidPattern = #"```mermaid[\s\S]*?```"#
        while let range = working.range(of: mermaidPattern, options: .regularExpression) {
            let raw = String(working[range])
            // Strip opening/closing fence
            let inner = raw
                .replacingOccurrences(of: #"^```mermaid\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "```", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let id = "mermaid-\(mermaidHTMLs.count)"
            mermaidHTMLs.append("<div class=\"mermaid\" id=\"\(id)\">\(escape(inner))</div>")
            working.replaceSubrange(range, with: "MERMAID_PLACEHOLDER_\(mermaidHTMLs.count - 1)_")
        }

        // ── Step 1: Extract footnote definitions ──────────────────────────────
        // A definition line looks like:  [^label]: content
        // Continuation lines are indented ≥ 4 spaces.
        let rawLines = working.components(separatedBy: "\n")
        var cleanLines: [String] = []
        var fnDefs: [String: String] = [:]   // label → raw content (may be image markdown)

        var i = 0
        while i < rawLines.count {
            if let (label, content) = parseFootnoteDef(rawLines[i]) {
                var full = content
                i += 1
                // Consume indented continuation lines
                while i < rawLines.count {
                    let next = rawLines[i]
                    let trimmed = next.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty,
                          next.prefix(while: { $0 == " " }).count >= 4 else { break }
                    full += " " + trimmed
                    i += 1
                }
                fnDefs[label] = full
            } else {
                cleanLines.append(rawLines[i])
                i += 1
            }
        }

        // ── Step 2: Find reference order ──────────────────────────────────────
        // Scan the cleaned text for [^label] to determine numbering order.
        let joined = cleanLines.joined(separator: "\n")
        var fnOrder: [String] = []
        var fnNumbers: [String: Int] = [:]
        if let re = try? NSRegularExpression(pattern: "\\[\\^([^\\]\\n]+)\\]") {
            let ns = joined as NSString
            for m in re.matches(in: joined, range: NSRange(location: 0, length: ns.length)) {
                let r = m.range(at: 1)
                guard r.location != NSNotFound else { continue }
                let label = ns.substring(with: r)
                if fnNumbers[label] == nil {
                    fnOrder.append(label)
                    fnNumbers[label] = fnOrder.count
                }
            }
        }

        // ── Step 3: Render ────────────────────────────────────────────────────
        // Replace mermaid placeholders with actual HTML before rendering paragraphs
        var linesToRender = cleanLines
        for (i, html) in mermaidHTMLs.enumerated() {
            let placeholder = "MERMAID_PLACEHOLDER_\(i)_"
            if let idx = linesToRender.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == placeholder }) {
                linesToRender[idx] = html
            }
        }

        _fnNumbers = fnNumbers
        var body = renderLines(linesToRender)
        _fnNumbers = [:]

        // ── Step 4: Append footnotes section ─────────────────────────────────
        if !fnOrder.isEmpty {
            body += renderFootnotesSection(fnOrder, defs: fnDefs, numbers: fnNumbers)
        }

        return body
    }

    // MARK: - Internal line renderer (used both top-level and recursively)

    private static func renderLines(_ lines: [String]) -> String {
        var out = ""
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let lang  = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    let cl = lines[i]
                    if cl.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { i += 1; break }
                    codeLines.append(cl)
                    i += 1
                }
                let cls = lang.isEmpty ? "" : " class=\"language-\(escapeAttr(lang))\""
                out += "<pre><code\(cls)>\(escape(codeLines.joined(separator: "\n")))</code></pre>\n"
                continue
            }

            // Blank line
            if trimmed.isEmpty { out += "\n"; i += 1; continue }

            // ATX heading
            if let (level, text) = parseHeading(line) {
                out += "<h\(level)>\(inline(text))</h\(level)>\n"
                i += 1; continue
            }

            // Horizontal rule
            if isHRule(trimmed) { out += "<hr>\n"; i += 1; continue }

            // Blockquote
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                var bqLines: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("> ") { bqLines.append(String(t.dropFirst(2))); i += 1 }
                    else if t == ">" { bqLines.append(""); i += 1 }
                    else { break }
                }
                out += "<blockquote>\n\(renderLines(bqLines))</blockquote>\n"
                continue
            }

            // List
            if isListLine(trimmed) {
                var listLines: [String] = []
                while i < lines.count && isListLine(lines[i].trimmingCharacters(in: .whitespaces)) {
                    listLines.append(lines[i])
                    i += 1
                }
                out += renderList(listLines)
                continue
            }

            // Paragraph — collect until blank/block-start
            var para: [String] = []
            while i < lines.count {
                let pl = lines[i]
                let pt = pl.trimmingCharacters(in: .whitespaces)
                if pt.isEmpty { break }
                if parseHeading(pl) != nil { break }
                if isHRule(pt) { break }
                if pt.hasPrefix("> ") || pt == ">" { break }
                if isListLine(pt) { break }
                if pt.hasPrefix("```") || pt.hasPrefix("~~~") { break }
                para.append(pl)
                i += 1
            }
            if !para.isEmpty {
                out += "<p>\(inline(para.joined(separator: " ")))</p>\n"
            }
        }
        return out
    }

    // MARK: - Footnote helpers

    /// Parses a footnote definition line like `[^label]: content`.
    private static func parseFootnoteDef(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[^") else { return nil }
        guard let closeBracket = trimmed.firstIndex(of: "]") else { return nil }
        let afterClose = trimmed.index(after: closeBracket)
        guard afterClose < trimmed.endIndex, trimmed[afterClose] == ":" else { return nil }
        let labelStart = trimmed.index(trimmed.startIndex, offsetBy: 2)
        let label = String(trimmed[labelStart..<closeBracket])
        guard !label.isEmpty else { return nil }
        let afterColon = trimmed.index(after: afterClose)
        let content = afterColon < trimmed.endIndex
            ? String(trimmed[afterColon...]).trimmingCharacters(in: .whitespaces)
            : ""
        return (label, content)
    }

    /// Renders the `<section class="footnotes">` block appended after the document body.
    private static func renderFootnotesSection(_ order: [String],
                                               defs: [String: String],
                                               numbers: [String: Int]) -> String {
        var html = "<section class=\"footnotes\">\n"
        html += "<hr class=\"footnotes-sep\">\n"
        html += "<ol class=\"footnotes-list\">\n"
        for label in order {
            guard let content = defs[label], let num = numbers[label] else { continue }
            let eLabel = escapeAttr(label)
            // inline() handles images (![alt](url)) and other markup inside footnote content
            let rendered = inline(content)
            html += "<li id=\"fn-\(eLabel)\" value=\"\(num)\">"
            html += "<p>\(rendered)"
            html += " <a href=\"#fnref-\(eLabel)\" class=\"footnote-backref\" title=\"返回正文\">↩</a>"
            html += "</p></li>\n"
        }
        html += "</ol>\n</section>\n"
        return html
    }

    // MARK: - Block helpers

    private static func parseHeading(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("#") else { return nil }
        var lvl = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", lvl < 6 {
            lvl += 1; idx = line.index(after: idx)
        }
        guard lvl > 0, idx < line.endIndex, line[idx] == " " else { return nil }
        return (lvl, String(line[line.index(after: idx)...]))
    }

    private static func isHRule(_ t: String) -> Bool {
        let clean = t.filter { !$0.isWhitespace }
        guard clean.count >= 3 else { return false }
        let chars = Set(clean)
        return chars.count == 1 && (chars.first == "-" || chars.first == "*" || chars.first == "_")
    }

    private static func isListLine(_ t: String) -> Bool {
        if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") { return true }
        var j = t.startIndex
        while j < t.endIndex, t[j].isNumber { j = t.index(after: j) }
        return j > t.startIndex && j < t.endIndex && t[j] == "." &&
               t.index(after: j) < t.endIndex && t[t.index(after: j)] == " "
    }

    private static func renderList(_ lines: [String]) -> String {
        struct Item {
            let indent: Int; let ordered: Bool; let content: String
            var children: [Item] = []
        }

        var flat: [Item] = []
        for line in lines {
            let indent = line.prefix(while: { $0 == " " }).count
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") {
                flat.append(Item(indent: indent, ordered: false, content: String(t.dropFirst(2))))
            } else {
                var j = t.startIndex; var digits = ""
                while j < t.endIndex, t[j].isNumber { digits.append(t[j]); j = t.index(after: j) }
                guard !digits.isEmpty, j < t.endIndex, t[j] == ".",
                      t.index(after: j) < t.endIndex, t[t.index(after: j)] == " " else { continue }
                flat.append(Item(indent: indent, ordered: true,
                                 content: String(t[t.index(j, offsetBy: 2)...])))
            }
        }
        guard !flat.isEmpty else { return "" }

        func build(start: inout Int, minIndent: Int) -> [Item] {
            var nodes: [Item] = []
            while start < flat.count {
                var item = flat[start]
                if item.indent < minIndent { break }
                start += 1
                if start < flat.count && flat[start].indent > item.indent {
                    item.children = build(start: &start, minIndent: flat[start].indent)
                }
                nodes.append(item)
            }
            return nodes
        }
        var idx = 0
        let roots = build(start: &idx, minIndent: flat[0].indent)

        func render(_ items: [Item]) -> String {
            guard !items.isEmpty else { return "" }
            let tag = items[0].ordered ? "ol" : "ul"
            var html = "<\(tag)>\n"
            for item in items {
                let raw = item.content
                let body: String
                if raw.hasPrefix("[ ] ") {
                    body = "<input type=\"checkbox\" disabled> \(inline(String(raw.dropFirst(4))))"
                } else if raw.hasPrefix("[x] ") || raw.hasPrefix("[X] ") {
                    body = "<input type=\"checkbox\" checked disabled> \(inline(String(raw.dropFirst(4))))"
                } else { body = inline(raw) }
                html += item.children.isEmpty
                    ? "<li>\(body)</li>\n"
                    : "<li>\(body)\n\(render(item.children))</li>\n"
            }
            return html + "</\(tag)>\n"
        }
        return render(roots)
    }

    // MARK: - Inline

    private static func inline(_ text: String) -> String {
        var s = text
        var map: [String: String] = [:]
        var n = 0

        func protect(_ html: String) -> String {
            let ph = "\u{E000}\(n)\u{E001}"; map[ph] = html; n += 1; return ph
        }

        // Protect inline code (before HTML escaping so content is escaped once)
        s = sub(s, "`([^`\n]+)`") { g in protect("<code>\(escape(g[1]))</code>") }

        // Protect footnote references [^label] — before images/links to avoid mis-parsing
        s = sub(s, "\\[\\^([^\\]\\n]+)\\]") { g in
            let label = g[1]
            guard let num = _fnNumbers[label] else {
                // No definition found — render as literal text
                return protect(escape(g[0]))
            }
            let eLabel = escapeAttr(label)
            return protect(
                "<sup id=\"fnref-\(eLabel)\"><a href=\"#fn-\(eLabel)\" class=\"footnote-ref\">\(num)</a></sup>"
            )
        }

        // Protect images (before links to avoid conflict)
        s = sub(s, "!\\[([^\\]]*?)\\]\\(([^)\n]*?)\\)") { g in
            protect("<img src=\"\(escapeAttr(g[2]))\" alt=\"\(escapeAttr(g[1]))\">")
        }
        // Protect links
        s = sub(s, "\\[([^\\]]*?)\\]\\(([^)\n]*?)\\)") { g in
            protect("<a href=\"\(escapeAttr(g[2]))\">\(escape(g[1]))</a>")
        }

        // HTML-escape the remaining text (placeholders have no &/</>)
        s = s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")

        // Bold+italic
        s = sub(s, "\\*\\*\\*(.+?)\\*\\*\\*") { g in "<strong><em>\(g[1])</em></strong>" }
        // Bold
        s = sub(s, "\\*\\*(.+?)\\*\\*") { g in "<strong>\(g[1])</strong>" }
        s = sub(s, "__(.+?)__")           { g in "<strong>\(g[1])</strong>" }
        // Italic
        s = sub(s, "\\*([^*\n]+)\\*")    { g in "<em>\(g[1])</em>" }
        s = sub(s, "_([^_\n]+)_")        { g in "<em>\(g[1])</em>" }
        // Strikethrough
        s = sub(s, "~~(.+?)~~")           { g in "<del>\(g[1])</del>" }
        // Highlight ==text==
        s = sub(s, "==(.+?)==")           { g in "<mark>\(g[1])</mark>" }

        // Restore protected spans
        for (ph, rep) in map { s = s.replacingOccurrences(of: ph, with: rep) }
        return s
    }

    // MARK: - Regex helper

    private static func sub(_ input: String, _ pattern: String,
                             _ f: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return input }
        let ns = input as NSString
        let full = NSRange(location: 0, length: ns.length)
        var result = "", last = 0
        for m in re.matches(in: input, range: full) {
            result += ns.substring(with: NSRange(location: last,
                                                 length: m.range.location - last))
            var gs = [String]()
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                gs.append(r.location != NSNotFound ? ns.substring(with: r) : "")
            }
            result += f(gs)
            last = m.range.location + m.range.length
        }
        if last < ns.length { result += ns.substring(from: last) }
        return result
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttr(_ s: String) -> String {
        escape(s).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
