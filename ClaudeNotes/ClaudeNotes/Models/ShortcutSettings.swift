import Foundation
import AppKit
import SwiftUI

// MARK: - Shortcut Action

enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    // Text formatting
    case bold
    case italic
    case strikethrough
    case inlineCode
    case codeBlock
    // Structure
    case heading1, heading2, heading3, heading4, heading5, heading6
    case unorderedList, orderedList, taskList
    case blockquote, horizontalRule
    // Insert
    case link, image
    // Editing
    case indent, outdent
    case panguSpacing
    // View
    case togglePreview
    case toggleOutline
    case revealInFinder
    // AI
    case claudeWrite
    case generateInbox
    case inboxTopics
    // Search
    case findInNote
    case findReplaceInNote
    case searchAllNotes
    // Selection
    case selectLine
    case selectWord
    case selectSentence
    case selectParagraph
    case selectList
    // Deselection (reverse)
    case deselectLine
    case deselectWord
    case deselectSentence
    case deselectParagraph
    case deselectList
    // Folding
    case foldBlock
    case unfoldBlock
    case foldAll
    case unfoldAll
    // Line movement
    case moveLineUp
    case moveLineDown
    // Library file movement
    case moveLibraryFileUp
    case moveLibraryFileDown
    // Tab navigation
    case selectPreviousTab
    case selectNextTab

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bold: return "加粗"
        case .italic: return "斜体"
        case .strikethrough: return "删除线"
        case .inlineCode: return "行内代码"
        case .codeBlock: return "代码块"
        case .heading1: return "标题 H1"
        case .heading2: return "标题 H2"
        case .heading3: return "标题 H3"
        case .heading4: return "标题 H4"
        case .heading5: return "标题 H5"
        case .heading6: return "标题 H6"
        case .unorderedList: return "无序列表"
        case .orderedList: return "有序列表"
        case .taskList: return "任务列表"
        case .blockquote: return "引用"
        case .horizontalRule: return "分割线"
        case .link: return "链接"
        case .image: return "图片"
        case .indent: return "缩进"
        case .outdent: return "取消缩进"
        case .panguSpacing: return "盘古之白"
        case .togglePreview: return "编辑/预览切换"
        case .toggleOutline: return "大纲面板"
        case .revealInFinder: return "在访达中显示"
        case .claudeWrite: return "续写（再按停止）"
        case .generateInbox: return "生成每日简报"
        case .inboxTopics: return "简报订阅设置"
        case .findInNote: return "搜索当前笔记"
        case .findReplaceInNote: return "搜索与替换"
        case .searchAllNotes: return "搜索所有笔记"
        case .selectLine: return "选择行（再按扩展）"
        case .selectWord: return "选择词"
        case .selectSentence: return "选择句"
        case .selectParagraph: return "选择段落"
        case .selectList: return "选择列表分支"
        case .deselectLine: return "反选行"
        case .deselectWord: return "反选词"
        case .deselectSentence: return "反选句"
        case .deselectParagraph: return "反选段落"
        case .deselectList: return "反选列表分支"
        case .foldBlock: return "折叠当前块"
        case .unfoldBlock: return "展开当前块"
        case .foldAll: return "折叠所有标题和列表"
        case .unfoldAll: return "展开所有折叠"
        case .moveLineUp: return "上移当前行/段"
        case .moveLineDown: return "下移当前行/段"
        case .moveLibraryFileUp: return "上移外部文件夹文件"
        case .moveLibraryFileDown: return "下移外部文件夹文件"
        case .selectPreviousTab: return "切换到上一个标签"
        case .selectNextTab: return "切换到下一个标签"
        }
    }

    var category: ShortcutCategory {
        switch self {
        case .bold, .italic, .strikethrough, .inlineCode, .codeBlock:
            return .textFormat
        case .heading1, .heading2, .heading3, .heading4, .heading5, .heading6,
             .unorderedList, .orderedList, .taskList, .blockquote, .horizontalRule:
            return .structure
        case .link, .image:
            return .insert
        case .indent, .outdent, .panguSpacing, .moveLineUp, .moveLineDown,
             .moveLibraryFileUp, .moveLibraryFileDown,
             .selectPreviousTab, .selectNextTab:
            return .editing
        case .togglePreview, .toggleOutline, .revealInFinder:
            return .view
        case .claudeWrite, .generateInbox, .inboxTopics:
            return .ai
        case .findInNote, .findReplaceInNote, .searchAllNotes:
            return .search
        case .selectLine, .selectWord, .selectSentence, .selectParagraph, .selectList,
             .deselectLine, .deselectWord, .deselectSentence, .deselectParagraph, .deselectList:
            return .selection
        case .foldBlock, .unfoldBlock, .foldAll, .unfoldAll:
            return .editing
        }
    }

    /// Convert to MarkdownFormat (if applicable)
    var markdownFormat: MarkdownFormat? {
        switch self {
        case .bold: return .bold
        case .italic: return .italic
        case .strikethrough: return .strikethrough
        case .inlineCode: return .inlineCode
        case .codeBlock: return .codeBlock
        case .heading1: return .heading(1)
        case .heading2: return .heading(2)
        case .heading3: return .heading(3)
        case .heading4: return .heading(4)
        case .heading5: return .heading(5)
        case .heading6: return .heading(6)
        case .unorderedList: return .unorderedList
        case .orderedList: return .orderedList
        case .taskList: return .taskList
        case .blockquote: return .blockquote
        case .horizontalRule: return .horizontalRule
        case .link: return .link
        case .image: return .image
        case .indent: return .indent
        case .outdent: return .outdent
        case .panguSpacing, .togglePreview, .toggleOutline, .revealInFinder, .claudeWrite,
             .generateInbox, .inboxTopics,
             .findInNote, .findReplaceInNote, .searchAllNotes,
             .selectLine, .selectWord, .selectSentence, .selectParagraph, .selectList,
             .deselectLine, .deselectWord, .deselectSentence, .deselectParagraph, .deselectList,
             .foldBlock, .unfoldBlock, .foldAll, .unfoldAll,
             .moveLineUp, .moveLineDown,
             .moveLibraryFileUp, .moveLibraryFileDown,
             .selectPreviousTab, .selectNextTab:
            return nil
        }
    }
}

