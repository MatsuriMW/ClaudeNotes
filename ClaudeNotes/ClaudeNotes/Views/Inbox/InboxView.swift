import SwiftUI

// MARK: - Main View

struct InboxView: View {
    @State private var store = InboxStore.shared
    @State private var selectedDigestID: UUID?
    @State private var showTopics = false

    private var selectedDigest: InboxDigest? {
        guard let id = selectedDigestID else { return store.digests.first }
        return store.digests.first { $0.id == id }
    }

    private var canGenerate: Bool { !store.enabledTopics.isEmpty || !store.keywords.isEmpty }

    var body: some View {
        HSplitView {
            digestList
                .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)
            digestDetail
        }
        .background(Color(nsColor: .textBackgroundColor))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showTopics = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .help("订阅设置")
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    guard canGenerate else { return }
                    store.startGenerate()
                } label: {
                    if store.isGenerating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(!canGenerate || store.isGenerating)
                .help(canGenerate ? "生成简报" : "请先添加关键词或启用主题")

                if store.generationCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .help("简报已生成完成")
                }
            }
        }
        .sheet(isPresented: $showTopics) {
            InboxTopicsView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuInboxTopics)) { _ in
            showTopics = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuGenerateInbox)) { _ in
            guard canGenerate else { return }
            store.startGenerate()
        }
        .onChange(of: store.digests.first?.id) { _, newID in
            // Auto-select the newest digest when generation completes
            if store.generationCompleted, let id = newID {
                selectedDigestID = id
            }
        }
    }

    // MARK: - Left: Digest List

    private var digestList: some View {
        List(selection: $selectedDigestID) {
            if store.digests.isEmpty && !store.isGenerating {
                Text("暂无简报")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 20)
            } else {
                if store.isGenerating {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("正在生成…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                ForEach(store.digests) { digest in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(digest.shortDate)
                            .font(.callout.weight(.medium))
                        Text(digest.topicsLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 2)
                    .tag(digest.id)
                    .contextMenu {
                        Button(role: .destructive) {
                            deleteDigest(digest)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Right: Digest Detail

    @ViewBuilder
    private var digestDetail: some View {
        if let digest = selectedDigest {
            VStack(spacing: 0) {
                if let err = store.generationError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(err).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("关闭") { store.clearGenerationError() }.font(.caption)
                    }
                    .padding(8)
                    .background(.orange.opacity(0.08))
                }
                MarkdownPreviewView(content: digest.content)
            }
        } else if store.isGenerating {
            VStack(spacing: 16) {
                Spacer()
                ProgressView().scaleEffect(1.4)
                Text("正在生成今日简报…").font(.headline)
                Text(store.generationProgress).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "newspaper").font(.system(size: 52)).foregroundStyle(.tertiary)
            Text("今日简报").font(.title2.weight(.semibold))
            if let err = store.generationError {
                Text(err).font(.caption).foregroundStyle(.red)
                    .multilineTextAlignment(.center).padding(.horizontal)
            } else {
                Text("在「订阅设置」中添加关键词或开启主题，\n点击「生成简报」即可获取带来源链接的今日资讯。")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if !canGenerate {
                Text("请先添加关键词或启用至少一个主题")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Logic

    private func deleteDigest(_ digest: InboxDigest) {
        if selectedDigestID == digest.id {
            if let idx = store.digests.firstIndex(where: { $0.id == digest.id }) {
                let next = store.digests.dropFirst(idx + 1).first ?? store.digests.prefix(idx).last
                selectedDigestID = next?.id
            }
        }
        store.deleteDigest(digest)
    }
}

// MARK: - Topics & Keywords Settings Sheet

struct InboxTopicsView: View {
    @State private var store = InboxStore.shared
    @State private var newKeyword = ""
    @State private var isAddingCustomTopic = false
    @State private var newTopicName = ""
    @State private var newTopicPrompt = ""
    @Environment(\.dismiss) private var dismiss

    private var builtIns: [InboxTopic] { store.topics.filter(\.isBuiltIn) }
    private var custom: [InboxTopic] { store.topics.filter { !$0.isBuiltIn } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("订阅设置").font(.headline)
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    keywordsSection
                    topicSection(title: "内置主题", topics: builtIns, canDelete: false)
                    if !custom.isEmpty {
                        topicSection(title: "自定义主题", topics: custom, canDelete: true)
                    }
                    addCustomTopicSection
                    if let persona = PersonaStore.shared.persona, !persona.interests.isEmpty {
                        personaTip(persona: persona)
                    }
                }
                .padding()
            }
        }
        .frame(width: 500, height: 620)
    }

    // MARK: - Keywords Section

    private var keywordsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("关键词追踪", systemImage: "tag").font(.headline)
            Text("输入任意关键词（如：Tesla、量子计算、NBA季后赛），AI 将为每个关键词搜索最新资讯并附上来源链接。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Keyword chips
            if !store.keywords.isEmpty {
                InboxFlowLayout(spacing: 8) {
                    ForEach(store.keywords, id: \.self) { kw in
                        KeywordChip(text: kw) {
                            store.removeKeyword(kw)
                        }
                    }
                }
            }

            // Add keyword input
            HStack(spacing: 8) {
                TextField("输入关键词后按 Return 添加…", text: $newKeyword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitKeyword() }
                Button("添加") { commitKeyword() }
                    .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .background(.blue.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.blue.opacity(0.12), lineWidth: 1))
    }

    private func commitKeyword() {
        let trimmed = newKeyword.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.addKeyword(trimmed)
        newKeyword = ""
    }

    // MARK: - Topic Sections

    @ViewBuilder
    private func topicSection(title: String, topics: [InboxTopic], canDelete: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            VStack(spacing: 6) {
                ForEach(topics) { topic in
                    topicRow(topic, canDelete: canDelete)
                }
            }
        }
    }

    private func topicRow(_ topic: InboxTopic, canDelete: Bool) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { topic.enabled },
                set: { store.setEnabled(topic, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

            Image(systemName: topic.icon).foregroundStyle(.secondary).frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(topic.name).font(.callout.weight(.medium))
                Text(topic.searchPrompt).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }

            Spacer()

            if canDelete {
                Button {
                    store.deleteTopic(topic)
                } label: {
                    Image(systemName: "trash").foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(topic.enabled ? Color.accentColor.opacity(0.06) : Color.secondary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(topic.enabled ? Color.accentColor.opacity(0.2) : Color.clear, lineWidth: 1)
        )
    }

    // MARK: - Add Custom Topic

    private var addCustomTopicSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("添加自定义主题", systemImage: "plus.circle").font(.headline)

            if isAddingCustomTopic {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("主题名称（如：炒股、深度学习…）", text: $newTopicName)
                        .textFieldStyle(.roundedBorder)
                    TextField("搜索描述（英文效果更好，如：stock trading strategies and market news）", text: $newTopicPrompt)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("添加") {
                            let name = newTopicName.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty else { return }
                            let prompt = newTopicPrompt.isEmpty ? name : newTopicPrompt
                            store.addCustomTopic(name: name, prompt: prompt)
                            newTopicName = ""; newTopicPrompt = ""; isAddingCustomTopic = false
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(newTopicName.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("取消") { newTopicName = ""; newTopicPrompt = ""; isAddingCustomTopic = false }
                    }
                }
                .padding(12)
                .background(.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Button {
                    isAddingCustomTopic = true
                } label: {
                    Label("新增主题", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Persona Tip

    private func personaTip(persona: UserPersona) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("来自您的画像", systemImage: "person.crop.circle").font(.headline)
            Text("根据您的个人画像，可一键将以下兴趣添加为关键词：")
                .font(.caption).foregroundStyle(.secondary)
            let missing = persona.interests.filter { interest in
                !store.keywords.contains { $0.localizedCaseInsensitiveContains(interest.name) }
            }.prefix(6)
            if missing.isEmpty {
                Text("关键词已覆盖所有画像兴趣").font(.caption).foregroundStyle(.tertiary)
            } else {
                InboxFlowLayout(spacing: 8) {
                    ForEach(Array(missing)) { interest in
                        Button(interest.name) {
                            store.addKeyword(interest.name)
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                    }
                }
            }
        }
        .padding(12)
        .background(.purple.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.purple.opacity(0.15), lineWidth: 1))
    }
}

// MARK: - Keyword Chip

private struct KeywordChip: View {
    let text: String
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.callout)
            Button {
                onDelete()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.10))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Flow Layout

private struct InboxFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let height = rows.map { $0.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0 }
            .reduce(0) { $0 + $1 + spacing }
        return CGSize(width: proposal.width ?? 0, height: max(0, height - spacing))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            let rowH = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            for view in row {
                let size = view.sizeThatFits(.unspecified)
                view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowH + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubview]] {
        var rows: [[LayoutSubview]] = [[]]
        var x: CGFloat = 0
        let maxW = proposal.width ?? .infinity
        for view in subviews {
            let w = view.sizeThatFits(.unspecified).width
            if x + w > maxW, !rows[rows.count - 1].isEmpty {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(view)
            x += w + spacing
        }
        return rows.filter { !$0.isEmpty }
    }
}
