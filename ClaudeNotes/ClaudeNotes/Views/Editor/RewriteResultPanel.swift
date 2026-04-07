import SwiftUI

/// The right-side panel shown when a platform rewrite is in progress or complete.
/// Displayed inside the HSplitView alongside the primary editor.
struct RewriteResultPanel: View {
    @State private var session = RewriteSession.shared
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "rectangle.righthalf.inset.filled")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Image(systemName: session.platformIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("改写为 · \(session.platformName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if session.isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                }

                Spacer()

                // Copy button
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.content, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        await MainActor.run { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .help(copied ? "已复制" : "复制全文")
                .disabled(session.content.isEmpty)

                // Stop streaming
                if session.isStreaming {
                    Button {
                        session.dismiss()
                    } label: {
                        Image(systemName: "stop.circle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("停止生成")
                }

                // Close panel
                Button {
                    session.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .help("关闭改写面板")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.bar)

            Divider()

            // Content
            if session.content.isEmpty && session.isStreaming {
                Spacer()
                ProgressView("正在改写…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else if session.content.isEmpty {
                Spacer()
                Text("未生成内容")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                TextEditor(text: .constant(session.content))
                    .font(.body)
                    .padding(12)
                    .scrollContentBackground(.hidden)
                    .background(.background)
            }
        }
    }
}