enum ShortcutCategory: String, CaseIterable {
    case textFormat = "文本格式"
    case structure = "结构"
    case insert = "插入"
    case editing = "编辑"
    case view = "视图"
    case ai = "AI 功能"
    case search = "搜索"
    case selection = "智能选择"
}

// MARK: - Shortcut Binding

struct ShortcutBinding: Codable, Equatable {
    var key: String       // lowercased, e.g. "b", "1", "x"
    var command: Bool
    var shift: Bool
    var control: Bool
    var option: Bool

    /// Human-readable display string
    var displayString: String {
        var parts: [String] = []
        if control { parts.append("⌃") }
        if option { parts.append("⌥") }
        if shift { parts.append("⇧") }
        if command { parts.append("⌘") }

        let keyDisplay: String
        switch key {
        case "[":       keyDisplay = "["
        case "]":       keyDisplay = "]"
        case ".":       keyDisplay = "."
        case " ":       keyDisplay = "Space"
        case "\r":      keyDisplay = "↩"
        case "\u{F700}": keyDisplay = "↑"
        case "\u{F701}": keyDisplay = "↓"
        case "\u{F702}": keyDisplay = "←"
        case "\u{F703}": keyDisplay = "→"
        default: keyDisplay = key.uppercased()
        }
        parts.append(keyDisplay)
        return parts.joined()
    }

    /// SwiftUI KeyEquivalent for use with `.keyboardShortcut`
    var swiftUIKey: KeyEquivalent { KeyEquivalent(key.first ?? "p") }

