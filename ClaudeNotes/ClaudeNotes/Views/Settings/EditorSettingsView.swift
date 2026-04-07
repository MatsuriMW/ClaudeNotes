import SwiftUI

struct EditorSettingsView: View {
    @State private var settings = EditorSettings.shared
    @State private var showFontPicker = false

    var body: some View {
        Form {
            // MARK: - Indentation
            Section("缩进") {
                Picker("缩进快捷键", selection: $settings.indentShortcut) {
                    ForEach(EditorSettings.IndentShortcut.allCases, id: \.rawValue) { opt in
                        Text(opt.displayName).tag(opt)
                    }
                }

                Picker("缩进单位", selection: $settings.indentUnit) {
                    ForEach(EditorSettings.IndentUnit.allCases, id: \.rawValue) { opt in
                        Text(opt.displayName).tag(opt)
                    }
                }
            }

            // MARK: - Font
            Section("字体") {
                HStack {
                    Text("编辑器字体")
                    Spacer()
                    Button(settings.fontFamilyName.isEmpty ? "系统等宽字体（默认）" : settings.fontFamilyName) {
                        showFontPicker = true
                    }
                    .buttonStyle(.bordered)
                    if !settings.fontFamilyName.isEmpty {
                        Button {
                            settings.fontFamilyName = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("恢复默认字体")
                    }
                }
                .sheet(isPresented: $showFontPicker) {
                    FontPickerSheet(fontFamilyName: $settings.fontFamilyName)
                }

                HStack {
                    Text("字体大小")
                    Spacer()
                    Stepper(value: $settings.fontSize, in: 9...32, step: 1) {
                        Text("\(Int(settings.fontSize)) pt")
                            .monospacedDigit()
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                }

                HStack {
                    Text("行高倍率")
                    Spacer()
                    Slider(value: $settings.lineHeightMultiple, in: 1.0...2.5, step: 0.1) {
                        EmptyView()
                    }
                    .frame(width: 140)
                    Text(String(format: "%.1f×", settings.lineHeightMultiple))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36, alignment: .trailing)
                }
            }

            // MARK: - Behavior
            Section("行为") {
                Toggle("自动配对括号", isOn: $settings.autoPairBrackets)
                Toggle("智能引号", isOn: $settings.smartQuotes)
                Toggle("拼写检查", isOn: $settings.spellingCheck)
            }

            // MARK: - Highlighting
            Section("语法高亮") {
                ColorPicker("[[双括号链接]] 颜色", selection: Binding(
                    get: { Color(settings.wikiLinkColor) },
                    set: { settings.wikiLinkColor = NSColor($0) }
                ))
            }

            // MARK: - Version Control
            Section("版本历史") {
                Picker("自动记录版本", selection: $settings.versionIntervalMinutes) {
                    Text("仅切换笔记时").tag(0)
                    Text("每 5 分钟").tag(5)
                    Text("每 15 分钟").tag(15)
                    Text("每 30 分钟").tag(30)
                    Text("每 60 分钟").tag(60)
                }

                HStack {
                    Text("每篇笔记最多保留")
                    Spacer()
                    Stepper(value: $settings.maxVersionsPerNote, in: 5...200, step: 5) {
                        Text("\(settings.maxVersionsPerNote) 个版本")
                            .monospacedDigit()
                            .frame(minWidth: 70, alignment: .trailing)
                    }
                }

                Picker("自动删除旧版本", selection: $settings.autoDeleteVersionsDays) {
                    Text("永不").tag(0)
                    Text("7 天前").tag(7)
                    Text("30 天前").tag(30)
                    Text("90 天前").tag(90)
                    Text("180 天前").tag(180)
                    Text("1 年前").tag(365)
                }
            }

            // MARK: - Preview
            Section("预览") {
                previewBox
            }
        }
        .formStyle(.grouped)
    }

    private var previewBox: some View {
        let baseFont = Font(settings.makeNSFont() as CTFont)
        let spacing = (settings.lineHeightMultiple - 1.0) * settings.fontSize
        return VStack(alignment: .leading, spacing: 0) {
            Text("# 标题示例")
            Text("这是一段普通文字，**加粗**，*斜体*。")
            Text("`let x = 42`")
            Text("- 列表项一")
            Text("  - 嵌套列表")
            HStack(spacing: 0) {
                Text("相关笔记：")
                Text("[[双括号链接]]")
                    .foregroundStyle(Color(settings.wikiLinkColor))
            }
        }
        .font(baseFont)
        .lineSpacing(spacing)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Font Picker Sheet

private struct FontPickerSheet: View {
    @Binding var fontFamilyName: String
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var families: [String] {
        let all = NSFontManager.shared.availableFontFamilies.sorted()
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    private func previewFont(for family: String) -> Font {
        if let nf = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13) {
            return Font(nf as CTFont)
        }
        return .body
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("选择字体").font(.headline)
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding()

            TextField("搜索字体…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 8)

            Divider()

            List {
                // System default
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("系统等宽字体（默认）")
                            .font(.system(.body, design: .monospaced))
                        Text("AaBbCc 0123")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if fontFamilyName.isEmpty {
                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { fontFamilyName = "" }
                .listRowBackground(fontFamilyName.isEmpty ? Color.accentColor.opacity(0.08) : Color.clear)

                ForEach(families, id: \.self) { family in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(family)
                                .font(previewFont(for: family))
                            Text("AaBbCc 0123")
                                .font(previewFont(for: family).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if fontFamilyName == family {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { fontFamilyName = family }
                    .listRowBackground(fontFamilyName == family ? Color.accentColor.opacity(0.08) : Color.clear)
                }
            }
            .listStyle(.plain)
        }
        .frame(width: 420, height: 520)
    }
}
