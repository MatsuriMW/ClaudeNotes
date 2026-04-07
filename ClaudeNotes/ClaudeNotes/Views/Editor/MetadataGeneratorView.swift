import SwiftUI

struct MetadataGeneratorView: View {
    let noteContent: String
    /// Called with the updated full content string (metadata prepended) after the user confirms.
    let onInsert: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var format: MetadataFormat = {
        let saved = UserDefaults.standard.string(forKey: "metadataFormat") ?? ""
        return MetadataFormat(rawValue: saved) ?? .obsidian
    }()
    @State private var tags: [String] = []
    @State private var author      = ""
    @State private var source      = ""
    @State private var newTagInput = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?

    private var metadata: NoteMetadata {
        NoteMetadata(tags: tags, author: author, source: source)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──────────────────────────────────────────────────────
            HStack {
                Label("AI 元数据生成", systemImage: "tag.square")
                    .font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // ── Format ───────────────────────────────────────────────
                    sectionHeader("目标格式")

                    Picker("格式", selection: $format) {
                        ForEach(MetadataFormat.allCases, id: \.self) { f in
                            Text(f.displayName).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: format) { _, new in
                        UserDefaults.standard.set(new.rawValue, forKey: "metadataFormat")
                    }

                    Text(formatHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    // ── Manual fields ────────────────────────────────────────
                    sectionHeader("基本信息")

                    LabeledContent("作者") {
                        TextField("文章作者（可选）", text: $author)
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledContent("来源") {
                        TextField("原文 URL 或引用来源（可选）", text: $source)
                            .textFieldStyle(.roundedBorder)
                    }

                    Divider()

                    // ── Tags ─────────────────────────────────────────────────
                    HStack(alignment: .firstTextBaseline) {
                        sectionHeader("关键词 / 学科标签")
                        Spacer()
                        Button {
                            generateTags()
                        } label: {
                            HStack(spacing: 5) {
                                if isGenerating {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "sparkles")
                                        .font(.caption)
                                }
                                Text(isGenerating ? "AI 分析中…" : "AI 生成")
                                    .font(.caption)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isGenerating || noteContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if let err = errorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(err).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("关闭") { errorMessage = nil }.font(.caption)
                        }
                        .padding(8)
                        .background(.orange.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    // Tag chips
                    if tags.isEmpty && !isGenerating {
                        Text("点击「AI 生成」自动识别学科、主题和作者名，或手动输入后按 Return。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        TagChipLayout(spacing: 7) {
                            ForEach(tags, id: \.self) { tag in
                                TagChip(text: tag) { tags.removeAll { $0 == tag } }
                            }
                        }
                    }

                    // Manual tag input
                    HStack(spacing: 6) {
                        TextField("输入标签后按 Return 添加（如：cognitive-science）", text: $newTagInput)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { commitNewTag() }
                        Button("添加") { commitNewTag() }
                            .disabled(newTagInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    Divider()

                    // ── Preview ───────────────────────────────────────────────
                    sectionHeader("预览")

                    let preview = format.block(metadata: metadata)
                    ScrollView {
                        Text(preview.isEmpty ? "(无内容)" : preview)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(preview.isEmpty ? .tertiary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(height: 110)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.secondary.opacity(0.2), lineWidth: 1))

                    Text("注：文件顶部已有同格式的元数据块将被替换。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    // ── Insert ────────────────────────────────────────────────
                    Button {
                        let updated = format.insertInto(noteContent, metadata: metadata)
                        onInsert(updated)
                        dismiss()
                    } label: {
                        Label("插入到笔记顶部", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isGenerating)
                    .controlSize(.large)
                }
                .padding()
            }
        }
        .frame(width: 480, height: 620)
        .onAppear { prefillFromContent() }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
    }

    private var formatHint: String {
        switch format {
        case .obsidian: return "YAML frontmatter（---…---），Obsidian、Jekyll 等工具均可读取。"
        case .logseq:   return "Logseq 页面属性（key:: value），写在文件最顶部。"
        }
    }

    /// Auto-detect author/source from the existing metadata block at top, if present.
    private func prefillFromContent() {
        let stripped = format.stripExistingMetadata(from: noteContent)
        let existing = String(noteContent.prefix(noteContent.count - stripped.count))
        guard !existing.isEmpty else { return }

        // Obsidian YAML
        for line in existing.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("author:") {
                author = t.dropFirst("author:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            } else if t.hasPrefix("source:") {
                source = t.dropFirst("source:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            } else if t.hasPrefix("- "), !t.dropFirst(2).isEmpty, author.isEmpty, source.isEmpty {
                // Likely a tag line — ignore here
            }
        }
        // Logseq properties
        for line in existing.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("author::") {
                author = t.dropFirst("author::".count).trimmingCharacters(in: .whitespaces)
            } else if t.hasPrefix("source::") {
                source = t.dropFirst("source::".count).trimmingCharacters(in: .whitespaces)
            } else if t.hasPrefix("tags::") {
                let rawTags = t.dropFirst("tags::".count).trimmingCharacters(in: .whitespaces)
                tags = rawTags.components(separatedBy: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty }
            }
        }
    }

    private func generateTags() {
        guard !isGenerating else { return }
        isGenerating = true
        errorMessage = nil
        Task {
            do {
                let result = try await MetadataService.shared.generateTags(from: noteContent)
                await MainActor.run {
                    let existing = Set(tags)
                    tags += result.filter { !existing.contains($0) }
                    isGenerating = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isGenerating = false
                }
            }
        }
    }

    private func commitNewTag() {
        let t = newTagInput
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        guard !t.isEmpty, !tags.contains(t) else { newTagInput = ""; return }
        tags.append(t)
        newTagInput = ""
    }
}

// MARK: - Tag Chip

private struct TagChip: View {
    let text: String
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "tag.fill")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(text).font(.callout)
            Button { onDelete() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.10))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Flow Layout

private struct TagChipLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let h = rows.map { row in row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0 }
            .reduce(0) { $0 + $1 + spacing }
        return CGSize(width: proposal.width ?? 0, height: max(0, h - spacing))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            let rh = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            for view in row {
                let sz = view.sizeThatFits(.unspecified)
                view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
                x += sz.width + spacing
            }
            y += rh + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubview]] {
        var rows: [[LayoutSubview]] = [[]]
        var x: CGFloat = 0
        let maxW = proposal.width ?? .infinity
        for view in subviews {
            let w = view.sizeThatFits(.unspecified).width
            if x + w > maxW, !rows[rows.count - 1].isEmpty { rows.append([]); x = 0 }
            rows[rows.count - 1].append(view)
            x += w + spacing
        }
        return rows.filter { !$0.isEmpty }
    }
}
