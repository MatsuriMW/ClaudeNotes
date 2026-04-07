import SwiftUI

struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text(note.title.isEmpty ? "无标题" : note.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            }

            Text(note.contentPreview.isEmpty ? "空笔记" : note.contentPreview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Text(note.modifiedAt.shortDisplay)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
