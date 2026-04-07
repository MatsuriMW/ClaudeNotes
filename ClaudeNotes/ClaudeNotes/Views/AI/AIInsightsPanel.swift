import SwiftUI

struct AIInsightsPanel: View {
    let note: Note
    /// Access to the active NSTextView for cursor-position insertion.
    let textViewHolder: TextViewHolder
    /// The note's raw content at the time the panel opened.
    let noteContent: String
    /// Callback: insert `formatted` at the current cursor position.
    /// The `offset` param is a byte offset from the cursor, default = 0 (insert at cursor).
    let onInsert: (_ formatted: String, _ cursorOffset: Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = AIInsightsViewModel()
    @State private var insertToast: String?
    @State private var toastTask: Task<Void, Never>?

    /// Insert history to avoid repeating the same card in quick succession.
    @State private var lastInsertedKey: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("AI 分析", systemImage: "brain")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await viewModel.loadAnalysis(for: note) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
                .help("重新分析")

                Button("关闭") { dismiss() }
                    .font(.subheadline)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if viewModel.isLoading {
                        AILoadingView()
                    } else if let error = viewModel.errorMessage {
                        ErrorCard(message: error)
                    } else if viewModel.summary != nil {
                        AnalysisContent(
                            viewModel: viewModel,
                            noteTitle: note.title,
                            onInsert: handleInsert
                        )
                    } else {
                        emptyState
                    }
                }
                .padding(16)
            }

            // Toast bar
            if let toast = insertToast {
                toastBar(message: toast)
            }
        }
        .frame(width: 380, height: 480)
        .task {
            await viewModel.loadAnalysis(for: note)
        }
        .onChange(of: note.id) { _, _ in
            viewModel.clear()
        }
    }

    // MARK: - Insert handler

    private func handleInsert(_ key: String, _ formatted: String) {
        lastInsertedKey = key
        onInsert(formatted, nil)
        showToast("已插入到笔记")
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        insertToast = message
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled {
                await MainActor.run { insertToast = nil }
            }
        }
    }

    @ViewBuilder
    private func toastBar(message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(.green.opacity(0.08))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: insertToast)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("点击右上角按钮开始分析此笔记")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("开始分析") {
                Task { await viewModel.loadAnalysis(for: note) }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }
}

// MARK: - Analysis Content

private struct AnalysisContent: View {
    let viewModel: AIInsightsViewModel
    let noteTitle: String
    let onInsert: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let summary = viewModel.summary {
                AnalysisCard(
                    title: "摘要",
                    icon: "doc.text",
                    insertLabel: "插入摘要",
                    insertDisabled: false,
                    onInsert: {
                        let formatted = """

                        ---

                        ## AI 摘要

                        \(summary)

                        """
                        onInsert("summary", formatted)
                    }
                ) {
                    Text(summary)
                        .font(.subheadline)
                }
            }

            if !viewModel.topics.isEmpty {
                AnalysisCard(
                    title: "相关主题",
                    icon: "tag",
                    insertLabel: "插入主题",
                    insertDisabled: false,
                    onInsert: {
                        let tags = viewModel.topics.map { "- \($0)" }.joined(separator: "\n")
                        let formatted = """

                        ---

                        ## 相关主题

                        \(tags)

                        """
                        onInsert("topics", formatted)
                    }
                ) {
                    FlowLayout(spacing: 6) {
                        ForEach(viewModel.topics, id: \.self) { topic in
                            Text(topic)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(.blue.opacity(0.1))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            if let insights = viewModel.insights {
                AnalysisCard(
                    title: "洞察",
                    icon: "lightbulb",
                    insertLabel: "插入洞察",
                    insertDisabled: false,
                    onInsert: {
                        let formatted = """

                        ---

                        ## AI 洞察

                        \(insights)

                        """
                        onInsert("insights", formatted)
                    }
                ) {
                    Text(insights)
                        .font(.subheadline)
                }
            }

            // Insert all button
            if viewModel.summary != nil || !viewModel.topics.isEmpty || viewModel.insights != nil {
                Button {
                    var all: [String] = []
                    if let s = viewModel.summary {
                        all.append("## AI 摘要\n\n\(s)")
                    }
                    if !viewModel.topics.isEmpty {
                        let tags = viewModel.topics.map { "- \($0)" }.joined(separator: "\n")
                        all.append("## 相关主题\n\n\(tags)")
                    }
                    if let i = viewModel.insights {
                        all.append("## AI 洞察\n\n\(i)")
                    }
                    let formatted = """

                    ---

                    \(all.joined(separator: "\n\n"))

                    """
                    onInsert("all", formatted)
                } label: {
                    Label("插入全部分析", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
    }
}

// MARK: - Analysis Card with Insert Button

private struct AnalysisCard<Content: View>: View {
    let title: String
    let icon: String
    let insertLabel: String
    let insertDisabled: Bool
    let onInsert: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Spacer()
                Button(insertLabel) { onInsert() }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(insertDisabled)
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Supporting Views

private struct ErrorCard: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.yellow.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(in: proposal.width ?? 0, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                                  proposal: .unspecified)
        }
    }

    private func layout(in width: CGFloat, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxWidth = max(maxWidth, x)
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}
