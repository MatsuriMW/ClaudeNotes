import Foundation

enum TaskExtractionService {

    // MARK: - Extraction

    /// Scans all non-deleted notes for lines that:
    /// 1. Start with unordered list markers followed by task keywords (e.g., "- TODO", "- todo", "* DOING")
    /// 2. Contain hash tags anywhere in a list item (e.g., "- Some text #todo")
    /// 3. Contain hash tags anywhere in a non-list paragraph (e.g., "Read this #toread")
    static func extract(from notes: [Note], settings: TaskSettings) -> [TaskItem] {
        // keyword (lowercased) → canonical column keyword
        var keywordMap: [String: String] = [:]
        for col in settings.columns {
            for kw in col.allKeywords {
                keywordMap[kw.lowercased()] = col.keyword
            }
        }
        // Longer keywords checked first so "toread" wins over "to"
        let sortedKeywords = keywordMap.keys.sorted { $0.count > $1.count }

        // Build tag map: #tag -> column keyword
        var tagMap: [String: String] = [:]
        let tagPattern = #"#(\w+)"#
        for kw in keywordMap.keys {
            tagMap["#\(kw)"] = keywordMap[kw]
        }

        var items: [TaskItem] = []
        for note in notes where !note.isDeleted {
            let lines = note.content.components(separatedBy: "\n")
            var inCodeBlock = false

            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                // Track fenced code blocks and skip their contents
                if trimmed.hasPrefix("```") { inCodeBlock.toggle(); continue }
                if inCodeBlock || trimmed.isEmpty { continue }

                // ── First: try list-item extraction (existing behaviour) ──────────
                if let (prefix, content) = listItemParts(of: line) {
                    var matched: (status: String, keyword: String)?
                    var checkboxMatched = false

                    if content.hasPrefix("[ ]") || content.hasPrefix("[]") {
                        if let todoKeyword = keywordMap["todo"] {
                            matched = (todoKeyword, "[ ]")
                            checkboxMatched = true
                        }
                    } else if content.hasPrefix("[x]") || content.hasPrefix("[X]") {
                        if let doneKeyword = keywordMap["done"] {
                            matched = (doneKeyword, "[x]")
                            checkboxMatched = true
                        }
                    }

                    if !checkboxMatched {
                        for kw in sortedKeywords {
                            if content.lowercased().hasPrefix(kw.lowercased()) {
                                let nextIdx = content.index(content.startIndex, offsetBy: kw.count)
                                if nextIdx == content.endIndex ||
                                   !content[nextIdx].isLetter && !content[nextIdx].isNumber {
                                    matched = (keywordMap[kw]!, kw)
                                    break
                                }
                            }
                        }
                    }

                    // Hash tags inside list items
                    if matched == nil {
                        if let regex = try? NSRegularExpression(pattern: tagPattern, options: .caseInsensitive) {
                            let ns = content as NSString
                            for match in regex.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
                                let tagRange = match.range(at: 1)
                                guard tagRange.location != NSNotFound else { continue }
                                let tag = ns.substring(with: tagRange)
                                if let status = tagMap["#" + tag.lowercased()] {
                                    matched = (status, "#" + tag)
                                    break
                                }
                            }
                        }
                    }

                    if let (status, matchedKw) = matched {
                        let (text, leads) = displayTextAndPosition(trimmed: trimmed, keyword: matchedKw)
                        items.append(TaskItem(
                            note: note,
                            status: status,
                            text: text,
                            originalLine: line,
                            originalLineIndex: index,
                            matchedKeyword: matchedKw,
                            keywordLeadsContent: leads,
                            isInlineTag: false
                        ))
                    }
                    continue
                }

                // ── Second: non-list paragraphs with inline hash tags ─────────────
                if let regex = try? NSRegularExpression(pattern: tagPattern, options: .caseInsensitive) {
                    let ns = line as NSString
                    for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                        let tagRange = match.range(at: 1)
                        guard tagRange.location != NSNotFound else { continue }
                        let tag = ns.substring(with: tagRange).lowercased()
                        guard let status = tagMap["#\(tag)"] else { continue }

                        // Full line as originalLine; strip the #tag for display text
                        let fullLine = line
                        let matchedKw = "#" + tag
                        let tagStart = match.range.location
                        let beforeTag = (tagStart > 0) ? String(line[line.startIndex..<line.index(line.startIndex, offsetBy: tagStart)]).trimmingCharacters(in: .whitespaces) : ""
                        let afterTagIdx = line.index(line.startIndex, offsetBy: tagRange.location + tagRange.length)
                        let afterTag = (afterTagIdx < line.endIndex) ? String(line[afterTagIdx...]).trimmingCharacters(in: .whitespaces) : ""
                        let rawText = beforeTag + (afterTag.isEmpty ? "" : " ") + afterTag

                        // keyword leads if #tag is the first non-whitespace thing on the line
                        let leadingKeyword = line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(matchedKw.lowercased())

                        items.append(TaskItem(
                            note: note,
                            status: status,
                            text: rawText.isEmpty ? line.trimmingCharacters(in: .whitespaces) : rawText,
                            originalLine: fullLine,
                            originalLineIndex: index,
                            matchedKeyword: matchedKw,
                            keywordLeadsContent: leadingKeyword,
                            isInlineTag: true
                        ))
                        break  // only first tag per line
                    }
                }
            }
        }
        return items
    }

    // MARK: - Sync back to note content

    /// Replace the matched keyword with the new status keyword.
    static func updateStatus(of item: TaskItem, to newStatus: String, in note: Note, settings: TaskSettings) {
        // Inline tag in a non-list paragraph: keep the tag, append checkbox at line end
        if item.isInlineTag {
            let checkbox: String = (newStatus == "done") ? "[x]" : "[ ]"
            // Remove any existing checkbox from this line first
            var stripped = item.originalLine
            if let r = stripped.range(of: "[x]", options: .caseInsensitive) { stripped.removeSubrange(r) }
            if let r = stripped.range(of: "[ ]") { stripped.removeSubrange(r) }
            if let r = stripped.range(of: "[]") { stripped.removeSubrange(r) }
            let newLine = stripped.trimmingCharacters(in: .whitespaces) + " " + checkbox
            replaceLine(at: item.originalLineIndex, originalContent: item.originalLine, with: newLine, in: note)
            return
        }

        // Handle hash tags in list items: replace #oldtag with #newtag
        if item.matchedKeyword.hasPrefix("#") {
            let oldTag = item.matchedKeyword
            let newTag = "#\(newStatus)"
            var newLine = item.originalLine

            // Replace the tag (case-insensitive)
            if let range = newLine.range(of: oldTag, options: .caseInsensitive) {
                newLine = newLine.replacingCharacters(in: range, with: newTag)
            }

            replaceLine(at: item.originalLineIndex, originalContent: item.originalLine, with: newLine, in: note)
            return
        }

        // Handle checkbox syntax specially
        if item.matchedKeyword == "[ ]" || item.matchedKeyword == "[x]" {
            var newLine = item.originalLine

            // Map status to checkbox: todo/done -> [ ]/[x]
            let newCheckbox: String
            if newStatus == "done" {
                newCheckbox = "[x]"
            } else if newStatus == "todo" {
                newCheckbox = "[ ]"
            } else {
                // For non-checkbox statuses, replace with keyword
                newLine = replaceCheckboxInLine(item.originalLine, with: newStatus)
                replaceLine(at: item.originalLineIndex, originalContent: item.originalLine, with: newLine, in: note)
                return
            }

            // Replace checkbox in the line
            newLine = replaceCheckboxInLine(item.originalLine, with: newCheckbox)
            replaceLine(at: item.originalLineIndex, originalContent: item.originalLine, with: newLine, in: note)
            return
        }

        // Preserve capitalisation style of the original keyword occurrence
        let newLine = replaceKeyword(item.matchedKeyword, with: newStatus, in: item.originalLine)
        replaceLine(at: item.originalLineIndex, originalContent: item.originalLine, with: newLine, in: note)
    }

    /// Replace checkbox ([ ] or [x]) with new checkbox or keyword
    private static func replaceCheckboxInLine(_ line: String, with replacement: String) -> String {
        // Find checkbox pattern and replace it
        if let range = line.range(of: "[x]", options: .caseInsensitive) {
            return line.replacingCharacters(in: range, with: replacement)
        } else if let range = line.range(of: "[ ]") {
            return line.replacingCharacters(in: range, with: replacement)
        } else if let range = line.range(of: "[]") {
            return line.replacingCharacters(in: range, with: replacement)
        }
        return line
    }

    /// Update the task text while keeping the keyword in place.
    static func updateText(of item: TaskItem, to newText: String, in note: Note) {
        // Inline tags: always preserve the tag and put new text after it
        if item.isInlineTag {
            let checkbox: String
            // Preserve any existing checkbox on the line
            if item.originalLine.range(of: "[x]", options: .caseInsensitive) != nil {
                checkbox = "[x]"
            } else if item.originalLine.range(of: "[ ]") != nil || item.originalLine.range(of: "[]") != nil {
                checkbox = "[ ]"
            } else {
                checkbox = ""
            }
            let checkboxSuffix = checkbox.isEmpty ? "" : " \(checkbox)"
            let newLine = "\(item.originalLine.trimmingCharacters(in: .whitespaces)) \(newText)\(checkboxSuffix)"
            replaceLine(at: item.originalLineIndex, originalContent: item.originalLine, with: newLine, in: note)
            return
        }

        let newLine: String
        if item.keywordLeadsContent {
            // Keyword is at the start of content — rebuild cleanly
            if let (prefix, content) = listItemParts(of: item.originalLine) {
                let sep = colonSuffix(in: content, keyword: item.matchedKeyword)
                newLine = "\(prefix)\(item.matchedKeyword)\(sep) \(newText)"
            } else {
                let bare = item.originalLine.trimmingCharacters(in: .whitespaces)
                let sep = colonSuffix(in: bare, keyword: item.matchedKeyword)
                newLine = "\(item.matchedKeyword)\(sep) \(newText)"
            }
        } else {
            // Keyword is embedded in the middle — replace the whole line
            newLine = newText
        }
        replaceLine(at: item.originalLineIndex, originalContent: item.originalLine, with: newLine, in: note)
    }

    static func delete(_ item: TaskItem, from note: Note) {
        var lines = note.content.components(separatedBy: "\n")
        if item.originalLineIndex < lines.count, lines[item.originalLineIndex] == item.originalLine {
            lines.remove(at: item.originalLineIndex)
        } else if let idx = lines.firstIndex(of: item.originalLine) {
            lines.remove(at: idx)
        }
        note.content = lines.joined(separator: "\n")
        note.modifiedAt = Date()
    }

    // MARK: - External file support

    /// Update task text in an external file
    static func updateTextInFile(_ item: TaskItem, newText: String) -> Bool {
        guard let fileURL = item.fileURL else { return false }
        guard var content = try? String(contentsOf: fileURL, encoding: .utf8) else { return false }

        let newLine: String
        // Inline tags: preserve the tag and append new text + checkbox
        if item.isInlineTag {
            let checkbox: String
            if item.originalLine.range(of: "[x]", options: .caseInsensitive) != nil {
                checkbox = "[x]"
            } else if item.originalLine.range(of: "[ ]") != nil || item.originalLine.range(of: "[]") != nil {
                checkbox = "[ ]"
            } else {
                checkbox = ""
            }
            let checkboxSuffix = checkbox.isEmpty ? "" : " \(checkbox)"
            newLine = "\(item.originalLine.trimmingCharacters(in: .whitespaces)) \(newText)\(checkboxSuffix)"
        } else if item.keywordLeadsContent {
            if let (prefix, content) = listItemParts(of: item.originalLine) {
                let sep = colonSuffix(in: content, keyword: item.matchedKeyword)
                newLine = "\(prefix)\(item.matchedKeyword)\(sep) \(newText)"
            } else {
                let bare = item.originalLine.trimmingCharacters(in: .whitespaces)
                let sep = colonSuffix(in: bare, keyword: item.matchedKeyword)
                newLine = "\(item.matchedKeyword)\(sep) \(newText)"
            }
        } else {
            newLine = newText
        }

        var lines = content.components(separatedBy: "\n")
        if item.originalLineIndex < lines.count, lines[item.originalLineIndex] == item.originalLine {
            lines[item.originalLineIndex] = newLine
        } else if let found = lines.firstIndex(of: item.originalLine) {
            lines[found] = newLine
        } else {
            return false
        }

        content = lines.joined(separator: "\n")
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Update task status in an external file
    static func updateStatusInFile(_ item: TaskItem, newStatus: String) -> Bool {
        guard let fileURL = item.fileURL else { return false }
        guard var content = try? String(contentsOf: fileURL, encoding: .utf8) else { return false }

        var newLine: String = item.originalLine

        // Inline tag in non-list paragraph: keep tag, append checkbox
        if item.isInlineTag {
            let checkbox: String = (newStatus == "done") ? "[x]" : "[ ]"
            var stripped = item.originalLine
            if let r = stripped.range(of: "[x]", options: .caseInsensitive) { stripped.removeSubrange(r) }
            if let r = stripped.range(of: "[ ]") { stripped.removeSubrange(r) }
            if let r = stripped.range(of: "[]") { stripped.removeSubrange(r) }
            newLine = stripped.trimmingCharacters(in: .whitespaces) + " " + checkbox
        } else if item.matchedKeyword.hasPrefix("#") {
            // List-item hash tag: replace tag
            let oldTag = item.matchedKeyword
            let newTag = "#" + newStatus
            if let range = newLine.range(of: oldTag, options: .caseInsensitive) {
                newLine = newLine.replacingCharacters(in: range, with: newTag)
            }
        } else if item.matchedKeyword == "[ ]" || item.matchedKeyword == "[x]" {
            let newCheckbox: String
            if newStatus == "done" {
                newCheckbox = "[x]"
            } else if newStatus == "todo" {
                newCheckbox = "[ ]"
            } else {
                newLine = replaceCheckboxInLine(item.originalLine, with: newStatus)
                var lines = content.components(separatedBy: "\n")
                if item.originalLineIndex < lines.count, lines[item.originalLineIndex] == item.originalLine {
                    lines[item.originalLineIndex] = newLine
                } else if let found = lines.firstIndex(of: item.originalLine) {
                    lines[found] = newLine
                } else {
                    return false
                }
                content = lines.joined(separator: "\n")
                do {
                    try content.write(to: fileURL, atomically: true, encoding: .utf8)
                    return true
                } catch {
                    return false
                }
            }
            newLine = replaceCheckboxInLine(item.originalLine, with: newCheckbox)
        } else {
            newLine = replaceKeyword(item.matchedKeyword, with: newStatus, in: item.originalLine)
        }

        var lines = content.components(separatedBy: "\n")
        if item.originalLineIndex < lines.count, lines[item.originalLineIndex] == item.originalLine {
            lines[item.originalLineIndex] = newLine
        } else if let found = lines.firstIndex(of: item.originalLine) {
            lines[found] = newLine
        } else {
            return false
        }

        content = lines.joined(separator: "\n")
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Delete task from an external file
    static func deleteFromFile(_ item: TaskItem) -> Bool {
        guard let fileURL = item.fileURL else { return false }
        guard var content = try? String(contentsOf: fileURL, encoding: .utf8) else { return false }

        var lines = content.components(separatedBy: "\n")
        if item.originalLineIndex < lines.count, lines[item.originalLineIndex] == item.originalLine {
            lines.remove(at: item.originalLineIndex)
        } else if let idx = lines.firstIndex(of: item.originalLine) {
            lines.remove(at: idx)
        } else {
            return false
        }

        content = lines.joined(separator: "\n")
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Helpers accessible to tests / other services

    /// Returns (listPrefix, content) for a markdown unordered list line, nil otherwise.
    static func listItemParts(of line: String) -> (prefix: String, content: String)? {
        var i = line.startIndex
        let end = line.endIndex
        while i < end && (line[i] == " " || line[i] == "\t") { i = line.index(after: i) }
        guard i < end, line[i] == "-" || line[i] == "*" || line[i] == "+" else { return nil }
        i = line.index(after: i)
        guard i < end, line[i] == " " || line[i] == "\t" else { return nil }
        i = line.index(after: i)
        guard i < end else { return nil }
        let prefix = String(line[line.startIndex..<i])
        let content = String(line[i...]).trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        return (prefix, content)
    }

    // MARK: - Private helpers

    /// Returns `true` when `word` appears in `text` as a whole word (case-insensitive).
    private static func containsWholeWord(_ word: String, in text: String) -> Bool {
        guard !word.isEmpty else { return false }
        var pos = text.startIndex
        while pos < text.endIndex {
            guard let range = text.range(of: word, options: .caseInsensitive,
                                          range: pos..<text.endIndex) else { break }
            let beforeOK = range.lowerBound == text.startIndex ||
                           !text[text.index(before: range.lowerBound)].isLetter &&
                           !text[text.index(before: range.lowerBound)].isNumber
            let afterOK  = range.upperBound == text.endIndex ||
                           !text[range.upperBound].isLetter &&
                           !text[range.upperBound].isNumber
            if beforeOK && afterOK { return true }
            pos = text.index(after: range.lowerBound)
        }
        return false
    }

    /// Returns (displayText, keywordLeadsContent).
    /// • If the keyword leads the content (after optional list prefix), the display
    ///   text is everything after the keyword (and optional colon/space).
    /// • Otherwise the display text is the full trimmed content.
    /// • For checkboxes "[ ]" or "[x]", strip them and the following space.
    private static func displayTextAndPosition(trimmed: String,
                                                keyword: String) -> (text: String, leads: Bool) {
        // Strip list prefix to get bare content
        let content: String
        if let (_, c) = listItemParts(of: trimmed) { content = c } else { content = trimmed }

        // Handle checkbox syntax specially
        if keyword == "[ ]" || keyword == "[x]" {
            let checkboxLen = keyword.count
            guard content.count >= checkboxLen else { return (content, true) }

            guard content.prefix(checkboxLen).lowercased() == keyword.lowercased() else { return (content, true) }

            // Strip checkbox and following space
            let afterIdx = content.index(content.startIndex, offsetBy: checkboxLen)
            var rest = String(afterIdx < content.endIndex ? content[afterIdx...] : "")
            if rest.hasPrefix(" ") { rest = String(rest.dropFirst()) }
            return (rest.isEmpty ? content : rest, true)
        }

        let kwLen = keyword.count
        guard content.count >= kwLen else { return (content, false) }

        guard content.prefix(kwLen).lowercased() == keyword.lowercased() else { return (content, false) }

        // Verify word boundary after keyword
        let afterIdx = content.index(content.startIndex, offsetBy: kwLen)
        if afterIdx < content.endIndex,
           content[afterIdx].isLetter || content[afterIdx].isNumber {
            return (content, false)
        }

        // Keyword leads — strip it plus optional colon/space
        var rest = String(afterIdx < content.endIndex ? content[afterIdx...] : "")
        if rest.hasPrefix(":") { rest = String(rest.dropFirst()) }
        rest = rest.trimmingCharacters(in: .whitespaces)
        return (rest.isEmpty ? content : rest, true)
    }

    /// Returns ": " suffix if the original content had `keyword:`, else "".
    private static func colonSuffix(in content: String, keyword: String) -> String {
        let kwLen = keyword.count
        guard content.count > kwLen else { return "" }
        let afterIdx = content.index(content.startIndex, offsetBy: kwLen)
        return (afterIdx < content.endIndex && content[afterIdx] == ":") ? ":" : ""
    }

    private static func replaceKeyword(_ old: String, with new: String, in line: String) -> String {
        guard let range = line.range(of: old, options: .caseInsensitive) else { return line }
        return line.replacingCharacters(in: range, with: new)
    }

    private static func replaceLine(at index: Int, originalContent: String,
                                     with newLine: String, in note: Note) {
        var lines = note.content.components(separatedBy: "\n")
        if index < lines.count, lines[index] == originalContent {
            lines[index] = newLine
        } else if let found = lines.firstIndex(of: originalContent) {
            lines[found] = newLine
        } else {
            return
        }
        note.content = lines.joined(separator: "\n")
        note.modifiedAt = Date()
    }
}
