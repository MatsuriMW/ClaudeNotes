import SwiftUI
import SwiftData

struct VaultSearchView: View {
    @Query(sort: \Note.modifiedAt, order: .reverse) private var allNotes: [Note]

    var onSelectNote: (Note, String) -> Void
    var onSelectFile: (URL, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var focusedIndex = 0
    @FocusState private var searchFocused: Bool

    /// File results filled by background search task
    @State private var fileResults: [(FileNote, snippet: String?)] = []
    @State private var searchTask: Task<Void, Never>? = nil

    // MARK: - Unified result type

    private enum SearchResult: Identifiable {
        case note(Note, snippet: String?)
        case file(FileNote, snippet: String?, source: String)

        var id: String {
            switch self {
            case .note(let n, _):        return "n-\(n.id)"
            case .file(let f, _, _):     return "f-\(f.url.path)"
            }
        }
        var title: String {
            switch self {
            case .note(let n, _):        return n.title.isEmpty ? "无标题" : n.title
            case .file(let f, _, _):     return f.displayTitle
            }
        }
        var snippet: String? {
            switch self {
            case .note(_, let s):        return s
            case .file(_, let s, _):     return s
            }
        }
        var sourceLabel: String? {
            switch self {
            case .note:                  return nil
            case .file(_, _, let src):   return src
            }
        }
        var isFile: Bool {
            if case .file = self { return true }
            return false
        }
    }

    private var noteResults: [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return allNotes
            .filter { !$0.isDeleted && ($0.title.lowercased().contains(q) || $0.content.lowercased().contains(q)) }
            .map { .note($0, snippet: matchSnippet(in: $0.content, query: q)) }
    }

    private var allResults: [SearchResult] {
        noteResults + fileResults.map { .file($0.0, snippet: $0.snippet, source: $0.0.url.deletingLastPathComponent().lastPathComponent) }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            content
        }
        .frame(width: 580)
        .frame(minHeight: 80, maxHeight: 480)
        .background(.regularMaterial)
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, q in
            focusedIndex = 0
            startFileSearch(query: q)
        }
        .onKeyPress(.downArrow)  { move(+1); return .handled }
        .onKeyPress(.upArrow)    { move(-1); return .handled }
        .onKeyPress(.return)     { selectFocused(); return .handled }
        .onKeyPress(.escape)     { dismiss(); return .handled }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 15))
            TextField("搜索所有笔记和文件…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Content area

    @ViewBuilder
    private var content: some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            hint("输入关键词搜索所有笔记和文件", icon: "magnifyingglass")
        } else if allResults.isEmpty {
            hint("没有找到匹配的内容", icon: "doc.questionmark")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(allResults.enumerated()), id: \.element.id) { idx, result in
                            resultRow(result: result, index: idx)
                                .id(idx)
                        }
                    }
                }
                .onChange(of: focusedIndex) { _, idx in
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(idx, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Result row

    private func resultRow(result: SearchResult, index: Int) -> some View {
        Button {
            select(result)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: result.isFile ? "doc.text" : "note.text")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(result.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let src = result.sourceLabel {
                            Text(src)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    if let snippet = result.snippet {
                        Text(snippet)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(index == focusedIndex
                        ? Color.accentColor.opacity(0.12)
                        : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { if $0 { focusedIndex = index } }
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 16)
        }
    }

    // MARK: - File search (background)

    private func startFileSearch(query: String) {
        searchTask?.cancel()
        fileResults = []
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return }

        // Collect all unique file URLs from libraries and opened single files
        var seen = Set<URL>()
        var candidates: [FileNote] = []
        for file in LibraryManager.shared.libraries.flatMap(\.files) + LibraryManager.shared.openedFiles {
            if seen.insert(file.url).inserted { candidates.append(file) }
        }

        searchTask = Task {
            var found: [(FileNote, snippet: String?)] = []
            for file in candidates {
                guard !Task.isCancelled else { return }
                let nameMatch = file.displayTitle.lowercased().contains(q)
                let content = (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
                let contentMatch = content.lowercased().contains(q)
                if nameMatch || contentMatch {
                    let snip = contentMatch ? matchSnippet(in: content, query: q) : nil
                    found.append((file, snippet: snip))
                }
            }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                fileResults = found
            }
        }
    }

    // MARK: - Helpers

    private func hint(_ text: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding(.vertical, 24)
    }

    private func matchSnippet(in content: String, query: String) -> String? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty, let range = content.lowercased().range(of: q) else { return nil }
        let lo = content.index(range.lowerBound, offsetBy: -40, limitedBy: content.startIndex) ?? content.startIndex
        let hi = content.index(range.upperBound, offsetBy: 80, limitedBy: content.endIndex) ?? content.endIndex
        var snippet = String(content[lo..<hi]).replacingOccurrences(of: "\n", with: " ")
        if lo > content.startIndex { snippet = "…" + snippet }
        if hi < content.endIndex   { snippet += "…" }
        return snippet
    }

    private func move(_ delta: Int) {
        let count = allResults.count
        guard count > 0 else { return }
        focusedIndex = min(max(focusedIndex + delta, 0), count - 1)
    }

    private func select(_ result: SearchResult) {
        let q = query.trimmingCharacters(in: .whitespaces)
        switch result {
        case .note(let note, _):
            onSelectNote(note, q)
        case .file(let file, _, _):
            onSelectFile(file.url, file.displayTitle, q)
        }
        dismiss()
    }

    private func selectFocused() {
        guard focusedIndex < allResults.count else { return }
        select(allResults[focusedIndex])
    }
}
