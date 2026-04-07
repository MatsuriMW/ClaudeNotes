import SwiftUI

struct ShortcutsHelpView: View {
    @Environment(\.dismiss) private var dismiss
    let settings: ShortcutSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("快捷键参考")
                    .font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
                    .font(.caption)
            }

            Text("可在 设置 → 快捷键 中自定义")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            ForEach(ShortcutCategory.allCases, id: \.self) { category in
                let actions = ShortcutAction.allCases.filter { $0.category == category }
                VStack(alignment: .leading, spacing: 3) {
                    Text(category.rawValue)
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)

                    ForEach(actions) { action in
                        HStack(spacing: 12) {
                            Text(settings.binding(for: action).displayString)
                                .font(.system(.caption, design: .monospaced))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .frame(width: 60, alignment: .trailing)
                            Text(action.displayName)
                                .font(.caption)
                            Spacer()
                        }
                    }
                }

                if category != ShortcutCategory.allCases.last {
                    Divider()
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                Text("文件")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Text("⌘O")
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .frame(width: 60, alignment: .trailing)
                    Text("打开文件")
                        .font(.caption)
                    Spacer()
                }
                HStack(spacing: 12) {
                    Text("⌘S")
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .frame(width: 60, alignment: .trailing)
                    Text("保存文件")
                        .font(.caption)
                    Spacer()
                }
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}
