import SwiftUI
import SwiftData

struct VersionHistoryView: View {
    let note: Note
    let onRestore: (NoteVersion) -> Void
    let onDismiss: () -> Void

    @Query private var allVersions: [NoteVersion]
    @State private var selected: NoteVersion?

    private var versions: [NoteVersion] {
        allVersions
            .filter { $0.noteID == note.id }
            .sorted { $0.savedAt > $1.savedAt }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: version list
            VStack(spacing: 0) {
                HStack {
                    Text("历史版本")
                        .font(.headline)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                if versions.isEmpty {
                    Spacer()
                    Text("暂无历史版本")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Spacer()
                } else {
                    List(versions, id: \.id, selection: $selected) { version in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(version.title.isEmpty ? "无标题" : version.title)
                                .font(.callout)
                                .lineLimit(1)
                            Text(version.savedAt, style: .relative) + Text(" 前")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                                + Text("  ") + Text(version.savedAt, format: .dateTime.month().day().hour().minute())
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .padding(.vertical, 2)
                        .tag(version)
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(width: 220)
            .background(.background)

            Divider()

            // Right: content preview + restore
            VStack(spacing: 0) {
                if let version = selected {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(version.savedAt, format: .dateTime.year().month().day().hour().minute().second())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("恢复此版本") {
                            onRestore(version)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    Divider()

                    ScrollView {
                        Text(version.content.isEmpty ? "(空内容)" : version.content)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(version.content.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                } else {
                    Spacer()
                    Text("选择左侧版本以预览")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Spacer()
                }
            }
            .frame(minWidth: 360)
            .background(.background)
        }
        .frame(width: 620, height: 460)
        .onAppear {
            selected = versions.first
        }
    }
}