    /// SwiftUI EventModifiers for use with `.keyboardShortcut`
    var swiftUIModifiers: EventModifiers {
        var mods: EventModifiers = []
        if command { mods.insert(.command) }
        if shift   { mods.insert(.shift) }
        if control { mods.insert(.control) }
        if option  { mods.insert(.option) }
        return mods
    }

    /// Check if a keyboard event matches this binding
    func matches(key eventKey: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        let hasCmd = flags.contains(.command)
        let hasShift = flags.contains(.shift)
        let hasCtrl = flags.contains(.control)
        let hasOpt = flags.contains(.option)

        return eventKey.lowercased() == key.lowercased()
            && hasCmd == command
            && hasShift == shift
            && hasCtrl == control
            && hasOpt == option
    }
}

// MARK: - Settings Store

@Observable
final class ShortcutSettings {
    static let shared = ShortcutSettings()

    private let userDefaultsKey = "shortcutBindings"
    private(set) var bindings: [ShortcutAction: ShortcutBinding]

    init() {
        bindings = Self.loadFromDefaults() ?? Self.defaults
    }

    func binding(for action: ShortcutAction) -> ShortcutBinding {
        bindings[action] ?? Self.defaults[action]!
    }

    func setBinding(_ binding: ShortcutBinding, for action: ShortcutAction) {
        bindings[action] = binding
        saveToDefaults()
    }

    func resetToDefaults() {
        bindings = Self.defaults
        saveToDefaults()
    }

    func resetAction(_ action: ShortcutAction) {
        bindings[action] = Self.defaults[action]
        saveToDefaults()
    }

    /// Look up which action matches a key event
    func action(forKey key: String, modifiers: NSEvent.ModifierFlags) -> ShortcutAction? {
        for (action, binding) in bindings {
            if binding.matches(key: key, modifiers: modifiers) {
                return action
            }
        }
        return nil
    }

    // MARK: - Persistence

    private func saveToDefaults() {
        let dict = bindings.reduce(into: [String: ShortcutBinding]()) { result, pair in
            result[pair.key.rawValue] = pair.value
        }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    private static func loadFromDefaults() -> [ShortcutAction: ShortcutBinding]? {
        guard let data = UserDefaults.standard.data(forKey: "shortcutBindings"),
              let dict = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) else {
            return nil
        }
        var result: [ShortcutAction: ShortcutBinding] = [:]
        for (key, value) in dict {
            if let action = ShortcutAction(rawValue: key) {
                result[action] = value
            }
        }
        return result
    }

    // MARK: - Defaults

