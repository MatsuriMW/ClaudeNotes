import SwiftUI
import AppKit

struct ShortcutSettingsView: View {
    @State private var settings = ShortcutSettings.shared
    @State private var recordingAction: ShortcutAction?
    @State private var showResetAlert = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("点击快捷键区域后按下新的组合键即可修改。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("全部恢复默认", role: .destructive) {
                        showResetAlert = true
                    }
                    .controlSize(.small)
                    .alert("确认恢复默认快捷键？", isPresented: $showResetAlert) {
                        Button("恢复", role: .destructive) {
                            settings.resetToDefaults()
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("所有自定义快捷键将被重置为默认值。")
                    }
                }
            }

            ForEach(ShortcutCategory.allCases, id: \.self) { category in
                Section(category.rawValue) {
                    let actions = ShortcutAction.allCases.filter { $0.category == category }
                    ForEach(actions) { action in
                        ShortcutRow(
                            action: action,
                            binding: settings.binding(for: action),
                            isRecording: recordingAction == action,
                            defaultBinding: ShortcutSettings.defaults[action]!,
                            onStartRecording: {
                                recordingAction = action
                            },
                            onBindingChanged: { newBinding in
                                settings.setBinding(newBinding, for: action)
                                recordingAction = nil
                            },
                            onCancel: {
                                recordingAction = nil
                            },
                            onReset: {
                                settings.resetAction(action)
                            }
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcut Row

private struct ShortcutRow: View {
    let action: ShortcutAction
    let binding: ShortcutBinding
    let isRecording: Bool
    let defaultBinding: ShortcutBinding
    let onStartRecording: () -> Void
    let onBindingChanged: (ShortcutBinding) -> Void
    let onCancel: () -> Void
    let onReset: () -> Void

    var isCustomized: Bool {
        binding != defaultBinding
    }

    var body: some View {
        HStack {
            Text(action.displayName)
                .frame(width: 120, alignment: .leading)

            Spacer()

            if isRecording {
                ShortcutRecorder(onRecord: onBindingChanged, onCancel: onCancel)
                    .frame(width: 160)
            } else {
                Button {
                    onStartRecording()
                } label: {
                    HStack(spacing: 4) {
                        Text(binding.displayString)
                            .font(.system(.body, design: .monospaced))
                        if isCustomized {
                            Circle()
                                .fill(.orange)
                                .frame(width: 5, height: 5)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(minWidth: 80)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }

            // Reset single shortcut
            Button {
                onReset()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("恢复默认: \(defaultBinding.displayString)")
            .opacity(isCustomized ? 1 : 0.3)
            .disabled(!isCustomized)
        }
    }
}

// MARK: - Shortcut Recorder (captures key events)

struct ShortcutRecorder: NSViewRepresentable {
    var onRecord: (ShortcutBinding) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> ShortcutRecorderField {
        let field = ShortcutRecorderField()
        field.onRecord = onRecord
        field.onCancel = onCancel
        field.isBordered = true
        field.isEditable = false
        field.isSelectable = false
        field.alignment = .center
        field.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        field.stringValue = "请按下快捷键..."
        field.backgroundColor = .controlAccentColor.withAlphaComponent(0.1)

        // Become first responder to capture key events
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }

        return field
    }

    func updateNSView(_ nsView: ShortcutRecorderField, context: Context) {}
}

class ShortcutRecorderField: NSTextField {
    var onRecord: ((ShortcutBinding) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }

        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Escape cancels recording
        if event.keyCode == 53 { // Escape
            onCancel?()
            return true
        }

        // Must have at least one modifier (otherwise it's just typing)
        let hasCmd = flags.contains(.command)
        let hasShift = flags.contains(.shift)
        let hasCtrl = flags.contains(.control)
        let hasOpt = flags.contains(.option)

        guard hasCmd || hasCtrl || hasOpt else {
            return true // Absorb but don't record
        }

        // Don't record standalone modifier keys
        guard !key.isEmpty, key != " " || (hasCmd || hasCtrl) else {
            return true
        }

        let binding = ShortcutBinding(
            key: key,
            command: hasCmd,
            shift: hasShift,
            control: hasCtrl,
            option: hasOpt
        )

        onRecord?(binding)
        return true
    }

    override func keyDown(with event: NSEvent) {
        // Also handle keyDown for keys that don't trigger performKeyEquivalent
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == 53 {
            onCancel?()
            return
        }

        let hasCmd = flags.contains(.command)
        let hasCtrl = flags.contains(.control)
        let hasOpt = flags.contains(.option)

        guard hasCmd || hasCtrl || hasOpt else { return }
        guard !key.isEmpty else { return }

        let binding = ShortcutBinding(
            key: key,
            command: hasCmd,
            shift: flags.contains(.shift),
            control: hasCtrl,
            option: hasOpt
        )

        onRecord?(binding)
    }
}
