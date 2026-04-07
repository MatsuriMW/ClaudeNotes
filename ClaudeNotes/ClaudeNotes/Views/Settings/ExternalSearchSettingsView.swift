import SwiftUI
import AppKit

struct ExternalSearchSettingsView: View {
    @State private var settings = ExternalSearchSettings.shared
    @State private var editingEngine: ExternalSearchEngine? = nil
    @State private var isAddingNew = false
    @State private var showResetAlert = false

    var body: some View {
        Form {
            // Default AI chatbot
            Section("AI 问答默认服务") {
                HStack {
                    Text("使用 /askai 时打开：")
                        .font(.subheadline)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { settings.defaultAIChatbotID },
                        set: { settings.defaultAIChatbotID = $0; settings.save() }
                    )) {
                        Text("（未设置）").tag(UUID?.none)
                        ForEach(settings.engines) { engine in
                            Text(engine.name).tag(Optional(engine.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }

                Text("选中文字后按对应快捷键，或在编辑器中输入 /slash命令 后回车，均可跳转至浏览器搜索。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Engine list
            Section {
                ForEach(settings.engines) { engine in
                    EngineRow(engine: engine) {
                        editingEngine = engine
                    } onDelete: {
                        settings.engines.removeAll { $0.id == engine.id }
                        settings.save()
                    }
                }
                .onMove { from, to in
                    settings.engines.move(fromOffsets: from, toOffset: to)
                    settings.save()
                }
            } header: {
                HStack {
                    Text("搜索引擎")
                    Spacer()
                    Button {
                        isAddingNew = true
                    } label: {
                        Label("新增", systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }

            // Reset
            Section {
                HStack {
                    Spacer()
                    Button("恢复默认搜索引擎列表", role: .destructive) {
                        showResetAlert = true
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .alert("恢复默认？", isPresented: $showResetAlert) {
            Button("恢复", role: .destructive) {
                settings.resetToDefaults()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有自定义搜索引擎将被替换为内置默认列表。")
        }
        .sheet(item: $editingEngine) { engine in
            EngineEditSheet(engine: engine) { updated in
                if let idx = settings.engines.firstIndex(where: { $0.id == updated.id }) {
                    settings.engines[idx] = updated
                    settings.save()
                }
                editingEngine = nil
            } onCancel: {
                editingEngine = nil
            }
        }
        .sheet(isPresented: $isAddingNew) {
            EngineEditSheet(engine: ExternalSearchEngine(
                name: "", urlTemplate: "https://example.com/search?q={query}",
                slashCommand: "", iconName: "magnifyingglass"
            )) { newEngine in
                settings.engines.append(newEngine)
                settings.save()
                isAddingNew = false
            } onCancel: {
                isAddingNew = false
            }
        }
    }
}

// MARK: - Engine Row

private struct EngineRow: View {
    let engine: ExternalSearchEngine
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: engine.iconName)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(engine.name)
                    .font(.subheadline)
                Text("/\(engine.slashCommand)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(engine.shortcutDisplayString)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(minWidth: 32, alignment: .trailing)

            Button("编辑") { onEdit() }
                .buttonStyle(.borderless)
                .controlSize(.small)

            Button(role: .destructive) { onDelete() } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }
}

// MARK: - Engine Edit Sheet

private struct EngineEditSheet: View {
    @State private var draft: ExternalSearchEngine
    let onSave: (ExternalSearchEngine) -> Void
    let onCancel: () -> Void

    @State private var recordingShortcut = false

    init(engine: ExternalSearchEngine,
         onSave: @escaping (ExternalSearchEngine) -> Void,
         onCancel: @escaping () -> Void) {
        _draft = State(initialValue: engine)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !draft.slashCommand.trimmingCharacters(in: .whitespaces).isEmpty &&
        draft.urlTemplate.contains("{query}")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(draft.name.isEmpty ? "新建搜索引擎" : "编辑 · \(draft.name)")
                    .font(.headline)
                Spacer()
                Button("取消") { onCancel() }
                Button("保存") { onSave(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            .padding()

            Divider()

            Form {
                Section("基本信息") {
                    HStack {
                        Text("名称")
                            .frame(width: 80, alignment: .trailing)
                        TextField("例：Google", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text("Slash 命令")
                            .frame(width: 80, alignment: .trailing)
                        HStack(spacing: 2) {
                            Text("/")
                                .foregroundStyle(.secondary)
                            TextField("例：askgoogle", text: $draft.slashCommand)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    HStack {
                        Text("图标")
                            .frame(width: 80, alignment: .trailing)
                        TextField("SF Symbol 名称，例：magnifyingglass", text: $draft.iconName)
                            .textFieldStyle(.roundedBorder)
                        if !draft.iconName.isEmpty {
                            Image(systemName: draft.iconName)
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                        }
                    }
                }

                Section {
                    TextField("https://example.com/search?q={query}", text: $draft.urlTemplate)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                    if !draft.urlTemplate.contains("{query}") {
                        Text("URL 模板必须包含 {query} 占位符")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("选中文字时将把 {query} 替换为选中内容并在浏览器中打开。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("URL 模板")
                }

                Section("快捷键（选中文字时触发）") {
                    HStack {
                        Text("当前快捷键")
                            .frame(width: 100, alignment: .leading)
                        Spacer()
                        if recordingShortcut {
                            ShortcutRecorder(
                                onRecord: { binding in
                                    draft.shortcut = binding
                                    recordingShortcut = false
                                },
                                onCancel: { recordingShortcut = false }
                            )
                            .frame(width: 160)
                        } else {
                            HStack(spacing: 8) {
                                Button {
                                    recordingShortcut = true
                                } label: {
                                    Text(draft.shortcutDisplayString)
                                        .font(.system(.body, design: .monospaced))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .frame(minWidth: 80)
                                        .background(.quaternary.opacity(0.5))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)

                                if draft.shortcut != nil {
                                    Button {
                                        draft.shortcut = nil
                                    } label: {
                                        Image(systemName: "xmark.circle")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                    .help("清除快捷键")
                                }
                            }
                        }
                    }
                    Text("点击快捷键区域后按下新的组合键（需包含 ⌥、⌘ 或 ⌃ 修饰键）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 480, height: 460)
    }
}