    static let defaults: [ShortcutAction: ShortcutBinding] = [
        .bold:           ShortcutBinding(key: "b", command: true, shift: false, control: false, option: false),
        .italic:         ShortcutBinding(key: "i", command: true, shift: false, control: false, option: false),
        .strikethrough:  ShortcutBinding(key: "x", command: true, shift: true,  control: false, option: false),
        .inlineCode:     ShortcutBinding(key: "e", command: true, shift: false, control: false, option: false),
        .codeBlock:      ShortcutBinding(key: "c", command: true, shift: true,  control: false, option: false),
        .heading1:       ShortcutBinding(key: "1", command: true, shift: false, control: false, option: false),
        .heading2:       ShortcutBinding(key: "2", command: true, shift: false, control: false, option: false),
        .heading3:       ShortcutBinding(key: "3", command: true, shift: false, control: false, option: false),
        .heading4:       ShortcutBinding(key: "4", command: true, shift: false, control: false, option: false),
        .heading5:       ShortcutBinding(key: "5", command: true, shift: false, control: false, option: false),
        .heading6:       ShortcutBinding(key: "6", command: true, shift: false, control: false, option: false),
        .link:           ShortcutBinding(key: "k", command: true, shift: false, control: false, option: false),
        .image:          ShortcutBinding(key: "k", command: true, shift: true,  control: false, option: false),
        .unorderedList:  ShortcutBinding(key: "8", command: true, shift: true,  control: false, option: false),
        .orderedList:    ShortcutBinding(key: "7", command: true, shift: true,  control: false, option: false),
        .taskList:       ShortcutBinding(key: "9", command: true, shift: true,  control: false, option: false),
        .blockquote:     ShortcutBinding(key: ".", command: true, shift: true,  control: false, option: false),
        .horizontalRule: ShortcutBinding(key: "h", command: true, shift: true,  control: false, option: false),
        .indent:         ShortcutBinding(key: "]", command: true, shift: false, control: false, option: false),
        .outdent:        ShortcutBinding(key: "[", command: true, shift: false, control: false, option: false),
        .panguSpacing:   ShortcutBinding(key: "p", command: true, shift: true,  control: false, option: false),
        .togglePreview:   ShortcutBinding(key: "p", command: true, shift: false, control: false, option: true),
        .toggleOutline:   ShortcutBinding(key: "o", command: true, shift: false, control: false, option: true),
        .revealInFinder:  ShortcutBinding(key: "r", command: true, shift: true,  control: false, option: false),
        .claudeWrite:       ShortcutBinding(key: "k", command: true, shift: false, control: false, option: true),
        .generateInbox:     ShortcutBinding(key: "g", command: true, shift: false, control: false, option: false),
        .inboxTopics:      ShortcutBinding(key: "g", command: true, shift: true,  control: false, option: false),
        // Search
        .findInNote:        ShortcutBinding(key: "f", command: true, shift: false, control: false, option: false),
        .findReplaceInNote: ShortcutBinding(key: "f", command: true, shift: true,  control: false, option: false),
        .searchAllNotes:    ShortcutBinding(key: "o", command: true, shift: true,  control: false, option: false),
        // Selection
        .selectLine:      ShortcutBinding(key: "l", command: true, shift: false, control: false, option: false),
        .selectWord:      ShortcutBinding(key: "d", command: true, shift: false, control: false, option: false),
        .selectSentence:  ShortcutBinding(key: "s", command: true, shift: false, control: false, option: true),
        .selectParagraph: ShortcutBinding(key: "a", command: true, shift: false, control: false, option: true),
        .selectList:      ShortcutBinding(key: "l", command: true, shift: false, control: false, option: true),
        // Deselection (Shift variants)
        .deselectLine:      ShortcutBinding(key: "l", command: true, shift: true, control: false, option: false),
        .deselectWord:      ShortcutBinding(key: "d", command: true, shift: true, control: false, option: false),
        .deselectSentence:  ShortcutBinding(key: "s", command: true, shift: true, control: false, option: true),
        .deselectParagraph: ShortcutBinding(key: "a", command: true, shift: true, control: false, option: true),
        .deselectList:      ShortcutBinding(key: "l", command: true, shift: true, control: false, option: true),
        // Folding
        .foldBlock:   ShortcutBinding(key: "[", command: true, shift: false, control: false, option: true),
        .unfoldBlock:  ShortcutBinding(key: "]", command: true, shift: false, control: false, option: true),
        .foldAll:    ShortcutBinding(key: "[", command: true, shift: true,  control: false, option: true),
        .unfoldAll:  ShortcutBinding(key: "]", command: true, shift: true,  control: false, option: true),
        // Line movement (⌥↑ / ⌥↓)
        .moveLineUp:   ShortcutBinding(key: "\u{F700}", command: false, shift: false, control: false, option: true),
        .moveLineDown: ShortcutBinding(key: "\u{F701}", command: false, shift: false, control: false, option: true),
        // Library file movement (⌘⌥U / ⌘⌥D)
        .moveLibraryFileUp:   ShortcutBinding(key: "u", command: true, shift: false, control: false, option: true),
        .moveLibraryFileDown: ShortcutBinding(key: "d", command: true, shift: false, control: false, option: true),
        // Tab navigation (⌘⇧[ / ⌘⇧])
        .selectPreviousTab: ShortcutBinding(key: "[", command: true, shift: true, control: false, option: false),
        .selectNextTab:     ShortcutBinding(key: "]", command: true, shift: true, control: false, option: false),
    ]
}
