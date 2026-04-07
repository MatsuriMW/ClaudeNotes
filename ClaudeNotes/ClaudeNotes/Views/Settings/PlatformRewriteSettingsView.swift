import SwiftUI

struct PlatformRewriteSettingsView: View {
    @State private var settings = PlatformRewriteSettings.shared
    @State private var editingPlatform: SocialPlatform? = nil
    @State private var isAddingNew = false
    @State private var showResetAlert = false

    var body: some View {
        Form {
            Section {
                Text("在编辑器中输入 / 后，可以在弹出菜单里选择「改写为 [平台]」。光标所在段落或列表块将被发送给 Claude，改写结果显示在右侧第二编辑器中，原文保持不变。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(settings.platforms) { platform in
                    PlatformRow(platform: platform) {
                        editingPlatform = platform
                    } onDelete: {
                        settings.platforms.removeAll { $0.id == platform.id }
                        settings.save()
                    }
                }
                .onMove { from, to in
                    settings.platforms.move(fromOffsets: from, toOffset: to)
                    settings.save()
                }
            } header: {
                HStack {
                    Text("改写平台")
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

            Section {
                HStack {
                    Spacer()
                    Button("恢复默认平台列表", role: .destructive) {
                        showResetAlert = true
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .alert("恢复默认？", isPresented: $showResetAlert) {
            Button("恢复", role: .destructive) { settings.resetToDefaults() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有自定义改写平台将被替换为内置默认列表。")
        }
        .sheet(item: $editingPlatform) { platform in
            PlatformEditSheet(platform: platform) { updated in
                if let idx = settings.platforms.firstIndex(where: { $0.id == updated.id }) {
                    settings.platforms[idx] = updated
                    settings.save()
                }
                editingPlatform = nil
            } onCancel: {
                editingPlatform = nil
            }
        }
        .sheet(isPresented: $isAddingNew) {
            PlatformEditSheet(platform: SocialPlatform(
                name: "", slashCommand: "to",
                iconName: "sparkles",
                rewritePrompt: "请将【原文】按照以下风格改写：\n\n直接输出改写后的内容，不要加任何解释。"
            )) { newPlatform in
                settings.platforms.append(newPlatform)
                settings.save()
                isAddingNew = false
            } onCancel: {
                isAddingNew = false
            }
        }
    }
}

// MARK: - Platform Row

private struct PlatformRow: View {
    let platform: SocialPlatform
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: platform.iconName)
                .foregroundStyle(.purple)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(platform.name).font(.subheadline)
                Text("/\(platform.slashCommand)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

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

// MARK: - Platform Edit Sheet

private struct PlatformEditSheet: View {
    @State private var draft: SocialPlatform
    let onSave: (SocialPlatform) -> Void
    let onCancel: () -> Void

    init(platform: SocialPlatform,
         onSave: @escaping (SocialPlatform) -> Void,
         onCancel: @escaping () -> Void) {
        _draft = State(initialValue: platform)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !draft.slashCommand.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(draft.name.isEmpty ? "新建改写平台" : "编辑 · \(draft.name)")
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
                        Text("平台名称")
                            .frame(width: 80, alignment: .trailing)
                        TextField("例：小红书", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text("Slash 命令")
                            .frame(width: 80, alignment: .trailing)
                        HStack(spacing: 2) {
                            Text("/")
                                .foregroundStyle(.secondary)
                            TextField("例：toxiaohongshu", text: $draft.slashCommand)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    HStack {
                        Text("图标")
                            .frame(width: 80, alignment: .trailing)
                        TextField("SF Symbol 名称，例：heart.circle", text: $draft.iconName)
                            .textFieldStyle(.roundedBorder)
                        if !draft.iconName.isEmpty {
                            Image(systemName: draft.iconName)
                                .foregroundStyle(.purple)
                                .frame(width: 20)
                        }
                    }
                }

                Section {
                    TextEditor(text: $draft.rewritePrompt)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 160)
                    Text("提示词会连同「【原文】+ 原文内容」一起发给 Claude。直接描述改写风格要求即可，Claude 会自动理解。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("改写提示词（Rewrite Prompt）")
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 500, height: 520)
    }
}
